--- tests/test_dotted_caller_name.lua — verify that caller functions with
--- dotted names (e.g. `function M.foo()`) are correctly extracted.
---
--- Before the fix, `get_function_name` only looked at NAME_NODE_TYPES children
--- (identifier, method_name, etc.) and returned nil for `function M.foo()`
--- because the first named child is a `dot_index_expression` (not in
--- NAME_NODE_TYPES). This caused callers like `M.analyze_at_cursor_json` to
--- appear in the callers list with `name = null`.

local Scenario = require("scenario")
local mocks    = require("mocks")
local TB       = require("tree_builder")
local A        = require("assert")
local utils    = require("calltree.utils")

local M = {}

--------------------------------------------------------------------------------
-- Test 1: caller function with dotted name `function M.bar()` should have
-- name = "M.bar" (not null).
--------------------------------------------------------------------------------
function M.test_dotted_caller_name_extracted()
  -- Tree:
  --   function M.foo() end           <- cursor here
  --   function M.bar()
  --       M.foo()                    <- caller: M.bar
  --   end
  -- Note: dot_index_expression must have identifier children so the cursor
  -- lands on an identifier (in NAME_NODE_TYPES), matching real Neovim behavior.
  local tree = TB.tree({
    type = "chunk", range = {0, 0, 6, 0}, children = {
      { type = "function_declaration", range = {0, 0, 0, 21}, children = {
        { type = "dot_index_expression", range = {0, 9, 0, 13}, children = {
          { type = "identifier", range = {0, 9, 0, 10}, text = "M" },
          { type = "identifier", range = {0, 11, 0, 14}, text = "foo" },
        }},
        { type = "parameters", range = {0, 13, 0, 15}, children = {} },
        { type = "block", range = {0, 16, 0, 21}, children = {} },
      }},
      { type = "function_declaration", range = {2, 0, 4, 3}, children = {
        { type = "dot_index_expression", range = {2, 9, 2, 13}, text = "M.bar", children = {
          { type = "identifier", range = {2, 9, 2, 10}, text = "M" },
          { type = "identifier", range = {2, 11, 2, 14}, text = "bar" },
        }},
        { type = "parameters", range = {2, 13, 2, 15}, children = {} },
        { type = "block", range = {3, 4, 4, 3}, children = {
          { type = "function_call", range = {3, 4, 3, 11}, children = {
            { type = "dot_index_expression", range = {3, 4, 3, 9}, children = {
              { type = "identifier", range = {3, 4, 3, 5}, text = "M" },
              { type = "identifier", range = {3, 6, 3, 9}, text = "foo" },
            }},
            { type = "arguments", range = {3, 9, 3, 11}, children = {} },
          }},
        }},
      }},
    },
  })
  local uri = utils.path_to_uri("/project/test.lua")
  local s = Scenario.new()
    :with_code("function M.foo() end\nfunction M.bar()\n    M.foo()\nend\n")
    :with_cursor(0, 11)  -- on "foo" inside "M.foo"
    :with_language("lua")
    :with_tree(tree:root())
    :with_file("/project/test.lua")
    :with_cwd("/project")
    :with_symbols(uri, {
      mocks.symbol("M.foo", utils.LSP_SYMBOL_FUNCTION, 0, 9, 0, 13),
      mocks.symbol("M.bar", utils.LSP_SYMBOL_FUNCTION, 2, 9, 4, 3),
    })
    :with_definition(uri, { line = 0, character = 11 }, {
      mocks.loc(uri, 0, 9, 0, 13),
    })
    :with_references(uri, { line = 0, character = 11 }, {
      mocks.loc(uri, 0, 9, 0, 13),
      mocks.loc(uri, 3, 4, 3, 9),  -- call from M.bar
    }, true)

  local result = s:analyze()
  A.is_not_nil(result.current_function)
  -- current_function.name comes from the cursor identifier's text, which is
  -- just "foo" (the inner identifier), not "M.foo". This matches real Neovim
  -- behavior where the cursor lands on the inner identifier.
  A.equal("foo", result.current_function.name,
    "current_function.name is the cursor identifier text ('foo')")
  A.length(1, result.callers, "exactly one caller (M.bar)")
  A.equal("M.bar", result.callers[1].caller_function.name,
    "caller name should be 'M.bar' (not null) — dotted caller names must be extracted via get_function_name")
end

--------------------------------------------------------------------------------
-- Test 2: caller with method syntax `function obj:method()` should have
-- name = "obj:method".
--------------------------------------------------------------------------------
function M.test_method_caller_name_extracted()
  local tree = TB.tree({
    type = "chunk", range = {0, 0, 6, 0}, children = {
      { type = "function_declaration", range = {0, 0, 0, 21}, children = {
        { type = "dot_index_expression", range = {0, 9, 0, 13}, children = {
          { type = "identifier", range = {0, 9, 0, 10}, text = "M" },
          { type = "identifier", range = {0, 11, 0, 14}, text = "foo" },
        }},
        { type = "parameters", range = {0, 13, 0, 15}, children = {} },
        { type = "block", range = {0, 16, 0, 21}, children = {} },
      }},
      { type = "function_declaration", range = {2, 0, 4, 3}, children = {
        { type = "method_index_expression", range = {2, 9, 2, 18}, text = "obj:method", children = {
          { type = "identifier", range = {2, 9, 2, 12}, text = "obj" },
          { type = "identifier", range = {2, 13, 2, 19}, text = "method" },
        }},
        { type = "parameters", range = {2, 18, 2, 20}, children = {} },
        { type = "block", range = {3, 4, 4, 3}, children = {
          { type = "function_call", range = {3, 4, 3, 11}, children = {
            { type = "dot_index_expression", range = {3, 4, 3, 9}, children = {
              { type = "identifier", range = {3, 4, 3, 5}, text = "M" },
              { type = "identifier", range = {3, 6, 3, 9}, text = "foo" },
            }},
            { type = "arguments", range = {3, 9, 3, 11}, children = {} },
          }},
        }},
      }},
    },
  })
  local uri = utils.path_to_uri("/project/test.lua")
  local s = Scenario.new()
    :with_code("function M.foo() end\nfunction obj:method()\n    M.foo()\nend\n")
    :with_cursor(0, 11)
    :with_language("lua")
    :with_tree(tree:root())
    :with_file("/project/test.lua")
    :with_cwd("/project")
    :with_symbols(uri, {
      mocks.symbol("M.foo", utils.LSP_SYMBOL_FUNCTION, 0, 9, 0, 13),
      mocks.symbol("obj:method", utils.LSP_SYMBOL_METHOD, 2, 9, 4, 3),
    })
    :with_definition(uri, { line = 0, character = 11 }, {
      mocks.loc(uri, 0, 9, 0, 13),
    })
    :with_references(uri, { line = 0, character = 11 }, {
      mocks.loc(uri, 0, 9, 0, 13),
      mocks.loc(uri, 3, 4, 3, 9),
    }, true)

  local result = s:analyze()
  A.is_not_nil(result.current_function)
  A.length(1, result.callers)
  A.equal("obj:method", result.callers[1].caller_function.name,
    "caller name should be 'obj:method' (method syntax extracted)")
end

return M
