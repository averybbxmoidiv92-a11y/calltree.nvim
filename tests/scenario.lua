--- scenario.lua — fluent builder for analyzer test scenarios.
---
--- Usage:
---   local s = Scenario:new()
---     :with_code("def foo():\n    pass\n")
---     :with_cursor(0, 4)
---     :with_language("python")
---     :with_cwd("/project")
---     :with_tree(tree_root_node)
---     :with_symbols(uri, symbols)
---     :with_definition(uri, pos, result)
---     :with_references(uri, pos, result)
---   local result = s:analyze()
---
--- Each scenario owns its own MockLSP and MockTreesitter so tests don't bleed.

local mocks = require("mocks")
local utils  = require("calltree.utils")
local analyzer = require("calltree.core.analyzer")

local M = {}

local Scenario = {}
Scenario.__index = Scenario

function M.new()
  local self = setmetatable({}, Scenario)
  self._source_code = ""
  self._file_path = "/project/test.lua"
  self._cursor_pos = { line = 0, character = 0 }
  self._language = "lua"
  self._cwd = "/project"
  self._tree = nil
  self._trees_by_source = {}
  self._lsp = mocks.new_lsp_client()
  self._files = {}  -- map path -> source_code (for read_file)
  return self
end

-- Convenience alias.
function Scenario:new() return M.new() end

function Scenario:with_code(code)
  self._source_code = code
  return self
end

function Scenario:with_file(path)
  self._file_path = path
  return self
end

function Scenario:with_cursor(line, character)
  self._cursor_pos = { line = line, character = character }
  return self
end

function Scenario:with_language(lang)
  self._language = lang
  return self
end

function Scenario:with_cwd(cwd)
  self._cwd = cwd
  return self
end

function Scenario:with_tree(root_node)
  self._tree = root_node
  return self
end

-- Register an alternate tree for a different source code (used when the
-- analyzer parses a referencing file in another buffer).
function Scenario:with_tree_for_source(source_code, root_node)
  self._trees_by_source[source_code] = root_node
  return self
end

function Scenario:with_file_content(path, source_code)
  self._files[path] = source_code
  return self
end

function Scenario:with_symbols(uri, symbols)
  self._lsp:define_symbols(uri, symbols)
  return self
end

function Scenario:with_definition(uri, pos, result)
  self._lsp:define_definition(uri, pos, result)
  return self
end

function Scenario:with_default_definition(result)
  self._lsp:set_default_definition(result)
  return self
end

function Scenario:with_declaration(uri, pos, result)
  self._lsp:define_declaration(uri, pos, result)
  return self
end

function Scenario:with_references(uri, pos, result, includeDecl)
  self._lsp:define_references(uri, pos, result, includeDecl)
  return self
end

function Scenario:with_default_references(result)
  self._lsp:set_default_references(result)
  return self
end

function Scenario:lsp() return self._lsp end

-- Build the treesitter mock from the scenario's tree(s).
function Scenario:_build_treesitter()
  local trees_by_source = {}
  for src, root in pairs(self._trees_by_source) do
    trees_by_source[src] = mocks.Tree.new(root, false)
  end
  local main_tree = self._tree and mocks.Tree.new(self._tree, false) or nil
  return mocks.new_treesitter({
    tree = main_tree,
    trees_by_source = trees_by_source,
    parse_fn = function(source, _lang)
      if trees_by_source[source] then return trees_by_source[source] end
      if main_tree then return main_tree end
      return nil
    end,
  })
end

function Scenario:analyze(opts)
  local ts = self:_build_treesitter()
  -- Reuse the canonical uri_to_path implementation instead of the
  -- duplicated inline version below. The previous inline impl was a
  -- maintenance burden and could drift out of sync with the real one
  -- (e.g. when path.lua fixes a Windows-handling bug, this mock would
  -- not pick it up).
  local path_utils = require("calltree.utils.path")
  local ctx = {
    source_code = self._source_code,
    file_path   = self._file_path,
    cursor_pos  = self._cursor_pos,
    language    = self._language,
    lsp_client  = self._lsp,
    treesitter  = ts,
    getcwd      = function() return self._cwd end,
    read_file   = function(path)
      if path == nil then return nil end
      if self._files[path] then return self._files[path] end
      -- Normalize file:// URIs to filesystem paths via the canonical
      -- helper. Falls back to the raw input when uri_to_path returns
      -- nil (e.g. for already-normalized filesystem paths).
      local stripped = path_utils.uri_to_path(path) or path
      return self._files[stripped]
    end,
    -- v1.2.0: thread post-collection filtering flags through the test
    -- scenario. Default behavior matches the production default (both
    -- true). Tests that need the raw unfiltered list (e.g. tests
    -- verifying the stdlib-keep path) pass
    --   { skip_stdlib_calls = false, deduplicate_external_calls = false }
    skip_stdlib_calls          = opts and opts.skip_stdlib_calls,
    deduplicate_external_calls = opts and opts.deduplicate_external_calls,
  }
  return analyzer.analyze(ctx)
end

return M
