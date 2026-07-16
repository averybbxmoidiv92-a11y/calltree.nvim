--- resolution/require_resolver.lua — extract the module spec from a `require("...")` call.
--- Pure Lua, no Neovim dependencies.

local utils = require("calltree.utils")
local M = {}

-- Node types that represent a function-call expression across the languages
-- we support. Unified into `utils.CALL_NODE_TYPES` (the superset shared with
-- treesitter/walker.lua) so adding a new language's call-node type only
-- needs one edit.
--
-- Item 8 (1.2.4 refactor): the previous `M.CALL_NODE_TYPES = utils.CALL_NODE_TYPES`
-- alias was removed because it added a redundant export with zero additional
-- logic. Internal callers now reference `utils.CALL_NODE_TYPES` directly,
-- which is one less indirection and one less place to keep in sync. No
-- external callers reference `require_resolver.CALL_NODE_TYPES` (verified
-- via grep across the codebase and tests).
--
-- Previously this module defined its own subset
-- (function_call / call / call_expression) which was a strict subset of
-- walker.lua's superset. The subset was sufficient here because
-- require() detection only ran on Lua/Python/C/JS/Rust/Go sources, but
-- using the superset is harmless: the extra node types
-- (method_invocation / command_call / method_call_expression) are never
-- produced by the languages where require() is meaningful, so they
-- simply never match.

-- Node types that represent a string literal. Same rationale.
M.STRING_NODE_TYPES = {
  ["string"]          = true,
  ["string_literal"]  = true,
  ["literal"]         = true,
}

-- Maximum number of ancestor hops to walk up from the binding identifier
-- looking for an enclosing require() call. 10 is generous: real-world
-- `local foo = require("bar")` bindings have the require call as a sibling
-- at depth 1; nested forms like `local foo = require(...).bar` push it to
-- depth 2-3. Anything deeper is almost certainly not a require binding.
-- Reference the centralized constant from utils/constants.lua to avoid
-- duplication (was a local literal 10 that could drift out of sync).
M.MAX_PARENT_HOPS = utils.MAX_PARENT_HOPS or 10

-- Maximum depth for the `search_subtree` recursion. Prevents stack overflow
-- on pathological / malformed AST subtrees (e.g. a generated test tree with
-- a long chain of wrappers). 32 is comfortably above any realistic Lua
-- expression nesting. Reference the centralized constant.
M.MAX_SUBTREE_DEPTH = utils.MAX_SUBTREE_DEPTH or 32

-- Strip a single layer of matching quotes from a string literal's text.
-- Handles `"..."`, `'...'`, and `[[...]]` forms (the latter via the leading
-- `[[` check). Returns the unquoted string, or the input unchanged if no
-- surrounding quotes were found. Note: this is a simple strip — it does
-- NOT process escape sequences (Lua's require() argument is conventionally
-- a plain module path without escapes, so this is fine in practice).
local function strip_quotes(s)
  if s == nil then return nil end
  -- `[[ ... ]]` long-bracket form (Lua-specific), including the
  -- nested-equals variants `[==[ ... ]==]`, `[===[ ... ]===]`, etc.
  -- The previous version only handled the level-0 `[[ ]]` form,
  -- which silently dropped the quoting for higher levels and
  -- produced a module name with the brackets still attached.
  local open_level = s:match("^%[(=*)%[")
  if open_level then
    local close = "]" .. open_level .. "]"
    if s:sub(-#close) == close then
      return s:sub(#open_level + 3, -(#close + 1))
    end
  end
  -- Single or double quoted form. Strip only ONE layer; an inner quote
  -- at the start/end (e.g. `"he said \"hi\""` is rare in require args)
  -- would survive but won't crash.
  local first = s:sub(1, 1)
  if first == '"' or first == "'" then
    if s:sub(-1) == first then
      return s:sub(2, -2)
    end
  end
  return s
end
M.strip_quotes = strip_quotes

-- Find the first string-literal descendant of `n` (DFS, bounded by
-- MAX_SUBTREE_DEPTH). Returns the unquoted string, or nil.
-- Item 3 (1.2.4 refactor): the redundant `get_node_text` wrapper was
-- removed; this function and `check_require_call` now call
-- `utils.node_text` directly. The wrapper added an extra call layer with
-- zero additional logic, and its existence made it easy to accidentally
-- diverge from the canonical implementation.
local function find_string(n, depth)
  if n == nil then return nil end
  depth = depth or 0
  if depth > M.MAX_SUBTREE_DEPTH then return nil end
  local nt = n:type()
  if M.STRING_NODE_TYPES[nt] then
    local s = utils.node_text(n)
    if s then return strip_quotes(s) end
  end
  -- Defensive: n:named_child_count() can be nil for mock nodes that don't
  -- implement it (or for nodes whose underlying treesitter handle has been
  -- invalidated). Without this guard the `for i = 0, c - 1` loop would
  -- crash with "attempt to perform arithmetic on a nil value".
  local c = n:named_child_count()
  if c == nil then return nil end
  for i = 0, c - 1 do
    local r = find_string(n:named_child(i), depth + 1)
    if r then return r end
  end
  return nil
end

-- Check whether `call_node` is a `require(...)` call and, if so, return
-- the module-spec string from its first argument. Returns nil otherwise.
local function check_require_call(call_node)
  if call_node == nil then return nil end
  local ct = call_node:type()
  if not utils.CALL_NODE_TYPES[ct] then return nil end
  local callee = call_node:named_child(0)
  if not callee then return nil end
  local callee_text = utils.node_text(callee)
  if callee_text ~= "require" then return nil end
  -- Look for the first string-literal argument among the remaining
  -- named children (index 1 onwards; index 0 is the callee).
  local count = call_node:named_child_count()
  for i = 1, count - 1 do
    local r = find_string(call_node:named_child(i))
    if r then return r end
  end
  return nil
end

-- Recursively search a subtree for a require() call, bounded by
-- MAX_SUBTREE_DEPTH. Defined at module scope (rather than as an IIFE inside
-- `extract_require_module`) so it's properly scoped on both Lua 5.1/LuaJIT
-- and 5.4 — the previous IIFE form `(function search(...) ... end)(arg)`
-- is a syntax error on 5.4.
local function search_subtree_for_require(n, depth)
  if n == nil then return nil end
  depth = depth or 0
  if depth > M.MAX_SUBTREE_DEPTH then return nil end
  local m = check_require_call(n)
  if m then return m end
  local c = n:named_child_count()
  for j = 0, c - 1 do
    local r = search_subtree_for_require(n:named_child(j), depth + 1)
    if r then return r end
  end
  return nil
end

--- Extract the module string from a `require("module.name")` call.
--- Walks up to MAX_PARENT_HOPS ancestors looking for an enclosing
--- require() call; at each level, also scans sibling subtrees (bounded
--- by MAX_SUBTREE_DEPTH) to handle forms like
--- `local foo = require("bar").baz` where the require call is a sibling
--- of the binding identifier's parent.
---
--- Review 5.1: the previous version had a duplicate
--- `local utils = require("calltree.utils")` declaration that crashed
--- module load. The duplicate has already been removed in a prior
--- refactor — the current file declares `utils` exactly once at the top.
--- No change needed; the comment documents the resolution.
---
--- Review 5.2: for multi-binding forms like
---   `local a, b = require("foo"), require("bar")`
--- the previous sibling scan returned the FIRST require call found,
--- regardless of which variable was being resolved. So resolving `b`
--- incorrectly returned "foo" instead of "bar". We now track the
--- POSITION of the current identifier among its name-like siblings
--- and try to match it against the position of require calls among
--- the call-like siblings. When the positions align, we return that
--- specific require's module; otherwise we fall back to the original
--- "first match" behavior for single-binding forms (which don't have
--- a positional correspondence to disambiguate).
--- @param node table the treesitter node inside a require binding
--- @return string|nil module_spec e.g. "calltree.adapter"
function M.extract_require_module(node)
  if node == nil then return nil end

  local current = node
  for _ = 1, M.MAX_PARENT_HOPS do
    if current == nil then break end
    local mod = check_require_call(current)
    if mod then return mod end
    local parent = current:parent()
    if parent then
      -- Review 5.2: determine the positional index of `current` among
      -- identifier-like siblings, and the positional index of each
      -- require-call sibling. When they match, prefer that require
      -- over the first-match fallback.
      local count = parent:named_child_count()
      local name_idx = nil  -- 0-based position of `current` among NAME siblings
      local name_counter = 0
      local require_calls = {}  -- list of { idx = N, mod = "..." }
      local call_counter = 0
      for i = 0, count - 1 do
        local sibling = parent:named_child(i)
        if sibling then
          if sibling == current then
            name_idx = name_counter
          end
          -- Classify sibling: name-like (identifier) vs call-like.
          local st = sibling:type()
          if utils.NAME_NODE_TYPES and utils.NAME_NODE_TYPES[st] then
            name_counter = name_counter + 1
          end
          local r = check_require_call(sibling)
          if r then
            require_calls[#require_calls + 1] = { idx = call_counter, mod = r }
            call_counter = call_counter + 1
          end
        end
      end
      -- Positional match: if we found the current identifier's position
      -- AND a require call exists at the same position, return it.
      if name_idx ~= nil then
        for _, rc in ipairs(require_calls) do
          if rc.idx == name_idx then
            return rc.mod
          end
        end
      end
      -- Fallback: original "first match" behavior (single-binding case).
      for _, rc in ipairs(require_calls) do
        return rc.mod
      end
      -- Last-resort: deep-scan sibling subtrees (for forms like
      -- `local foo = require("bar").baz` where the require call is
      -- nested inside a dot_index_expression sibling).
      for i = 0, count - 1 do
        local sibling = parent:named_child(i)
        if sibling and sibling ~= current then
          mod = search_subtree_for_require(sibling)
          if mod then return mod end
        end
      end
    end
    current = parent
  end
  return nil
end

return M
