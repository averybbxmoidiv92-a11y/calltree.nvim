--- analysis/definition_body.lua — definition body checker (extracted from
--- external_call_analysis.lua).
---
--- Given an LSP definition location, determine whether the definition site
--- corresponds to a function with a body. Handles module imports (require
--- bindings) by resolving the require and searching the referenced module
--- file for the function definition.
---
--- Pure Lua, no Neovim dependencies.

local utils       = require("calltree.utils")
local nodes       = require("calltree.treesitter.nodes")
local resolver    = require("calltree.resolution.require_resolver")
local module_finder = require("calltree.resolution.module_finder")
local file_parser = require("calltree.infrastructure.file_parser")
local fifo_cache  = require("calltree.utils.fifo_cache")  -- Item 19: bounded module_cache

local M = {}

-- Contract prefix used by definition_body.check to signal that the LSP
-- definition points at a parameter declaration (function-pointer parameter).
-- external_calls._check_has_body detects this prefix and converts the call
-- to "kept_unresolved" instead of "kept_resolved". Centralized as a
-- module-level constant (was an inline string duplicated between this
-- module and external_calls, creating a hidden coupling where renaming
-- the prefix in one place would break the other).
M.PARAM_DECLARATION_PREFIX = "PARAM_DECLARATION:"

-- Node types that represent a declaration / assignment / binding statement
-- across the languages we support. Used in two places below (the
-- assignment-RHS function-expression scan AND the bare-declaration walk-up),
-- so extracted as a module-level constant to avoid the two lists drifting
-- out of sync (was a code-review finding: the two previous inline lists
-- overlapped but weren't identical, and the second one was missing
-- `variable_declarator` and `lexical_declaration`).
M.DECLARATION_NODE_TYPES = {
  ["local_declaration"]               = true,  -- Lua
  ["local_statement"]                 = true,  -- Lua (alternate grammar)
  ["assignment"]                      = true,  -- Lua / generic
  ["variable_declaration"]            = true,  -- JS/TS (var)
  ["variable_assignment_statement"]   = true,  -- Python
  ["variable_declarator"]             = true,  -- C/C++
  ["lexical_declaration"]             = true,  -- JS/TS (let/const)
  ["local_function_declaration"]      = true,  -- Lua local function
}

-- Node types that represent a "bare" declaration WITHOUT a body — a
-- prototype, signature, or extern. When the def-node walk-up hits one of
-- these, the call is discarded as "no body".
M.BARE_DECLARATION_NODE_TYPES = {
  ["declaration"                   ] = true,  -- C/C++ extern
  ["abstract_method_declaration"   ] = true,  -- Java/C#
  ["method_signature"              ] = true,  -- C#/TS interface
  ["function_signature"            ] = true,  -- TS interface
  ["field_declaration"             ] = true,  -- Java/C++ class field
}

-- Node types that wrap the RHS of an assignment in a "value" / "initializer"
-- container (some grammars add this extra layer). Used by the
-- assignment-RHS function-expression scan.
M.RHS_WRAPPER_NODE_TYPES = {
  ["value"           ] = true,
  ["initializer"     ] = true,
  ["expression"      ] = true,
  ["init_expression" ] = true,
}

-- Node types that represent a function body / block. Used to decide whether
-- a function-definition node "has a body" even when it spans a single line.
M.BLOCK_NODE_TYPES = {
  ["block"               ] = true,
  ["body"                ] = true,
  ["compound_statement"  ] = true,  -- C/C++/JS
  ["statement_block"     ] = true,  -- JS/TS
  ["block_statement"     ] = true,
  ["function_body"       ] = true,
  ["statements"          ] = true,
}

-- Query: read the definition file source. Prefers ctx.source_code (same
-- file), otherwise read_file. Failures are logged via dbg (dbg may be a
-- NoopCollector, call is safe).
local function _read_def_source(ctx, def, def_path, dbg)
  -- Review 1.4: guard against nil ctx.file_path or def.uri before calling
  -- path_to_uri / read_source — these can be nil when the caller (LSP)
  -- returns a malformed Location. Previously nil propagated into
  -- path_to_uri (gsub on nil) and crashed the whole analysis.
  if ctx.file_path == nil or def == nil or def.uri == nil then
    if dbg and dbg.error then
      dbg:error("external_calls.read_file:" .. tostring(def_path),
        "missing ctx.file_path or def.uri (got file_path=" .. tostring(ctx.file_path)
        .. ", def.uri=" .. (def and tostring(def.uri) or "nil") .. ")")
    end
    return nil
  end
  local uri = utils.path_to_uri(ctx.file_path)
  local src, err = file_parser.read_source(def.uri, uri, ctx.source_code, ctx.read_file)
  if src == nil and err ~= nil and dbg and dbg.error then
    dbg:error("external_calls.read_file:" .. def_path, err)
  end
  return src
end

-- Query: parse the definition file source into a treesitter root.
local function _parse_def_tree(ts, def_source, def_lang, def_path, dbg)
  local def_root, def_tree, err = file_parser.parse_tree(ts, def_source, def_lang)
  if def_root == nil then
    return nil, "treesitter parse failed for def file: " .. tostring(err)
  end
  if dbg and dbg.ts_parse then
    dbg:ts_parse("def_file:" .. def_path, def_lang, true, def_tree.has_error,
      def_root and def_root:type())
  end
  return def_root, nil
end

-- Query: locate the treesitter node for the LSP definition position in root.
-- Item 16 (1.2.4 refactor): the body of this function was identical to
-- `callers._find_ref_node` (same range validation, same
-- descendant_for_range two-step lookup). Both now delegate to the shared
-- `nodes.find_node_at_location` helper, so a future change to the lookup
-- strategy only needs to be made in one place.
-- Review 1.5: defensive — `def.range` (or its `start`/`end` sub-tables) may
-- be missing on non-conformant LSP servers. The shared helper returns nil
-- rather than crashing on `def.range["end"].line`.
--
-- Review 2.1 — NOT A BUG (won't fix): the report claimed
-- `ts.descendant_for_range(ts, def_root, ...)` passes `ts` twice and
-- shadows `def_root`. That is incorrect: in Lua,
-- `ts.descendant_for_range(ts, def_root, ...)` is the explicit-self form
-- of the method call — `ts` becomes `self`, `def_root` becomes `root`,
-- exactly matching MockTreesitter.descendant_for_range(self, root, sl, sc, el, ec).
-- Every other caller in this codebase (callers.lua L326/L328,
-- analyzer.lua L235) uses the same explicit-self form. Changing only this
-- call site would desync it from the rest and break analysis. The shared
-- `nodes.find_node_at_location` preserves the same explicit-self form.
local function _find_def_node(ts, def_root, def)
  return nodes.find_node_at_location(ts, def_root, def)
end

-- Query: scan the RHS of assignment statements in def_node's ancestor chain
-- for a function_expression. Used for `local foo = function() ... end` forms.
local function _scan_rhs_for_function(stmt_node)
  local nc = stmt_node:named_child_count()
  for i = 0, nc - 1 do
    local child = stmt_node:named_child(i)
    if child and utils.FUNCTION_NODE_TYPES[child:type()] then
      return child
    end
    if child and M.RHS_WRAPPER_NODE_TYPES[child:type()] then
      local gc = child:named_child_count()
      for j = 0, gc - 1 do
        local sub = child:named_child(j)
        if sub and utils.FUNCTION_NODE_TYPES[sub:type()] then
          return sub
        end
      end
    end
  end
  return nil
end

-- Node types that represent a parameter declaration boundary in C/C++.
-- When _find_func_def_node walks up from a def_node, crossing one of these
-- means the def_node is a parameter declaration (e.g. a function-pointer
-- parameter like `void (*fp)()` inside `void dispatcher(void (*fp)())`).
-- clangd's textDocument/definition on a call to such a parameter returns
-- the parameter declaration position — and without this boundary, the
-- walk_up_to_type would climb through parameter_list → function_declarator
-- → function_definition, landing on the ENCLOSING function (dispatcher),
-- not a nested function definition. The body check would then say "yes,
-- dispatcher has a body", and the call would be incorrectly classified
-- as "resolved" (pointing back at the cursor function itself).
--
-- Stopping the walk at this boundary makes _find_func_def_node return nil,
-- causing _find_decl_ancestor to be tried next; since parameter_declaration
-- is not in DECLARATION_NODE_TYPES or BARE_DECLARATION_NODE_TYPES, the
-- result is "no function-definition ancestor (likely bare declaration)"
-- and the call is discarded as no-body — which matches the spec's
-- expectation that function-pointer calls be marked unresolved/discarded.
local PARAMETER_BOUNDARY_TYPES = {
  ["parameter_list"]       = true,
  ["parameter_declaration"] = true,
  ["parameters"]           = true,  -- Python / generic
}

-- Query: find the function-definition node. First walk_up_to_type, then
-- fall back to scanning the assignment RHS.
-- Stops the walk at parameter boundaries (see PARAMETER_BOUNDARY_TYPES)
-- so parameter declarations inside the cursor function's signature are
-- not mistaken for nested function definitions.
-- Item 15 (1.2.4 refactor): the two manual while-loops below were replaced
-- by calls to the shared `nodes.walk_up_until` helper. The first walk uses
-- a predicate that returns true on FUNCTION_NODE_TYPES matches and "stop"
-- on PARAMETER_BOUNDARY_TYPES matches (early bail-out). The second walk
-- uses a predicate that returns true on DECLARATION_NODE_TYPES matches.
-- This removes the duplicated hop-cap + cycle-detection skeleton.
local function _find_func_def_node(def_node)
  if def_node == nil then return nil end
  -- First walk: find a FUNCTION_NODE_TYPES ancestor, stopping early if we
  -- cross a parameter boundary (parameter declarations are NOT nested
  -- function definitions).
  local func_node = nodes.walk_up_until(def_node, function(cur)
    local ct = cur:type()
    if utils.FUNCTION_NODE_TYPES[ct] then return true end
    if PARAMETER_BOUNDARY_TYPES[ct] then return "stop" end
    return false
  end)
  if func_node ~= nil then return func_node end
  -- Second walk (RHS scan): find a DECLARATION_NODE_TYPES ancestor and
  -- scan its RHS for a function_expression (covers `local foo = function()
  -- ... end` forms).
  local decl_node = nodes.walk_up_until(def_node, function(cur)
    return M.DECLARATION_NODE_TYPES[cur:type()] or false
  end)
  if decl_node ~= nil then
    return _scan_rhs_for_function(decl_node)
  end
  return nil
end

-- Query: check whether the function-definition node has a body. Returns
-- has_body, range_1based, detail.
local function _check_func_body(func_def_node)
  if func_def_node == nil then return false, nil, "no func_def_node" end
  -- Guard: pcall(nil, ...) crashes. Check type() == "function" first so
  -- mock nodes without :range() don't crash the pcall itself.
  -- (Replaced with utils.safe_range — same defensive behavior, removes
  -- the inline pcall(node.range, node) pattern duplicated across the
  -- codebase.)
  if type(func_def_node.range) ~= "function" then
    return false, nil, "function node has no :range() method"
  end
  local fdl, _, fel, fec = utils.safe_range(func_def_node)
  if fdl == nil then
    return false, nil, "function node range() failed"
  end
  local named_count = func_def_node:named_child_count()
  -- Review 7.3: renamed from `spans_multiple_lines` (misleading — the
  -- expression is true even for single-line bodies where `fec > 0`, so
  -- "spans multiple lines" was inaccurate). The new name reflects what
  -- the flag actually means: "the function body has content past the
  -- signature line".
  local has_body_content = (fdl ~= nil and fel ~= nil)
     and ((fel > fdl) or (fec and fec > 0))
  -- Item 4 (1.2.4 refactor): use the shared `nodes.find_body_child` helper
  -- instead of re-implementing the named-child walk here. The previous
  -- inline loop was identical to `analyzer._find_body_child`; both now
  -- delegate to the canonical implementation so a future change to the
  -- body-detection logic only needs to be made in BLOCK_NODE_TYPES.
  -- We still need `block_child_type` for the detail string, so when
  -- find_body_child returns a child we read its type() for the message.
  local block_child = nodes.find_body_child(func_def_node, M.BLOCK_NODE_TYPES)
  local has_block_child = block_child ~= nil
  local block_child_type = has_block_child and block_child:type() or nil
  if has_body_content or has_block_child then
    local range_1based = nodes.range_to_1based_closed(fdl, fel, fec)
    local detail = "has_body_content=" .. tostring(has_body_content) ..
      ", has_block_child=" .. tostring(has_block_child) ..
      ", block_child_type=" .. tostring(block_child_type)
    return true, range_1based, detail
  end
  return false, nil, "function node spans single line and has no block child"
end

-- Query: find a declaration statement node in def_node's ancestor chain.
-- Returns decl_ancestor, "bare" | nil ("bare" means a bare declaration was hit).
-- MAX_HOPS guard prevents infinite loops on cyclic mock trees whose
-- :parent() returns self (consistent with _find_func_def_node above).
-- Item 15 (1.2.4 refactor): the manual while-loop was replaced by a call
-- to the shared `nodes.walk_up_until` helper. The predicate returns true
-- on DECLARATION_NODE_TYPES matches and "stop" on BARE_DECLARATION_NODE_TYPES
-- matches (early bail-out with the "bare" kind). The two return values
-- (decl_ancestor, kind) are reconstructed from the walk result.
local function _find_decl_ancestor(def_node)
  local hit_bare = false
  local decl_node = nodes.walk_up_until(def_node, function(cur)
    local ct = cur:type()
    if M.DECLARATION_NODE_TYPES[ct] then return true end
    if M.BARE_DECLARATION_NODE_TYPES[ct] then
      hit_bare = true
      return "stop"
    end
    return false
  end)
  if decl_node ~= nil then return decl_node, nil end
  if hit_bare then return nil, "bare" end
  return nil, nil
end

-- Item 12 (1.2.4 refactor): the `_resolve_module_path` wrapper was
-- removed. It was a thin adapter that just constructed `exists_func`
-- from `ctx.fs` and forwarded to `module_finder.resolve_module_path`.
-- The construction is now inlined at the single call site in M.check
-- (3 lines), removing one level of indirection with zero behavior change.
-- Review 3.6's note about `ctx.fs.exists(path)` vs `ctx.fs:exists(path)`
-- still applies at the inlined call site: we use the function form (not
-- method-call form) because `fs.exists` is a regular function, not a
-- method.

-- Query: read and parse a module file, returning mod_root, err.
local function _read_and_parse_module(ctx, ts, resolved_path, dbg)
  local mod_source = nil
  if ctx.read_file and type(ctx.read_file) == "function" then
    local ok_rf2, ms = pcall(ctx.read_file, resolved_path)
    if ok_rf2 then mod_source = ms
    elseif dbg and dbg.error then dbg:error("module_import.read_file:" .. resolved_path, ms)
    end
  end
  if not mod_source then return nil, "could not read source" end
  local mod_lang = ctx.language or utils.DEFAULT_LANGUAGE
  local mod_root, mod_tree, parse_err = file_parser.parse_tree(ts, mod_source, mod_lang)
  if mod_root == nil then
    if dbg and dbg.error then dbg:error("module_import.parse:" .. resolved_path, parse_err) end
    return nil, "treesitter parse failed"
  end
  if dbg and dbg.ts_parse then
    dbg:ts_parse("module_file:" .. resolved_path, mod_lang, true,
      mod_tree and mod_tree.has_error, mod_root and mod_root:type())
  end
  return mod_root, nil
end

-- Query: search the module tree for a function definition by suffix
-- (with caching).
-- Review 3.7: previously the cache stored BOTH hits and misses — once a
-- suffix was searched and not found, subsequent calls returned the cached
-- nil, so a function that was added to the module LATER in the same
-- analysis run would never be found. We now only cache successful
-- lookups; failed lookups re-scan (the scan is cheap, and the false-
-- negative risk from caching misses outweighs the perf cost).
local function _search_module_function(mod_root, func_cache, suffix)
  local cached_func = func_cache[suffix]
  if cached_func then
    -- Cache hit (success only — failures are not cached, see above).
    return cached_func.node, cached_func.range, true
  end
  local node, range = nodes.find_function_def_by_name(mod_root, suffix)
  if node ~= nil then
    func_cache[suffix] = { node = node, range = range }
  end
  return node, range, false
end

--- Orchestrator: check whether the LSP definition location corresponds to
--- a function with a body. Calls the queries above and aggregates results.
--- Return values match the original API for backward compatibility.
--- @param ctx table
--- @param dbg table
--- @param def table
--- @param def_path string
--- @param call_name string
--- @param cwd string|nil
--- @param module_cache table
--- @return boolean, string|nil, string, string|nil, string|nil, string|nil
function M.check(ctx, dbg, def, def_path, call_name, cwd, module_cache)
  -- Contract: ctx must have treesitter and (optionally) read_file.
  assert(ctx ~= nil, "definition_body.check: ctx is nil")
  assert(def ~= nil and def.range ~= nil, "definition_body.check: def.range is nil")
  local ts = ctx.treesitter
  assert(ts ~= nil and type(ts.parse) == "function", "definition_body.check: ctx.treesitter invalid")
  -- Review 1.3: defensive — `module_cache` may be nil when callers forget
  -- to thread it through. Treat as empty cache (no cached modules); the
  -- downstream `fifo_cache.get(module_cache, ...)` would otherwise raise
  -- "attempt to index a nil value" (fifo_cache.get expects a cache table
  -- with .map/.order fields, not nil).
  -- Item 19 (1.2.4 refactor): module_cache is now a fifo_cache instance
  -- (capped at 128 entries) instead of a plain table. When nil, we
  -- substitute an empty fifo_cache so the rest of the function can use
  -- the fifo_cache API uniformly.
  if module_cache == nil then
    module_cache = fifo_cache.new(128)
  end

  -- 1. Read the definition file source.
  local def_source = _read_def_source(ctx, def, def_path, dbg)
  if def_source == nil then
    -- Design decision (review finding: "语义反直觉——源读不到却认为有 body"):
    -- We intentionally return has_body=true here. Rationale: when the
    -- source file can't be read (permission denied, network mount down,
    -- file deleted since LSP indexed it), we CANNOT determine whether
    -- the callee has a body. Returning has_body=false would DISCARD the
    -- call (discarded_no_body), which is a false negative if the callee
    -- actually has a body (the common case for most real definitions).
    -- Returning has_body=true KEEPS the call as resolved with
    -- function_body_range=nil, which is a milder false positive (user
    -- sees the call but without a body range). Between losing a real
    -- call and showing a call without a body range, the latter is
    -- preferable for a code-analysis tool. The LSP already confirmed
    -- the definition EXISTS (it returned a Location), so we're not
    -- fabricating calls — we just can't extract the body range.
    -- Marked as "won't fix" per the review report's semantic concern;
    -- the behavior is intentional and documented.
    return true, nil, def_path, "could not read source for def file (kept conservatively; body range unavailable)", nil, nil
  end

  -- 2. Parse into a treesitter root.
  local def_lang = ctx.language or utils.DEFAULT_LANGUAGE
  local def_root, parse_err = _parse_def_tree(ts, def_source, def_lang, def_path, dbg)
  if def_root == nil then
    -- Parse failure (treesitter couldn't parse the def file). Same
    -- conservative rationale as def_source==nil above: keep the call
    -- rather than discard it, since the LSP confirmed the definition
    -- exists. The body range will be nil but the call stays visible.
    return true, nil, def_path, parse_err or "parse failed (kept conservatively)", nil, nil
  end

  -- 3. Locate def_node.
  local def_node = _find_def_node(ts, def_root, def)
  if def_node == nil then
    -- def_node lookup failed (range mismatch between LSP location and
    -- treesitter tree). Conservative: keep the call.
    return true, nil, def_path, "def_node is nil (kept conservatively)", nil, nil
  end

  -- 4. Find the function-definition node (including RHS scan).
  local func_def_node = _find_func_def_node(def_node)
  if func_def_node ~= nil then
    local has_body, range_1based, detail = _check_func_body(func_def_node)
    return has_body, range_1based, def_path, detail, nil, nil
  end

  -- 4b. Parameter declaration check: if def_node is inside a parameter
  -- boundary (parameter_list / parameter_declaration / parameters), the
  -- LSP definition points at a function-pointer-parameter declaration
  -- (e.g. clangd's response to `fp()` where `fp` is a parameter). Such
  -- a "definition" is not a real function body — but the call is real,
  -- and the spec requires it to be marked UNRESOLVED rather than
  -- discarded. Signal this via a special return: has_body=true (so the
  -- caller keeps the call) with range_1based=nil (no body) and a
  -- distinctive detail string that external_calls._check_has_body can
  -- detect and convert to "kept_unresolved" instead of "kept_resolved".
  --
  -- The detail prefix "PARAM_DECLARATION:" is the contract between this
  -- module and external_calls._check_has_body.
  -- Item 15 (1.2.4 refactor): the manual while-loop was replaced by a
  -- call to the shared `nodes.walk_up_until` helper. The predicate
  -- returns true on PARAMETER_BOUNDARY_TYPES matches; when walk_up_until
  -- returns a non-nil node, we know a parameter boundary was hit.
  local param_boundary = nodes.walk_up_until(def_node, function(cur)
    return PARAMETER_BOUNDARY_TYPES[cur:type()] or false
  end)
  if param_boundary ~= nil then
    return true, nil, def_path,
      M.PARAM_DECLARATION_PREFIX .. " definition is a parameter declaration (function pointer parameter); call kept as unresolved",
      nil, nil
  end

  -- 5. No function-definition ancestor — check if it's a bare declaration.
  local decl_ancestor, kind = _find_decl_ancestor(def_node)
  if decl_ancestor == nil then
    if kind == "bare" then
      return false, nil, def_path, "no function-definition ancestor (bare declaration)", nil, nil
    end
    return false, nil, def_path, "no function-definition ancestor (likely bare declaration)", nil, nil
  end

  -- 6. Module import / variable binding: try to resolve require().
  local module_spec = resolver.extract_require_module(def_node)
  if module_spec == nil then
    -- Variable binding to a non-function expression (e.g. Python
    -- `f = lambda x: x + 1` — lambda is NOT in FUNCTION_NODE_TYPES, so
    -- _scan_rhs_for_function already returned nil at step 4). There's
    -- no callable function body here, so discard the call as no-body.
    -- Previously this returned has_body=true, which kept lambda
    -- assignments as "resolved" external calls with a nil body range —
    -- misleading. Returning has_body=false lets the caller discard
    -- them via the standard "discarded_no_body" path.
    return false, nil, def_path,
      "variable binding to non-function expression (no require, no function_definition in RHS); function_body_range = null", nil, nil
  end

  -- Item 12 (1.2.4 refactor): the `_resolve_module_path` wrapper was
  -- removed — it was a thin adapter that just constructed `exists_func`
  -- from `ctx.fs` and forwarded to `module_finder.resolve_module_path`.
  -- The construction is now inlined here (3 lines), removing one level
  -- of indirection with zero behavior change. Review 3.6's note about
  -- `ctx.fs.exists(path)` vs `ctx.fs:exists(path)` still applies: we use
  -- the function form (not method-call form) because `fs.exists` is a
  -- regular function, not a method.
  local search_paths = ctx.package_paths or module_finder.DEFAULT_PACKAGE_PATHS
  local exists_func = nil
  if ctx.fs and type(ctx.fs.exists) == "function" then
    exists_func = function(path) return ctx.fs.exists(path) end
  end
  local resolved_path = module_finder.resolve_module_path(
    module_spec, search_paths, cwd, ctx.read_file, exists_func)
  if resolved_path == nil then
    -- This is a require() binding (module_spec is non-nil), but the
    -- module file could not be resolved on disk. Unlike the "could not
    -- read source" case above, here we KNOW the callee is a module-level
    -- function (the require() binding proves it), we just can't find
    -- the file to extract its body range. This commonly happens for
    -- pre-compiled C modules or Lua rockspec-installed packages whose
    -- source isn't on disk. We conservatively keep has_body=true so the
    -- call isn't discarded — the user will see the call in external_calls
    -- with definition.function_body_range = nil (acceptable: the call
    -- IS resolved to a module, we just don't have the body range).
    return true, nil, def_path,
      "require binding for '" .. module_spec .. "' but module file not resolved (may be pre-compiled)",
      module_spec, nil
  end

  -- 7. Read / cache the module file.
  -- Item 19 (1.2.4 refactor): use fifo_cache:get / fifo_cache:set instead
  -- of raw table access. fifo_cache handles eviction internally (oldest
  -- entry popped when over the 128-entry cap), preventing unbounded growth.
  local cached_mod = fifo_cache.get(module_cache, resolved_path)
  local mod_root, func_cache
  if cached_mod then
    mod_root = cached_mod.root
    func_cache = cached_mod.func_cache
  else
    mod_root, _ = _read_and_parse_module(ctx, ts, resolved_path, dbg)
    if mod_root == nil then
      return true, nil, resolved_path,
        "resolved module path " .. resolved_path .. " but could not read/parse source",
        module_spec, resolved_path
    end
    func_cache = {}
    fifo_cache.set(module_cache, resolved_path, { root = mod_root, func_cache = func_cache })
  end

  if mod_root == nil then
    return true, nil, resolved_path,
      "resolved module path " .. resolved_path .. " but no root node",
      module_spec, resolved_path
  end

  -- 8. Search the module for the function (with caching).
  -- Bug fix: previously `([%w_]+)$` did not match hyphens, so call_name
  -- like "get-data" was truncated to "data" (losing the "get-" prefix)
  -- and module-internal lookup failed. We now include hyphens in the
  -- suffix match. (Lua identifiers don't contain hyphens, but
  -- call_name may originate from other languages where hyphens are
  -- valid in identifiers — e.g. Python, Lisp, CSS-style keys.)
  local suffix = call_name:match("([%w_%-]+)$") or call_name
  local mod_func_node, mod_func_range, was_cached = _search_module_function(mod_root, func_cache, suffix)
  if mod_func_node and mod_func_range then
    local detail = was_cached
      and ("resolved via require('" .. module_spec .. "') -> " .. resolved_path .. ", function '" .. suffix .. "' found (cached)")
      or  ("resolved via require('" .. module_spec .. "') -> " .. resolved_path .. ", function '" .. suffix .. "' found")
    return true, mod_func_range, resolved_path, detail, module_spec, resolved_path
  end
  local detail = was_cached
    and ("resolved via require('" .. module_spec .. "') -> " .. resolved_path .. ", but function '" .. suffix .. "' not found in module (cached)")
    or  ("resolved via require('" .. module_spec .. "') -> " .. resolved_path .. ", but function '" .. suffix .. "' not found in module")
  return true, nil, resolved_path, detail, module_spec, resolved_path
end

return M
