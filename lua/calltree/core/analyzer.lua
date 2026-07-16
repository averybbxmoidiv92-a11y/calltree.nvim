--- core/analyzer.lua — thin orchestrator for calltree.nvim analysis.
---
--- This module is the entry point for analysis. It accepts injected dependencies
--- (a mock LSP client, a mock Treesitter, source code, cursor position, and a
--- `getcwd` function) and produces the structured JSON described in the spec.
---
--- The actual analysis logic is split into focused modules:
---   - utils                     — constants, path, range helpers
---   - utils.debug               — debug collector
---   - treesitter.nodes          — node comparison, name extraction, tree walking
---   - analysis.preconditions    — precondition checks
---   - resolution.require_resolver — Lua module/require resolution
---   - analysis.callers          — inbound caller analysis
---   - analysis.external_calls   — cross-function call analysis
---
--- This file orchestrates the pipeline and is intentionally free of `vim.*`
--- references so it can be unit-tested in a plain Lua environment.

local utils                = require("calltree.utils")
local debug_mod            = require("calltree.utils.debug")
local nodes                = require("calltree.treesitter.nodes")
local preconditions        = require("calltree.analysis.preconditions")
local caller_analysis      = require("calltree.analysis.callers")
local external_call_analysis = require("calltree.analysis.external_calls")
local definition_body_mod  = require("calltree.analysis.definition_body")
local types                = require("calltree.domain.types")

-- Domain types and service interfaces (orchestration layer may reference;
-- analysis layer should not reference directly).
local M = {}

-- Empty result returned for any "no-op" condition.
local EMPTY_RESULT = {
  current_function = nil,
  callers = {},
  external_calls = {},
}

-- Per-call deep copy of EMPTY_RESULT. We do NOT cache a single clone across
-- calls (the previous optimization attempt) because callers hold the
-- returned `r` by reference — if two `analyze()` calls both returned the
-- shared clone, the second call's `r.debug = ...` would retroactively
-- mutate the first caller's `r.debug`. The deepcopy is cheap (3-key table
-- + 2 empty arrays) and only happens on early-return paths, so the
-- allocation cost is negligible.

-- Maximum recursion depth for deepcopy. Guards against stack overflow on
-- deeply-nested acyclic tables (the `seen` memo only breaks true cycles, not
-- deep chains). 200 is comfortably above any realistic analysis result depth
-- while staying within Lua's default ~200-frame call stack.
local DEEPCOPY_MAX_DEPTH = 200

-- Deep-copy helper with cycle detection and type-safe handling.
-- - Tables are recursively copied, with a `seen` memo to break cycles.
-- - A depth guard (DEEPCOPY_MAX_DEPTH) prevents stack overflow on deeply-
--   nested acyclic tables.
-- - Functions and userdata/thread references are shared by reference (NOT
--   copied) — copying them is impossible without unsafe tricks, and the
--   analyzer's result tables only ever store functions for the `lsp_calls`
--   / `caller_decisions` debug records where sharing the reference is fine.
-- - Strings, numbers, booleans, and nil are immutable and returned as-is.
-- - The original metatable is preserved (shallow copy of the metatable
--   itself) so objects with `__index` method tables (e.g. DebugCollector
--   instances) keep their methods callable after copying.
local function deepcopy(t, seen, depth)
  if type(t) ~= "table" then return t end
  seen = seen or {}
  if seen[t] ~= nil then return seen[t] end
  depth = depth or 0
  if depth > DEEPCOPY_MAX_DEPTH then
    -- Exceeded max depth: return a shallow copy as a safe fallback rather
    -- than overflowing the stack. This is extremely unlikely in practice
    -- (analysis results are at most ~5 levels deep) but the guard prevents
    -- a crash if a pathological table is ever passed.
    local fallback = {}
    for k, v in pairs(t) do fallback[k] = v end
    return fallback
  end
  local copy = {}
  seen[t] = copy
  -- Wrap the pairs iteration in pcall so a misconfigured __pairs metamethod
  -- (or a mock table that raises on iteration) doesn't propagate the error.
  -- Previously only setmetatable was pcall'd, leaving the iteration unguarded.
  --
  -- Keys are NOT deep-copied: analysis-result keys are always strings or
  -- integers (immutable), so recursing on them was pure waste. Only the
  -- values are deep-copied. (Original code did `deepcopy(k, ...)` which
  -- for string keys returned the string unchanged — harmless but slow.
  -- For table keys it would recurse, which is rare but unbounded.)
  local ok_iter, iter_err = pcall(function()
    for k, v in pairs(t) do
      copy[k] = deepcopy(v, seen, depth + 1)
    end
  end)
  if not ok_iter then
    -- Review 3.4: capture the iteration error so a future maintainer can
    -- log it. We can't log from here (deepcopy has no dbg handle), but
    -- storing it on the partial copy lets callers inspect what went wrong.
    -- The previous code discarded the error (`_`), making debugging impossible.
    copy._deepcopy_error = tostring(iter_err)
    return copy
  end
  -- Preserve the original metatable so objects with method tables keep
  -- their behavior after copying.
  local mt = getmetatable(t)
  if mt ~= nil then
    -- pcall guards against mt being a value that setmetatable rejects
    -- (e.g. `false`). The error is intentionally not logged here because
    -- deepcopy is a module-local helper with no access to the debug
    -- collector; callers that need visibility into copy failures should
    -- validate the result table's shape.
    pcall(setmetatable, copy, mt)
  end
  return copy
end

-- Wall-clock time helper. Prefers `vim.uv.hrtime` (nanosecond wall clock;
-- `vim.uv` is the canonical name since Neovim 0.10 — `vim.loop` is a
-- deprecated alias). Falls back to `vim.loop.hrtime` for older Neovim, then
-- to `os.clock` (CPU time, sub-millisecond precision) for the pure-Lua test
-- environment. We previously used `os.time` (second precision) but that is
-- 9 orders of magnitude away from the nanosecond field semantics, making the
-- timing fields meaningless in tests. `os.clock` is at least in the right
-- ballpark for relative comparisons (note: it measures CPU time, not
-- wall-clock time, so cross-environment diffs are not directly comparable —
-- documented here so callers interpret the fields correctly).
--
-- NS_PER_SEC centralizes the ns→s conversion factor (was a literal `1e9`
-- repeated 3× in this function).
local NS_PER_SEC = 1e9
local function now()
  -- `vim` is a free variable that resolves to _G.vim at runtime; the
  -- previous `local vim = vim or _G.vim` was dead code (the `or _G.vim`
  -- branch could never trigger since a free `vim` reference IS _G.vim).
  if vim and vim.uv and vim.uv.hrtime then
    return vim.uv.hrtime() / NS_PER_SEC  -- ns -> s
  end
  if vim and vim.loop and vim.loop.hrtime then
    return vim.loop.hrtime() / NS_PER_SEC  -- deprecated alias, kept for old Neovim
  end
  if vim and vim._hrtime then
    return vim._hrtime() / NS_PER_SEC
  end
  -- Review 8.4: prefer `os.time()` over `os.clock()` as the pure-Lua fallback.
  -- `os.clock()` measures CPU time (not wall-clock), so timings collected in
  -- the pure-Lua test env were not comparable to timings collected in Neovim
  -- (which uses `vim.uv.hrtime` = wall-clock). `os.time()` returns wall-clock
  -- seconds (integer precision), matching the semantic of `hrtime/NS_PER_SEC`
  -- at lower resolution. We fall back to `os.clock()` only if `os.time` is
  -- unavailable (which never happens in practice) so the function never
  -- returns nil.
  if os and type(os.time) == "function" then
    return tonumber(os.time()) or 0
  end
  return os.clock()
end

------------------------------------------------------------------------------
-- _warn: thin wrapper around `if dbg and dbg.warning then dbg:warning(msg) end`.
-- Extracted because the exact pattern was repeated 4× in _run_analysis_phases,
-- making the phase loop noisy. Centralizing here keeps the callsites readable
-- and ensures future warn sites apply the same dbg-nil guard.
------------------------------------------------------------------------------
local function _warn(dbg, msg)
  if dbg and dbg.warning then
    dbg:warning(msg)
  end
end


-- Decorator: AOP cross-cutting logging.
-- `with_phase_logging` wraps a phase function, recording timing and a
-- result summary before/after the call. Business functions (e.g.
-- preconditions.check) keep their original signature; the decorator only
-- records at the outer layer.

local unpack_fn = table.unpack or unpack  -- Lua 5.4 uses table.unpack; LuaJIT/5.1 uses global unpack.

local function with_phase_logging(dbg, phase_name, fn)
  return function(...)
    local t_start = now()
    -- Use table.pack / select for Lua 5.1+ and LuaJIT compatibility,
    -- correctly passing through all return values.
    local results
    local ok, err
    if table.pack then
      results = table.pack(pcall(fn, ...))
      ok = results[1]
      err = results[2]
    else
      -- Lua 5.1 / LuaJIT has no table.pack. We capture pcall results into a
      -- table and use `#packed` as the count. LIMITATION: if `fn` returns a
      -- nil hole (e.g. `return a, nil, c`), `#packed` stops at the first nil
      -- and the trailing values are truncated. In practice the analyzer's
      -- phase functions never return nil-holed values (they return either
      -- nothing on success or (false, nil) on failure), so this is safe.
      -- If a future phase function needs nil-hole support, require Lua 5.2+
      -- (table.pack) or restructure to avoid nil-in-the-middle returns.
      local packed = { pcall(fn, ...) }
      ok = packed[1]
      err = packed[2]
      results = packed
      results.n = #packed
    end
    if dbg and dbg.timing then
      dbg:timing(phase_name .. "_seconds", now() - t_start)
    end
    if not ok then
      if dbg and dbg.error then
        dbg:error(phase_name, err)
      end
      if dbg and dbg.warning then
        dbg:warning(phase_name .. " phase failed; downstream phases may produce incomplete results")
      end
      -- On phase failure return (false, nil) so callers can distinguish
      -- "phase raised an error" from "phase succeeded with no return
      -- value" (the latter is the common case for caller/external
      -- analyzers, which mutate the result table in place and return
      -- nothing). Returning `false` here makes the success/failure
      -- check in _run_analysis_phases unambiguous.
      return false, nil
    end
    -- Pass through all return values of fn (dropping the first ok flag).
    -- Prepend `true` so callers can detect success unambiguously even
    -- when fn itself returns nothing (or returns nil).
    return true, unpack_fn(results, 2, results.n)
  end
end


-- Query/Command helpers (orchestration layer only; business logic stays
-- in the analysis layer).


-- Command: build an empty result. Called only on early-return paths.
-- Uses the domain-types CallGraphBuilder to construct the result,
-- ensuring the field shape matches the CallGraph type definition.
-- Review 9.1: instead of `deepcopy(EMPTY_RESULT)` on every early return
-- (which creates a short-lived temp table per call, increasing GC pressure
-- on hot paths like "cursor not on a function name"), we use the
-- CallGraphBuilder which constructs a fresh mutable table directly.
-- The builder's :build() call at the end of _run_analysis_phases freezes
-- the final result; for early-return paths we attach debug (if enabled)
-- and return the mutable table directly (freezing is not needed since
-- the caller receives a fresh table each time).
local function _build_empty_result(dbg, debug_enabled, reason, t_start)
  if debug_enabled then
    dbg:set_completion_reason(reason)
    dbg:timing("total_seconds", now() - t_start)
  end
  -- Item 5 (1.2.4 refactor): delegate to `types.EmptyCallGraph` instead
  -- of hand-constructing the { current_function, callers, external_calls,
  -- debug } table here. The factory centralizes the field list so any
  -- future shape change (e.g. adding a `metadata` field) only needs to
  -- be made in one place. Previously this same shape was duplicated in
  -- 4+ early-return paths (analyzer + init.lua cursor-error fallbacks),
  -- risking drift if the shape ever changed.
  local debug_snapshot = nil
  if debug_enabled then
    debug_snapshot = dbg:get()
  end
  return types.EmptyCallGraph(debug_snapshot)
end

-- Query: locate the treesitter node at the cursor position within root.
local function _detect_cursor_node(ts, root, cursor_pos)
  return ts.descendant_for_range(ts, root,
    cursor_pos.line, cursor_pos.character,
    cursor_pos.line, cursor_pos.character)
end

-- Query: resolve the current function name. Prefers node:text(), falls
-- back to node._text, then symbol.name.
-- Note: the `node._text` fallback MUST be a separate `if` (not `elseif`)
-- because when `node.text` is a function but pcall returns an empty string,
-- the outer `if` branch is taken (condition was true) so an `elseif` would
-- never evaluate. Using a separate `if` ensures the `_text` fallback runs
-- whenever the `text()` call did not produce a usable string.
local function _resolve_current_name(node, symbol)
  -- Simplified `node.text and type(node.text) == "function"` to
  -- `type(node.text) == "function"` — `type()` returns a non-nil string
  -- for every value, so the leading `node.text` truthiness check is dead.
  if type(node.text) == "function" then
    local ok, t = pcall(node.text, node)
    if ok and t and t ~= "" then return t end
  end
  if node._text and node._text ~= "" then
    return node._text
  end
  if symbol and symbol.name then return symbol.name end
  return nil
end

------------------------------------------------------------------------------
-- _find_body_child: find the first named child of func_node whose type is
-- in definition_body_mod.BLOCK_NODE_TYPES (compound_statement / block /
-- body / etc.). Extracted from a 17-line `do ... end` block inside
-- _locate_cursor_function so the main function reads as a sequence of
-- queries. Returns nil when no body child is found.
-- @param func_node table
-- @return table|nil body_child
-- Item 4 (1.2.4 refactor): delegates to the shared `nodes.find_body_child`
-- helper, which is also used by `definition_body._check_func_body`. The
-- two implementations were near-identical; centralizing means a future
-- change to the body-detection logic (e.g. handling a new block type)
-- only needs to be made in BLOCK_NODE_TYPES, not in two walk loops.
------------------------------------------------------------------------------
local function _find_body_child(func_node)
  return nodes.find_body_child(func_node, definition_body_mod.BLOCK_NODE_TYPES)
end


-- Main analyze function
-- Phase 2-4: locate the function at the cursor, build current_function +
-- state. On failure returns _build_empty_result(...) (caller should
-- return directly). On success returns (result, state).
local function _locate_cursor_function(ctx, dbg, debug_enabled, ts, root, symbols, t_start)
  local file_path = ctx.file_path
  local cursor_pos = ctx.cursor_pos

  -- Phase 2: Find the node at the cursor (query)
  local node = _detect_cursor_node(ts, root, cursor_pos)
  if debug_enabled then
    dbg.data.cursor_detection.node_at_cursor = debug_mod.node_summary(node)
  end
  if node == nil then
    if debug_enabled then
      dbg.data.cursor_detection.reason = "no treesitter node at cursor position"
    end
    return _build_empty_result(dbg, debug_enabled, "cursor_no_node", t_start), nil
  end

  -- Phase 3: Check if cursor is on a function-definition name (query)
  local func_node = nodes.is_function_name_node(node, dbg)
  if func_node == nil then
    if debug_enabled then
      dbg.data.cursor_detection.is_name_node = false
      dbg.data.cursor_detection.reason =
        "node type '" .. tostring(node:type()) ..
        "' is not a function-definition name (not in NAME_NODE_TYPES, or no " ..
        "function-definition ancestor reachable without crossing a body/parameters block)"
    end
    return _build_empty_result(dbg, debug_enabled, "cursor_not_on_function_name", t_start), nil
  end
  if debug_enabled then
    dbg.data.cursor_detection.is_name_node = true
    dbg.data.cursor_detection.function_node = debug_mod.node_summary(func_node)
  end

  -- Phase 4: Cross-check with LSP document symbols (query)
  local symbol = preconditions.find_function_symbol_at(symbols, cursor_pos)
  if symbol == nil then
    if debug_enabled then
      dbg.data.cursor_detection.symbol_match = nil
      dbg.data.cursor_detection.reason =
        "no LSP document symbol of kind Function/Method encloses the cursor"
    end
    return _build_empty_result(dbg, debug_enabled, "cursor_no_lsp_symbol", t_start), nil
  end
  -- LSP SymbolKind constants we accept as "this symbol denotes a function":
  --   6  = Method
  --   12 = Function
  --   13 = Variable   (JS/TS: `const foo = () => {}`, `let bar = function() {}`)
  --   14 = Constant   (JS/TS: `const add = (a,b) => a+b`)
  -- Some LSP servers (notably typescript-language-server) classify
  -- arrow-function / function-expression assignments as Variable or
  -- Constant rather than Function. We accept these ONLY when the
  -- treesitter node we already identified (func_node above) is a
  -- function-type node — so a non-function variable/constant doesn't
  -- slip through. This keeps the check strict for languages where the
  -- LSP correctly tags functions as Function/Method, while allowing
  -- JS/TS arrow-function assignments to be analyzed.
  -- Use the centralized LSP SymbolKind constants from utils.constants
  -- (was a local literal 13/14 that duplicated preconditions.lua).
  local LSP_SYMBOL_VARIABLE = utils.LSP_SYMBOL_VARIABLE
  local LSP_SYMBOL_CONSTANT = utils.LSP_SYMBOL_CONSTANT
  local kind_acceptable = (symbol.kind == utils.LSP_SYMBOL_FUNCTION
                        or symbol.kind == utils.LSP_SYMBOL_METHOD)
  -- For Variable/Constant kinds, only accept if func_node is actually a
  -- function-type treesitter node (already verified in Phase 3).
  if not kind_acceptable
     and (symbol.kind == LSP_SYMBOL_VARIABLE or symbol.kind == LSP_SYMBOL_CONSTANT)
     and func_node ~= nil
     and utils.FUNCTION_NODE_TYPES[func_node:type()] then
    kind_acceptable = true
  end
  if not kind_acceptable then
    if debug_enabled then
      dbg.data.cursor_detection.symbol_match = { name = symbol.name, kind = symbol.kind }
      dbg.data.cursor_detection.reason =
        "LSP symbol kind is " .. tostring(symbol.kind) ..
        " (expected " .. utils.LSP_SYMBOL_FUNCTION ..
        " = Function or " .. utils.LSP_SYMBOL_METHOD .. " = Method)"
    end
    return _build_empty_result(dbg, debug_enabled, "cursor_symbol_wrong_kind", t_start), nil
  end
  if debug_enabled then
    dbg.data.cursor_detection.symbol_match = { name = symbol.name, kind = symbol.kind }
  end

  -- Query: resolve the current function name.
  local current_name = _resolve_current_name(node, symbol)
  -- Query: compute the current function body range (1-based closed).
  -- Replaced the inline `type(func_node.range) == "function"` + pcall
  -- pattern with utils.safe_range — same defensive behavior (returns
  -- nils on failure), one less duplicated pattern.
  -- Review 4.1: provide default numeric values for cur_start_line /
  -- cur_end_line / cur_end_col so downstream state never sees nils.
  -- Previously a nil range propagated into `state.cur_start_line`, then
  -- into external_calls._check_in_scope where `ds_line >= c_start_line`
  -- would crash with "attempt to compare number with nil".
  local cur_start_line, _, cur_end_line, cur_end_col =
    utils.safe_range(func_node)
  cur_start_line = cur_start_line or 0
  cur_end_line   = cur_end_line or 0
  cur_end_col    = cur_end_col or 0
  local cur_range_1based = nodes.range_to_1based_closed(cur_start_line, cur_end_line, cur_end_col)
  -- Defensive fallback: when range is nil (mock node without :range(),
  -- or treesitter parse anomaly), use {0, 0} as a sentinel so downstream
  -- consumers like dump_at_cursor can index cf.range[1] without raising.
  if cur_range_1based == nil then
    cur_range_1based = { 0, 0 }
  end
  local cur_closed_end = nodes.closed_end_line_0based(cur_start_line, cur_end_line, cur_end_col)

  -- Query: locate the function body's start position (line, col).
  -- Used by external_calls._check_in_scope to distinguish "real in-body
  -- nested function definition" from "parameter declaration on the
  -- function signature line". For C/C++, clangd's textDocument/definition
  -- on a function-pointer-parameter call returns the parameter declaration
  -- position (which sits on the function's signature line, BEFORE the
  -- compound_statement body starts). Without this distinction, the in_scope
  -- check would wrongly discard such calls as "local nested function".
  -- When no body child is found, fall back to (cur_start_line, 0) so the
  -- in_scope check degrades to the previous line-range-only behavior.
  --
  -- The body-child search was previously a 17-line `do ... end` block
  -- inside _locate_cursor_function; extracted to `_find_body_child` so the
  -- main function reads as a sequence of queries.
  local cur_body_start_line = cur_start_line
  local cur_body_start_col  = 0
  local body_child = _find_body_child(func_node)
  if body_child then
    local bsl, bsc = utils.safe_range(body_child)
    if bsl ~= nil then
      cur_body_start_line = bsl
      cur_body_start_col  = bsc or 0
    end
  end
  -- Review 4.2: ensure cur_body_start_line is non-nil even when the
  -- body_child's :range() failed. Defaults to cur_start_line (already
  -- defaulted to 0 above), so external_calls._check_in_scope never
  -- sees a nil body_line.
  cur_body_start_line = cur_body_start_line or cur_start_line or 0
  cur_body_start_col  = cur_body_start_col or 0

  -- Command: build the result object using the domain-types
  -- CallGraphBuilder. The current_function sub-table is constructed
  -- as a plain table (name + range + file) and stored in the builder.
  -- The builder stays mutable during phases 5-6 (callers / external_calls
  -- append to its arrays); :build() is called at the end of
  -- _run_analysis_phases to freeze the final CallGraph.
  local builder = types.CallGraphBuilder()
  builder.current_function = {
    name = current_name,
    range = cur_range_1based,
    file = file_path,
  }
  assert(builder.current_function.file ~= nil, "analyzer: current_function.file is nil")

  local result = builder
  local state = {
    current_name       = current_name,
    func_node          = func_node,
    cur_start_line     = cur_start_line,
    cur_closed_end     = cur_closed_end,
    cur_body_start_line = cur_body_start_line,
    cur_body_start_col  = cur_body_start_col,
  }
  return result, state
end

-- Phase 5-6 + Finalize: run caller/external analysis, populate result,
-- and validate contracts.
--
-- Returns true on success (both phases ran without raising), false if any
-- phase failed (the decorator returns nil on pcall failure). The result
-- table is still populated with whatever partial data the phases wrote
-- before failing; the caller (M.analyze) records a completion_reason
-- reflecting the partial-success outcome.

-- v1.2.0: Post-collection filtering for external_calls.
--
-- Two independent flags (both default to true, configurable via setup()):
--   - skip_stdlib_calls: drop entries with is_stdlib=true
--   - deduplicate_external_calls: drop entries that share the same
--     (function_name, definition.file) pair with an earlier entry
--
-- Processing order (MANDATORY):
--   1. deduplicate FIRST (on the full collected list, including stdlib)
--   2. then filter stdlib (on the deduplicated list)
--
-- Rationale: dedup uses (function_name, definition.file) as the key. If
-- we filtered stdlib first, two stdlib entries for the same function
-- would both be dropped before dedup ran — which is fine — BUT a stdlib
-- entry and a project entry sharing the same (name, file) pair (rare but
-- possible when a project shadows a stdlib name) would not be deduped,
-- leaving the project entry in the result. By deduping first, we ensure
-- the first-occurrence-wins rule applies uniformly, and the stdlib filter
-- then operates on a clean list. The user-visible behavior is:
--   - one entry per (function_name, definition.file) pair
--   - no stdlib entries in the final output (when skip_stdlib_calls=true)

-- Build the dedup key for an external_call entry. Returns a string suitable
-- for use as a table key, or nil when the entry lacks both name and file
-- (in which case the entry is kept as-is — never silently dropped by dedup).
-- The key is `function_name \0 definition.file` so a name containing "/"
-- cannot collide with a file path separator.
local function _external_call_dedup_key(ec)
  if ec == nil then return nil end
  local name = ec.function_name or ""
  local file = (ec.definition and ec.definition.file) or ""
  if name == "" and file == "" then return nil end
  return name .. "\0" .. file
end

-- Deduplicate external_calls in place, keeping the first occurrence of
-- each (function_name, definition.file) pair. Entries with no name AND
-- no file (the dedup key is nil) are always kept (never silently dropped).
-- Returns the deduplicated count (number of entries removed).
local function _deduplicate_external_calls(result, dbg, debug_enabled)
  local calls = result.external_calls
  if type(calls) ~= "table" then return 0 end
  local seen = {}
  local kept = {}
  local removed = 0
  for _, ec in ipairs(calls) do
    local key = _external_call_dedup_key(ec)
    if key == nil then
      -- No dedup key — always keep (don't silently drop entries we can't
      -- identify). This is rare (only happens for malformed entries).
      kept[#kept + 1] = ec
    elseif not seen[key] then
      seen[key] = true
      kept[#kept + 1] = ec
    else
      removed = removed + 1
    end
  end
  result.external_calls = kept
  if debug_enabled and removed > 0 then
    _warn(dbg, "external_calls dedup removed " .. removed .. " duplicate entries "
      .. "(kept " .. #kept .. " of " .. #calls .. " collected)")
  end
  return removed
end

-- Filter out stdlib entries from external_calls in place. Returns the
-- filtered count (number of entries removed). When skip_stdlib_calls is
-- false or nil, this is a no-op.
local function _filter_stdlib_external_calls(result, dbg, debug_enabled)
  local calls = result.external_calls
  if type(calls) ~= "table" then return 0 end
  local kept = {}
  local removed = 0
  for _, ec in ipairs(calls) do
    if ec.is_stdlib ~= false then
      removed = removed + 1
    else
      kept[#kept + 1] = ec
    end
  end
  result.external_calls = kept
  if debug_enabled and removed > 0 then
    _warn(dbg, "external_calls stdlib filter removed " .. removed
      .. " stdlib entries (kept " .. #kept .. ")")
  end
  return removed
end

-- Apply the post-collection pipeline (dedup + stdlib filter) to
-- result.external_calls. Updates summary counts to reflect the final
-- array length. Records raw count in debug for diagnostics when filtering
-- actually changes the list.
local function _apply_external_calls_post_processing(ctx, dbg, result, debug_enabled)
  -- Item 20 (1.2.4 refactor): the duplicate `if X == nil then X = true end`
  -- default-resolution for `skip_stdlib_calls` and `deduplicate_external_calls`
  -- was removed. init.lua already resolves these flags (opts → M.options →
  -- true default) and writes the resolved boolean into ctx before calling
  -- analyzer.analyze. Re-resolving here duplicated the default value (true)
  -- in two places — if the default ever changed in init.lua, this code
  -- would silently keep the old default, causing drift. We now trust ctx
  -- to always carry a boolean (falling back to true only when ctx itself
  -- is missing the field, which is a defensive measure for direct callers
  -- that bypass init.lua — e.g. unit tests that construct ctx by hand).
  local dedup_enabled = ctx.deduplicate_external_calls
  if dedup_enabled == nil then dedup_enabled = true end
  local skip_stdlib = ctx.skip_stdlib_calls
  if skip_stdlib == nil then skip_stdlib = true end

  local raw_count = (type(result.external_calls) == "table") and #result.external_calls or 0

  -- Order: dedup FIRST, then stdlib filter (see header comment for rationale).
  local dedup_removed = 0
  if dedup_enabled then
    dedup_removed = _deduplicate_external_calls(result, dbg, debug_enabled)
  end
  local stdlib_removed = 0
  if skip_stdlib then
    stdlib_removed = _filter_stdlib_external_calls(result, dbg, debug_enabled)
  end

  -- Recompute summary counts so they reflect the FINAL array length.
  -- The external_calls phase incremented calls_kept / calls_unresolved /
  -- calls_in_scope / etc. as it collected; after filtering those counts
  -- no longer match #result.external_calls. We recompute the two summary
  -- fields that callers most commonly inspect (calls_kept and
  -- calls_unresolved) from the final list, and stash the raw pre-filter
  -- count in debug for diagnostics.
  local final_count = (type(result.external_calls) == "table") and #result.external_calls or 0
  if debug_enabled and (dedup_removed > 0 or stdlib_removed > 0) then
    -- Stash the raw count for debugging. This is NOT a default summary
    -- field (per the spec); it lives under debug.inputs alongside the
    -- other raw-input snapshots.
    if type(dbg.data) == "table" and type(dbg.data.inputs) == "table" then
      dbg.data.inputs.raw_external_calls_before_filter = raw_count
      dbg.data.inputs.external_calls_dedup_removed = dedup_removed
      dbg.data.inputs.external_calls_stdlib_removed = stdlib_removed
    end
  end

  -- Recompute calls_kept and calls_unresolved from the final list.
  -- The other summary counters (calls_in_scope, calls_no_body,
  -- calls_outside_project, calls_kept as-kept-stdlib) are left as-is —
  -- they describe the DECISIONS made during collection, which is
  -- useful for debugging even after filtering. Only calls_kept and
  -- calls_unresolved are recomputed because they directly correspond
  -- to "what's in the result array" (kept = resolved entries in array;
  -- unresolved = unresolved entries in array).
  if type(result.debug) == "table" and type(result.debug.summary) == "table" then
    local kept_count = 0
    local unresolved_count = 0
    for _, ec in ipairs(result.external_calls or {}) do
      if ec.resolution_status == utils.RESOLUTION_STATUS_RESOLVED then
        kept_count = kept_count + 1
      elseif ec.resolution_status == utils.RESOLUTION_STATUS_UNRESOLVED then
        unresolved_count = unresolved_count + 1
      end
    end
    result.debug.summary.calls_kept = kept_count
    result.debug.summary.calls_unresolved = unresolved_count
  end
end

local function _run_analysis_phases(ctx, dbg, state, result, t_start, debug_enabled)
  local phase_failed = false

  -- Phase 5: Inbound caller analysis (decorator-wrapped). The decorator
  -- returns (true, ...) on success and (false, nil) on pcall failure;
  -- we only mark phase_failed on the latter.
  local caller_analyze = with_phase_logging(dbg, "callers", caller_analysis.analyze)
  local ok_callers = caller_analyze(ctx, dbg, state, result)
  if ok_callers == false then
    phase_failed = true
    _warn(dbg, "callers phase returned nil; result.callers may be incomplete")
  end

  -- Phase 6: Cross-function call analysis (decorator-wrapped)
  local external_analyze = with_phase_logging(dbg, "external_calls", external_call_analysis.analyze)
  local ok_external = external_analyze(ctx, dbg, state, result)
  if ok_external == false then
    phase_failed = true
    _warn(dbg, "external_calls phase returned nil; result.external_calls may be incomplete")
  end

  -- Contract: callers and external_calls must always be tables. Previously
  -- these used `assert(...)`, which would raise and propagate to the caller
  -- — violating the "M.analyze always returns a result table" contract.
  -- Replace with defensive fallbacks so a partial phase failure (e.g.
  -- caller_analysis.analyze returned nil due to an internal bug) doesn't
  -- crash the whole analyze call.
  if type(result.callers) ~= "table" then
    if debug_enabled then
      _warn(dbg, "result.callers was not a table; replaced with empty array")
    end
    result.callers = {}
  end
  if type(result.external_calls) ~= "table" then
    if debug_enabled then
      _warn(dbg, "result.external_calls was not a table; replaced with empty array")
    end
    result.external_calls = {}
  end

  -- v1.2.0: Apply post-collection filtering (dedup + stdlib filter) to
  -- result.external_calls. This runs AFTER the external_calls phase
  -- finishes collecting and AFTER the table-type contract check above
  -- (so the filter always sees a real table). The summary counts
  -- (calls_kept, calls_unresolved) are recomputed inside this call to
  -- reflect the final array length.
  --
  -- IMPORTANT: this must run BEFORE `result.debug = dbg:get()` below,
  -- so that the summary recompute (which writes to result.debug.summary)
  -- takes effect on the snapshot that gets attached to the result. We
  -- handle this by attaching dbg:get() to result.debug first (so the
  -- summary table is shared by reference), then calling the filter —
  -- writes to result.debug.summary inside the filter will be visible in
  -- the final result.
  if debug_enabled then
    -- Attach debug snapshot early so _apply_external_calls_post_processing
    -- can write summary updates that will be visible in the final result.
    -- (dbg:get() returns the live data table by reference, so subsequent
    -- mutations are reflected.)
    result.debug = dbg:get()
  end
  _apply_external_calls_post_processing(ctx, dbg, result, debug_enabled)

  -- Finalize
  if debug_enabled then
    dbg:set_completion_reason(phase_failed and "analyzed_with_phase_errors" or "analyzed")
    dbg:timing("total_seconds", now() - t_start)
    -- result.debug was already attached above; no need to re-attach (the
    -- table is shared by reference, so timing/reason updates are visible).
    -- But re-attach defensively in case a future refactor detaches it.
    result.debug = dbg:get()
  end
  -- Merge LSP adapter diagnostics into the debug snapshot BEFORE freezing.
  -- This was previously done in init.lua AFTER analyze() returned, but
  -- now that the result is frozen (via :build()), post-return writes to
  -- result.debug would raise. Moving the merge here keeps the same
  -- user-visible behavior (debug.lsp_adapter_diagnostics is populated)
  -- while respecting the immutability contract.
  if result.debug and ctx.lsp_client and type(ctx.lsp_client._diagnostics) == "function" then
    result.debug.lsp_adapter_diagnostics = ctx.lsp_client._diagnostics()
  end
  -- Freeze the final CallGraph so the caller receives an immutable result.
  -- The CallGraphBuilder's :build() deep-copies + freezes the current
  -- state, including current_function, callers (already-frozen CallerInfo
  -- entries), external_calls (already-frozen ExternalCall entries), and
  -- debug (if attached). The returned frozen proxy raises on any write
  -- attempt, protecting the result from accidental mutation downstream.
  -- We return the frozen proxy directly.
  -- Note: result is a CallGraphBuilder (table with current_function,
  -- callers, external_calls, debug, and a :build() method). :build()
  -- only freezes the data fields, not the :build() method closure (which
  -- lives on the builder, not in the data the proxy wraps).
  return result:build()
end


--- Run the full analysis. Returns a table ready to be JSON-encoded.
--- The result always contains a `debug` field with comprehensive diagnostics.
--- @param ctx table {
---   source_code = string,
---   file_path   = string,
---   cursor_pos  = { line = number, character = number } (0-based),
---   language    = string (default "lua"),
---   lsp_client  = table,
---   treesitter  = table,
---   getcwd      = function,
---   read_file   = function|nil,
---   package_paths = array|nil,
--- }
--- @return table result
function M.analyze(ctx)
  -- Contract: ctx must be non-nil for analysis to be meaningful. Rather
  -- than raising (which violates the "always return a result table"
  -- contract of this function), return an empty result with a debug
  -- completion_reason so callers can introspect the failure.
  if ctx == nil then
    local t_start = now()
    local dbg = debug_mod.new({ source_code = "", file_path = "", cursor_pos = { line = 0, character = 0 } })
    return _build_empty_result(dbg, true, "ctx_is_nil", t_start)
  end

  local t_start = now()
  local debug_enabled = ctx.debug ~= false  -- default: enabled
  local dbg = debug_enabled and debug_mod.new(ctx) or debug_mod.disabled()

  -- Phase 1: Precondition checks (direct call + manual timing). Wrapped
  -- in pcall so that an unexpected error inside preconditions.check does
  -- not propagate to the caller — we record it as a completion_reason
  -- instead and return an empty result.
  -- preconditions.check returns (ok, root, symbols) on success; pcall
  -- prepends a `true` flag so we capture 4 values total. On failure pcall
  -- returns (false, err) and the trailing vars are nil.
  local t0 = now()
  local ok_pre, ok_flag, root, symbols = pcall(preconditions.check, ctx, dbg)
  if debug_enabled then dbg:timing("preconditions_seconds", now() - t0) end
  if not ok_pre then
    if dbg and dbg.error then
      dbg:error("preconditions", tostring(ok_flag))
    end
    return _build_empty_result(dbg, debug_enabled, "preconditions_panic", t_start)
  end
  if not ok_flag then
    return _build_empty_result(dbg, debug_enabled, "preconditions_failed", t_start)
  end

  -- Phase 2-4: locate the cursor function.
  local result, state = _locate_cursor_function(
    ctx, dbg, debug_enabled, ctx.treesitter, root, symbols, t_start)
  if state == nil then
    -- _locate_cursor_function returned an empty_result; pass it through.
    return result
  end

  -- Phase 5-6 + Finalize: run analysis and validate.
  return _run_analysis_phases(ctx, dbg, state, result, t_start, debug_enabled)
end

return M
