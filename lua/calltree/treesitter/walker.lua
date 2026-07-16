--- walker.lua — tree traversal helpers for calltree.nvim.
--- Extracted from external_call_analysis to make tree walking reusable.
--- Pure Lua, no Neovim dependencies.

local utils = require("calltree.utils")

local M = {}

-- Node types that represent an "arguments" list (skipped when finding the callee).
local ARGUMENT_NODE_TYPES = {
  ["arguments"] = true,
  ["argument_list"] = true,
  ["argument"] = true,
  ["parenthesized_arguments"] = true,
}

-- Node types that represent call expressions.
-- Unified into `utils.CALL_NODE_TYPES` (shared with
-- resolution/require_resolver.lua) so adding a new language's call-node
-- type only needs one edit in utils/constants.lua.
local CALL_NODE_TYPES = utils.CALL_NODE_TYPES

--================================================================================
-- get_callee orchestrator.
--
-- Split into the following query functions:
--   _node_text_and_range(node) -> text|nil, range|nil  (query; extracts text and range)
--   _first_non_argument_child(call_node) -> child|nil  (query; skips arguments nodes)
--================================================================================

-- Query: safely extract a node's text and 0-based range.
-- Reused to eliminate the three duplicated text-extraction blocks in the
-- original get_callee. Text extraction is delegated to the unified
-- utils.node_text helper.
local function _node_text_and_range(node)
  if node == nil then return nil, nil end
  local text = utils.node_text(node)
  -- Use utils.safe_range (pcall-wrapped node:range()) instead of the
  -- inline `pcall(function() sl, sc, el, ec = node:range() end)` —
  -- same behavior, no closure allocation, and consistent with the other
  -- safe_range call sites across the codebase.
  local sl, sc, el, ec = utils.safe_range(node)
  if sl == nil then return text, nil end
  return text, { sl, sc, el, ec }
end

-- Query: return the first non-arguments named child of call_node (i.e. the callee).
local function _first_non_argument_child(call_node)
  local count = call_node:named_child_count()
  for i = 0, count - 1 do
    local child = call_node:named_child(i)
    if child and not ARGUMENT_NODE_TYPES[child:type()] then
      return child
    end
  end
  return nil
end

--- Orchestrator: extract the callee from a call-expression node.
--- Order: (1) no children → return call_node itself; (2) first non-arguments
--- child; (3) fall back to call_node itself (when all children are arguments).
--- @param call_node table
--- @return table|nil callee_node, string|nil callee_text, table|nil callee_range
function M.get_callee(call_node)
  if call_node == nil then return nil, nil, nil end
  -- (1) No children: return call_node itself.
  if call_node:named_child_count() == 0 then
    local text, range = _node_text_and_range(call_node)
    return call_node, text, range
  end
  -- (2) First non-arguments child.
  local callee = _first_non_argument_child(call_node)
  if callee ~= nil then
    local text, range = _node_text_and_range(callee)
    return callee, text, range
  end
  -- (3) Fallback: all children are arguments; use call_node itself as callee.
  local text, range = _node_text_and_range(call_node)
  return call_node, text, range
end

-- Maximum walk depth to prevent stack overflow on pathologically deep ASTs.
-- Uses the centralized utils.MAX_WALK_DEPTH constant (value 64, enough to
-- cover any realistic function nesting depth). The `or 32` fallback was
-- dead code — utils.constants always defines this as 64.
local MAX_WALK_DEPTH = utils.MAX_WALK_DEPTH

------------------------------------------------------------------------------
-- walk_collect_calls: recursive body of M.collect_top_level_calls.
-- Extracted to module level (previously a nested `walk` closure) so it can
-- be unit-tested in isolation. Mutates `calls` in place.
--
-- @param node table current node
-- @param depth number current recursion depth
-- @param max_depth number depth cap (caller passes MAX_WALK_DEPTH)
-- @param same_range_as_func_node function(node) -> boolean predicate for
--   "this node has the same range as the cursor func_node" (used to skip
--   re-entering the cursor function itself when its body is walked)
-- @param calls array accumulator (mutated in place)
------------------------------------------------------------------------------
local function walk_collect_calls(node, depth, max_depth, same_range_as_func_node, calls)
  if node == nil then return end
  if depth > max_depth then return end
  local nt = node:type()
  if utils.FUNCTION_NODE_TYPES[nt] and not same_range_as_func_node(node) then
    return
  end
  -- Skip inactive preprocessor branches (C/C++ #else / #elif).
  -- Real tree-sitter-c parses BOTH branches into named children; without
  -- this guard, calls inside the inactive #else block would be collected
  -- alongside the active branch's calls, contradicting the spec's
  -- "default to active branch" expectation. For languages without
  -- preprocessor directives these node types don't exist, so the check
  -- is a harmless no-op.
  if utils.PREPROC_INACTIVE_BRANCH_TYPES[nt] then
    return
  end
  if CALL_NODE_TYPES[nt] then
    local callee_node, callee_text, callee_range = M.get_callee(node)
    if callee_text and #callee_text > 0 then
      -- call_node_range: wrap node:range() in pcall (via utils.safe_range)
      -- so a mock node without :range() doesn't crash here. Previously
      -- `{ node:range() }` would raise on such mocks.
      local csl, csc, cel, cec = utils.safe_range(node)
      local call_node_range = (csl ~= nil) and { csl, csc, cel, cec } or nil
      table.insert(calls, {
        node = node,
        callee_node = callee_node,
        name = callee_text,
        range = callee_range,
        call_node_range = call_node_range,
      })
    end
    return
  end
  local count = node:named_child_count()
  for i = 0, count - 1 do
    walk_collect_calls(node:named_child(i), depth + 1, max_depth, same_range_as_func_node, calls)
  end
end

--- Recursively collect top-level call expressions inside `func_node`'s body,
--- skipping any nested function definitions.
--- @param func_node table
--- @return array of { node, callee_node, name, range, call_node_range }
function M.collect_top_level_calls(func_node)
  local calls = {}
  -- Cache the func_node's range so we can compare by range instead of by
  -- reference. The previous `node ~= func_node` check used reference
  -- equality, which breaks when wrap_node returns a fresh table per call
  -- (providers/treesitter.lua L101) — the wrapped node would never be
  -- `==` to func_node even when they describe the same tree position,
  -- causing nested function definitions to NOT be skipped.
  -- Use utils.safe_range (replaces the inline type-check + pcall pattern).
  local fn_sl, _, fn_el, _ = utils.safe_range(func_node)
  local fn_sc, fn_ec  -- Review 5.6: also capture column info so single-line
                      -- nested functions (lambdas, short closures) that share
                      -- the same start/end line but occupy different column
                      -- ranges are correctly distinguished.
  -- Re-extract using a 4-tuple form to also get columns.
  local sl2, sc2, el2, ec2 = utils.safe_range(func_node)
  fn_sc, fn_ec = sc2, ec2
  local function same_range_as_func_node(node)
    if fn_sl == nil then return false end  -- no range to compare against
    local sl, sc, el, ec = utils.safe_range(node)
    if sl == nil then return false end
    -- Range equality: require start AND end positions to match
    -- (both line and column). The previous check compared only lines,
    -- which mis-classified two distinct single-line functions sharing
    -- the same line as "the same function" — causing nested single-line
    -- functions to be wrongly skipped, so calls inside them were
    -- wrongly attributed to the enclosing function.
    return sl == fn_sl and sc == fn_sc and el == fn_el and ec == fn_ec
  end
  -- `walk` was previously a nested closure inside collect_top_level_calls;
  -- extracted to module-level `walk_collect_calls` so it can be unit-
  -- tested in isolation and collect_top_level_calls stays a thin wrapper.
  local function walk(node, depth)
    walk_collect_calls(node, depth, MAX_WALK_DEPTH, same_range_as_func_node, calls)
  end
  local count = func_node:named_child_count()
  for i = 0, count - 1 do
    local child = func_node:named_child(i)
    if child and not utils.NAME_NODE_TYPES[child:type()] then
      walk(child, 1)
    end
  end
  return calls
end

return M
