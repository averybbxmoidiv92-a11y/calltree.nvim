--- tests/test_cursor_position.lua — cursor-not-on-function-name cases.
---
--- Covers:
---   - cursor on a function call expression -> empty.
---   - cursor on an identifier in a parameter list -> empty.
---   - cursor on a function name inside a comment -> empty (the node under the
---     cursor is not a "name" sub-node of a function definition).

local Scenario = require("scenario")
local mocks    = require("mocks")
local TB       = require("tree_builder")
local A        = require("assert")
local utils    = require("calltree.utils")

local M = {}

-- Helper: build a typical Python-style tree with a function definition and a
-- call to it from another function, with full position info.
local function build_basic_tree()
  return TB.tree({
    type = "module", range = {0,0,5,0}, children = {
      -- def foo():
      { type = "function_definition", range = {0,0,1,0}, children = {
        { type = "identifier", range = {0,4,0,7}, text = "foo" },
        { type = "parameters", range = {0,7,0,9}, children = {
          { type = "identifier", range = {0,8,0,8}, text = "" },  -- empty param
        }},
        { type = "block", range = {1,0,1,0}, children = {} },
      }},
      -- def bar():
      { type = "function_definition", range = {2,0,4,0}, children = {
        { type = "identifier", range = {2,4,2,7}, text = "bar" },
        { type = "block", range = {3,0,3,0}, children = {
          { type = "call", range = {3,4,3,7}, text = "foo" },
        }},
      }},
    },
  })
end

function M.test_cursor_on_call_site()
  local tree = build_basic_tree()
  local uri = utils.path_to_uri("/project/test.py")
  local s = Scenario.new()
    :with_code("def foo():\n    pass\ndef bar():\n    foo()\n")
    :with_cursor(3, 4)  -- on the `foo` call
    :with_language("python")
    :with_tree(tree:root())
    :with_file("/project/test.py")
    :with_symbols(uri, {
      mocks.symbol("foo", utils.LSP_SYMBOL_FUNCTION, 0, 4, 1, 0),
      mocks.symbol("bar", utils.LSP_SYMBOL_FUNCTION, 2, 4, 4, 0),
    })
  local result = s:analyze()
  A.is_nil(result.current_function, "cursor on call site should yield empty result")
  A.length(0, result.callers)
  A.length(0, result.external_calls)
end

function M.test_cursor_on_parameter_identifier()
  -- Cursor is on a parameter name inside `def foo(x):`.
  local tree = TB.tree({
    type = "module", range = {0,0,2,0}, children = {
      { type = "function_definition", range = {0,0,1,0}, children = {
        { type = "identifier", range = {0,4,0,7}, text = "foo" },
        { type = "parameters", range = {0,7,0,10}, children = {
          { type = "identifier", range = {0,8,0,9}, text = "x" },
        }},
        { type = "block", range = {1,0,1,0}, children = {} },
      }},
    },
  })
  local uri = utils.path_to_uri("/project/test.py")
  local s = Scenario.new()
    :with_code("def foo(x):\n    pass\n")
    :with_cursor(0, 8)  -- on the `x` parameter
    :with_language("python")
    :with_tree(tree:root())
    :with_file("/project/test.py")
    :with_symbols(uri, {
      mocks.symbol("foo", utils.LSP_SYMBOL_FUNCTION, 0, 4, 1, 0),
    })
  local result = s:analyze()
  A.is_nil(result.current_function, "cursor on parameter should yield empty result")
end

function M.test_cursor_in_comment()
  -- The cursor is on an identifier that lives inside a comment node, not a
  -- function-definition name.
  local tree = TB.tree({
    type = "module", range = {0,0,3,0}, children = {
      { type = "comment", range = {0,0,0,20}, text = "# this is foo" },
      { type = "function_definition", range = {1,0,2,0}, children = {
        { type = "identifier", range = {1,4,1,7}, text = "foo" },
        { type = "block", range = {2,0,2,0}, children = {} },
      }},
    },
  })
  local uri = utils.path_to_uri("/project/test.py")
  local s = Scenario.new()
    :with_code("# this is foo\ndef foo():\n    pass\n")
    :with_cursor(0, 12)  -- inside the comment, on "foo"
    :with_language("python")
    :with_tree(tree:root())
    :with_file("/project/test.py")
    :with_symbols(uri, {
      mocks.symbol("foo", utils.LSP_SYMBOL_FUNCTION, 1, 4, 2, 0),
    })
  local result = s:analyze()
  A.is_nil(result.current_function, "cursor on comment-identifier should yield empty")
end

function M.test_cursor_on_variable_assignment()
  -- Cursor on the LHS of an assignment, e.g. `x = 1` -> empty.
  local tree = TB.tree({
    type = "module", range = {0,0,2,0}, children = {
      { type = "assignment", range = {0,0,0,5}, children = {
        { type = "identifier", range = {0,0,0,1}, text = "x" },
      }},
      { type = "function_definition", range = {1,0,2,0}, children = {
        { type = "identifier", range = {1,4,1,7}, text = "foo" },
      }},
    },
  })
  local uri = utils.path_to_uri("/project/test.py")
  local s = Scenario.new()
    :with_code("x = 1\ndef foo():\n    pass\n")
    :with_cursor(0, 0)
    :with_language("python")
    :with_tree(tree:root())
    :with_file("/project/test.py")
    :with_symbols(uri, {
      mocks.symbol("foo", utils.LSP_SYMBOL_FUNCTION, 1, 4, 2, 0),
    })
  local result = s:analyze()
  A.is_nil(result.current_function)
end

return M
