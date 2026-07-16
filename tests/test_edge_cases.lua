--- tests/test_edge_cases.lua — boundary scenarios.
---
--- Covers:
---   - Empty file -> empty JSON.
---   - Function name with special chars (_init_, foo?) -> extracted correctly.
---   - Multiple callers + multiple external_calls simultaneously.

local Scenario = require("scenario")
local mocks    = require("mocks")
local TB       = require("tree_builder")
local A        = require("assert")
local utils    = require("calltree.utils")

local M = {}

function M.test_empty_file()
  local tree = TB.tree({
    type = "program", range = {0,0,0,0}, children = {},
  })
  local uri = utils.path_to_uri("/project/test.lua")
  local s = Scenario.new()
    :with_code("")
    :with_cursor(0, 0)
    :with_language("lua")
    :with_tree(tree:root())
    :with_file("/project/test.lua")
    :with_cwd("/project")
    :with_symbols(uri, {})  -- no symbols -> precondition fails

  local result = s:analyze()
  A.is_nil(result.current_function)
  A.length(0, result.callers)
  A.length(0, result.external_calls)
end

function M.test_special_function_names()
  -- Lua: function _init_() ... end   (underscore-prefixed)
  -- Ruby: def foo?() ... end  (question-mark identifier)
  -- We test the Lua case first.
  local tree = TB.tree({
    type = "program", range = {0,0,2,0}, children = {
      { type = "function", range = {0,0,0,19}, children = {
        { type = "identifier", range = {0,9,0,15}, text = "_init_" },
        { type = "block", range = {0,16,0,19}, children = {} },
      }},
    },
  })
  local uri = utils.path_to_uri("/project/test.lua")
  local s = Scenario.new()
    :with_code("function _init_() end\n")
    :with_cursor(0, 9)
    :with_language("lua")
    :with_tree(tree:root())
    :with_file("/project/test.lua")
    :with_cwd("/project")
    :with_symbols(uri, {
      mocks.symbol("_init_", utils.LSP_SYMBOL_FUNCTION, 0, 9, 0, 15),
    })
    :with_definition(uri, { line = 0, character = 9 }, {
      mocks.loc(uri, 0, 9, 0, 15),
    })
    :with_references(uri, { line = 0, character = 9 }, {
      mocks.loc(uri, 0, 9, 0, 15),
    }, true)

  local result = s:analyze()
  A.is_not_nil(result.current_function)
  A.equal("_init_", result.current_function.name)
end

function M.test_ruby_question_mark_name()
  -- Ruby method name `foo?`. Different grammar: identifier type "method_name".
  local tree = TB.tree({
    type = "program", range = {0,0,2,0}, children = {
      { type = "method", range = {0,0,0,15}, children = {
        { type = "method_name", range = {0,4,0,8}, text = "foo?" },
        { type = "body_statement", range = {0,10,0,15}, children = {} },
      }},
    },
  })
  local uri = utils.path_to_uri("/project/test.rb")
  local s = Scenario.new()
    :with_code("def foo?\nend\n")
    :with_cursor(0, 4)
    :with_language("ruby")
    :with_tree(tree:root())
    :with_file("/project/test.rb")
    :with_cwd("/project")
    :with_symbols(uri, {
      mocks.symbol("foo?", utils.LSP_SYMBOL_METHOD, 0, 4, 0, 8),
    })
    :with_definition(uri, { line = 0, character = 4 }, {
      mocks.loc(uri, 0, 4, 0, 8),
    })
    :with_references(uri, { line = 0, character = 4 }, {
      mocks.loc(uri, 0, 4, 0, 8),
    }, true)

  local result = s:analyze()
  A.is_not_nil(result.current_function)
  A.equal("foo?", result.current_function.name)
end

function M.test_multiple_callers_and_external_calls()
  -- Layout:
  --   function foo()
  --       bar()
  --       baz()
  --   end
  -- Two callers (in different files) call foo.
  -- Two external calls (bar, baz) from within foo.
  local main_tree = TB.tree({
    type = "program", range = {0,0,5,0}, children = {
      { type = "function", range = {0,0,4,3}, children = {
        { type = "identifier", range = {0,9,0,12}, text = "foo" },
        { type = "block", range = {1,4,4,3}, children = {
          { type = "call", range = {1,4,1,9}, text = "bar" },
          { type = "call", range = {2,4,2,9}, text = "baz" },
        }},
      }},
    },
  })

  local caller1_source = "function c1()\n    foo()\nend\n"
  local caller1_tree = TB.tree({
    type = "program", range = {0,0,3,0}, children = {
      { type = "function", range = {0,0,2,3}, children = {
        { type = "identifier", range = {0,9,0,11}, text = "c1" },
        { type = "block", range = {1,4,2,3}, children = {
          { type = "call", range = {1,4,1,8}, text = "foo" },
        }},
      }},
    },
  })
  local caller2_source = "function c2()\n    foo()\nend\n"
  local caller2_tree = TB.tree({
    type = "program", range = {0,0,3,0}, children = {
      { type = "function", range = {0,0,2,3}, children = {
        { type = "identifier", range = {0,9,0,11}, text = "c2" },
        { type = "block", range = {1,4,2,3}, children = {
          { type = "call", range = {1,4,1,8}, text = "foo" },
        }},
      }},
    },
  })

  local uri = utils.path_to_uri("/project/main.lua")
  local c1_uri = utils.path_to_uri("/project/c1.lua")
  local c2_uri = utils.path_to_uri("/project/c2.lua")
  local bar_uri = utils.path_to_uri("/project/bar.lua")
  local baz_uri = utils.path_to_uri("/project/baz.lua")

  local s = Scenario.new()
    :with_code("function foo()\n    bar()\n    baz()\nend\n")
    :with_cursor(0, 9)
    :with_language("lua")
    :with_tree(main_tree:root())
    :with_file("/project/main.lua")
    :with_cwd("/project")
    :with_file_content("/project/c1.lua", caller1_source)
    :with_tree_for_source(caller1_source, caller1_tree:root())
    :with_file_content("/project/c2.lua", caller2_source)
    :with_tree_for_source(caller2_source, caller2_tree:root())
    :with_file_content("/project/bar.lua", "function bar() end\n")
    :with_file_content("/project/baz.lua", "function baz() end\n")
    :with_symbols(uri, {
      mocks.symbol("foo", utils.LSP_SYMBOL_FUNCTION, 0, 9, 0, 12),
    })
    :with_definition(uri, { line = 0, character = 9 }, {
      mocks.loc(uri, 0, 9, 0, 12),
    })
    :with_references(uri, { line = 0, character = 9 }, {
      mocks.loc(uri, 0, 9, 0, 12),
      mocks.loc(c1_uri, 1, 4, 1, 8),
      mocks.loc(c2_uri, 1, 4, 1, 8),
    }, true)
    -- bar definition: a function with body.
    :with_definition(uri, { line = 1, character = 4 }, {
      mocks.loc(bar_uri, 0, 9, 0, 12),
    })
    -- baz definition: a function with body.
    :with_definition(uri, { line = 2, character = 4 }, {
      mocks.loc(baz_uri, 0, 9, 0, 12),
    })

  -- Register bar and baz trees in the project.
  local bar_tree = TB.tree({
    type = "program", range = {0,0,1,0}, children = {
      { type = "function", range = {0,0,0,18}, children = {
        { type = "identifier", range = {0,9,0,12}, text = "bar" },
        { type = "block", range = {0,15,0,18}, children = {} },
      }},
    },
  })
  local baz_tree = TB.tree({
    type = "program", range = {0,0,1,0}, children = {
      { type = "function", range = {0,0,0,18}, children = {
        { type = "identifier", range = {0,9,0,12}, text = "baz" },
        { type = "block", range = {0,15,0,18}, children = {} },
      }},
    },
  })
  s:with_tree_for_source("function bar() end\n", bar_tree:root())
  s:with_tree_for_source("function baz() end\n", baz_tree:root())

  local result = s:analyze()
  A.is_not_nil(result.current_function)
  A.equal("foo", result.current_function.name)
  A.length(2, result.callers, "two callers expected")
  A.length(2, result.external_calls, "two external calls expected")

  -- Verify caller names.
  local caller_names = {}
  for _, c in ipairs(result.callers) do
    table.insert(caller_names, c.caller_function.name)
  end
  table.sort(caller_names)
  A.equal("c1", caller_names[1])
  A.equal("c2", caller_names[2])

  -- Verify external call function names.
  local ext_names = {}
  for _, ec in ipairs(result.external_calls) do
    table.insert(ext_names, ec.function_name)
    A.equal("resolved", ec.resolution_status)
  end
  table.sort(ext_names)
  A.equal("bar", ext_names[1])
  A.equal("baz", ext_names[2])
end

return M
