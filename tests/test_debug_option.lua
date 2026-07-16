--- tests/test_debug_option.lua — verify the `debug` config option controls
--- whether debug info is collected and included in the result.
---
--- When debug=false:
---   - The result has NO `debug` field
---   - The analysis still produces correct callers/external_calls
---   - Sub-modules incur zero debug-collection overhead (no-op collector)
---
--- When debug=true (or nil, the default):
---   - The result HAS a `debug` field with full diagnostics

local Scenario = require("scenario")
local mocks    = require("mocks")
local TB       = require("tree_builder")
local A        = require("assert")
local utils    = require("calltree.utils")

local M = {}

--------------------------------------------------------------------------------
-- Helper: build a simple scenario with one caller and one external call.
--------------------------------------------------------------------------------
local function build_scenario()
  local tree = TB.tree({
    type = "chunk", range = {0, 0, 5, 0}, children = {
      { type = "function_declaration", range = {0, 0, 2, 3}, children = {
        { type = "identifier", range = {0, 9, 0, 12}, text = "foo" },
        { type = "parameters", range = {0, 12, 0, 14}, children = {} },
        { type = "block", range = {1, 4, 2, 3}, children = {
          { type = "function_call", range = {1, 4, 1, 9}, children = {
            { type = "identifier", range = {1, 4, 1, 7}, text = "bar" },
            { type = "arguments", range = {1, 7, 1, 9}, children = {} },
          }},
        }},
      }},
    },
  })
  local uri = utils.path_to_uri("/project/test.lua")
  return Scenario.new()
    :with_code("function foo()\n    bar()\nend\n")
    :with_cursor(0, 9)
    :with_language("lua")
    :with_tree(tree:root())
    :with_file("/project/test.lua")
    :with_cwd("/project")
    :with_symbols(uri, {
      mocks.symbol("foo", utils.LSP_SYMBOL_FUNCTION, 0, 9, 2, 3),
    })
    :with_definition(uri, { line = 0, character = 9 }, {
      mocks.loc(uri, 0, 9, 0, 12),
    })
    :with_references(uri, { line = 0, character = 9 }, {
      mocks.loc(uri, 0, 9, 0, 12),
    }, true)
    :with_definition(uri, { line = 1, character = 4 }, {})
end

--------------------------------------------------------------------------------
-- Test 1: debug=true (explicit) produces a result WITH a debug field.
--------------------------------------------------------------------------------
function M.test_debug_true_produces_debug_field()
  local s = build_scenario()
  -- Pass debug=true explicitly via the analyzer context.
  local analyzer = require("calltree.core.analyzer")
  local ts = s:_build_treesitter()
  local ctx = {
    source_code = s._source_code,
    file_path = s._file_path,
    cursor_pos = s._cursor_pos,
    language = s._language,
    lsp_client = s._lsp,
    treesitter = ts,
    getcwd = function() return s._cwd end,
    read_file = function(path) return s._files[path] end,
    debug = true,
  }
  local result = analyzer.analyze(ctx)
  A.is_not_nil(result.debug, "debug=true must produce a debug field")
  A.is_not_nil(result.debug.summary, "debug field must have summary")
  A.is_not_nil(result.debug.preconditions, "debug field must have preconditions")
end

--------------------------------------------------------------------------------
-- Test 2: debug=false produces a result WITHOUT a debug field.
--------------------------------------------------------------------------------
function M.test_debug_false_omits_debug_field()
  local s = build_scenario()
  local analyzer = require("calltree.core.analyzer")
  local ts = s:_build_treesitter()
  local ctx = {
    source_code = s._source_code,
    file_path = s._file_path,
    cursor_pos = s._cursor_pos,
    language = s._language,
    lsp_client = s._lsp,
    treesitter = ts,
    getcwd = function() return s._cwd end,
    read_file = function(path) return s._files[path] end,
    debug = false,
  }
  local result = analyzer.analyze(ctx)
  A.is_nil(result.debug, "debug=false must NOT produce a debug field")
  -- The analysis itself should still work.
  A.is_not_nil(result.current_function, "current_function must still be detected")
  A.equal("foo", result.current_function.name)
end

--------------------------------------------------------------------------------
-- Test 3: debug not set (nil) defaults to enabled (backward compatible).
--------------------------------------------------------------------------------
function M.test_debug_nil_defaults_to_enabled()
  local s = build_scenario()
  local analyzer = require("calltree.core.analyzer")
  local ts = s:_build_treesitter()
  local ctx = {
    source_code = s._source_code,
    file_path = s._file_path,
    cursor_pos = s._cursor_pos,
    language = s._language,
    lsp_client = s._lsp,
    treesitter = ts,
    getcwd = function() return s._cwd end,
    read_file = function(path) return s._files[path] end,
    -- debug not set
  }
  local result = analyzer.analyze(ctx)
  A.is_not_nil(result.debug, "debug=nil (default) must produce a debug field")
end

--------------------------------------------------------------------------------
-- Test 4: debug=false still produces correct analysis (callers, external_calls).
--------------------------------------------------------------------------------
function M.test_debug_false_analysis_still_correct()
  local s = build_scenario()
  local analyzer = require("calltree.core.analyzer")
  local ts = s:_build_treesitter()
  local ctx = {
    source_code = s._source_code,
    file_path = s._file_path,
    cursor_pos = s._cursor_pos,
    language = s._language,
    lsp_client = s._lsp,
    treesitter = ts,
    getcwd = function() return s._cwd end,
    read_file = function(path) return s._files[path] end,
    debug = false,
    skip_stdlib_calls = false,
    deduplicate_external_calls = false,
  }
  local result = analyzer.analyze(ctx)
  A.is_nil(result.debug)
  A.is_not_nil(result.current_function)
  A.equal("foo", result.current_function.name)
  A.equal("table", type(result.callers), "callers must be a table")
  A.equal("table", type(result.external_calls), "external_calls must be a table")
  -- foo calls bar (unresolved since LSP returns empty)
  A.length(1, result.external_calls, "one external call (bar)")
  A.equal("bar", result.external_calls[1].function_name)
  A.equal("unresolved", result.external_calls[1].resolution_status)
end

--------------------------------------------------------------------------------
-- Test 5: debug=false produces correct EMPTY result on precondition failure.
--------------------------------------------------------------------------------
function M.test_debug_false_empty_result_on_failure()
  local analyzer = require("calltree.core.analyzer")
  local lsp = mocks.new_lsp_client()
  local uri = utils.path_to_uri("/project/test.lua")
  lsp:define_symbols(uri, { mocks.symbol("foo", utils.LSP_SYMBOL_FUNCTION, 0, 0, 1, 0) })
  local ctx = {
    source_code = "function foo() end\n",
    file_path = "/project/test.lua",
    cursor_pos = { line = 0, character = 9 },
    language = "lua",
    lsp_client = lsp,
    treesitter = nil,  -- precondition fails
    getcwd = function() return "/project" end,
    debug = false,
  }
  local result = analyzer.analyze(ctx)
  A.is_nil(result.current_function, "precondition failure -> nil current_function")
  A.is_nil(result.debug, "debug=false -> no debug field even on failure")
  A.equal(0, #result.callers)
  A.equal(0, #result.external_calls)
end

return M
