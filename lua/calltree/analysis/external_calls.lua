--- analysis/external_calls.lua — cross-function call analysis for calltree.nvim.
---
--- Analyzes which project functions the cursor function calls by:
---   1. Collecting top-level call expressions inside the cursor function's body
---   2. For each call, resolving its definition via LSP
---   3. Filtering out local nested functions, external-project files, and
---      declarations without bodies
---   4. Resolving require() imports to find the real function definition
---
--- Pure Lua, no Neovim dependencies.

local utils          = require("calltree.utils")
local walker         = require("calltree.treesitter.walker")
local debug_mod      = require("calltree.utils.debug")
local definition_body = require("calltree.analysis.definition_body")
local types           = require("calltree.domain.types")
local lsp_client      = require("calltree.providers.lsp_client")  -- Item 6 & 17: for safe_request
local fifo_cache      = require("calltree.utils.fifo_cache")       -- Item 19: bounded module_cache

local M = {}

------------------------------------------------------------------------------
-- Forward declarations.
-- _maybe_warn_all_unresolved and _run_resolved_call_filters are defined
-- later in this file (after the sub-checks they call), but M.analyze /
-- M._analyze_resolved_call reference them. Lua locals must be declared
-- before use, so we forward-declare here and assign the function bodies
-- below. This keeps the file readable (main entry points first, helpers
-- after) without resorting to globals.
------------------------------------------------------------------------------
local _maybe_warn_all_unresolved
local _run_resolved_call_filters

-------------------------------------------------------------------------------
-- Configurable stdlib path patterns (plain substring match).
--
-- Matched against the absolute file path of a definition to heuristically
-- classify a call as stdlib when the LSP does not provide SymbolTag information.
-- The match is case‑sensitive; add entries only when they reliably indicate
-- a standard‑library or SDK source file.
--
-- Extracted as a module‑level table so callers can extend or override via:
--   M.STDLIB_PATH_PATTERNS = { "/my/custom/sdk/", … }
-- This fixes the "configurability gap" where asdf, nix, homebrew Cellar, venv,
-- and similar installations were misclassified as non‑stdlib.
-------------------------------------------------------------------------------
M.STDLIB_PATH_PATTERNS = {
  -- Rust
  "rustup/toolchains/",          -- ~/.rustup/toolchains/…/rustlib/…
  "/rustlib/src/rust/library/",  -- Rust stdlib source
  "/rustlib/src/rust/core/",     -- Rust core source

  -- C / C++
  "/usr/include/",               -- system headers (Linux / BSD)
  "/usr/local/include/",         -- locally built / package manager headers
  "/Library/Developer/",         -- macOS SDK (Xcode)

  -- Python
  "/usr/lib/python",             -- system stdlib (unix)
  "/usr/local/lib/python",       -- system stdlib (local installation)
  "/typeshed/",                  -- Pyright / Pylance bundled typeshed stubs

  -- Lua (lua‑language‑server)
  "/lua-language-server",        -- binary install tmp dir
  "/meta/Lua",                   -- Lua stdlib meta files
  "/meta/LuaJIT",                -- LuaJIT stdlib meta files
  "/meta/builtin",               -- builtin meta files

  -- Go
  "/go/src/",                    -- GOROOT/src/… (any OS, e.g. /usr/local/go/src/)

  -- TypeScript / JavaScript (tsserver)
  "/typescript/lib/",            -- bundled lib.*.d.ts files (lib.es*.d.ts)

  -- Java (OpenJDK, Oracle, etc.)
  "/jdk",                        -- JDK home path (e.g. …/java-17-openjdk/…)
  "/jre/lib/",                   -- runtime library (rt.jar, modules)

  -- Ruby
  "/lib/ruby/",                  -- Ruby stdlib (e.g. /usr/lib/ruby/3.0.0/)

  -- Swift
  "/usr/lib/swift/",             -- Swift stdlib (Linux)
  "/usr/share/swift/",           -- Swift SDK overlays

  -- .NET (Core / 5+)
  "/dotnet/shared/Microsoft.NETCore.App/", -- runtime & BCL

  -- PHP
  "/usr/share/php/",             -- PHP extensions & built‑ins
  "/usr/lib/php/",               -- alternative location

  -- macOS system frameworks
  "/System/Library/Frameworks/",
}



------------------------------------------------------------------------------
-- Shared helper: construct an external_call entry table.
-- Previously this exact table shape was duplicated 6× across M.analyze,
-- _check_project_scope, _check_has_body, _set_stdlib_flag (nil-uri branch),
-- and _keep_resolved_call. The duplication risked the copies drifting
-- (e.g. one call site forgetting is_stdlib, another using a different
-- call_position convention). Now all sites delegate here.
------------------------------------------------------------------------------
-- Shared helper: construct an external_call entry using the domain-types
-- ExternalCall factory. This ensures the field shape matches the
-- ExternalCall type definition and the returned object is immutable
-- (frozen). All call sites that create external_call entries delegate
-- here so the shape stays consistent.
local function _make_external_call(call_line, call_col, name, definition, status, is_stdlib)
  return types.ExternalCall(call_line + 1, call_col + 1, name, definition, status, is_stdlib)
end

------------------------------------------------------------------------------
-- Main external call analysis
------------------------------------------------------------------------------

--- Run the cross-function call analysis.
--- @param ctx table analysis context
--- @param dbg table debug collector
--- @param state table analysis state (func_node, cur_start_line, cur_closed_end)
--- @param result table the result table to populate (result.external_calls)
function M.analyze(ctx, dbg, state, result)
  local lsp = ctx.lsp_client
  local ts = ctx.treesitter
  local uri = utils.path_to_uri(ctx.file_path)
  local func_node = state.func_node
  local cur_start_line = state.cur_start_line
  local cur_closed_end = state.cur_closed_end

  -- Cache for parsed module files: resolved_path -> { root, func_cache }
  -- func_cache: suffix -> { node, range } (avoids re-searching the same module)
  -- Item 19 (1.2.4 refactor): the previous plain-table cache was unbounded
  -- (could grow without limit on a large analysis run with many distinct
  -- module imports). Replaced with a `fifo_cache` instance capped at 128
  -- entries, matching the cap used by file_parser and callers.tree_cache.
  -- The cache shape ({root, func_cache}) is unchanged.
  local module_cache = fifo_cache.new(128)

  -- Get cwd (lazily).
  local cwd = nil
  if ctx.getcwd then
    local ok_cwd, c = pcall(ctx.getcwd)
    if ok_cwd and c ~= nil then
      cwd = c
      dbg:set_cwd(cwd)
    else
      if not ok_cwd then
        dbg:error("external_calls.getcwd", c)
      end
      dbg:warning("getcwd() returned nil or failed; project-scope filtering will be skipped")
    end
  else
    dbg:warning("ctx.getcwd not provided; project-scope filtering will be skipped")
  end

  local calls = walker.collect_top_level_calls(func_node)
  dbg:set("total_calls", #calls)

  for _, call in ipairs(calls) do
    local call_node = call.node
    local callee_node = call.callee_node
    local call_name = call.name
    local call_range = call.range
    local call_line, call_col = call_range[1], call_range[2]

    -- Item 14 (1.2.4 refactor): use `types.CallDecision` factory instead
    -- of hand-constructing the decision table. The factory centralizes the
    -- field list so any future shape change (e.g. adding a `timestamp`
    -- field) only needs one edit. The previous inline table had the same
    -- fields; the factory guarantees the field names stay in sync with
    -- the DecisionFactory contract.
    local call_decision = types.CallDecision(
      call_line, call_col, call_name,
      debug_mod.node_summary(call_node),
      debug_mod.node_summary(callee_node),
      call.call_node_range)

    -- Try LSP definition using the call-site position.
    -- Item 6 & 17 (1.2.4 refactor): use `lsp_client.safe_request` instead
    -- of hand-rolling the pcall + error-log + dbg:lsp_call pattern. The
    -- previous inline code was identical to the pattern in callers.lua;
    -- both now delegate to safe_request so a future change to the error-
    -- handling or logging format only needs one edit.
    -- Note: external_calls treats the result as "unresolved" when the
    -- pcall fails (def_results_call = nil), while callers treats it as
    -- "empty list" (def_results = {}). safe_request returns {} on failure,
    -- so we convert {} to nil below to preserve the external_calls
    -- "unresolved on failure" semantics.
    local call_position = { line = call_line, character = call_col }
    local def_params = { uri = uri, position = call_position,
                         purpose = "external_call_resolution" }
    local def_results_call = lsp_client.safe_request(
      utils.LSP_METHODS.definition, def_params,
      function() return lsp:definition(uri, call_position) end,
      dbg, "external_calls.lsp_definition")
    -- safe_request returns {} on failure; external_calls expects nil to
    -- trigger the "unresolved" branch. Convert empty-list-from-failure
    -- back to nil. (An empty-list-from-success is also {}, but that
    -- falls through to the same "unresolved" branch via #result == 0,
    -- so the conversion is safe for both cases.)
    if #def_results_call == 0 then
      def_results_call = nil
    end

    if def_results_call == nil or #def_results_call == 0 then
      -- Unresolved.
      table.insert(result.external_calls,
        _make_external_call(call_line, call_col, call_name, nil,
          utils.RESOLUTION_STATUS_UNRESOLVED, nil))
      call_decision.outcome = utils.CALL_OUTCOME_KEPT_UNRESOLVED
      call_decision.reason = "LSP returned no definition for this call site"
      dbg:incr("calls_unresolved")
      dbg:external_call_decision(call_decision)
    else
      -- Review 4.3: `#def_results_call == 0` is unreliable for sparse / nil-
      -- holed arrays (Lua's `#` is undefined on `{[1]=nil, [2]=loc}`).
      -- The defensive `opts.def_results[1]` lookup in M._analyze_resolved_call
      -- already covers the sparse case, so this branch is only entered
      -- when `#def_results_call > 0` (which guarantees [1] is non-nil in
      -- any well-formed list). No change needed here; the comment documents
      -- why this is safe.
      -- Refactored: previously 12 positional args; now packed into
      -- a single `opts` table to make the call site readable and
      -- robust against argument-order mistakes.
      local opts = {
        call_name      = call_name,
        call_line      = call_line,
        call_col       = call_col,
        def_results    = def_results_call,
        cur_start_line = cur_start_line,
        cur_closed_end = cur_closed_end,
        cur_body_start_line = state.cur_body_start_line,
        cur_body_start_col  = state.cur_body_start_col,
        cwd            = cwd,
        result         = result,
        module_cache   = module_cache,
      }
      M._analyze_resolved_call(ctx, dbg, call_decision, opts)
      dbg:external_call_decision(call_decision)
    end
  end

  _maybe_warn_all_unresolved(dbg)
end

------------------------------------------------------------------------------
-- _maybe_warn_all_unresolved: emit a warning when EVERY external call was
-- unresolved (a strong signal that LSP definition requests are broken —
-- e.g. LSP not attached, server crashed, timeouts).
-- Extracted from M.analyze (was inline at the end of the function) so
-- M.analyze reads as a straight loop and the warning logic is testable
-- in isolation.
------------------------------------------------------------------------------
_maybe_warn_all_unresolved = function(dbg)
  -- Only meaningful when debug is enabled (the NoopCollector's `data`
  -- sentinel returns nil on __index, so unguarded access would crash).
  if dbg.get == nil or dbg:get() == nil then return end
  local summary = dbg.data.summary
  if summary == nil then return end
  if type(summary.total_calls) ~= "number" then return end
  if type(summary.calls_unresolved) ~= "number" then return end
  if summary.total_calls > 0 and summary.calls_unresolved == summary.total_calls then
    dbg:warning(
      "ALL " .. summary.total_calls .. " external calls were unresolved. " ..
      "This strongly suggests the LSP definition requests are not returning " ..
      "results — check debug.lsp_adapter_diagnostics for client_count, " ..
      "timeouts, and errors.")
  end
end

-- a. In-scope (local nested function) check: if the definition site is
-- inside the cursor function's lexical body, discard it. Returns true if
-- the call was discarded (caller should short-circuit).
--
-- Both the start line and end line of the definition must fall within the
-- cursor function's range. This avoids false positives when the cursor
-- function spans a large range (e.g. containing closures/nested
-- functions) and the def's start line happens to fall inside but the
-- actual definition is in a nested scope.
--
-- Additionally, the definition must start AT OR AFTER the function body's
-- start position (cur_body_start_line / cur_body_start_col). This excludes
-- parameter declarations on the function signature line, which clangd
-- returns as "definition" for function-pointer-parameter calls in C/C++.
-- Without this refinement, a call like `fp()` (where fp is a function-
-- pointer parameter) gets its LSP definition pointing at the parameter
-- declaration on the signature line — which falls in the function's line
-- range but is NOT a nested function definition. The body-start check
-- correctly classifies it as out-of-scope.
local function _check_in_scope(cc)
  local in_scope = false
  if cc.def.uri == cc.uri and cc.def.range and cc.def.range.start and cc.def.range["end"]
     and cc.cur_start_line ~= nil and cc.cur_closed_end ~= nil then
    local ds_line = cc.def.range.start.line
    local ds_col  = cc.def.range.start.character
    local de_line = cc.def.range["end"].line
    if ds_line >= cc.cur_start_line and ds_line <= cc.cur_closed_end
       and de_line >= cc.cur_start_line and de_line <= cc.cur_closed_end then
      -- Within the function's overall line range. Now refine: the
      -- definition must start at or after the body's start position.
      -- cur_body_start_line defaults to cur_start_line (with col 0) when
      -- no body child was found, so this check degrades to the previous
      -- behavior for languages/functions where body detection fails.
      -- Review 1.9: `cc.cur_body_start_line` and `cc.cur_start_line` can
      -- BOTH be nil (e.g. when analyzer._locate_cursor_function failed
      -- to extract the function range). Default `body_line` to -1 so the
      -- `ds_line > body_line` comparison always returns true (the def is
      -- always after -1), preserving the original "keep nested fn calls"
      -- behavior. Previously a nil `body_line` would crash with
      -- "attempt to compare number with nil".
      local body_line = cc.cur_body_start_line or cc.cur_start_line or -1
      local body_col  = cc.cur_body_start_col or 0
      local after_body_start = false
      if ds_line > body_line then
        after_body_start = true
      elseif ds_line == body_line and ds_col >= body_col then
        after_body_start = true
      end
      in_scope = after_body_start
    end
  end
  if in_scope then
    cc.call_decision.outcome = utils.CALL_OUTCOME_DISCARDED_IN_SCOPE
    cc.call_decision.reason = "definition is inside the cursor function's lexical scope (local nested function)"
    cc.dbg:incr("calls_in_scope")
    return true
  end
  return false
end

-- b. Project-scope check: if the definition file is outside the project
-- (cwd), classify the call. Returns true if discarded (caller should
-- short-circuit), false if the call should proceed to the body check.
--
-- Classification:
--   - When cwd is nil (couldn't be determined): keep the call (default
--     to "in project"), record a warning.
--   - When def_path is under cwd: in_project = true, proceed.
--   - When def_path is outside cwd: the call is from an external source
--     (third-party crate, system library that wasn't tagged as stdlib,
--     etc.). We KEEP these as resolved external calls so users can see
--     "you're calling serde_json::to_string here" without the call
--     silently disappearing from the result. The body check is skipped
--     (external crate sources may be huge / have unusual layout).
local function _check_project_scope(cc)
  local in_project = true
  if cc.cwd ~= nil and cc.def_path ~= nil then
    in_project = utils.is_path_under(cc.def_path, cc.cwd)
  end
  cc.call_decision.in_project = in_project
  if not in_project then
    -- Keep as external-crate call. is_stdlib was already set by
    -- _set_stdlib_flag (called before us); if it's true we already
    -- short-circuited. So here is_stdlib is false (or nil).
    cc.call_decision.outcome = utils.CALL_OUTCOME_KEPT_EXTERNAL_CRATE
    cc.call_decision.reason = "definition file path '" .. tostring(cc.def_path) ..
      "' is outside project root '" .. tostring(cc.cwd) ..
      "'; kept as external-crate call (is_stdlib=false)"
    table.insert(cc.result.external_calls,
      _make_external_call(cc.call_line, cc.call_col, cc.call_name,
        { file = cc.def_path, function_body_range = nil },
        utils.RESOLUTION_STATUS_RESOLVED, cc.call_decision.is_stdlib or false))
    cc.dbg:incr("calls_kept")
    cc.dbg:incr("calls_outside_project")  -- also count for diagnostics
    return true
  end
  return false
end

-- c. Determine is_stdlib from the LSP definition's tags. Some servers
-- (notably clangd) tag system-header definitions with tag value 256;
-- others use the string forms "system" / "library".
-- As a fallback when the LSP server doesn't tag (e.g. rust-analyzer),
-- also inspect the definition file PATH for typical standard-library
-- locations (`/rustlib/`, `/usr/include/`, `/usr/lib/`, `/Library/Developer/`
-- for macOS SDK, etc.). This is a heuristic — false positives are possible
-- if a project lives under one of these paths, but in practice projects
-- live under the user's home dir or a workspace.
local function _set_stdlib_flag(cc)
  local is_stdlib = false
  local matched_tag = nil
  -- Use the centralized constant from utils/constants.lua. The `or 256`
  -- fallback was dead code — utils.constants always defines this constant
  -- (value 256, a clangd private extension; LSP 3.17 spec only defines
  -- 1=Deprecated and 2=Unnecessary). Removed the fallback to make the
  -- dependency on utils.constants explicit.
  local LSP_TAG_SYSTEM_LIBRARY = utils.LSP_TAG_SYSTEM_LIBRARY
  -- Review 5.5: removed the dead-code string-tag branches
  -- (`tag == "system" / "library"`). Per LSP 3.17 spec, SymbolTag is an
  -- integer enum (1=Deprecated, 2=Unnecessary) — string values are never
  -- sent by spec-compliant servers. The string constants in utils/constants.lua
  -- are kept for backward-compat with non-spec clangd extensions, but the
  -- branches here now check the integer form only (which is what the spec
  -- and clangd actually send).
  -- Simplified the redundant `cc.def.tags and type(cc.def.tags) == "table"`
  -- — `type(x) == "table"` already implies x is non-nil, so the leading
  -- truthiness check is dead.
  if type(cc.def.tags) == "table" then
    for _, tag in ipairs(cc.def.tags) do
      if tag == LSP_TAG_SYSTEM_LIBRARY then
        is_stdlib = true
        matched_tag = tag
        break
      end
      -- Backward-compat: accept the clangd private string-form tag values
      -- ("system"/"library") even though they're not in the LSP spec —
      -- some clangd versions still emit them.
      if type(tag) == "string"
         and (tag == utils.LSP_TAG_STR_SYSTEM or tag == utils.LSP_TAG_STR_LIBRARY) then
        is_stdlib = true
        matched_tag = tag
        break
      end
    end
  end
  -- Path-based heuristic fallback: definition file lives under a known
  -- system / stdlib install location. Critical for rust-analyzer, which
  -- does NOT tag std symbols via LSP SymbolTag.
  -- Uses the configurable M.STDLIB_PATH_PATTERNS table (was 6 inline
  -- string literals) so callers can add patterns for asdf / nix / homebrew
  -- Cellar / venv without editing this function.
  if not is_stdlib and cc.def_path then
    local p = cc.def_path
    for _, pattern in ipairs(M.STDLIB_PATH_PATTERNS) do
      if p:find(pattern, 1, true) then
        is_stdlib = true
        matched_tag = "path_heuristic:" .. pattern
        break
      end
    end
  end
  cc.call_decision.is_stdlib = is_stdlib
  cc.call_decision.matched_tag = matched_tag
end

-- d. Body check: filter out declarations without bodies, resolving
-- require() imports via the definition_body module. Returns true if the
-- call was discarded (no body found).
--
-- Special case: when definition_body.check signals a PARAM_DECLARATION
-- (definition points at a function-pointer-parameter declaration, common
-- with clangd on C/C++ function-pointer calls), the call is kept as
-- UNRESOLVED rather than discarded. This matches the spec requirement
-- that function-pointer calls be marked `resolution_status = "unresolved"`.
local function _check_has_body(cc)
  local has_body, def_func_range_1based, final_def_path, body_detail, module_spec, resolved_module_path =
    definition_body.check(cc.ctx, cc.dbg, cc.def, cc.def_path, cc.call_name, cc.cwd, cc.module_cache)
  cc.call_decision.body_check_detail = body_detail
  cc.call_decision.module_spec = module_spec
  cc.call_decision.resolved_module_path = resolved_module_path

  -- Parameter declaration signal: definition_body detected the def points
  -- at a parameter declaration (function pointer parameter). The call is
  -- real but cannot be resolved to a function body — mark as unresolved.
  -- Uses the centralized PARAM_DECLARATION_PREFIX constant from
  -- definition_body (was an inline string that coupled the two modules).
  local prefix = definition_body.PARAM_DECLARATION_PREFIX
  if has_body and body_detail and body_detail:sub(1, #prefix) == prefix then
    table.insert(cc.result.external_calls,
      _make_external_call(cc.call_line, cc.call_col, cc.call_name, nil,
        utils.RESOLUTION_STATUS_UNRESOLVED, nil))
    cc.call_decision.outcome = utils.CALL_OUTCOME_KEPT_UNRESOLVED
    cc.call_decision.reason = "definition is a parameter declaration (function pointer parameter); call marked unresolved"
    cc.dbg:incr("calls_unresolved")
    cc.dbg:incr("calls_kept")
    -- Short-circuit: do NOT fall through to _keep_resolved_call.
    -- Return true so the caller skips the resolved-keep step.
    return true
  end

  -- Stash for the keep step.
  cc._has_body = has_body
  cc._def_func_range_1based = def_func_range_1based
  cc._final_def_path = final_def_path
  if not has_body then
    cc.call_decision.outcome = utils.CALL_OUTCOME_DISCARDED_NO_BODY
    cc.call_decision.reason = "definition site has no implementation body: " .. (body_detail or "")
    cc.dbg:incr("calls_no_body")
    return true
  end
  return false
end

-- Keep this call as resolved.
local function _keep_resolved_call(cc)
  table.insert(cc.result.external_calls,
    _make_external_call(cc.call_line, cc.call_col, cc.call_name,
      { file = cc._final_def_path, function_body_range = cc._def_func_range_1based },
      utils.RESOLUTION_STATUS_RESOLVED, cc.call_decision.is_stdlib))
  cc.call_decision.outcome = utils.CALL_OUTCOME_KEPT_RESOLVED
  cc.call_decision.reason = "definition resolved and passed all filters"
  cc.call_decision.function_body_range_1based = cc._def_func_range_1based
  cc.dbg:incr("calls_kept")
end

--- Analyze a single resolved call (LSP returned a definition).
---
--- **Refactor note:** this function previously took 12 positional
--- parameters which made call sites error-prone and the signature hard
--- to read. The signature is now `(ctx, dbg, call_decision, opts)` where
--- `opts` is a table carrying all per-call state. This eliminates the
--- argument-order footgun at the single call site in `M.analyze`.
---
--- @param ctx table
--- @param dbg table
--- @param call_decision table the decision record to populate
--- @param opts table {
---   call_name      = string,
---   call_line      = number,
---   call_col       = number,
---   def_results    = table,  -- LSP definition results
---   cur_start_line = number|nil,
---   cur_closed_end = number|nil,
---   cwd            = string|nil,
---   result         = table,
---   module_cache   = table,
--- }
function M._analyze_resolved_call(ctx, dbg, call_decision, opts)
  -- Defensive: opts.def_results[1] might be nil (sparse array or LSP
  -- returned a table with .n but no [1]). The caller (M.analyze) already
  -- filters #def_results == 0, but that doesn't catch the sparse-array
  -- edge case. Bail out gracefully instead of crashing on opts.def_results[1].uri.
  local first_def = opts.def_results and opts.def_results[1]
  if first_def == nil then
    call_decision.outcome = utils.CALL_OUTCOME_KEPT_UNRESOLVED
    call_decision.reason = "LSP returned empty/nil first definition result"
    dbg:incr("calls_unresolved")
    -- Also record it in external_calls so the user sees the call.
    table.insert(opts.result.external_calls,
      _make_external_call(opts.call_line, opts.call_col, opts.call_name, nil,
        utils.RESOLUTION_STATUS_UNRESOLVED, nil))
    return
  end

  -- Pack the per-call state into a single object so the sub-checks below
  -- can be extracted into focused helpers without 8-arg signatures.
  local cc = {
    ctx              = ctx,
    dbg              = dbg,
    call_decision    = call_decision,
    call_name        = opts.call_name,
    call_line        = opts.call_line,
    call_col         = opts.call_col,
    def              = first_def,
    cur_start_line   = opts.cur_start_line,
    cur_closed_end   = opts.cur_closed_end,
    cur_body_start_line = opts.cur_body_start_line,
    cur_body_start_col  = opts.cur_body_start_col,
    cwd              = opts.cwd,
    result           = opts.result,
    module_cache     = opts.module_cache,
    uri              = utils.path_to_uri(ctx.file_path),
    def_path         = first_def.uri and utils.uri_to_path(first_def.uri) or nil,
  }
  cc.call_decision.definition_uri  = first_def.uri
  cc.call_decision.definition_path = cc.def_path

  -- Defensive: if def.uri is nil, _check_in_scope's `cc.def.uri == cc.uri`
  -- would be nil == (a string) = false (OK), but if cc.uri is ALSO nil
  -- (ctx.file_path was nil), nil == nil = true → falsely classified as
  -- in_scope. Guard explicitly: when def.uri is nil, skip the in_scope
  -- check (can't determine scope without a URI) and proceed to stdlib /
  -- project-scope checks.
  --
  -- The two branches below (uri==nil vs uri!=nil) run the same 5-step
  -- filter pipeline (`_set_stdlib_flag` → stdlib short-circuit →
  -- `_check_project_scope` → `_check_has_body` → `_keep_resolved_call`)
  -- differing only in whether `_check_in_scope` is skipped. Extracted
  -- into `_run_resolved_call_filters(cc, skip_in_scope)` so the pipeline
  -- is defined once and both branches stay in sync.
  if first_def.uri == nil then
    -- Review 4.4: when definition.uri is nil we cannot do meaningful
    -- project-scope or body checks — the downstream code would propagate
    -- nil into _check_project_scope (def_path = nil → is_path_under(nil, cwd)
    -- → false → "kept_external_crate" with file=nil) and into
    -- _check_has_body (definition_body.check would crash on nil def_path).
    -- Mark the call as UNRESOLVED instead of letting it flow through the
    -- filters with a nil uri, which matches the spec's intent that calls
    -- whose definition can't be located be marked unresolved.
    if dbg and dbg.warning then
      dbg:warning("external_calls: definition.uri is nil for call '" ..
        tostring(opts.call_name) .. "'; marking as unresolved")
    end
    call_decision.outcome = utils.CALL_OUTCOME_KEPT_UNRESOLVED
    call_decision.reason = "definition.uri is nil; cannot determine project scope or body"
    dbg:incr("calls_unresolved")
    dbg:incr("calls_kept")
    table.insert(opts.result.external_calls,
      _make_external_call(opts.call_line, opts.call_col, opts.call_name, nil,
        utils.RESOLUTION_STATUS_UNRESOLVED, nil))
    return
  end
  return _run_resolved_call_filters(cc, false)
end

------------------------------------------------------------------------------
-- _run_resolved_call_filters: shared 5-step filter pipeline for a resolved
-- external call. Both the uri==nil and uri!=nil branches of
-- M._analyze_resolved_call delegate here so the pipeline stays in sync.
-- @param cc table per-call state (built by M._analyze_resolved_call)
-- @param skip_in_scope boolean when true, skip the in_scope check (used
--   when def.uri is nil and scope cannot be determined)
------------------------------------------------------------------------------
_run_resolved_call_filters = function(cc, skip_in_scope)
  if not skip_in_scope then
    if _check_in_scope(cc) then return end
  end
  -- Set the stdlib flag BEFORE the project-scope check so that
  -- standard-library / system calls (which by definition live outside
  -- the user's project) are NOT discarded by the project-scope filter.
  -- Previously _set_stdlib_flag ran AFTER _check_project_scope, which
  -- meant any stdlib call whose definition file lived under
  -- `/usr/lib/...` or `~/.rustup/...` was silently dropped before we
  -- ever set is_stdlib = true. The user-visible symptom was empty
  -- external_calls for Rust `std::fs::read_to_string(...)` and similar.
  _set_stdlib_flag(cc)
  if cc.call_decision.is_stdlib then
    -- Short-circuit: stdlib calls bypass project-scope filtering and
    -- body checks (stdlib sources may be huge / have unusual layout).
    -- They're kept as resolved external calls with is_stdlib=true.
    cc.call_decision.outcome = utils.CALL_OUTCOME_KEPT_STDLIB
    cc.call_decision.reason = "definition tagged as standard library / system; kept without project-scope or body check"
    table.insert(cc.result.external_calls,
      _make_external_call(cc.call_line, cc.call_col, cc.call_name,
        { file = cc.def_path, function_body_range = nil },
        utils.RESOLUTION_STATUS_RESOLVED, true))
    cc.dbg:incr("calls_kept")
    return
  end
  if _check_project_scope(cc) then return end
  if _check_has_body(cc) then return end
  _keep_resolved_call(cc)
end

return M
