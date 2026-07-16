--- tests/test_callee_extraction.lua — verify function_name extracts the CALLEE
--- (the function being called), NOT the whole call expression including arguments.
---
--- This is a regression test for a real-world bug: when the real Neovim adapter
--- returned the full call node's text (e.g. "adapter.build_context(bufnr, cursor_pos)"
--- instead of just "adapter.build_context"), the `function_name` field was wrong.
---
--- We build mock trees with realistic AST structure (call node has a callee
--- child + an arguments child) and verify:
---   1. function_name = callee text only (no parens, no args)
---   2. call_position = start of the callee, not start of the whole call
---   3. LSP definition request uses the callee's start position

local Scenario  = require("scenario")
local mocks     = require("mocks")
local TB        = require("tree_builder")
local A         = require("assert")
local utils     = require("calltree.utils")

local M = {}

--------------------------------------------------------------------------------
-- Helper: build a realistic Lua call tree where the call node has children
-- (callee + arguments), mimicking the real tree-sitter-lua grammar.
--------------------------------------------------------------------------------
local function build_lua_call_tree(callee_text, callee_range, call_range, func_name, func_range)
  func_name = func_name or "foo"
  func_range = func_range or {0, 0, 2, 3}
  return TB.tree({
    type = "program", range = {0, 0, 3, 0}, children = {
      {
        type = "function_declaration", range = func_range, children = {
          { type = "identifier", range = {func_range[1], 9, func_range[1], 9 + #func_name}, text = func_name },
          { type = "parameters", range = {func_range[1], 9 + #func_name, func_range[1], 11 + #func_name}, children = {} },
          { type = "block", range = {func_range[1] + 1, 4, func_range[3], 3}, children = {
            {
              type = "function_call", range = call_range, children = {
                { type = "dot_index_expression", range = callee_range, text = callee_text },
                { type = "arguments", range = {call_range[3], call_range[2] + #callee_text, call_range[3], call_range[4]}, children = {} },
              },
            },
          }},
        },
      },
    },
  })
end

--------------------------------------------------------------------------------
-- Test 1: `adapter.build_context(bufnr, cursor_pos)` → function_name should be
-- "adapter.build_context" (no args), call_position should point at "adapter".
--------------------------------------------------------------------------------
function M.test_dotted_callee_no_args()
  -- Source:  function foo()
  --              adapter.build_context(bufnr, cursor_pos)
  --          end
  -- callee "adapter.build_context" at (1, 4) to (1, 28)
  -- full call at (1, 4) to (1, 54)
  local tree = build_lua_call_tree(
    "adapter.build_context",           -- callee text
    {1, 4, 1, 28},                     -- callee range (0-based)
    {1, 4, 1, 54},                     -- full call range
    "foo", {0, 0, 2, 3}
  )
  local uri = utils.path_to_uri("/project/main.lua")
  local s = Scenario.new()
    :with_code("function foo()\n    adapter.build_context(bufnr, cursor_pos)\nend\n")
    :with_cursor(0, 9)
    :with_language("lua")
    :with_tree(tree:root())
    :with_file("/project/main.lua")
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
    -- LSP definition for the callee at position (1, 4)
    :with_definition(uri, { line = 1, character = 4 }, {
      mocks.loc(utils.path_to_uri("/project/adapter.lua"), 0, 0, 0, 10),
    })

  local result = s:analyze({ skip_stdlib_calls = false, deduplicate_external_calls = false })
  A.is_not_nil(result.current_function)
  A.length(1, result.external_calls, "exactly one external call")
  local ec = result.external_calls[1]
  A.equal("adapter.build_context", ec.function_name,
    "function_name should be callee only, not including arguments")
  A.equal(2, ec.call_position.line, "call_position line should be 1-based (1+1=2)")
  A.equal(5, ec.call_position.character, "call_position char should be 1-based (4+1=5)")
end

--------------------------------------------------------------------------------
-- Test 2: `unpack(vim.api.nvim_win_get_cursor(0))` → function_name should be
-- "unpack" (just the callee identifier, no args). The inner call
-- `vim.api.nvim_win_get_cursor(0)` should NOT be double-counted.
--------------------------------------------------------------------------------
function M.test_nested_call_not_double_counted()
  -- Tree: function foo()
  --          unpack(vim.api.nvim_win_get_cursor(0))
  --       end
  -- The outer call is `unpack(...)`. Its callee is the identifier "unpack".
  -- The argument contains a nested call, but we should NOT descend into it.
  local tree = TB.tree({
    type = "program", range = {0, 0, 2, 3}, children = {
      { type = "function_declaration", range = {0, 0, 2, 3}, children = {
        { type = "identifier", range = {0, 9, 0, 12}, text = "foo" },
        { type = "parameters", range = {0, 12, 0, 14}, children = {} },
        { type = "block", range = {1, 4, 2, 3}, children = {
          { type = "function_call", range = {1, 4, 1, 40}, children = {
            { type = "identifier", range = {1, 4, 1, 9}, text = "unpack" },
            { type = "arguments", range = {1, 9, 1, 40}, children = {
              -- Nested call inside arguments — should be ignored.
              { type = "function_call", range = {1, 10, 1, 39}, children = {
                { type = "dot_index_expression", range = {1, 10, 1, 34}, text = "vim.api.nvim_win_get_cursor" },
                { type = "arguments", range = {1, 34, 1, 39}, children = {} },
              }},
            }},
          }},
        }},
      }},
    },
  })
  local uri = utils.path_to_uri("/project/test.lua")
  local s = Scenario.new()
    :with_code("function foo()\n    unpack(vim.api.nvim_win_get_cursor(0))\nend\n")
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

  local result = s:analyze({ skip_stdlib_calls = false, deduplicate_external_calls = false })
  A.length(1, result.external_calls, "only the OUTER call should be recorded; nested call in args must be skipped")
  A.equal("unpack", result.external_calls[1].function_name,
    "function_name should be 'unpack' (callee only), not the full expression with args")
end

--------------------------------------------------------------------------------
-- Test 3: Verify the debug field records both call_node and callee_node.
--------------------------------------------------------------------------------
function M.test_debug_records_callee_node()
  local tree = TB.tree({
    type = "program", range = {0, 0, 2, 3}, children = {
      { type = "function_declaration", range = {0, 0, 2, 3}, children = {
        { type = "identifier", range = {0, 9, 0, 12}, text = "foo" },
        { type = "parameters", range = {0, 12, 0, 14}, children = {} },
        { type = "block", range = {1, 4, 2, 3}, children = {
          { type = "function_call", range = {1, 4, 1, 20}, children = {
            { type = "identifier", range = {1, 4, 1, 7}, text = "bar" },
            { type = "arguments", range = {1, 7, 1, 20}, children = {} },
          }},
        }},
      }},
    },
  })
  local uri = utils.path_to_uri("/project/test.lua")
  local s = Scenario.new()
    :with_code("function foo()\n    bar(some_arg)\nend\n")
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

  local result = s:analyze({ skip_stdlib_calls = false, deduplicate_external_calls = false })
  A.length(1, result.external_calls)
  A.equal("bar", result.external_calls[1].function_name)
  -- Debug should record both the full call node and the callee node.
  local d = result.debug.external_call_decisions[1]
  A.is_not_nil(d.call_node, "debug should record the full call_node")
  A.is_not_nil(d.callee_node, "debug should record the callee_node separately")
  A.equal("function_call", d.call_node.type)
  A.equal("identifier", d.callee_node.type)
  A.equal("bar", d.callee_node.text)
  A.is_not_nil(d.full_call_range_0based, "debug should record the full call range")
end

return M
