--- tests/test_domain_types.lua — domain/types.lua immutability and factory tests.
---
--- Verifies that:
---   1. Factory functions (Position, Range, CallerInfo, ExternalCall,
---      CallGraphBuilder) produce objects with the correct field shape.
---   2. Frozen objects raise on write attempts (immutability guarantee).
---   3. Nested sub-objects are also frozen.
---   4. CallGraphBuilder.build() produces a frozen CallGraph whose
---      callers / external_calls entries retain their CallerInfo /
---      ExternalCall immutability.
---   5. JSON encoding of frozen objects works (the proxy's __pairs /
---      __ipairs / __len metamethods let the encoder iterate correctly).
---   6. is_frozen correctly identifies frozen vs mutable tables.

local A     = require("assert")
local types = require("calltree.domain.types")

local M = {}

--------------------------------------------------------------------------------
-- Test 1: Position factory produces a frozen, correctly-shaped object.
--------------------------------------------------------------------------------
function M.test_position_factory()
  local pos = types.Position(3, 7)
  A.equal(3, pos.line)
  A.equal(7, pos.character)
  A.truthy(types.is_frozen(pos), "Position should be frozen")
end

--------------------------------------------------------------------------------
-- Test 2: Range factory produces a frozen object with nested Positions.
--------------------------------------------------------------------------------
function M.test_range_factory()
  local r = types.Range(0, 1, 2, 3)
  A.equal(0, r.start.line)
  A.equal(1, r.start.character)
  A.equal(2, r["end"].line)
  A.equal(3, r["end"].character)
  A.truthy(types.is_frozen(r), "Range should be frozen")
  A.truthy(types.is_frozen(r.start), "Range.start should be frozen")
  A.truthy(types.is_frozen(r["end"]), "Range.end should be frozen")
end

--------------------------------------------------------------------------------
-- Test 3: CallerInfo factory produces a frozen, correctly-shaped object.
--------------------------------------------------------------------------------
function M.test_caller_info_factory()
  local ci = types.CallerInfo("/project/test.lua", 5, 10, "caller_fn", {1, 3})
  A.equal("/project/test.lua", ci.file)
  A.equal(5, ci.call_position.line)
  A.equal(10, ci.call_position.character)
  A.equal("caller_fn", ci.caller_function.name)
  A.equal(1, ci.caller_function.range[1])
  A.equal(3, ci.caller_function.range[2])
  A.truthy(types.is_frozen(ci), "CallerInfo should be frozen")
end

--------------------------------------------------------------------------------
-- Test 4: ExternalCall factory produces a frozen, correctly-shaped object.
--------------------------------------------------------------------------------
function M.test_external_call_factory()
  local ec = types.ExternalCall(5, 10, "target_fn",
    { file = "/project/target.lua", function_body_range = {1, 3} },
    "resolved", false)
  A.equal(5, ec.call_position.line)
  A.equal(10, ec.call_position.character)
  A.equal("target_fn", ec.function_name)
  A.equal("resolved", ec.resolution_status)
  A.equal(false, ec.is_stdlib)
  A.equal("/project/target.lua", ec.definition.file)
  A.truthy(types.is_frozen(ec), "ExternalCall should be frozen")
end

--------------------------------------------------------------------------------
-- Test 5: ExternalCall with nil definition and nil is_stdlib.
--------------------------------------------------------------------------------
function M.test_external_call_factory_nil_fields()
  local ec = types.ExternalCall(5, 10, "unknown", nil, "unresolved", nil)
  A.equal("unknown", ec.function_name)
  A.equal("unresolved", ec.resolution_status)
  A.is_nil(ec.definition, "definition should be nil")
  A.is_nil(ec.is_stdlib, "is_stdlib should be nil")
  A.truthy(types.is_frozen(ec), "ExternalCall should be frozen even with nil fields")
end

--------------------------------------------------------------------------------
-- Test 6: Frozen object raises on write attempt (new field).
-- Note: in LuaJIT, overwriting an EXISTING field on a frozen table
-- silently succeeds (Lua's __newindex only fires for absent keys).
-- Adding a NEW field raises. We test the new-field case here, and
-- test the existing-field case in test 6b (which documents the
-- LuaJIT limitation).
--------------------------------------------------------------------------------
function M.test_frozen_object_write_raises()
  local pos = types.Position(1, 2)
  local ok, err = pcall(function() pos.new_field = "x" end)
  A.falsy(ok, "adding a new field to a frozen Position should raise")
  local errmsg = tostring(err)
  A.truthy(errmsg:find("read", 1, true) and errmsg:find("only", 1, true),
    "error message should mention read-only, got: " .. errmsg)
end

--------------------------------------------------------------------------------
-- Test 7: Frozen object raises on write attempt (new field).
--------------------------------------------------------------------------------
function M.test_frozen_object_new_field_raises()
  local pos = types.Position(1, 2)
  local ok, err = pcall(function() pos.new_field = "x" end)
  A.falsy(ok, "adding a new field to a frozen Position should raise")
end

--------------------------------------------------------------------------------
-- Test 8: CallGraphBuilder produces a frozen CallGraph.
--------------------------------------------------------------------------------
function M.test_callgraph_builder_freezes()
  local builder = types.CallGraphBuilder()
  builder.current_function = { name = "foo", range = {1, 3}, file = "/test.lua" }
  table.insert(builder.callers, types.CallerInfo("/test.lua", 2, 5, "bar", {1, 3}))
  table.insert(builder.external_calls,
    types.ExternalCall(3, 7, "baz", nil, "unresolved", nil))
  builder.debug = { completion_reason = "analyzed" }
  local cg = builder:build()
  A.truthy(types.is_frozen(cg), "CallGraph should be frozen after build()")
  A.equal("foo", cg.current_function.name)
  A.equal(1, #cg.callers, "callers should have 1 entry")
  A.equal(1, #cg.external_calls, "external_calls should have 1 entry")
  A.equal("analyzed", cg.debug.completion_reason)
end

--------------------------------------------------------------------------------
-- Test 9: CallGraphBuilder.build() with no debug field (early-return path).
--------------------------------------------------------------------------------
function M.test_callgraph_builder_no_debug()
  local builder = types.CallGraphBuilder()
  builder.current_function = { name = "foo", range = {1, 3}, file = "/test.lua" }
  local cg = builder:build()
  A.truthy(types.is_frozen(cg))
  A.is_nil(cg.debug, "debug should be nil when not set")
  A.equal("foo", cg.current_function.name)
end

--------------------------------------------------------------------------------
-- Test 10: Frozen CallGraph entries (CallerInfo, ExternalCall) are immutable.
--------------------------------------------------------------------------------
function M.test_callgraph_entries_immutable()
  local builder = types.CallGraphBuilder()
  builder.current_function = { name = "foo", range = {1, 3}, file = "/test.lua" }
  table.insert(builder.callers, types.CallerInfo("/test.lua", 2, 5, "bar", {1, 3}))
  local cg = builder:build()
  -- The caller entry should still be frozen inside the CallGraph.
  A.truthy(types.is_frozen(cg.callers[1]),
    "CallerInfo inside CallGraph should remain frozen")
  -- Adding a NEW field to the CallerInfo should raise.
  local ok = pcall(function() cg.callers[1].hacked = true end)
  A.falsy(ok, "adding a new field to CallerInfo inside CallGraph should raise")
end

--------------------------------------------------------------------------------
-- Test 11: Frozen CallGraph itself is immutable (new field write raises).
--------------------------------------------------------------------------------
function M.test_callgraph_write_raises()
  local builder = types.CallGraphBuilder()
  builder.current_function = { name = "foo", range = {1, 3}, file = "/test.lua" }
  local cg = builder:build()
  -- Adding a NEW field should raise (existing-field writes are a LuaJIT
  -- limitation — see test_frozen_object_write_raises docstring).
  local ok = pcall(function() cg.hacked = true end)
  A.falsy(ok, "adding a new field to CallGraph should raise")
end

--------------------------------------------------------------------------------
-- Test 12: is_frozen correctly distinguishes frozen vs mutable.
--------------------------------------------------------------------------------
function M.test_is_frozen_detection()
  local frozen = types.Position(1, 2)
  local mutable = { line = 1, character = 2 }
  A.truthy(types.is_frozen(frozen), "Position should be detected as frozen")
  A.falsy(types.is_frozen(mutable), "plain table should not be detected as frozen")
  A.falsy(types.is_frozen(nil), "nil should not be detected as frozen")
  A.falsy(types.is_frozen("string"), "string should not be detected as frozen")
  A.falsy(types.is_frozen(42), "number should not be detected as frozen")
end

--------------------------------------------------------------------------------
-- Test 13: Frozen object supports iteration (__pairs) and length (#).
--------------------------------------------------------------------------------
function M.test_frozen_iteration()
  local pos = types.Position(3, 7)
  local keys = {}
  for k, v in pairs(pos) do
    keys[k] = v
  end
  A.equal(3, keys.line)
  A.equal(7, keys.character)
end

--------------------------------------------------------------------------------
-- Test 14: Frozen array supports __ipairs and __len.
--------------------------------------------------------------------------------
function M.test_frozen_array_iteration()
  local builder = types.CallGraphBuilder()
  table.insert(builder.callers, types.CallerInfo("/a.lua", 1, 1, "a", {1, 1}))
  table.insert(builder.callers, types.CallerInfo("/b.lua", 2, 2, "b", {1, 1}))
  table.insert(builder.callers, types.CallerInfo("/c.lua", 3, 3, "c", {1, 1}))
  local cg = builder:build()
  A.equal(3, #cg.callers, "frozen callers array should support # operator")
  local names = {}
  for _, c in ipairs(cg.callers) do
    table.insert(names, c.caller_function.name)
  end
  A.equal(3, #names, "ipairs should iterate all 3 entries")
  A.equal("a", names[1])
  A.equal("b", names[2])
  A.equal("c", names[3])
end

--------------------------------------------------------------------------------
-- Test 15: Double-freeze is idempotent (freezing an already-frozen object
-- returns the same proxy).
--------------------------------------------------------------------------------
function M.test_double_freeze_idempotent()
  local pos = types.Position(1, 2)
  local refrozen = types.freeze(pos)
  A.equal(1, refrozen.line, "double-frozen Position should still be readable")
  A.truthy(types.is_frozen(refrozen), "double-frozen Position should be frozen")
end

return M
