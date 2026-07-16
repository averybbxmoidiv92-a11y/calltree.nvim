--- tests/test_coordinates.lua — verify 0-based internal / 1-based output.
---
--- Constructs a known-position call and asserts that every line/character in
--- the output JSON has been converted from 0-based to 1-based.

local Scenario = require("scenario")
local mocks    = require("mocks")
local TB       = require("tree_builder")
local A        = require("assert")
local utils    = require("calltree.utils")

local M = {}

function M.test_all_coordinates_are_1based()
  -- Layout (0-based):
  --   line 0: function foo()
  --   line 1:     bar()           <- call to bar (external)
  --   line 2: end
  -- bar is defined elsewhere in the project at 0-based line 10.
  -- A second file calls foo at 0-based line 4 inside a function `caller` at
  -- 0-based lines 3..6.

  local main_tree = TB.tree({
    type = "program", range = {0,0,3,0}, children = {
      { type = "function", range = {0,0,2,3}, children = {
        { type = "identifier", range = {0,9,0,12}, text = "foo" },
        { type = "block", range = {1,4,2,3}, children = {
          { type = "call", range = {1,4,1,9}, text = "bar" },
        }},
      }},
    },
  })

  local bar_tree = TB.tree({
    type = "program", range = {0,0,12,0}, children = {
      { type = "function", range = {10,0,10,18}, children = {
        { type = "identifier", range = {10,9,10,12}, text = "bar" },
        { type = "block", range = {10,15,10,18}, children = {} },
      }},
    },
  })

  -- File that calls foo:
  local caller_source = "function caller()\n    foo()\nend\n"
  local caller_tree = TB.tree({
    type = "program", range = {0,0,3,0}, children = {
      { type = "function", range = {0,0,2,3}, children = {
        { type = "identifier", range = {0,9,0,15}, text = "caller" },
        { type = "block", range = {1,4,2,3}, children = {
          { type = "call", range = {1,4,1,8}, text = "foo" },
        }},
      }},
    },
  })

  local uri = utils.path_to_uri("/project/main.lua")
  local caller_uri = utils.path_to_uri("/project/caller.lua")
  local bar_uri = utils.path_to_uri("/project/bar.lua")

  local s = Scenario.new()
    :with_code("function foo()\n    bar()\nend\n")
    :with_cursor(0, 9)
    :with_language("lua")
    :with_tree(main_tree:root())
    :with_file("/project/main.lua")
    :with_cwd("/project")
    :with_file_content("/project/bar.lua", "function bar() end\n")
    :with_tree_for_source("function bar() end\n", bar_tree:root())
    :with_file_content("/project/caller.lua", caller_source)
    :with_tree_for_source(caller_source, caller_tree:root())
    :with_symbols(uri, {
      mocks.symbol("foo", utils.LSP_SYMBOL_FUNCTION, 0, 9, 0, 12),
    })
    :with_definition(uri, { line = 0, character = 9 }, {
      mocks.loc(uri, 0, 9, 0, 12),
    })
    :with_references(uri, { line = 0, character = 9 }, {
      mocks.loc(uri, 0, 9, 0, 12),
      mocks.loc(caller_uri, 1, 4, 1, 8),  -- 0-based call at (1,4)
    }, true)
    -- bar definition for the call at (1,4) in main.lua
    :with_definition(uri, { line = 1, character = 4 }, {
      mocks.loc(bar_uri, 10, 9, 10, 12),
    })

  local result = s:analyze()

  -- current_function range: 0-based [0..2] -> 1-based [1..3]
  A.same({1, 3}, result.current_function.range, "current_function range 1-based closed")

  -- callers: 1 caller at 0-based (1, 4) -> 1-based (2, 5)
  A.length(1, result.callers)
  local c = result.callers[1]
  A.equal(2, c.call_position.line, "caller call_position line 1-based")
  A.equal(5, c.call_position.character, "caller call_position char 1-based")
  -- caller_function range: 0-based [0..2] -> 1-based [1..3]
  A.same({1, 3}, c.caller_function.range)

  -- external_calls: call at 0-based (1, 4) -> 1-based (2, 5)
  -- bar's body 0-based [10..10] -> 1-based [11..11]
  A.length(1, result.external_calls)
  local ec = result.external_calls[1]
  A.equal(2, ec.call_position.line)
  A.equal(5, ec.call_position.character)
  A.same({11, 11}, ec.definition.function_body_range,
    "definition function_body_range should be 1-based")
end

return M
