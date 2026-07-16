--- nodes.lua — treesitter node helpers for calltree.nvim.
---
--- Provides utilities for comparing nodes, walking the tree, extracting
--- function names, detecting function-definition names, and finding
--- top-level calling functions.
---
--- Pure Lua, no Neovim dependencies.

local utils = require("calltree.utils")

local M = {}

-- Node types that mark a class/struct definition. A class does NOT count as
-- a wrapping function for our purposes, so methods defined inside a class
-- are considered top-level callers.
M.CLASS_NODE_TYPES = {
  ["class_definition"]     = true, -- Python
  ["class_declaration"]    = true, -- JS/TS
  ["class_specification"]  = true, -- Ada
  ["struct_specification"] = true, -- Rust / C++
  ["impl_item"]            = true, -- Rust impl block (NOT a function)
  ["class"]                = true, -- generic
  ["struct"]               = true, -- generic
}

-- Node types that represent a dotted/method name expression (e.g. M.foo, obj:method).
local DOTTED_NAME_TYPES = {
  ["dot_index_expression"]    = true, -- Lua M.foo
  ["method_index_expression"] = true, -- Lua obj:method
  ["field_expression"]        = true, -- C/C++ obj.method
  ["member_expression"]       = true, -- JS/TS obj.method
}

-- Node types that represent declarator-like wrappers (C/C++ function_declarator).
local WRAPPER_TYPES = {
  ["function_declarator"] = true,
  ["declarator"] = true,
  ["function_declaration"] = true,
  ["method_declarator"] = true,
  ["call_signature"] = true,
}

-- Node types we never cross when searching for a name path (they indicate we've
-- entered a body or parameter list, not a name).
local BODY_NODE_TYPES = {
  ["block"] = true, ["body"] = true, ["compound_statement"] = true,
  ["statement_block"] = true, ["statements"] = true,
  ["parameters"] = true, ["argument_list"] = true,
  ["parameter_list"] = true, ["function_body"] = true,
}

------------------------------------------------------------------------------
-- is_descendant_path: recursive search for whether `target` is reachable
-- from `from` via a chain of named children, WITHOUT crossing a node in
-- BODY_NODE_TYPES. Returns true if reachable, false otherwise.
--
-- Extracted to module level (previously a nested `find_path` closure inside
-- M.is_function_name_node) so it can be unit-tested in isolation and the
-- main function stays readable. Depth-limited to prevent stack overflow on
-- pathological trees.
------------------------------------------------------------------------------
local function is_descendant_path(from, target, depth, max_depth)
  if depth > max_depth then return false end
  if M.nodes_equal(from, target) then return true end
  local t = from:type()
  if BODY_NODE_TYPES[t] then return false end
  local count = from:named_child_count()
  for i = 0, count - 1 do
    local ch = from:named_child(i)
    if ch ~= nil and is_descendant_path(ch, target, depth + 1, max_depth) then return true end
  end
  return false
end

------------------------------------------------------------------------------
-- Node comparison
------------------------------------------------------------------------------

--- Compare two node-like objects for identity.
--- More robust than `==` because the Neovim adapter creates a fresh Lua table
--- each time `:parent()` / `:named_child(i)` is called, so two wrappers
--- referring to the same underlying treesitter node compare unequal under `==`.
--- Falls back to comparing type + range, which uniquely identifies a node.
--- @param a table|nil
--- @param b table|nil
--- @return boolean
function M.nodes_equal(a, b)
  if a == nil and b == nil then return true end
  if a == nil or b == nil then return false end
  if a == b then return true end  -- works for mock nodes (pre-linked)
  -- Review 1.13: wrap `:type()` in pcall (consistent with `:range()` below)
  -- so a mock node that has `type` as a function but raises during the
  -- call doesn't crash the comparison. Previously the type check was
  -- `type(a.type) == "function" and a:type()` — the `and` short-circuit
  -- catches `type` being non-function, but not a function that raises.
  local at = nil
  if type(a.type) == "function" then
    local ok, t = pcall(a.type, a)
    at = (ok and t) or nil
  end
  local bt = nil
  if type(b.type) == "function" then
    local ok, t = pcall(b.type, b)
    bt = (ok and t) or nil
  end
  if at == nil or bt == nil or at ~= bt then return false end
  -- Use the shared utils.safe_range helper (pcall-wrapped node:range())
  -- instead of the inline `pcall(a.range, a)` pattern that was duplicated
  -- here and in providers/treesitter.lua. safe_range returns 4 nils on
  -- any failure (non-function range method, pcall error, nil node), so
  -- the nil-check below catches every failure mode in one branch.
  local asl, asc, ael, aec = utils.safe_range(a)
  local bsl, bsc, bel, bec = utils.safe_range(b)
  if asl == nil or bsl == nil then return false end
  return asl == bsl and asc == bsc and ael == bel and aec == bec
end

------------------------------------------------------------------------------
-- Tree walking
------------------------------------------------------------------------------

--- Walk up from `node` and find the nearest ancestor whose type is in `types`.
--- @param node table
--- @param types table set of acceptable types
--- @return table|nil node
-- A MAX_HOPS limit protects against infinite loops if the tree has cyclic
-- references (e.g. a misconstructed mock node).
-- Item 15 (1.2.4 refactor): the body now delegates to the generic
-- `walk_up_until` helper, which centralizes the hop-cap + cycle-detection
-- skeleton that was previously duplicated 5+ times across the codebase.
function M.walk_up_to_type(node, types)
  -- Defensive: when `types` is nil (caller forgot to pass it, or passed
  -- a non-table), the previous code would crash on `types[current:type()]`
  -- with "attempt to index a nil value". Bail out cleanly instead.
  if types == nil then return nil end
  return M.walk_up_until(node, function(current)
    return types[current:type()] or false
  end)
end

------------------------------------------------------------------------------
-- Function name extraction
------------------------------------------------------------------------------

--- Try to find the name of a function-definition node.
--- Handles:
---   - Simple names: `function foo()` -> "foo"
---   - Dotted names: `function M.foo()` -> "M.foo" (dot_index_expression)
---   - Method names: `function obj:method()` -> "obj:method" (method_index_expression)
---   - C/C++ wrappers: function_declarator -> identifier
--- @param func_node table
--- @return string|nil (nil for anonymous functions)
-- If the first NAME/DOTTED_NAME child's text is nil, continue searching
-- subsequent children instead of returning nil immediately. This avoids
-- missing a sibling with real text when a mock node has not set text.
-- Item 3 (1.2.4 refactor): the redundant `node_text` wrapper was removed;
-- call sites now use `utils.node_text` directly. The wrapper added an
-- extra call layer with zero additional logic, and its existence made it
-- easy to accidentally diverge from the canonical implementation.
function M.get_function_name(func_node)
  if func_node == nil then return nil end
  local count = func_node:named_child_count()
  -- Direct name child?
  for i = 0, count - 1 do
    local child = func_node:named_child(i)
    if child then
      local ct = child:type()
      if utils.NAME_NODE_TYPES[ct] or DOTTED_NAME_TYPES[ct] then
        local text = utils.node_text(child)
        if text ~= nil then return text end
        -- text is nil: continue to the next child (defensive against mock
        -- nodes that have not set text).
      end
    end
  end
  -- Look inside declarator-like wrappers (e.g. C/C++ function_declarator).
  -- Review 5.7: recursively descend through WRAPPER_TYPES chains so
  -- deeply-nested declarators like
  --   function_definition -> function_declarator -> declarator -> identifier
  -- are unwrapped all the way to the name. Previously the code only
  -- checked ONE level of wrapping (`func_node -> child -> sub`), missing
  -- the name when it was buried deeper. The recursion is bounded by
  -- MAX_PATH_DEPTH to prevent stack overflow.
  local function _search_wrapper_for_name(wrapper_node, depth)
    if wrapper_node == nil then return nil end
    if depth > (utils.MAX_PATH_DEPTH or 16) then return nil end
    local sub_count = wrapper_node:named_child_count()
    for j = 0, sub_count - 1 do
      local sub = wrapper_node:named_child(j)
      if sub then
        local st = sub:type()
        if utils.NAME_NODE_TYPES[st] or DOTTED_NAME_TYPES[st] then
          local text = utils.node_text(sub)
          if text ~= nil then return text end
        end
        -- Recurse into nested wrappers.
        if WRAPPER_TYPES[st] then
          local deeper_name = _search_wrapper_for_name(sub, depth + 1)
          if deeper_name ~= nil then return deeper_name end
        end
      end
    end
    return nil
  end
  for i = 0, count - 1 do
    local child = func_node:named_child(i)
    if child and WRAPPER_TYPES[child:type()] then
      local name = _search_wrapper_for_name(child, 0)
      if name ~= nil then return name end
    end
  end
  -- JS/TS arrow-function / function-expression assignment:
  --   const add = (a, b) => a + b;
  -- The func_node is the `arrow_function`, but the name "add" lives in
  -- the parent `variable_declarator`'s first `identifier` child. Walk up
  -- to the parent (and grandparent `lexical_declaration` / `variable_declaration`)
  -- and look for an identifier sibling. This covers:
  --   - `const add = (a,b) => a+b`  (arrow_function)
  --   - `let foo = function() {}`   (function_expression)
  --   - `var bar = async () => {}`  (async arrow_function)
  local fparent = func_node:parent()
  if fparent and fparent:type() == "variable_declarator" then
    local vd_count = fparent:named_child_count()
    for i = 0, vd_count - 1 do
      local sibling = fparent:named_child(i)
      if sibling and sibling ~= func_node then
        local st = sibling:type()
        if utils.NAME_NODE_TYPES[st] or DOTTED_NAME_TYPES[st] then
          local text = utils.node_text(sibling)
          if text ~= nil then return text end
        end
      end
    end
  end
  return nil
end

------------------------------------------------------------------------------
-- Cursor-on-function-name detection
------------------------------------------------------------------------------

--- Determine whether `node` is the "name" sub-node of a function definition.
--- @param node table
--- @param dbg table|nil optional debug collector for recording the path search
--- @return table|nil the function-definition ancestor if `node` is its name
function M.is_function_name_node(node, dbg)
  if node == nil then return nil end
  if not utils.NAME_NODE_TYPES[node:type()] then return nil end

  -- JS/TS arrow-function / function-expression assignment:
  --   const add = (a, b) => a + b;
  -- The cursor lands on the identifier "add", whose parent is
  -- `variable_declarator` — NOT a function node. The actual function
  -- (`arrow_function`) is a SIBLING of "add" inside the same
  -- `variable_declarator`. Handle this case before the ancestor walk:
  -- if the identifier's parent is a `variable_declarator`, check whether
  -- any sibling is a function-type node, and if so return that sibling.
  -- This also covers `let foo = function() { ... }` (function_expression).
  local parent = node:parent()
  if parent and parent:type() == "variable_declarator" then
    local vd_count = parent:named_child_count()
    for i = 0, vd_count - 1 do
      local sibling = parent:named_child(i)
      if sibling and sibling ~= node and utils.FUNCTION_NODE_TYPES[sibling:type()] then
        return sibling
      end
    end
  end

  -- Walk up looking for a function-definition ancestor. Allow intermediate
  -- wrapper nodes like "function_declarator" (C/C++) — up to MAX_NAME_HOPS
  -- (defined in utils/constants.lua; was a literal `6` before).
  -- Dead `or 6` / `or 16` fallbacks removed (utils.constants always defines these).
  local MAX_NAME_HOPS = utils.MAX_NAME_HOPS
  local MAX_PATH_DEPTH = utils.MAX_PATH_DEPTH
  local current = node
  local hops = 0
  local hop_chain = { node:type() }
  while current ~= nil and hops < MAX_NAME_HOPS do
    local parent = current:parent()
    if parent == nil then break end
    table.insert(hop_chain, parent:type())
    if utils.FUNCTION_NODE_TYPES[parent:type()] then
      -- Check that `node` is reachable from `parent` via a chain of named
      -- children where every intermediate node is a declarator-like wrapper
      -- (i.e. we don't cross into a body/parameters block).
      --
      -- The path search was previously a nested `find_path` closure; it's
      -- now the module-level `is_descendant_path` helper so it can be
      -- unit-tested in isolation and the main function stays readable.
      local found = is_descendant_path(parent, node, 0, MAX_PATH_DEPTH)
      -- Review 5.8: guard chained access to `dbg` — previously
      -- `dbg and dbg:get() ~= nil` assumed `dbg` is a DebugCollector
      -- with a `:get()` method, but a caller could pass a plain table
      -- or a mock. Type-check `dbg.get` before calling it.
      if dbg and type(dbg.get) == "function" and dbg:get() ~= nil then
        -- Also guard `dbg.data` — NilData sentinel returns nil on __index,
        -- and a plain-table mock may not have `cursor_detection` at all.
        if type(dbg.data) == "table" and type(dbg.data.cursor_detection) == "table" then
          dbg.data.cursor_detection._name_path_search = {
            function_node_type = parent:type(),
            hop_chain = hop_chain,
            hops = hops,
            path_found = found,
          }
        end
      end
      if found then
        return parent
      end
      return nil
    end
    current = parent
    hops = hops + 1
  end
  if dbg and type(dbg.get) == "function" and dbg:get() ~= nil then
    if type(dbg.data) == "table" and type(dbg.data.cursor_detection) == "table" then
      dbg.data.cursor_detection._name_path_search = {
        hop_chain = hop_chain,
        hops = hops,
        path_found = false,
        reason = "no function-definition ancestor within " .. MAX_NAME_HOPS .. " hops",
      }
    end
  end
  return nil
end

--- Walk up the tree from `node` to find the *directly enclosing* calling function.
--- A class/struct/impl block is NOT a function wrapper, so a method directly
--- inside a class is still considered the enclosing function (its body is the
--- method body, not the class body). However, when a function is nested inside
--- another function (e.g. `function outer() function inner() callee() end end`),
--- the call inside `inner` must be attributed to `inner`, NOT `outer` — otherwise
--- the caller analysis would report the wrong function name and range.
---
--- Therefore: return the FIRST function-definition ancestor encountered while
--- walking up. Class/struct/impl blocks are still transparent (skipped), since
--- they are listed in CLASS_NODE_TYPES rather than FUNCTION_NODE_TYPES.
---
--- A MAX_HOPS limit (utils.MAX_ANCESTOR_HOPS) guards against infinite loops on
--- cyclic mock trees whose :parent() returns self.
--- Item 15 (1.2.4 refactor): the body now delegates to the generic
--- `walk_up_until` helper, which centralizes the hop-cap + cycle-detection
--- skeleton that was previously duplicated 5+ times across the codebase.
--- @param node table
--- @return table|nil function_node (nil if call is at global scope)
function M.find_top_level_calling_function(node)
  if node == nil then return nil end
  return M.walk_up_until(node, function(current)
    return utils.FUNCTION_NODE_TYPES[current:type()] or false
  end)
end

--- Search a parsed treesitter tree for a function definition whose name
--- matches `func_name_suffix` (e.g. "build_context" or "M.build_context").
--- @param root table the treesitter root node
--- @param func_name_suffix string e.g. "build_context" (the part after the last dot)
--- @return table|nil func_node, table|nil range_1based [start_line, end_line]
-- Item 22 (1.2.4 refactor): the manual `walk` closure was replaced by a
-- call to the shared `M.dfs_search` helper. The predicate checks
-- FUNCTION_NODE_TYPES + name-match (exact / dotted / method). dfs_search
-- handles the depth cap + recursion + early-return-on-first-match
-- skeleton that was previously duplicated here.
function M.find_function_def_by_name(root, func_name_suffix)
  if root == nil or func_name_suffix == nil then return nil, nil end
  -- Escape non-alphanumeric characters in func_name_suffix so that Lua
  -- pattern special characters (like `-`, `+`, `(`) in function names are
  -- matched literally.
  local escaped_suffix = func_name_suffix:gsub("([^%w])", "%%%1")
  local found_node = M.dfs_search(root, function(node)
    local nt = node:type()
    if not utils.FUNCTION_NODE_TYPES[nt] then return false end
    local name = M.get_function_name(node)
    if name == nil then return false end
    return name == func_name_suffix
      or name:match("%." .. escaped_suffix .. "$") ~= nil
      or name:match(":" .. escaped_suffix .. "$") ~= nil
  end)
  if found_node == nil then return nil, nil end
  -- Reuse closed_end_line_0based to compute the closed end line.
  -- Use utils.safe_range (pcall-wrapped) instead of the bare
  -- `found_node:range()` call — the bare call would crash on mock nodes
  -- that don't expose a :range() method (some unit-test mocks only
  -- implement :type() / :named_child_count() / :named_child()).
  -- safe_range returns 4 nils on any failure, so the nil-check below
  -- catches it the same way the original `sl == nil` check did.
  local sl, _, el, ec = utils.safe_range(found_node)
  if sl == nil or el == nil then return found_node, nil end
  local closed_end = M.closed_end_line_0based(sl, el, ec)
  return found_node, { sl + 1, closed_end + 1 }
end

--- Compute the 0-based "closed end line" of a treesitter range.
--- Tree-sitter ranges are half-open: the end line is the line AFTER the
--- last line of the node when the end column is 0 (e.g. a node ending at
--- the start of line 5 actually ends on line 4). This helper returns the
--- 0-based line number of the last line the node actually occupies.
---
--- Extracted as a shared helper because both `analyzer.lua` (for the cursor
--- function's body range) and `range_to_1based_closed` (for the 1-based
--- output range) need the same logic — previously it was duplicated, which
--- was a code-review finding.
---
--- @param sl number start line (0-based)
--- @param el number end line (0-based, exclusive-ish per TS convention)
--- @param ec number end column (0-based)
--- @return number|nil closed_end_0based (nil if sl or el is nil)
function M.closed_end_line_0based(sl, el, ec)
  if sl == nil or el == nil then return nil end
  local closed_end = el
  if ec == 0 and el > sl then closed_end = el - 1 end
  return closed_end
end

--- Convert a 0-based treesitter range to a 1-based closed [start_line, end_line] pair.
--- @param sl number start line (0-based)
--- @param el number end line (0-based, exclusive-ish per TS convention)
--- @param ec number end column (0-based)
--- @return table [start_line_1based, end_line_1based]
function M.range_to_1based_closed(sl, el, ec)
  if sl == nil or el == nil then return nil end
  local closed_end = M.closed_end_line_0based(sl, el, ec)
  return { sl + 1, closed_end + 1 }
end

------------------------------------------------------------------------------
-- Item 15 (1.2.4 refactor): walk_up_until — generic bounded ancestor walk.
--
-- Replaces the duplicated `local cur = node; local hops = 0; while cur ~= nil
-- and hops < MAX_HOPS do ... end` skeleton that appeared in 5+ places
-- (walk_up_to_type, find_top_level_calling_function, _find_func_def_node,
-- _find_decl_ancestor, the parameter-boundary walk in definition_body.check).
--
-- The `predicate` callback receives the current node and returns:
--   * truthy  → walk stops, that node is returned
--   * "stop"  → walk stops, nil is returned (early bail-out, e.g. when a
--               parameter boundary is crossed and we don't want to keep
--               walking)
--   * falsy   → walk continues to the parent
--
-- Cycle detection is built in: a `visited` set guards against mock nodes
-- whose `:parent()` returns self (or a cyclic chain), which would otherwise
-- spin until MAX_HOPS. This was previously duplicated in walk_up_to_type
-- and find_top_level_calling_function; it's now centralized here.
--
-- @param node table|nil starting node
-- @param predicate function(node) -> truthy|"stop"|falsy
-- @param max_hops number|nil optional hop cap (defaults to utils.MAX_ANCESTOR_HOPS)
-- @return table|nil the matching ancestor, or nil if none found / walked past cap
------------------------------------------------------------------------------
function M.walk_up_until(node, predicate, max_hops)
  if node == nil or type(predicate) ~= "function" then return nil end
  max_hops = max_hops or utils.MAX_ANCESTOR_HOPS
  local cur = node
  local hops = 0
  local visited = {}  -- cycle detection
  while cur ~= nil and hops < max_hops do
    local result = predicate(cur)
    if result == "stop" then return nil end
    if result then return cur end
    if visited[cur] then
      -- Cycle detected; bail out immediately rather than spinning.
      return nil
    end
    visited[cur] = true
    cur = cur:parent()
    hops = hops + 1
  end
  return nil
end

------------------------------------------------------------------------------
-- Item 16 (1.2.4 refactor): find_node_at_location — shared LSP-location →
-- treesitter-node lookup.
--
-- Replaces the near-identical `_find_ref_node` (callers.lua) and
-- `_find_def_node` (definition_body.lua). Both did:
--   1. Validate the location's range/start/end sub-tables are non-nil.
--   2. Extract line/character from start and end.
--   3. First try `ts.descendant_for_range(ts, root, sl, sc, sl, sc+1)`
--      (single-point lookup — catches the case where the LSP range is a
--      zero-width cursor position).
--   4. If that returns nil and end info is available, fall back to
--      `ts.descendant_for_range(ts, root, sl, sc, el, max(ec-1, 0))`
--      (range lookup — catches the case where the LSP range spans real
--      text).
--
-- Centralizing this logic means a future change to the lookup strategy
-- (e.g. adding column-offset tolerance, or trying el-1 before sl+1) only
-- needs to be made in ONE place. Previously such a change would have
-- required synchronized edits to both _find_ref_node and _find_def_node,
-- risking drift.
--
-- @param ts table treesitter service (with descendant_for_range method)
-- @param root table treesitter root node
-- @param location table LSP Location with { range = { start = {line,character}, ["end"] = {line,character} } }
-- @return table|nil the treesitter node at the location, or nil
------------------------------------------------------------------------------
function M.find_node_at_location(ts, root, location)
  if location == nil or location.range == nil
     or location.range.start == nil or location.range["end"] == nil then
    return nil
  end
  local sl = location.range.start.line
  local sc = location.range.start.character
  local el = location.range["end"].line
  local ec = location.range["end"].character
  if sl == nil or sc == nil then return nil end
  -- First try a single-point lookup (sl, sc) → (sl, sc+1). This catches
  -- zero-width cursor positions where the end range equals the start.
  local n = ts.descendant_for_range(ts, root, sl, sc, sl, sc + 1)
  if n == nil and el ~= nil and ec ~= nil then
    -- Fall back to a range lookup. We use `max(ec - 1, 0)` for the end
    -- column because treesitter's descendant_for_range treats the end as
    -- EXCLUSIVE — passing `ec` would include the character AFTER the
    -- location's actual end, potentially returning a parent node that
    -- extends past the location. Using `ec - 1` (clamped to 0) gives the
    -- tightest match.
    n = ts.descendant_for_range(ts, root, sl, sc, el, math.max(ec - 1, 0))
  end
  return n
end

------------------------------------------------------------------------------
-- Item 4 (1.2.4 refactor): find_body_child — shared body-block finder.
--
-- Both `analyzer._find_body_child` and the body-detection loop inside
-- `definition_body._check_func_body` walked a function node's named
-- children looking for the first one whose type was in
-- `definition_body.BLOCK_NODE_TYPES` (block / compound_statement /
-- statement_block / body / etc.). The two implementations were
-- near-identical; centralizing here means adding a new body-block type
-- (e.g. for a new language grammar) only needs the BLOCK_NODE_TYPES
-- table updated, not two separate walk loops.
--
-- @param func_node table|nil the function-definition node
-- @param block_types table set of acceptable body-block node types
-- @return table|nil the first matching child, or nil
------------------------------------------------------------------------------
function M.find_body_child(func_node, block_types)
  if func_node == nil or type(block_types) ~= "table" then return nil end
  -- Guard against mock nodes that don't implement named_child_count.
  -- Use `.` (not `:`) to read the method as a value without invoking it.
  local nc = func_node.named_child_count
  if type(nc) ~= "function" then return nil end
  local count = func_node:named_child_count()
  if count == nil then return nil end
  for i = 0, count - 1 do
    local ch = func_node:named_child(i)
    if ch and block_types[ch:type()] then
      return ch
    end
  end
  return nil
end

------------------------------------------------------------------------------
-- Item 22 (1.2.4 refactor): dfs_search — generic depth-first search.
--
-- Replaces the duplicated `function walk(node, depth) ... end` skeleton
-- that appeared in `find_function_def_by_name` (nodes.lua) and could also
-- serve similar "find first matching node" searches. The skeleton was:
--   1. if node == nil or depth > max_depth then return end
--   2. if predicate(node) then return node end
--   3. for each named child: recurse; if found, return early
--
-- `walk_collect_calls` (walker.lua) is NOT migrated here because it has a
-- side-effect accumulator (collects ALL matches, not just the first) and
-- a "stop at nested function definitions" predicate that doesn't fit the
-- "find first" pattern. Forcing it into this helper would add complexity
-- (a `visit` callback + an `accumulator` parameter) without reducing the
-- line count meaningfully.
--
-- @param root table|nil starting node
-- @param predicate function(node) -> truthy  called on each node; truthy = match
-- @param max_depth number|nil optional depth cap (defaults to utils.MAX_WALK_DEPTH)
-- @return table|nil the first matching node in pre-order, or nil
------------------------------------------------------------------------------
function M.dfs_search(root, predicate, max_depth)
  if root == nil or type(predicate) ~= "function" then return nil end
  max_depth = max_depth or utils.MAX_WALK_DEPTH
  local function walk(node, depth)
    if node == nil or depth > max_depth then return nil end
    if predicate(node) then return node end
    -- Guard against mock nodes that don't implement named_child_count.
    local nc = node.named_child_count
    if type(nc) ~= "function" then return nil end
    local count = node:named_child_count()
    if count == nil then return nil end
    for i = 0, count - 1 do
      local found = walk(node:named_child(i), depth + 1)
      if found then return found end
    end
    return nil
  end
  return walk(root, 1)
end

return M
