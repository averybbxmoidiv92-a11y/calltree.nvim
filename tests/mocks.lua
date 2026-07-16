--- mocks.lua — mock Treesitter and LSP client for unit tests.
---
--- Design notes:
---   - Mock treesitter nodes use Lua's "method-call" syntax (`node:type()`)
---     just like real Neovim treesitter nodes. We achieve this by giving each
---     node a metatable whose __index returns a function that closes over `self`.
---   - Trees are built from a nested-table DSL (see TSNode.new / TSBuilder).
---   - The mock `treesitter` object mimics `vim.treesitter`'s get_node/parse API
---     and supports descendant_for_range by walking the tree.
---
--- The mocks intentionally know nothing about specific languages — they just
--- hold node-type strings and child lists. Each test controls the tree shape
--- and the LSP responses.

local M = {}

-- Sentinel used by define_symbols(uri, nil) to distinguish "LSP returns nil"
-- from "no symbols registered for this URI" (which returns {}). Without this,
-- tests couldn't simulate the "LSP returns nil for document_symbols" path.
M._NIL_SENTINEL = {}  -- unique table reference

--------------------------------------------------------------------------------
-- Mock Treesitter Node
--------------------------------------------------------------------------------

-- A node is a table with fields:
--   _type      : string (the treesitter node:type() value)
--   _children  : array of named children (each a node)
--   _range     : { start_line, start_col, end_line, end_col } 0-based
--   _text      : string|nil (used as a fallback when the node has no children
--                but carries a literal value, e.g. an identifier)
--   _parent    : node|nil (set when added as a child)
--   has_error  : boolean (defaults to false)
--
-- Method syntax is provided via __index: `node:type()` works because
-- `__index.type` is a function taking (self).

local Node = {}
Node.__index = function(t, k)
  return Node[k]
end

function Node.new(opts)
  local self = setmetatable({}, Node)
  self._type = opts.type or "node"
  self._children = opts.children or {}
  self._range = opts.range or { 0, 0, 0, 0 }
  self._text = opts.text
  self._parent = nil
  self.has_error = opts.has_error or false
  -- Link children back to parent.
  for _, c in ipairs(self._children) do
    c._parent = self
  end
  return self
end

function Node:type() return self._type end
function Node:parent() return self._parent end
function Node:range() return self._range[1], self._range[2], self._range[3], self._range[4] end
function Node:named_child_count() return #self._children end
function Node:named_child(i)
  return self._children[i + 1]  -- 0-based index
end
function Node:text()
  -- If text was explicitly set, return it. Otherwise, concatenate named children text.
  if self._text ~= nil then return self._text end
  local parts = {}
  for _, c in ipairs(self._children) do
    local t = c:text()
    if t then table.insert(parts, t) end
  end
  return table.concat(parts, "")
end
function Node:child_count() return #self._children end
function Node:child(i) return self._children[i + 1] end

-- Find the smallest node whose range contains the given 0-based point.
-- Returns nil if no node contains it.
function Node:descendant_for_range(sl, sc, el, ec)
  local rsl, rsc, rel, rec = self._range[1], self._range[2], self._range[3], self._range[4]
  -- Check that this node's range contains the queried range.
  local function contains()
    if sl < rsl or el > rel then return false end
    if sl == rsl and sc < rsc then return false end
    if el == rel and ec > rec then return false end
    return true
  end
  if not contains() then return nil end
  -- Try children first (more specific).
  for _, c in ipairs(self._children) do
    local d = c:descendant_for_range(sl, sc, el, ec)
    if d ~= nil then return d end
  end
  return self
end

-- Debug helper: pretty-print the tree.
-- Truncation length uses the centralized constant from utils/constants.lua
-- (was an inline magic number 30).
local MOCK_DUMP_TEXT_LEN = require("calltree.utils.constants").MOCK_DUMP_TEXT_LEN or 30
function Node:dump(indent)
  indent = indent or ""
  local sl, sc, el, ec = self:range()
  local t = self._text or ""
  if #t > MOCK_DUMP_TEXT_LEN then t = t:sub(1, MOCK_DUMP_TEXT_LEN) .. "..." end
  print(string.format("%s%s [%d:%d-%d:%d] %q", indent, self._type, sl, sc, el, ec, t))
  for _, c in ipairs(self._children) do
    c:dump(indent .. "  ")
  end
end

M.Node = Node

--------------------------------------------------------------------------------
-- Mock Tree (returned by treesitter.parse)
--------------------------------------------------------------------------------

local Tree = {}
Tree.__index = Tree

function Tree.new(root, has_error)
  local self = setmetatable({}, Tree)
  self._root = root
  self.has_error = has_error or false
  return self
end

function Tree:root() return self._root end

M.Tree = Tree

--------------------------------------------------------------------------------
-- Mock Treesitter (the `treesitter` dependency object)
--------------------------------------------------------------------------------

-- The mock treesitter is constructed with a function that, given source_code
-- and language, returns a Tree. Tests usually pre-bake a tree and ignore the
-- source code; but the analyzer calls `treesitter.parse(source, lang)` to get
-- a tree, so the mock's parse() returns the pre-baked tree.
--
-- For tests that want parse() to actually inspect the source code (to verify
-- "real" behavior), they can pass a `parse_fn` that builds a tree from source.

local MockTreesitter = {}
MockTreesitter.__index = MockTreesitter

function M.new_treesitter(opts)
  opts = opts or {}
  local self = setmetatable({}, MockTreesitter)
  self._tree = opts.tree
  self._parse_fn = opts.parse_fn
  self._trees_by_source = opts.trees_by_source or {}
  return self
end

-- parse(source_code, language) -> Tree
function MockTreesitter:parse(source_code, language)
  if self._parse_fn then
    return self._parse_fn(source_code, language)
  end
  -- If a per-source tree was registered, use it.
  if self._trees_by_source[source_code] then
    return self._trees_by_source[source_code]
  end
  if self._tree then return self._tree end
  return nil
end

-- descendant_for_range(self, root, sl, sc, el, ec) -> node
-- This matches how the analyzer calls it: with `ts` as the first arg.
function MockTreesitter.descendant_for_range(self, root, sl, sc, el, ec)
  if root == nil then return nil end
  -- Allow the caller to pass a 4-arg range OR a (sl, sc, el, ec) sequence.
  -- The analyzer calls: ts.descendant_for_range(ts, root, sl, sc, el, ec)
  -- (we already popped `self` and `root` off, so sl/sc/el/ec are the args).
  return root:descendant_for_range(sl, sc, el, ec)
end

--------------------------------------------------------------------------------
-- Mock LSP Client
--------------------------------------------------------------------------------

-- The mock LSP client is constructed with response tables keyed by request
-- type. Tests register responses via :define_definition(uri, position, result)
-- or :define_default_definition(result) for "any request returns this".
--
-- Position matching: positions are matched by (uri, line, character). If the
-- test registers a response for a given (uri, line) without specifying character,
-- any character on that line matches. Use a wildcard `*` for any field.

local MockLSP = {}
-- Custom __index: returns nil for methods that have been explicitly
-- disabled via :disable_method(name). This makes the preconditions
-- check (`type(lsp_client[m]) == "function"`) correctly identify a
-- disabled method as "missing" — previously the method remained a
-- function (just returning nil when called), so preconditions passed
-- and the analyzer ran fully, defeating the purpose of the test.
MockLSP.__index = function(t, k)
  if t._disabled_methods and t._disabled_methods[k] then
    return nil
  end
  return MockLSP[k]
end

function M.new_lsp_client()
  local self = setmetatable({}, MockLSP)
  self._definitions = {}      -- list of { uri=, pos=, result= }
  self._declarations = {}
  self._references = {}
  self._symbols_by_uri = {}
  self._default_definition = nil
  self._default_declaration = nil  -- added for symmetry with :definition
  self._default_references = nil
  self._call_log = {}
  -- Methods that have been explicitly disabled via :disable_method(name).
  -- Keys are method names ("definition", "declaration", "references",
  -- "document_symbols"); values are `true`. When a method is disabled,
  -- the corresponding MockLSP method returns nil (mimicking a real LSP
  -- client that lacks the capability) so tests can exercise the
  -- preconditions "missing LSP method" code path.
  --
  -- This replaces the previous brittle pattern of
  --   `rawset(lsp, "definition", nil)` / `lsp.definition = nil`
  -- which was silently shadowed by the MockLSP __index metatable
  -- (so the method was never actually removed and tests passed for
  -- the wrong reason).
  self._disabled_methods = {}
  return self
end

local function pos_match(registered, actual)
  if registered.uri ~= nil and registered.uri ~= "*" and registered.uri ~= actual.uri then
    return false
  end
  if registered.pos == nil then return true end
  if registered.pos == "*" then return true end
  -- Both must be { line, character }.
  if registered.pos.line ~= nil and registered.pos.line ~= actual.line then
    return false
  end
  if registered.pos.character ~= nil and registered.pos.character ~= actual.character then
    return false
  end
  return true
end

local function find_response(registry, uri, pos)
  -- Try exact match first.
  for _, entry in ipairs(registry) do
    if pos_match(entry, { uri = uri, line = pos.line, character = pos.character }) then
      return entry.result
    end
  end
  return nil
end

function MockLSP:define_definition(uri, pos, result)
  table.insert(self._definitions, { uri = uri, pos = pos, result = result })
  return self
end

function MockLSP:define_declaration(uri, pos, result)
  table.insert(self._declarations, { uri = uri, pos = pos, result = result })
  return self
end

function MockLSP:define_references(uri, pos, result, includeDecl)
  table.insert(self._references, {
    uri = uri, pos = pos, result = result, includeDecl = includeDecl,
  })
  return self
end

function MockLSP:define_symbols(uri, symbols)
  -- Allow explicitly registering nil to simulate "LSP returns nil for
  -- document_symbols" (a different code path from "LSP returns empty table").
  -- Previously define_symbols(uri, nil) would set the key to nil, which
  -- `self._symbols_by_uri[uri] or {}` treated as "not set" → returned {}.
  -- Now we use a sentinel to distinguish "explicitly nil" from "not set".
  if symbols == nil then
    self._symbols_by_uri[uri] = M._NIL_SENTINEL
  else
    self._symbols_by_uri[uri] = symbols
  end
  return self
end

function MockLSP:set_default_definition(result)
  self._default_definition = result
  return self
end

--- Set a default declaration response (for symmetry with set_default_definition).
--- Previously :declaration had no default fallback, making it asymmetric with
--- :definition and preventing tests from simulating "any declaration request
--- returns this".
function MockLSP:set_default_declaration(result)
  self._default_declaration = result
  return self
end

function MockLSP:set_default_references(result)
  self._default_references = result
  return self
end

------------------------------------------------------------------------------
-- Method enable/disable API.
--
-- These let tests simulate "the LSP client is missing capability X"
-- without resorting to `lsp.definition = nil`, which was a no-op on a
-- metatable-backed instance (the __index fallback still resolved the
-- method). Disabled methods return nil from their handler.
------------------------------------------------------------------------------

--- Disable a capability method. Subsequent calls to that method return nil.
--- @param name string  one of "definition", "declaration", "references", "document_symbols"
--- @return self
function MockLSP:disable_method(name)
  self._disabled_methods[name] = true
  return self
end

--- Re-enable a previously-disabled method.
--- @param name string
--- @return self
function MockLSP:enable_method(name)
  self._disabled_methods[name] = nil
  return self
end

--- Check whether a method is currently disabled.
--- @param name string
--- @return boolean
function MockLSP:is_method_disabled(name)
  return self._disabled_methods[name] == true
end

-- The three required methods.
function MockLSP:definition(uri, pos)
  if self._disabled_methods.definition then return nil end
  table.insert(self._call_log, { kind = "definition", uri = uri, pos = pos })
  local r = find_response(self._definitions, uri, pos)
  if r ~= nil then return r end
  return self._default_definition
end

function MockLSP:declaration(uri, pos)
  if self._disabled_methods.declaration then return nil end
  table.insert(self._call_log, { kind = "declaration", uri = uri, pos = pos })
  local r = find_response(self._declarations, uri, pos)
  if r ~= nil then return r end
  return self._default_declaration
end

function MockLSP:references(uri, pos, includeDecl)
  if self._disabled_methods.references then return nil end
  table.insert(self._call_log, {
    kind = "references", uri = uri, pos = pos, includeDecl = includeDecl,
  })
  -- Try matching entries that don't care about includeDecl first, then any.
  for _, entry in ipairs(self._references) do
    if pos_match(entry, { uri = uri, line = pos.line, character = pos.character }) then
      if entry.includeDecl == nil or entry.includeDecl == includeDecl then
        return entry.result
      end
    end
  end
  return self._default_references or {}
end

function MockLSP:document_symbols(uri)
  if self._disabled_methods.document_symbols then return nil end
  table.insert(self._call_log, { kind = "document_symbols", uri = uri })
  local symbols = self._symbols_by_uri[uri]
  -- Distinguish "explicitly nil" (sentinel) from "not set" (key absent).
  -- When the sentinel is present, return nil so tests can simulate the
  -- "LSP returns nil" code path. When the key is absent, return {} (the
  -- backward-compatible default).
  if symbols == M._NIL_SENTINEL then
    return nil
  end
  return symbols or {}
end

function MockLSP:call_log()
  -- Return a shallow copy so callers cannot mutate the mock's internal
  -- call log via the returned reference. (Deep copy would be safer but
  -- the entries contain nested table data that callers may legitimately
  -- want to read; shallow copy blocks the most common mutation vector.)
  local copy = {}
  for i, entry in ipairs(self._call_log) do copy[i] = entry end
  return copy
end

--------------------------------------------------------------------------------
-- Convenience constructors for LSP locations / symbols
--------------------------------------------------------------------------------

--- Build a LSP location table.
--- @param uri string
--- @param sl number 0-based start line
--- @param sc number 0-based start char
--- @param el number 0-based end line
--- @param ec number 0-based end char
--- @param tags table|nil optional tags list
function M.loc(uri, sl, sc, el, ec, tags)
  return {
    uri = uri,
    range = {
      start = { line = sl, character = sc },
      ["end"] = { line = el, character = ec },
    },
    tags = tags,
  }
end

--- Build a LSP DocumentSymbol.
function M.symbol(name, kind, sl, sc, el, ec, children)
  return {
    name = name,
    kind = kind,
    range = {
      start = { line = sl, character = sc },
      ["end"] = { line = el, character = ec },
    },
    selectionRange = {
      start = { line = sl, character = sc },
      ["end"] = { line = el, character = ec },
    },
    children = children,
  }
end

return M
