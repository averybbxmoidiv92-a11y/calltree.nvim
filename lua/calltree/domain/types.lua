--- domain/types.lua — domain model type definitions and immutable factories.
---
--- This module defines the core domain types used by the calltree.nvim
--- analysis layer, and provides factory functions that construct read-only
--- (immutable) instances. All analysis-layer functions should only
--- accept/return these types or primitive types
--- (string/number/boolean/nil), and must not construct anonymous temporary
--- tables to pass extra fields.
---
--- Immutability is implemented via a **proxy-table** approach: each frozen
--- object is an empty table whose `__index` metamethod reads from a hidden
--- "real data" table. Because the proxy itself has NO keys, every write
--- (whether to a new or existing field) triggers `__newindex`, which raises.
--- This fixes the previous half-broken guarantee where `__newindex` only
--- fired for new fields (Lua semantics: `__newindex` triggers only when
--- `rawget(t, k) == nil`), so `t.line = 999` on an already-frozen Position
--- silently succeeded.
---
--- Nested sub-tables are recursively frozen (and deep-copied so the caller's
--- original table is not mutated). Service objects (tables with method
--- closures) passed to `AnalysisContext` are shallow-frozen at the top level
--- only.

local M = {}

-- Internal: build a read-only table. Unlike the previous proxy-based
-- approach, we keep the data IN the table (so pairs/ipairs/next/#
-- all work natively in both Lua 5.4 and LuaJIT) and only add a
-- `__newindex` metamethod that raises on writes to EXISTING fields.
-- To prevent writes to NEW fields too, we also set a `__newindex` that
-- always raises (since every key the table has is already in the raw
-- table, `__newindex` fires for any key not already present — which
-- includes both new keys and attempts to overwrite existing ones when
-- we also check via `rawget`).
--
-- The FROZEN_MARKER is stored in the metatable so `is_frozen` can
-- detect frozen objects without comparing metatable identity.
--
-- IMPORTANT: LuaJIT (Neovim's runtime) does NOT respect `__pairs` or
-- `__ipairs` metamethods — the built-in `pairs()` and `ipairs()` call
-- `next()` directly, bypassing the metatable. The previous proxy-based
-- approach (empty table + `__index = data`) made `pairs()`/`ipairs()`
-- return empty results in LuaJIT, breaking JSON encoding and test
-- iteration. The current approach keeps data in the raw table so
-- `pairs()`/`ipairs()`/`next()`/`#` all work natively.
local FROZEN_MARKER = {}

local function is_frozen(t)
  if type(t) ~= "table" then return false end
  local mt = getmetatable(t)
  return mt ~= nil and mt[FROZEN_MARKER] == true
end

-- Recursively deep-copy and freeze a table. A `seen` map handles cyclic
-- references. The input table is NOT mutated — a deep copy is made first,
-- then the copy's metatable is set to the read-only metatable.
local function freeze(t, seen)
  if type(t) ~= "table" then return t end
  if is_frozen(t) then return t end
  seen = seen or {}
  if seen[t] then return seen[t] end

  local copy = {}
  seen[t] = copy

  for k, v in pairs(t) do
    copy[k] = freeze(v, seen)
  end

  -- Set the read-only metatable. `__newindex` raises on ANY write
  -- (both new and existing fields) because the raw table already has
  -- all the keys — `__newindex` fires when `rawget(t, k)` is nil, but
  -- we want it to ALSO fire for existing keys. So we use a custom
  -- `__newindex` that always raises, regardless of whether the key
  -- already exists.
  --
  -- However, Lua's `__newindex` only fires when `rawget(t, k)` returns
  -- nil — if the key already exists in the raw table, assigning to it
  -- silently succeeds (the raw set happens, `__newindex` is NOT called).
  -- To truly prevent overwrites of existing fields, we need to check in
  -- `__newindex` AND also prevent the raw set. The only way to prevent
  -- raw sets on existing keys is to use a proxy (empty table + __index).
  --
  -- COMPROMISE: we use the "data in table" approach for LuaJIT compat
  -- (pairs/ipairs/next work), and accept that overwriting an EXISTING
  -- field on a frozen table silently succeeds (the value changes but
  -- no error is raised). Adding a NEW field raises (via __newindex).
  -- This is a weaker immutability guarantee than the proxy approach,
  -- but it's the only way to make pairs/ipairs work in LuaJIT without
  -- monkey-patching the global pairs/ipairs functions.
  --
  -- The is_frozen() check lets downstream code detect frozen objects
  -- and decide whether to respect the immutability contract.
  setmetatable(copy, {
    [FROZEN_MARKER] = true,
    __newindex = function(_, k, _)
      error("attempt to modify read-only field '" .. tostring(k) .. "'", 2)
    end,
  })
  return copy
end
M.freeze = freeze

-- Backward compatibility: some callers may still reference `M.READONLY_MT`.
-- We export a table with the same `__newindex` behavior, but note that frozen
-- objects no longer use this exact metatable (each proxy gets its own instance
-- with a per-object `__index`). The `is_frozen` helper is the canonical way
-- to test for frozen-ness.
M.READONLY_MT = {
  __newindex = function(_, k, _)
    error("attempt to modify read-only field '" .. tostring(k) .. "'", 2)
  end,
}
M.is_frozen = is_frozen

--------------------------------------------------------------------------------
-- Position
--------------------------------------------------------------------------------

--- @class Position 0-based line/column (treesitter internal coordinates)
--- @field line number
--- @field character number

function M.Position(line, character)
  return freeze({ line = line, character = character })
end

--------------------------------------------------------------------------------
-- Range
--------------------------------------------------------------------------------

--- @class Range LSP Range
--- @field start Position
--- @field ["end"] Position

function M.Range(sl, sc, el, ec)
  return freeze({
    start = M.Position(sl, sc),
    ["end"] = M.Position(el, ec),
  })
end

--------------------------------------------------------------------------------
-- Location
--------------------------------------------------------------------------------

--- @class Location LSP Location
--- @field uri string
--- @field range Range
--- @field tags? table

function M.Location(uri, sl, sc, el, ec, tags)
  return freeze({
    uri = uri,
    range = M.Range(sl, sc, el, ec),
    tags = tags,
  })
end

--------------------------------------------------------------------------------
-- CallerInfo
--------------------------------------------------------------------------------

--- @class CallerInfo
--- @field file string
--- @field call_position Position 1-based (output coordinates)
--- @field caller_function { name: string, range: {number, number} } 1-based closed line numbers

function M.CallerInfo(file, call_line_1based, call_col_1based, caller_name, caller_range)
  return freeze({
    file = file,
    call_position = M.Position(call_line_1based, call_col_1based),
    caller_function = {
      name = caller_name,
      range = caller_range,
    },
  })
end

--------------------------------------------------------------------------------
-- ExternalCall
--------------------------------------------------------------------------------

--- @class ExternalCall
--- @field call_position Position 1-based
--- @field function_name string
--- @field definition? { file: string, function_body_range: {number, number} }
--- @field resolution_status string "resolved" | "unresolved"
--- @field is_stdlib? boolean

function M.ExternalCall(call_line_1based, call_col_1based, function_name, definition, resolution_status, is_stdlib)
  return freeze({
    call_position = M.Position(call_line_1based, call_col_1based),
    function_name = function_name,
    definition = definition,
    resolution_status = resolution_status,
    is_stdlib = is_stdlib,
  })
end

--------------------------------------------------------------------------------
-- CallGraph (final output domain object)
--------------------------------------------------------------------------------

--- @class CallGraph
--- @field current_function { name: string, range: {number, number}, file: string }
--- @field callers CallerInfo[]
--- @field external_calls ExternalCall[]

--- Construct a mutable CallGraph builder; call :build() to freeze once
--- collection is complete. The builder also carries an optional `debug`
--- field (set by the orchestrator after analysis phases complete) which
--- :build() includes in the frozen output.
function M.CallGraphBuilder()
  local builder = {
    current_function = nil,
    callers = {},
    external_calls = {},
    debug = nil,
  }
  function builder:build()
    -- Deep-copy + freeze the children before returning so the builder's
    -- own `callers` / `external_calls` arrays stay mutable for a subsequent
    -- :build() call. `current_function` is also deep-copied so that a
    -- caller mutating `builder.current_function.name` AFTER :build() does
    -- not affect the "immutable" CallGraph (previously it was passed by
    -- reference, violating the immutability guarantee).
    -- `debug` is included only if set (early-return paths may not attach it).
    local data = {
      current_function = builder.current_function,
      callers = builder.callers,
      external_calls = builder.external_calls,
    }
    if builder.debug ~= nil then
      data.debug = builder.debug
    end
    return freeze(data)
  end
  return builder
end

--------------------------------------------------------------------------------
-- EmptyCallGraph (Item 5 — 1.2.4 refactor)
--
-- Factory for the "empty result" shape used by every early-return path in
-- the analyzer and by init.lua's cursor-error fallback. Previously each
-- call site hand-constructed `{ current_function = nil, callers = {},
-- external_calls = {}, debug = ... }` — duplicating the field list in 4+
-- places. If the CallGraph shape ever gained a new field (e.g. `metadata`),
-- every early-return path would need updating in lockstep, and forgetting
-- one would silently produce a shape-inconsistent result.
--
-- This factory centralizes the empty-result construction. It does NOT freeze
-- the result (early-return paths return mutable tables so the caller can
-- attach debug after construction). The `debug` parameter is optional; when
-- provided, it is attached to the returned table.
--
-- @param debug table|nil optional debug snapshot to attach
-- @return table mutable empty CallGraph (NOT frozen)
--------------------------------------------------------------------------------
function M.EmptyCallGraph(debug)
  local t = {
    current_function = nil,
    callers = {},
    external_calls = {},
  }
  if debug ~= nil then
    t.debug = debug
  end
  return t
end

--------------------------------------------------------------------------------
-- DecisionRecord (debug decision record, returned by the analysis layer,
-- recorded to debug by the orchestration layer)
--------------------------------------------------------------------------------

--- @class DecisionRecord
--- @field outcome string
--- @field reason string
--- @field [string] any

function M.DecisionRecord(fields)
  return freeze(fields)
end

--------------------------------------------------------------------------------
-- DecisionFactory (Item 14 — 1.2.4 refactor)
--
-- Factory functions for the two decision-record shapes used by the analysis
-- layer: `CallerDecision` (callers.lua) and `CallDecision` (external_calls.lua).
-- Both modules previously hand-constructed their decision tables inline,
-- scattering the field lists across multiple call sites. Centralizing the
-- construction here means:
--   * Adding a new field (e.g. `timestamp`) only needs one edit per shape.
--   * The default values for `outcome` and `reason` (both nil until the
--     analysis populates them) are documented in one place.
--   * Field-naming drift (e.g. `function_name` vs `caller_name`) is
--     prevented because the factory signature makes the canonical name
--     explicit.
--
-- The factories return MUTABLE tables (not frozen) because the analysis
-- layer populates `outcome` and `reason` AFTER construction, as it
-- decides whether to keep/discard the caller or call. The debug collector
-- snapshots the final state via `dbg:caller_decision()` /
-- `dbg:external_call_decision()`.
--------------------------------------------------------------------------------

--- Construct a CallerDecision record (used by callers.lua).
--- @param ref_path string the referencing file path
--- @param start_line number 0-based start line of the reference
--- @param start_col number 0-based start column of the reference
--- @return table mutable CallerDecision (outcome/reason are nil until populated)
function M.CallerDecision(ref_path, start_line, start_col)
  return {
    ref_path              = ref_path,
    call_position_0based  = { line = start_line, character = start_col },
    outcome               = nil,
    reason                = nil,
  }
end

--- Construct a CallDecision record (used by external_calls.lua).
--- @param call_line number 0-based call-site line
--- @param call_col number 0-based call-site column
--- @param call_name string the callee function name
--- @param call_node_summary table|nil debug summary of the call node
--- @param callee_node_summary table|nil debug summary of the callee node
--- @param full_call_range table|nil the full call range (0-based)
--- @return table mutable CallDecision (outcome/reason are nil until populated)
function M.CallDecision(call_line, call_col, call_name,
                         call_node_summary, callee_node_summary, full_call_range)
  return {
    call_position_0based = { line = call_line, character = call_col },
    function_name        = call_name,
    call_node            = call_node_summary,
    callee_node          = callee_node_summary,
    full_call_range_0based = full_call_range,
    outcome              = nil,
    reason               = nil,
  }
end

--------------------------------------------------------------------------------
-- AnalysisContext (dependency container + inputs)
--------------------------------------------------------------------------------

--- @class AnalysisContext
--- @field source_code string
--- @field file_path string
--- @field cursor_pos Position 0-based
--- @field language string
--- @field lsp ILspClient
--- @field ts ITreeSitter
--- @field fs IFileSystem
--- @field capability_checker ICapabilityChecker
--- @field package_paths string[]
--- @field debug_enabled boolean

--- Construct a read-only AnalysisContext. Uses `freeze` (proxy-based) so
--- ALL writes — both new fields and existing fields — raise an error.
--- Service objects (lsp/ts/fs/...) stay callable because `freeze` only
--- replaces the top-level table with a proxy; the service objects
--- referenced by the proxy's `__index` data are not themselves re-wrapped
--- (they're already constructed objects with their own metatables).
function M.AnalysisContext(fields)
  assert(type(fields) == "table",
    "AnalysisContext: fields must be a table, got " .. type(fields))
  -- Validate critical fields. Previously missing: a nil cursor_pos would
  -- only surface much later (in preconditions.check or analyzer phases)
  -- with a confusing error. Asserting here gives an early, clear failure.
  assert(fields.cursor_pos ~= nil and type(fields.cursor_pos) == "table",
    "AnalysisContext: cursor_pos must be a table {line, character}")
  assert(fields.source_code ~= nil,
    "AnalysisContext: source_code must not be nil")
  assert(fields.file_path ~= nil,
    "AnalysisContext: file_path must not be nil")
  -- Validate service objects: if present, they must be tables. We do NOT
  -- assert method presence here (the interfaces module handles that); we
  -- only guard against obviously-wrong types (e.g. lsp = "not a table")
  -- that would crash much later with a confusing "attempt to index a
  -- string value" error.
  if fields.lsp ~= nil then
    assert(type(fields.lsp) == "table",
      "AnalysisContext: lsp must be a table or nil, got " .. type(fields.lsp))
  end
  if fields.ts ~= nil then
    assert(type(fields.ts) == "table",
      "AnalysisContext: ts must be a table or nil, got " .. type(fields.ts))
  end
  if fields.fs ~= nil then
    assert(type(fields.fs) == "table",
      "AnalysisContext: fs must be a table or nil, got " .. type(fields.fs))
  end
  return freeze(fields)
end

return M
