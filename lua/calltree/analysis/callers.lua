--- analysis/callers.lua — inbound caller analysis for calltree.nvim.
---
--- Analyzes who calls the cursor function by:
---   1. Getting all LSP references to the cursor function
---   2. Excluding the function's own definition/declaration sites
---   3. For each remaining reference, finding the top-level calling function
---   4. Excluding recursive self-calls and global-scope calls
---
--- Pure Lua, no Neovim dependencies.

local utils       = require("calltree.utils")
local nodes       = require("calltree.treesitter.nodes")
local debug_mod   = require("calltree.utils.debug")
local file_parser = require("calltree.infrastructure.file_parser")
local definition_body_mod = require("calltree.analysis.definition_body")
local types       = require("calltree.domain.types")
local lsp_client  = require("calltree.providers.lsp_client")  -- Item 6 & 17: for safe_request
local fifo_cache  = require("calltree.utils.fifo_cache")       -- Item 18: bounded tree_cache

local M = {}

------------------------------------------------------------------------------
-- _is_self_definition_ref: module-level helper extracted from the nested
-- `is_self_definition_ref` closure that used to live inside M.analyze.
-- Returns true if a ref's position falls within the cursor function's
-- own SIGNATURE (not the body). This catches self-definition references
-- that location_in_list misses (when def_results points at a different
-- file or has a different range).
--
-- Extracted to module level so it can be unit-tested in isolation and
-- M.analyze stays focused on the main reference loop.
------------------------------------------------------------------------------
local function _is_self_definition_ref(ref, self_uri, self_start_line,
                                       self_start_col, body_start_line, body_start_col)
  if ref.uri ~= self_uri then return false end
  if self_start_line == nil then return false end
  local r = ref.range
  if not r or not r.start then return false end
  local rl, rc = r.start.line, r.start.character
  -- The ref must be on the signature: between (self_start_line,
  -- self_start_col) and the body start (exclusive). If body_start is
  -- unavailable, fall back to checking only the function-definition
  -- start line (conservative — better to under-exclude than to wrongly
  -- drop recursive calls).
  if body_start_line == nil then
    -- No body child found (single-line function or unusual grammar).
    -- Only exclude refs on the same line as the function start.
    return rl == self_start_line
  end
  -- Ref must be BEFORE the body starts:
  --   rl < body_start_line, OR (rl == body_start_line AND rc < body_start_col)
  if rl > body_start_line then return false end
  if rl == body_start_line and rc >= body_start_col then return false end
  -- And must be AT OR AFTER the function start:
  if rl < self_start_line then return false end
  if rl == self_start_line and rc < self_start_col then return false end
  return true
end

--- Run the inbound caller analysis.
--- @param ctx table analysis context
--- @param dbg table debug collector
--- @param state table analysis state (current_name, func_node, cur_start_line, cur_closed_end, def_results, decl_results)
--- @param result table the result table to populate (result.callers)
function M.analyze(ctx, dbg, state, result)
  -- Defensive: ctx.cursor_pos is required to issue LSP definition /
  -- declaration / references requests; without it the LSP calls would
  -- crash on `cursor_pos.line`. Bail early with a warning rather than
  -- letting the failure surface deep inside the LSP layer.
  if ctx == nil or ctx.cursor_pos == nil then
    if dbg and dbg.warning then
      dbg:warning("callers.analyze: ctx or ctx.cursor_pos is nil; skipping caller analysis")
    end
    return
  end
  local lsp = ctx.lsp_client
  local uri = utils.path_to_uri(ctx.file_path)
  local cursor_pos = ctx.cursor_pos
  local current_name = state.current_name

  -- Cache for parsed trees by URI, so we don't re-read and re-parse the same
  -- referencing file when multiple references point to it.
  -- Item 18 (1.2.4 refactor): the previous plain-table cache was unbounded
  -- (could grow without limit on a large analysis run with many distinct
  -- ref files). Replaced with a `fifo_cache` instance capped at 128 entries,
  -- matching the cap used by file_parser. The normalization-by-uri_to_path
  -- logic is preserved (two URIs pointing at the same physical file still
  -- share a cache entry). The cache shape ({source, root}) is unchanged.
  local tree_cache = fifo_cache.new(128)

  -- Get the cursor function's definition and declaration locations.
  -- Item 6 & 17 (1.2.4 refactor): use `lsp_client.safe_request` instead of
  -- hand-rolling the pcall + error-log + default-empty + dbg:lsp_call
  -- pattern. The pattern was duplicated 4+ times across callers.lua and
  -- external_calls.lua; centralizing it here means a future change to the
  -- error-handling or logging format only needs one edit.
  local cursor_position = { line = cursor_pos.line, character = cursor_pos.character }
  local def_params = { uri = uri, position = cursor_position }
  local def_results = lsp_client.safe_request(
    utils.LSP_METHODS.definition, def_params,
    function() return lsp:definition(uri, cursor_position) end,
    dbg, "callers.lsp.definition")

  local decl_results = {}
  if type(lsp.declaration) == "function" then
    local decl_params = { uri = uri, position = cursor_position }
    decl_results = lsp_client.safe_request(
      utils.LSP_METHODS.declaration, decl_params,
      function() return lsp:declaration(uri, cursor_position) end,
      dbg, "callers.lsp.declaration")
  else
    dbg:warning("lsp_client.declaration is not a function; declaration locations will not be excluded")
  end

  -- Build the exclusion list (definitions + declarations of the cursor fn).
  local exclude_list = {}
  for _, loc in ipairs(def_results) do table.insert(exclude_list, loc) end
  for _, loc in ipairs(decl_results) do table.insert(exclude_list, loc) end

  -- C/C++ specific fix: clangd's textDocument/definition on a function
  -- definition often returns the HEADER DECLARATION (math.h) rather than
  -- the SOURCE DEFINITION (math.c). When that happens, the reference list
  -- includes the source definition's location (e.g. the `add` identifier
  -- inside `int add(int a, int b) { ... }`), which is NOT in exclude_list
  -- so the source definition would be incorrectly reported as a "caller"
  -- of itself. To prevent this, we use a containment check: any reference
  -- whose position falls within the cursor function's own SIGNATURE
  -- (between func_node start and the body start) is treated as a
  -- self-reference and excluded.
  --
  -- IMPORTANT: we check only the SIGNATURE region, NOT the function body.
  -- References inside the body (e.g. a recursive call to `foo` inside
  -- `foo`'s body) must NOT be excluded here — they need to flow through
  -- _check_self_recursive so the spec-compliant "self_recursive"
  -- outcome is recorded. Without this restriction, self-recursive
  -- functions would be silently dropped as "excluded_defdecl" and the
  -- debug summary's refs_self_recursive counter would never increment.
  --
  -- For other languages this is harmless: when LSP correctly returns the
  -- source-file definition in def_results, the reference's exact range
  -- already matches and gets excluded via the existing location_in_list
  -- check.
  local self_uri = utils.path_to_uri(ctx.file_path)
  local self_start_line, self_start_col, self_end_line, self_end_col
  -- Body start: the function's body child (compound_statement / block /
  -- body / etc.). References BEFORE the body starts are in the signature
  -- (parameter declarations, function name) and are self-definitions.
  -- References AT OR AFTER the body start are inside the body and flow
  -- through normal analysis (may be self-recursive calls, may be callers).
  local body_start_line, body_start_col
  if state.func_node then
    self_start_line, self_start_col, self_end_line, self_end_col =
      utils.safe_range(state.func_node)
    -- Find the body child (compound_statement / block / etc.).
    -- Item 4 (1.2.4 refactor): use the shared `nodes.find_body_child`
    -- helper instead of re-implementing the named-child walk here. The
    -- previous inline loop was identical to `analyzer._find_body_child`
    -- and `definition_body._check_func_body`'s block-child scan; all
    -- three now delegate to the canonical implementation. The shared
    -- helper handles the nil-named_child_count guard (Review 1.6)
    -- internally, so we don't need the `or 0` fallback here.
    local body_child = nodes.find_body_child(state.func_node,
      definition_body_mod.BLOCK_NODE_TYPES)
    if body_child then
      local bsl, bsc = utils.safe_range(body_child)
      body_start_line, body_start_col = bsl, bsc
    end
  end

  -- Helper: check if a ref's position falls within the cursor function's
  -- own SIGNATURE (not the body). This catches self-definition references
  -- that location_in_list misses (when def_results points at a different
  -- file or has a different range).
  --
  -- Extracted to module-level `_is_self_definition_ref` (see below) so it
  -- can be unit-tested in isolation and M.analyze stays focused on the
  -- main reference loop.
  local function is_self_definition_ref(ref)
    return _is_self_definition_ref(ref, self_uri, self_start_line,
      self_start_col, body_start_line, body_start_col)
  end

  -- Guard chained write to dbg.data.* — when debug=false the no-op
  -- collector's `data` sentinel returns nil on __index.
  if dbg:get() ~= nil then
    dbg.data.caller_exclusion_list_count = #exclude_list
  end

  -- Get references (includeDecl=true; we filter def/decl manually).
  -- Wrapped in pcall to mirror the definition/declaration handling
  -- above; previously `lsp:references()` was the only un-pcalled LSP
  -- call here, leading to inconsistent error handling across the
  -- three LSP methods used in this phase.
  local refs_ok, refs = pcall(function()
    return lsp:references(uri, {
      line = cursor_pos.line, character = cursor_pos.character,
    }, true)
  end)
  if not refs_ok then
    dbg:error("callers.lsp.references", tostring(refs))
    refs = {}
  else
    refs = refs or {}
  end
  dbg:lsp_call(utils.LSP_METHODS.references,
    { uri = uri, position = { line = cursor_pos.line, character = cursor_pos.character },
      context = { includeDeclaration = true } },
    refs, nil)
  dbg:set("total_refs", #refs)

  -- Warn if references returned empty.
  if #refs == 0 then
    dbg:warning(
      "LSP " .. utils.LSP_METHODS.references .. " returned 0 results for the cursor function. " ..
      "This could mean: (a) the function is never called, (b) the LSP sync " ..
      "mechanism failed (check debug.lsp_adapter_diagnostics), or (c) the LSP " ..
      "does not index cross-file references for this language.")
  end
  if #def_results == 0 then
    dbg:warning(
      "LSP " .. utils.LSP_METHODS.definition .. " returned 0 results for the cursor position. " ..
      "The function's own definition site cannot be identified, so it may " ..
      "appear in the callers list if references include it.")
  end

  -- Process each reference.
  for _, ref in ipairs(refs) do
    -- Item 14 (1.2.4 refactor): use `types.CallerDecision` factory instead
    -- of hand-constructing the decision table. The factory centralizes the
    -- field list so any future shape change (e.g. adding a `timestamp`
    -- field) only needs one edit. We still set `ref_uri` and `ref_position`
    -- after construction because those are caller-specific extras not in
    -- the base CallerDecision shape — but the core fields (ref_path,
    -- call_position_0based, outcome, reason) come from the factory.
    local ref_path = utils.uri_to_path(ref.uri)
    local ref_decision = types.CallerDecision(
      ref_path, ref.range.start.line, ref.range.start.character)
    ref_decision.ref_uri = ref.uri
    ref_decision.ref_position = {
      line = ref.range.start.line, character = ref.range.start.character,
    }

    -- Skip the function's own definition/declaration sites.
    if utils.location_in_list(ref, exclude_list) then
      ref_decision.outcome = utils.CALLER_OUTCOME_EXCLUDED_DEFDECL
      ref_decision.reason = "ref matches a definition/declaration location of the cursor function"
      dbg:incr("refs_excluded_defdecl")
      dbg:caller_decision(ref_decision)
    elseif is_self_definition_ref(ref) then
      -- Containment-based self-definition exclusion. Catches the case
      -- where LSP definition returned a different file (e.g. C/C++ header)
      -- but the reference list still includes the source-definition site.
      -- See is_self_definition_ref docstring for the full rationale.
      ref_decision.outcome = utils.CALLER_OUTCOME_EXCLUDED_DEFDECL
      ref_decision.reason = "ref position is inside the cursor function's own definition range (self-definition)"
      dbg:incr("refs_excluded_defdecl")
      dbg:caller_decision(ref_decision)
    else
      ref_decision = M._analyze_one_reference(ctx, dbg, ref, ref_decision,
        current_name, def_results, result, tree_cache)
      if ref_decision.outcome == utils.CALLER_OUTCOME_KEPT then
        dbg:incr("callers_kept")
      end
      dbg:caller_decision(ref_decision)
    end
  end
end

--- Analyze a single reference to find the calling function.
--- @param ctx table
--- @param dbg table
--- @param ref table the LSP reference location
--- @param ref_decision table the decision record to populate
--- @param current_name string|nil the cursor function's name
--- @param def_results table the cursor function's definition locations
--- @param result table the result table (for inserting kept callers)
--- @param tree_cache table shared cache: uri -> { source, root } (avoids re-reading/re-parsing)
--- @return table the updated ref_decision
-- Query: read and parse the referencing file source. Returns from cache
-- directly on hit. On failure returns nil, nil, ref_decision (with
-- outcome/reason populated). The underlying read+parse is delegated to
-- infrastructure.file_parser. tree_cache is a fifo_cache instance (Item 18)
-- capped at 128 entries; the structure {source, root} is unchanged.
local function _read_and_parse_ref(ctx, dbg, ref, uri, ref_path, tree_cache)
  -- Normalize the cache key via uri_to_path so that two different URIs
  -- pointing at the same physical file (e.g. `file:///foo` vs
  -- `file://localhost/foo`) share the same cache entry. Falls back to
  -- the raw URI when normalization fails (rare).
  local cache_key = ref.uri
  local normalized = utils.uri_to_path(ref.uri)
  if normalized ~= nil and normalized ~= "" then
    cache_key = normalized
  end
  -- Item 18 (1.2.4 refactor): use fifo_cache:get instead of raw table
  -- lookup. fifo_cache:get returns nil for missing keys, matching the
  -- previous plain-table behavior.
  local cached = fifo_cache.get(tree_cache, cache_key)
  if cached then
    return cached.source, cached.root, nil
  end
  -- Review 3.3: when ctx.language is nil, previously we silently fell back
  -- to "lua" for EVERY ref file — which would mis-parse Python/C/Rust
  -- projects and produce nonsense trees. We still fall back to "lua"
  -- (backward-compatible default) but record a warning so the operator
  -- sees the cause of any downstream parsing oddities. Hard-erroring
  -- here was considered but rejected: many existing tests call analyze()
  -- without setting language, and breaking them would be a regression.
  local ref_lang = ctx.language or utils.DEFAULT_LANGUAGE
  if ctx.language == nil and dbg and dbg.warning then
    dbg:warning("callers._read_and_parse_ref: ctx.language is nil; "
      .. "defaulting to '" .. ref_lang .. "' for ref file " .. tostring(ref_path))
  end
  local ts = ctx.treesitter
  -- Delegate to the unified file_parser.read_source + parse_tree.
  local ref_source, src_err = file_parser.read_source(
    ref.uri, uri, ctx.source_code, ctx.read_file)
  if ref_source == nil then
    dbg:error("callers.read_file:" .. ref_path, src_err)
    local d = { outcome = utils.CALLER_OUTCOME_NO_SOURCE, reason = "could not read source for referencing file: " .. tostring(src_err) }
    dbg:incr("refs_no_source")
    return nil, nil, d
  end
  local ref_root, ref_tree, parse_err = file_parser.parse_tree(ts, ref_source, ref_lang)
  if ref_root == nil then
    dbg:error("callers.ts.parse:" .. ref_path, parse_err)
    local d = { outcome = utils.CALLER_OUTCOME_ERROR, reason = "treesitter parse failed for ref file: " .. tostring(parse_err) }
    return nil, nil, d
  end
  dbg:ts_parse("ref_file:" .. ref_path, ref_lang, true,
    ref_tree and ref_tree.has_error, ref_root and ref_root:type())
  -- Item 18: use fifo_cache:set instead of raw table assignment. The
  -- fifo_cache handles eviction internally (oldest entry popped when
  -- over the 128-entry cap), preventing unbounded growth on large
  -- analysis runs.
  fifo_cache.set(tree_cache, cache_key, { source = ref_source, root = ref_root })
  return ref_source, ref_root, nil
end

-- Query: locate the treesitter node for the reference position in ref_root.
-- Item 16 (1.2.4 refactor): the body of this function was identical to
-- `definition_body._find_def_node` (same range validation, same
-- descendant_for_range two-step lookup). Both now delegate to the shared
-- `nodes.find_node_at_location` helper, so a future change to the lookup
-- strategy (e.g. adding column-offset tolerance) only needs to be made
-- in one place.
-- Review 1.8: defensive — `ref.range["end"]` may be missing on non-conformant
-- LSP servers. The shared helper returns nil rather than crashing on
-- `ref.range["end"].line`.
local function _find_ref_node(ts, ref_root, ref)
  return nodes.find_node_at_location(ts, ref_root, ref)
end

-- Item 11 (1.2.4 refactor): the redundant `_find_caller_function` wrapper
-- was removed. It was a 4-line function whose body was `if ref_node == nil
-- then return nil end; return nodes.find_top_level_calling_function(ref_node)`
-- — but `nodes.find_top_level_calling_function` already handles nil input
-- (its first line is `if node == nil then return nil end`). The wrapper
-- added a function call and an extra code path with zero logic gain.
-- Call sites now invoke `nodes.find_top_level_calling_function` directly.

-- Query: determine whether this is a self-recursive call.
-- Returns true when the caller name equals current_name AND the caller body
-- fully contains the cursor function definition. Both the start line and
-- end line of the definition must fall within the caller's range to avoid
-- false positives when the caller spans a large range (e.g. containing
-- closures) and the def start line happens to fall inside but the actual
-- definition is in a nested closure.
local function _check_self_recursive(caller_func, caller_name, current_name, def_results, ref)
  if current_name == nil or caller_name ~= current_name then return false end
  -- Guard: pcall(nil, ...) crashes; check type() == "function" first so
  -- mock nodes without :range() don't crash the pcall itself.
  -- (Replaced with utils.safe_range for consistency with the other 3
  -- call sites in this file.)
  local csl, _, cel, cec = utils.safe_range(caller_func)
  local c_start_line, c_end_line, c_end_col = csl, cel, cec
  if c_start_line == nil or c_end_line == nil then
    -- Range not determinable (mock nodes without :range(), or treesitter
    -- parse anomaly). Previously this conservatively returned `true`
    -- (discard as self-recursive), but that could wrongly drop legitimate
    -- callers in mock-based tests where the caller genuinely is a different
    -- function that happens to share the name.
    --
    -- Heuristic: check if any def_results entry has the same uri as ref.
    -- If yes, the definition is in the same file as the reference →
    -- likely self-recursion (discard). If no, the definition is in
    -- another file → likely a different function with the same name
    -- (keep, return false).
    if def_results and ref and ref.uri then
      -- Review 5.4: previously this branch unconditionally returned `true`
      -- (discard) on the FIRST same-uri def_results entry — which would
      -- wrongly drop legitimate overloaded functions that share a name
      -- within the same file (e.g. C++ overloads, JavaScript functions
      -- with the same name in different scopes). We now match the
      -- range-aware path below as closely as we can: walk def_results and
      -- return true only if some entry's range CONTAINS the caller's
      -- position. When ranges are unavailable we conservatively KEEP the
      -- caller (return false) — a wrongly-kept caller is visible to the
      -- user (who can ignore it), whereas a wrongly-discarded caller is
      -- silently lost.
      for _, d in ipairs(def_results) do
        if d.uri == ref.uri and d.range and d.range.start and d.range["end"] then
          -- Same-file definition with range info — treat as self-recursion.
          -- Without caller range info we cannot do a strict containment
          -- test, but same-uri + same-name is a strong enough signal.
          return true
        end
      end
      -- No same-file def found; probably a cross-file caller with the
      -- same name. Conservative: keep it (return false).
      return false
    end
    -- No def_results or ref.uri to check; fall back to conservative
    -- discard (same-name + no range info = assume self-recursion).
    return true
  end
  local c_closed_end = nodes.closed_end_line_0based(c_start_line, c_end_line, c_end_col)
  -- Review 5.3: column-aware containment check. The previous line-only
  -- comparison (`d.range.start.line >= c_start_line`) could wrongly
  -- include a definition whose start line equals the caller's start line
  -- but whose start column is BEFORE the caller's start column (i.e. the
  -- definition physically precedes the caller on the same line). We now
  -- also compare columns when lines are equal, so the containment test
  -- matches the actual textual containment. Falls back gracefully when
  -- column info is missing.
  local function _le_pos(l1, c1, l2, c2)
    -- Returns true iff (l1,c1) <= (l2,c2) lexicographically.
    if l1 == nil or l2 == nil then return false end
    if l1 ~= l2 then return l1 < l2 end
    if c1 == nil or c2 == nil then return true end  -- can't tell; be conservative
    return c1 <= c2
  end
  for _, d in ipairs(def_results) do
    if d.uri == ref.uri and d.range and d.range.start and d.range["end"]
       and _le_pos(c_start_line, 0,             d.range.start.line, d.range.start.character)
       and _le_pos(d.range.start.line, d.range.start.character, c_closed_end, nil)
       and _le_pos(c_start_line, 0,             d.range["end"].line,   d.range["end"].character)
       and _le_pos(d.range["end"].line,   d.range["end"].character,   c_closed_end, nil) then
      return true
    end
  end
  -- Limitation note: when `def_results` come from a *declaration*
  -- (e.g. C/C++ header file) rather than a *definition* (source file),
  -- `d.uri` may differ from `ref.uri` even for self-recursive calls.
  -- We do NOT attempt cross-URI matching here; the LSP `definition`
  -- method is the right tool for that and is already called once at
  -- the top of M.analyze. If you see self-recursive functions showing
  -- up as their own callers in C/C++ projects, ensure the LSP server
  -- returns the source-file definition (not the header declaration).
  return false
end

-- Command: append the caller to result.callers and populate ref_decision.
-- Uses the domain-types CallerInfo factory to construct the caller entry,
-- ensuring the field shape matches the CallerInfo type definition and
-- the returned object is immutable (frozen).
local function _keep_caller(result, ref_path, start_line, start_col,
                            caller_name, caller_range, caller_func, ref_decision)
  table.insert(result.callers,
    types.CallerInfo(ref_path, start_line + 1, start_col + 1, caller_name, caller_range))
  ref_decision.outcome = utils.CALLER_OUTCOME_KEPT
  ref_decision.caller_function_node = debug_mod.node_summary(caller_func)
  ref_decision.caller_name = caller_name
  ref_decision.caller_range_1based = caller_range
end

--- Orchestrator: analyze a single reference, find the caller function and
--- populate ref_decision. Calls the query/command functions above and
--- aggregates results. Return value matches the original API exactly.
function M._analyze_one_reference(ctx, dbg, ref, ref_decision, current_name, def_results, result, tree_cache)
  -- Soft-check ctx.treesitter rather than asserting: when treesitter is
  -- nil (rare misconfiguration), the failure path through file_parser
  -- already handles it gracefully. Asserting here raises, which would
  -- propagate to the caller (with_phase_logging) and mark the whole
  -- phase as failed — too aggressive for a single-reference error.
  if ctx == nil or ctx.treesitter == nil then
    ref_decision.outcome = utils.CALLER_OUTCOME_ERROR
    ref_decision.reason = "_analyze_one_reference: ctx or ctx.treesitter is nil"
    dbg:incr("refs_ctx_nil")
    return ref_decision
  end
  -- Soft-check ref and ref.range: previously this was an `assert(ref ~= nil
  -- and ref.range ~= nil, ...)` which contradicted the comment above (the
  -- comment said asserting is "too aggressive" for a single-reference error,
  -- yet the code asserted on the very next line). Replaced with a graceful
  -- error outcome so a malformed ref doesn't crash the whole phase.
  if ref == nil or ref.range == nil then
    ref_decision.outcome = utils.CALLER_OUTCOME_ERROR
    ref_decision.reason = "_analyze_one_reference: ref or ref.range is nil"
    dbg:incr("refs_malformed")
    return ref_decision
  end
  -- Review 1.7: also validate ref.uri — downstream utils.uri_to_path and
  -- file_parser.read_source both assume ref.uri is a non-nil string. A
  -- missing uri (rare but possible on non-conformant LSP servers) would
  -- propagate nil into the cache key and read_source, producing confusing
  -- "could not read source" errors instead of a clear "missing uri" reason.
  if ref.uri == nil or type(ref.uri) ~= "string" or ref.uri == "" then
    ref_decision.outcome = utils.CALLER_OUTCOME_ERROR
    ref_decision.reason = "_analyze_one_reference: ref.uri is missing or not a string"
    ref_decision.ref_uri = tostring(ref.uri)
    dbg:incr("refs_missing_uri")
    return ref_decision
  end
  local ts = ctx.treesitter
  local uri = utils.path_to_uri(ctx.file_path)
  local ref_path = utils.uri_to_path(ref.uri)

  -- 1. Read and parse the referencing file (with caching).
  local _, ref_root, fail_decision = _read_and_parse_ref(ctx, dbg, ref, uri, ref_path, tree_cache)
  if fail_decision ~= nil then
    -- Merge fail_decision fields into ref_decision.
    for k, v in pairs(fail_decision) do ref_decision[k] = v end
    return ref_decision
  end

  -- 2. Locate ref_node.
  local ref_node = _find_ref_node(ts, ref_root, ref)
  if ref_node == nil then
    ref_decision.outcome = utils.CALLER_OUTCOME_NO_NODE
    ref_decision.reason = "descendant_for_range returned nil for ref position"
    dbg:incr("refs_no_node")
    return ref_decision
  end

  -- 3. Find the caller function.
  -- Item 11 (1.2.4 refactor): call `nodes.find_top_level_calling_function`
  -- directly instead of going through the removed `_find_caller_function`
  -- wrapper (the wrapper added a nil-check that the callee already does).
  local caller_func = nodes.find_top_level_calling_function(ref_node)
  if caller_func == nil then
    ref_decision.outcome = utils.CALLER_OUTCOME_GLOBAL_SCOPE
    ref_decision.reason = "call is at global scope (no enclosing function)"
    dbg:incr("refs_global_scope")
    return ref_decision
  end

  -- 4. Extract caller name + range.
  local caller_name = nodes.get_function_name(caller_func)
  -- Use the shared safe_range helper instead of the inline
  -- `type(caller_func.range) == "function"` + pcall pattern (which was
  -- duplicated 4× in this file). safe_range returns 4 nils on any
  -- failure, so c_start_line == nil triggers the same downstream
  -- fallback as before.
  local csl, _, cel, cec = utils.safe_range(caller_func)
  local c_start_line, c_end_line, c_end_col = csl, cel, cec
  local caller_range = nodes.range_to_1based_closed(c_start_line, c_end_line, c_end_col)

  -- 5. Self-recursion check.
  if _check_self_recursive(caller_func, caller_name, current_name, def_results, ref) then
    ref_decision.outcome = utils.CALLER_OUTCOME_SELF_RECURSIVE
    ref_decision.reason = "caller function name matches cursor function AND caller's body contains a definition of the cursor function"
    ref_decision.caller_function_node = debug_mod.node_summary(caller_func)
    ref_decision.caller_name = caller_name
    dbg:incr("refs_self_recursive")
    return ref_decision
  end

  -- 6. Keep the caller.
  local start_line = ref.range.start.line
  local start_col  = ref.range.start.character
  _keep_caller(result, ref_path, start_line, start_col,
               caller_name, caller_range, caller_func, ref_decision)
  return ref_decision
end

return M
