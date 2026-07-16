--- tests/test_preconditions.lua — precondition checks.
---
--- Covers:
---   a. LSP client missing the `definition` method -> empty JSON.
---   b. Treesitter parse returns an error node (has_error = true) -> empty JSON.
---   c. Document symbols empty -> empty JSON.

local Scenario = require("scenario")
local mocks    = require("mocks")
local TB       = require("tree_builder")
local A        = require("assert")
local utils    = require("calltree.utils")

local M = {}

function M.test_lsp_missing_definition_method()
  -- Build a scenario, then disable the `definition` method on the LSP
  -- client before analyzing.
  --
  -- We use the new MockLSP:disable_method("definition") API rather than
  -- the previous `lsp.definition = nil` hack, which was silently
  -- shadowed by the MockLSP metatable's __index fallback — so the
  -- method was never actually removed, the preconditions check did NOT
  -- bail on "LSP missing definition", and the test's assertions passed
  -- for the wrong reason (the analysis ran fully rather than short-
  -- circuited at preconditions).
  --
  -- We also register a tree + symbols here so the preconditions phase
  -- actually advances to the "LSP-calls" sub-check (otherwise it would
  -- bail earlier on "no treesitter tree" / "no document symbols" and
  -- never reach the missing-definition branch).
  local tree = TB.tree({
    type = "program", range = {0,0,1,0}, children = {
      { type = "function_definition", range = {0,0,1,0}, children = {
        { type = "identifier", range = {0,4,0,7}, text = "foo" },
      }},
    },
  })
  local uri = utils.path_to_uri("/project/test.py")
  local s = Scenario.new()
    :with_code("def foo():\n    pass\n")
    :with_cursor(0, 4)
    :with_language("python")
    :with_tree(tree:root())
    :with_cwd("/project")
    :with_file("/project/test.py")
    :with_symbols(uri, {
      mocks.symbol("foo", utils.LSP_SYMBOL_FUNCTION, 0, 0, 1, 0),
    })
  -- Pretend the LSP client is missing the `definition` method.
  local lsp = s:lsp()
  lsp:disable_method("definition")
  A.truthy(lsp:is_method_disabled("definition"),
    "disable_method should mark definition as disabled")
  local result = s:analyze()
  A.is_nil(result.current_function, "current_function should be nil when LSP lacks definition")
  A.length(0, result.callers, "callers should be empty")
  A.length(0, result.external_calls, "external_calls should be empty")
end

function M.test_treesitter_returns_error_node()
  local error_tree = TB.tree({
    type = "program", range = {0,0,2,0}, has_error = true,
    children = {
      { type = "ERROR", range = {0,0,1,0}, text = "garbage" },
    },
  }, true)
  local s = Scenario.new()
    :with_code("garbage")
    :with_cursor(0, 0)
    :with_language("python")
    :with_tree(error_tree:root())
    :with_file("/project/test.py")
  -- Even though symbols are defined, has_error means we bail.
  local uri = utils.path_to_uri("/project/test.py")
  s:with_symbols(uri, {
    mocks.symbol("foo", utils.LSP_SYMBOL_FUNCTION, 0, 0, 1, 0),
  })
  local result = s:analyze()
  A.is_nil(result.current_function)
  A.length(0, result.callers)
  A.length(0, result.external_calls)
end

function M.test_treesitter_returns_nil()
  -- parse returns nil entirely (no parser available).
  local s = Scenario.new()
    :with_code("def foo():\n    pass\n")
    :with_cursor(0, 4)
    :with_language("python")
    :with_file("/project/test.py")
  -- No tree set -> parse returns nil -> bail.
  local result = s:analyze()
  A.is_nil(result.current_function)
end

function M.test_document_symbols_empty()
  local tree = TB.tree({
    type = "program", range = {0,0,3,0}, children = {
      { type = "function_definition", range = {0,0,1,0}, children = {
        { type = "identifier", range = {0,4,0,7}, text = "foo" },
      }},
    },
  })
  local s = Scenario.new()
    :with_code("def foo():\n    pass\n")
    :with_cursor(0, 4)
    :with_language("python")
    :with_tree(tree:root())
    :with_file("/project/test.py")
  -- No symbols registered -> document_symbols returns {} -> bail.
  local result = s:analyze()
  A.is_nil(result.current_function)
  A.length(0, result.callers)
  A.length(0, result.external_calls)
end

function M.test_no_treesitter_object()
  -- Pass a context without a treesitter object.
  local analyzer = require("calltree.core.analyzer")
  local lsp = mocks.new_lsp_client()
  local uri = utils.path_to_uri("/project/test.py")
  lsp:define_symbols(uri, { mocks.symbol("foo", utils.LSP_SYMBOL_FUNCTION, 0,0,1,0) })
  local ctx = {
    source_code = "def foo():\n    pass\n",
    file_path = "/project/test.py",
    cursor_pos = { line = 0, character = 4 },
    language = "python",
    lsp_client = lsp,
    treesitter = nil,
    getcwd = function() return "/project" end,
  }
  local result = analyzer.analyze(ctx)
  A.is_nil(result.current_function)
end

return M
