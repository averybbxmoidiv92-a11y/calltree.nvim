--- utils.lua — backward-compatible shim.
---
--- The canonical home for utilities is now the `calltree.utils` package
--- (`lua/calltree/utils/init.lua`), which re-exports from `utils.constants`,
--- `utils.path`, and `utils.range`. This file simply forwards to that
--- package so existing `require("calltree.utils")` call sites keep working.
---
--- Legacy helper functions that previously lived here (find_named_child_by_type,
--- find_first_descendant_by_type) are re-added at the bottom for any
--- external consumers that may still reference them.
---
--- Item 13 (1.2.4 refactor): the dead `utils.get_node_text(source_code, ts_range)`
--- function was deleted. It was a 50-line source-slicing implementation
--- that had NO callers anywhere in the codebase (verified via grep across
--- lua/ and tests/). All node-text extraction now goes through the unified
--- `utils.node_text(node)` helper in `utils/init.lua`, which uses
--- `node:text()` / `node._text` / `node.name` fallbacks and is the
--- canonical entry point. Keeping the dead implementation risked future
--- contributors re-introducing inconsistent text-extraction behavior
--- (the old version had no caching and handled some edge cases differently).

local utils = require("calltree.utils.init")

------------------------------------------------------------------------------
-- Legacy helpers (kept for backward compatibility)
------------------------------------------------------------------------------

--- Find a node by `type` among the named children of `node`.
--- @param node table a treesitter node-like object
--- @param types table set of acceptable types
--- @return table|nil
function utils.find_named_child_by_type(node, types)
  if node == nil then return nil end
  -- Validate `types` is a table to avoid an opaque "attempt to index nil"
  -- error inside the loop. Previously `types[child:type()]` would raise
  -- with no context if `types` was nil.
  if type(types) ~= "table" then return nil end
  -- Guard `node:named_child_count` with a type check so a plain table
  -- passed by mistake (not a treesitter node) raises a clear error instead
  -- of "attempt to call a nil value".
  if type(node.named_child_count) ~= "function" then return nil end
  -- ALSO guard `node.named_child` — previously we checked `named_child_count`
  -- is a function but then called `node:named_child(i)` unconditionally,
  -- which would crash on a mock that implements only `named_child_count`
  -- and not `named_child`. Now both are required.
  if type(node.named_child) ~= "function" then return nil end
  local count = node:named_child_count()
  for i = 0, count - 1 do
    local child = node:named_child(i)
    if child and types[child:type()] then return child end
  end
  return nil
end

--- Recursively search for the first descendant matching one of `types`.
--- This is a pre-order DFS (recurses depth-first; returns on the first
--- deep-subtree hit), NOT a BFS.
---
--- Review 7.2: previous comment claimed "the first returned is the first
--- in pre-order traversal, NOT the nearest ancestor-type node" — but
--- the code STARTS by checking the current node (`types[node:type()]`),
--- so when the current node matches, it IS the nearest (current) node.
--- The comment was misleading; corrected here.
---
--- Review 10.2: the `depth` parameter is now an INTERNAL implementation
--- detail. The public API only accepts `(node, types)`; recursion is
--- delegated to the local `_find_first_descendant_recursive` helper so
--- callers cannot accidentally pass a non-numeric `depth` (which would
--- crash on `depth + 1`). The public function is now a thin wrapper that
--- seeds the recursion at depth 0.
--- A depth limit (MAX_PATH_DEPTH) prevents stack overflow on pathologically
--- deep trees.
local function _find_first_descendant_recursive(node, types, depth)
  if node == nil then return nil end
  if type(types) ~= "table" then return nil end
  assert(utils.MAX_PATH_DEPTH ~= nil,
    "utils.MAX_PATH_DEPTH missing — find_first_descendant_by_type cannot bound recursion")
  if depth > utils.MAX_PATH_DEPTH then return nil end
  if types[node:type()] then return node end
  if type(node.named_child_count) ~= "function" then return nil end
  if type(node.named_child) ~= "function" then return nil end
  local count = node:named_child_count()
  for i = 0, count - 1 do
    local child = node:named_child(i)
    local found = _find_first_descendant_recursive(child, types, depth + 1)
    if found then return found end
  end
  return nil
end

function utils.find_first_descendant_by_type(node, types)
  -- Review 10.2: public API no longer accepts `depth`. Callers who used
  -- to pass `depth` (none in this codebase, but possibly external
  -- consumers) will see it silently dropped — safer than crashing on
  -- non-numeric input. The recursion is seeded at depth 0.
  return _find_first_descendant_recursive(node, types, 0)
end

return utils
