--- assert.lua — tiny assertion library for the test runner.
---
--- Provides `assert.equal`, `assert.is_nil`, `assert.is_not_nil`, `assert.same`
--- (deep equality on tables), `assert.contains` (table contains a value),
--- `assert.truthy`, `assert.falsy`. Each assertion throws a table
--- `{ message = ..., expected = ..., actual = ... }` on failure.

local M = {}

-- Deep equality with cycle detection. The `seen_a` / `seen_b` tables map
-- table references to their counterpart in the other structure, so a cycle
-- like `a.x = a; b.x = b` is recognized as equal rather than recursing
-- forever (which would overflow the stack).
local function deep_eq(a, b, seen_a, seen_b)
  if type(a) ~= type(b) then return false end
  if type(a) ~= "table" then return a == b end
  -- If we've already started comparing these two tables, treat them as
  -- equal (the cycle closes back on a pair we're in the middle of
  -- comparing, and if any branch had failed we'd already have returned
  -- false). This is the standard cycle-safe deep-eq pattern.
  seen_a = seen_a or {}
  seen_b = seen_b or {}
  if seen_a[a] == b and seen_b[b] == a then return true end
  seen_a[a] = b
  seen_b[b] = a
  -- Compare keys both ways.
  for k, v in pairs(a) do
    if not deep_eq(v, b[k], seen_a, seen_b) then return false end
  end
  for k, v in pairs(b) do
    if a[k] == nil and v ~= nil then return false end
  end
  return true
end

M._deep_eq = deep_eq

local function fail(msg, expected, actual)
  local err = { message = msg, expected = expected, actual = actual }
  error(err, 3)
end

function M.equal(expected, actual, msg)
  if expected ~= actual then
    fail(msg or ("expected " .. tostring(expected) .. ", got " .. tostring(actual)),
         expected, actual)
  end
end

function M.same(expected, actual, msg)
  if not deep_eq(expected, actual) then
    fail(msg or ("tables not equal: expected=" .. M.dump(expected) ..
                 " actual=" .. M.dump(actual)), expected, actual)
  end
end

function M.is_nil(actual, msg)
  if actual ~= nil then
    fail(msg or ("expected nil, got " .. tostring(actual)), nil, actual)
  end
end

function M.is_not_nil(actual, msg)
  if actual == nil then
    fail(msg or "expected non-nil, got nil", "non-nil", nil)
  end
end

function M.truthy(actual, msg)
  if not actual then
    fail(msg or ("expected truthy, got " .. tostring(actual)), "truthy", actual)
  end
end

function M.falsy(actual, msg)
  if actual then
    fail(msg or ("expected falsy, got " .. tostring(actual)), "falsy", actual)
  end
end

-- Check that `list` contains an element deep-equal to `expected`.
function M.contains(list, expected, msg)
  for _, v in ipairs(list) do
    if deep_eq(v, expected) then return end
  end
  fail(msg or ("list does not contain " .. M.dump(expected)), expected, list)
end

-- Check that `list` has exactly `n` elements.
-- Prefers the `#` operator (Lua's built-in array length, O(1)); falls back
-- to `pairs` counting only when `#` returns 0 but the table is non-empty
-- (i.e. a pure hash table). This means:
--   - Pure arrays (e.g. result.callers): `#` is used, correct.
--   - Object-style tables (e.g. {a=1, b=2}): `#` returns 0, falls back to
--     `pairs` giving 2.
--   - Empty table `{}`: `#` returns 0, pairs also gives 0, no ambiguity.
function M.length(n, list, msg)
  if list == nil then
    fail(msg or "expected length " .. n .. ", got nil", n, nil)
    return
  end
  local got = #list
  if got == 0 then
    -- May be a pure hash table; count via pairs.
    got = 0
    for _ in pairs(list) do got = got + 1 end
  end
  if got ~= n then
    fail(msg or ("expected length " .. n .. ", got " .. got), n, got)
  end
end

-- Pretty-print a value for error messages.
-- Cycle-safe (uses a `seen` set to mark already-visited tables as "<cycle>")
-- and produces stable output by sorting keys alphabetically.
function M.dump(v, indent, seen)
  indent = indent or ""
  seen = seen or {}
  if type(v) == "nil" then return "nil" end
  if type(v) == "string" then return '"' .. v .. '"' end
  if type(v) == "number" or type(v) == "boolean" then return tostring(v) end
  if type(v) == "function" or type(v) == "userdata" or type(v) == "thread" then
    -- tostring() on a C function (e.g. print, table.insert) returns
    -- "function: builtin#x" without a 0x.. address, so the previous
    -- `:match("0x[%x]+")` returned nil and the `.. nil ..` concatenation
    -- raised. Use `or "?"` to fall back to a placeholder.
    return "<" .. type(v) .. ":" .. (tostring(v):match("0x[%x]+") or "?") .. ">"
  end
  if type(v) == "table" then
    if seen[v] then return "<cycle>" end
    seen[v] = true
    -- Collect keys and sort for stable output.
    local keys = {}
    for k, _ in pairs(v) do table.insert(keys, k) end
    table.sort(keys, function(a, b)
      -- Sort by type first (strings first, then numbers, then others),
      -- then by string representation — keeps mixed-key tables ordered.
      local ta, tb = type(a), type(b)
      if ta ~= tb then return ta < tb end
      return tostring(a) < tostring(b)
    end)
    local parts = {}
    for _, k in ipairs(keys) do
      local val = v[k]
      table.insert(parts, string.format("%s%s = %s",
        indent, tostring(k), M.dump(val, indent .. "  ", seen)))
    end
    if #parts == 0 then return "{}" end
    return "{\n" .. table.concat(parts, ",\n") .. "\n" .. indent .. "}"
  end
  return tostring(v)
end

return M
