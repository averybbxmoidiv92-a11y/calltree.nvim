--- tests/test_user_scenario.lua — end-to-end regression test mimicking the
--- exact scenario the user reported: `function M.analyze_at_cursor(bufnr)`
--- containing calls to `adapter.build_context(bufnr, cursor_pos)` and
--- `analyzer.analyze(ctx)`.
---
--- Before the fix, the output showed:
---   - function_name included args: "adapter.build_context(bufnr, cursor_pos)"
---   - all 3 external_calls were "unresolved"
---
--- After the fix, we expect:
---   - function_name is callee-only: "adapter.build_context", "analyzer.analyze", "unpack"
---   - calls to project-local functions (adapter.build_context, analyzer.analyze)
---     resolve successfully when the LSP returns their definitions

local Scenario = require("scenario")
local mocks    = require("mocks")
local TB       = require("tree_builder")
local A        = require("assert")
local utils    = require("calltree.utils")

local M = {}

--------------------------------------------------------------------------------
-- Build a realistic tree-sitter-lua AST for:
--   function M.analyze_at_cursor(bufnr)
--       local row, col = unpack(vim.api.nvim_win_get_cursor(0))
--       local cursor_pos = { line = row - 1, character = col }
--       local ctx = adapter.build_context(bufnr, cursor_pos)
--       local result = analyzer.analyze(ctx)
--       return result
--   end
--
-- We focus on the 3 call expressions the user reported. Each `function_call`
-- node has children: [callee_node, arguments_node].
--------------------------------------------------------------------------------
local function build_user_scenario_tree()
  return TB.tree({
    type = "chunk", range = {15, 0, 22, 3}, children = {
      { type = "function_declaration", range = {15, 0, 22, 3}, children = {
        -- M.analyze_at_cursor (dot_index_expression as the function name)
        { type = "dot_index_expression", range = {15, 9, 15, 28}, children = {
          { type = "identifier", range = {15, 9, 15, 10}, text = "M" },
          { type = "identifier", range = {15, 11, 15, 28}, text = "analyze_at_cursor" },
        }},
        { type = "parameters", range = {15, 28, 15, 35}, children = {
          { type = "identifier", range = {15, 29, 15, 34}, text = "bufnr" },
        }},
        { type = "block", range = {16, 4, 22, 3}, children = {
          -- Line 17: unpack(vim.api.nvim_win_get_cursor(0))
          { type = "function_call", range = {17, 19, 17, 57}, children = {
            { type = "identifier", range = {17, 19, 17, 24}, text = "unpack" },
            { type = "arguments", range = {17, 24, 17, 57}, children = {} },
          }},
          -- Line 20: adapter.build_context(bufnr, cursor_pos)
          { type = "function_call", range = {20, 14, 20, 54}, children = {
            { type = "dot_index_expression", range = {20, 14, 20, 38}, text = "adapter.build_context" },
            { type = "arguments", range = {20, 38, 20, 54}, children = {} },
          }},
          -- Line 21: analyzer.analyze(ctx)
          { type = "function_call", range = {21, 9, 21, 30}, children = {
            { type = "dot_index_expression", range = {21, 9, 21, 26}, text = "analyzer.analyze" },
            { type = "arguments", range = {21, 26, 21, 30}, children = {} },
          }},
        }},
      }},
    },
  })
end

--------------------------------------------------------------------------------
-- Test 1: function_name should NOT include arguments.
-- Before fix: "unpack(vim.api.nvim_win_get_cursor(0))"
-- After fix:  "unpack"
--------------------------------------------------------------------------------
function M.test_function_name_excludes_args()
  local tree = build_user_scenario_tree()
  local uri = utils.path_to_uri("/project/init.lua")
  local s = Scenario.new()
    :with_code("-- placeholder\n")
    :with_cursor(15, 15)  -- on "analyze_at_cursor"
    :with_language("lua")
    :with_tree(tree:root())
    :with_file("/project/init.lua")
    :with_cwd("/project")
    :with_symbols(uri, {
      mocks.symbol("M.analyze_at_cursor", utils.LSP_SYMBOL_FUNCTION, 15, 9, 22, 3),
    })
    :with_definition(uri, { line = 15, character = 15 }, {
      mocks.loc(uri, 15, 9, 15, 28),
    })
    :with_references(uri, { line = 15, character = 15 }, {
      mocks.loc(uri, 15, 9, 15, 28),
    }, true)
    -- All 3 callee definitions return empty (simulating the old broken LSP).
    :with_definition(uri, { line = 17, character = 19 }, {})
    :with_definition(uri, { line = 20, character = 14 }, {})
    :with_definition(uri, { line = 21, character = 9 }, {})

  local result = s:analyze({ skip_stdlib_calls = false, deduplicate_external_calls = false })
  A.is_not_nil(result.current_function)
  A.equal("analyze_at_cursor", result.current_function.name)

  A.length(3, result.external_calls, "should detect all 3 calls")

  -- Verify function_name does NOT include arguments.
  local names = {}
  for _, ec in ipairs(result.external_calls) do
    table.insert(names, ec.function_name)
  end
  table.sort(names)

  A.equal("adapter.build_context", names[1],
    "function_name should be 'adapter.build_context' (no args), NOT 'adapter.build_context(bufnr, cursor_pos)'")
  A.equal("analyzer.analyze", names[2],
    "function_name should be 'analyzer.analyze' (no args), NOT 'analyzer.analyze(ctx)'")
  A.equal("unpack", names[3],
    "function_name should be 'unpack' (no args), NOT 'unpack(vim.api.nvim_win_get_cursor(0))'")
end

--------------------------------------------------------------------------------
-- Test 2: when the LSP DOES return definitions for project-local functions,
-- adapter.build_context and analyzer.analyze should resolve.
-- This simulates the fixed adapter (using buf_request_sync) where LSP
-- requests actually return results.
--------------------------------------------------------------------------------
function M.test_project_calls_resolve_with_working_lsp()
  local tree = build_user_scenario_tree()
  local uri = utils.path_to_uri("/project/init.lua")
  local adapter_uri = utils.path_to_uri("/project/adapter.lua")
  local analyzer_uri = utils.path_to_uri("/project/call_analyzer.lua")

  local s = Scenario.new()
    :with_code("-- placeholder\n")
    :with_cursor(15, 15)
    :with_language("lua")
    :with_tree(tree:root())
    :with_file("/project/init.lua")
    :with_cwd("/project")
    :with_symbols(uri, {
      mocks.symbol("M.analyze_at_cursor", utils.LSP_SYMBOL_FUNCTION, 15, 9, 22, 3),
    })
    :with_definition(uri, { line = 15, character = 15 }, {
      mocks.loc(uri, 15, 9, 15, 28),
    })
    :with_references(uri, { line = 15, character = 15 }, {
      mocks.loc(uri, 15, 9, 15, 28),
    }, true)
    -- unpack: LSP returns nothing (it's a built-in) -> unresolved
    :with_definition(uri, { line = 17, character = 19 }, {})
    -- adapter.build_context: LSP returns a definition in the project -> resolved
    :with_definition(uri, { line = 20, character = 14 }, {
      mocks.loc(adapter_uri, 50, 9, 50, 22),
    })
    -- analyzer.analyze: LSP returns a definition in the project -> resolved
    :with_definition(uri, { line = 21, character = 9 }, {
      mocks.loc(analyzer_uri, 100, 9, 100, 16),
    })

  -- Register source + tree for the definition files so body-check passes.
  local adapter_source = "function M.build_context()\nend\n"
  local adapter_tree = TB.tree({
    type = "chunk", range = {48, 0, 52, 3}, children = {
      { type = "function_declaration", range = {50, 0, 52, 3}, children = {
        { type = "dot_index_expression", range = {50, 9, 50, 22}, children = {
          { type = "identifier", range = {50, 9, 50, 10}, text = "M" },
          { type = "identifier", range = {50, 11, 50, 22}, text = "build_context" },
        }},
        { type = "parameters", range = {50, 22, 50, 24}, children = {} },
        { type = "block", range = {51, 4, 52, 3}, children = {} },
      }},
    },
  })
  local analyzer_source = "function M.analyze()\nend\n"
  local analyzer_tree = TB.tree({
    type = "chunk", range = {98, 0, 102, 3}, children = {
      { type = "function_declaration", range = {100, 0, 102, 3}, children = {
        { type = "dot_index_expression", range = {100, 9, 100, 16}, children = {
          { type = "identifier", range = {100, 9, 100, 10}, text = "M" },
          { type = "identifier", range = {100, 11, 100, 16}, text = "analyze" },
        }},
        { type = "parameters", range = {100, 16, 100, 18}, children = {} },
        { type = "block", range = {101, 4, 102, 3}, children = {} },
      }},
    },
  })
  s:with_file_content("/project/adapter.lua", adapter_source)
  s:with_tree_for_source(adapter_source, adapter_tree:root())
  s:with_file_content("/project/call_analyzer.lua", analyzer_source)
  s:with_tree_for_source(analyzer_source, analyzer_tree:root())

  local result = s:analyze({ skip_stdlib_calls = false, deduplicate_external_calls = false })
  A.is_not_nil(result.current_function)
  A.length(3, result.external_calls)

  -- Categorize by resolution_status.
  local resolved = {}
  local unresolved = {}
  for _, ec in ipairs(result.external_calls) do
    if ec.resolution_status == "resolved" then
      table.insert(resolved, ec.function_name)
    else
      table.insert(unresolved, ec.function_name)
    end
  end
  table.sort(resolved)
  table.sort(unresolved)

  -- adapter.build_context and analyzer.analyze should resolve.
  A.length(2, resolved, "adapter.build_context and analyzer.analyze should resolve")
  A.equal("adapter.build_context", resolved[1])
  A.equal("analyzer.analyze", resolved[2])

  -- unpack should remain unresolved (it's a Lua built-in, no project definition).
  A.length(1, unresolved, "unpack should remain unresolved (built-in)")
  A.equal("unpack", unresolved[1])
end

--------------------------------------------------------------------------------
-- Test 3: the debug field should record callee_node separately from call_node.
--------------------------------------------------------------------------------
function M.test_debug_separates_callee_from_call()
  local tree = build_user_scenario_tree()
  local uri = utils.path_to_uri("/project/init.lua")
  local s = Scenario.new()
    :with_code("-- placeholder\n")
    :with_cursor(15, 15)
    :with_language("lua")
    :with_tree(tree:root())
    :with_file("/project/init.lua")
    :with_cwd("/project")
    :with_symbols(uri, {
      mocks.symbol("M.analyze_at_cursor", utils.LSP_SYMBOL_FUNCTION, 15, 9, 22, 3),
    })
    :with_definition(uri, { line = 15, character = 15 }, {
      mocks.loc(uri, 15, 9, 15, 28),
    })
    :with_references(uri, { line = 15, character = 15 }, {
      mocks.loc(uri, 15, 9, 15, 28),
    }, true)
    :with_definition(uri, { line = 17, character = 19 }, {})
    :with_definition(uri, { line = 20, character = 14 }, {})
    :with_definition(uri, { line = 21, character = 9 }, {})

  local result = s:analyze({ skip_stdlib_calls = false, deduplicate_external_calls = false })
  for _, d in ipairs(result.debug.external_call_decisions) do
    A.is_not_nil(d.call_node, "debug should record the full call_node")
    A.is_not_nil(d.callee_node, "debug should record the callee_node separately")
    A.is_not_nil(d.full_call_range_0based, "debug should record full_call_range_0based")
    -- The callee_node's type should be 'identifier' or 'dot_index_expression',
    -- NOT 'function_call' (that's the call_node's type).
    A.truthy(d.callee_node.type == "identifier" or d.callee_node.type == "dot_index_expression",
      "callee_node type should be identifier or dot_index_expression, got: " .. tostring(d.callee_node.type))
  end
end

return M
