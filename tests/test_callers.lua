--- tests/test_callers.lua — inbound calls (callers) test cases.
---
--- Covers:
---   - Top-level function caller: correct name + range extracted.
---   - Caller inside anonymous function (no name binding): name = nil, kept.
---   - Caller at global scope: discarded entirely.
---   - Recursive self-call: discarded.
---   - Definition and declaration sites differ (C-style): both excluded from refs.
---   - Caller body range via treesitter unavailable: range = nil.

local Scenario = require("scenario")
local mocks    = require("mocks")
local TB       = require("tree_builder")
local A        = require("assert")
local utils    = require("calltree.utils")

local M = {}

-------------------------------------------------------------------------------
-- Test 1: a single caller at top-level function.
--   def foo():           <- cursor here
--       pass
--   def bar():
--       foo()            <- caller: bar
-------------------------------------------------------------------------------
function M.test_top_level_caller()
  local tree = TB.tree({
    type = "module", range = {0,0,5,0}, children = {
      { type = "function_definition", range = {0,0,1,8}, children = {
        { type = "identifier", range = {0,4,0,7}, text = "foo" },
        { type = "block", range = {1,4,1,8}, children = {} },
      }},
      { type = "function_definition", range = {2,0,4,8}, children = {
        { type = "identifier", range = {2,4,2,7}, text = "bar" },
        { type = "block", range = {3,4,4,8}, children = {
          { type = "call", range = {3,4,3,8}, text = "foo" },
        }},
      }},
    },
  })
  local uri = utils.path_to_uri("/project/test.py")
  local s = Scenario.new()
    :with_code("def foo():\n    pass\ndef bar():\n    foo()\n")
    :with_cursor(0, 4)  -- on `foo` definition name
    :with_language("python")
    :with_tree(tree:root())
    :with_file("/project/test.py")
    :with_symbols(uri, {
      mocks.symbol("foo", utils.LSP_SYMBOL_FUNCTION, 0, 4, 1, 8),
      mocks.symbol("bar", utils.LSP_SYMBOL_FUNCTION, 2, 4, 4, 8),
    })
    :with_definition(uri, { line = 0, character = 4 }, {
      mocks.loc(uri, 0, 4, 0, 7),
    })
    :with_references(uri, { line = 0, character = 4 }, {
      mocks.loc(uri, 0, 4, 0, 7),  -- definition (will be excluded)
      mocks.loc(uri, 3, 4, 3, 8),  -- call from bar
    }, true)

  local result = s:analyze()
  A.is_not_nil(result.current_function)
  A.equal("foo", result.current_function.name)
  A.length(1, result.callers, "exactly one caller expected")

  local caller = result.callers[1]
  A.equal("/project/test.py", caller.file)
  A.equal(4, caller.call_position.line, "call_position line is 1-based (3+1)")
  A.equal(5, caller.call_position.character, "call_position char is 1-based (4+1)")
  A.equal("bar", caller.caller_function.name)
  A.same({3, 5}, caller.caller_function.range,
    "caller_function range is 1-based closed (2+1=3 .. 4+1=5)")
end

-------------------------------------------------------------------------------
-- Test 2: caller inside an anonymous function with no variable binding.
--   function foo() end
--   local handler = function() foo() end   -- caller is anonymous
-------------------------------------------------------------------------------
function M.test_anonymous_caller()
  local tree = TB.tree({
    type = "program", range = {0,0,3,0}, children = {
      { type = "function", range = {0,0,0,17}, children = {
        { type = "identifier", range = {0,9,0,12}, text = "foo" },
      }},
      { type = "local_declaration", range = {1,0,2,30}, children = {
        { type = "identifier", range = {1,6,1,13}, text = "handler" },
        { type = "function", range = {1,17,2,29}, children = {
          -- No name child -> anonymous
          { type = "block", range = {1,26,2,29}, children = {
            { type = "call", range = {2,4,2,8}, text = "foo" },
          }},
        }},
      }},
    },
  })
  local uri = utils.path_to_uri("/project/test.lua")
  local s = Scenario.new()
    :with_code("function foo() end\nlocal handler = function() foo() end\n")
    :with_cursor(0, 9)  -- on `foo` name in `function foo`
    :with_language("lua")
    :with_tree(tree:root())
    :with_file("/project/test.lua")
    :with_symbols(uri, {
      mocks.symbol("foo", utils.LSP_SYMBOL_FUNCTION, 0, 9, 0, 12),
    })
    :with_definition(uri, { line = 0, character = 9 }, {
      mocks.loc(uri, 0, 9, 0, 12),
    })
    :with_references(uri, { line = 0, character = 9 }, {
      mocks.loc(uri, 0, 9, 0, 12),
      mocks.loc(uri, 2, 4, 2, 8),
    }, true)

  local result = s:analyze()
  A.is_not_nil(result.current_function)
  A.equal("foo", result.current_function.name)
  A.length(1, result.callers, "anonymous caller should still be recorded")
  local caller = result.callers[1]
  A.is_nil(caller.caller_function.name, "anonymous caller name is nil")
  A.is_not_nil(caller.caller_function.range, "range still provided")
end

-------------------------------------------------------------------------------
-- Test 3: caller at global scope -> discarded.
--   function foo() end
--   foo()              <- global call, no enclosing function
-------------------------------------------------------------------------------
function M.test_caller_at_global_scope()
  local tree = TB.tree({
    type = "program", range = {0,0,2,0}, children = {
      { type = "function", range = {0,0,0,17}, children = {
        { type = "identifier", range = {0,9,0,12}, text = "foo" },
      }},
      { type = "call", range = {1,0,1,5}, text = "foo" },
    },
  })
  local uri = utils.path_to_uri("/project/test.lua")
  local s = Scenario.new()
    :with_code("function foo() end\nfoo()\n")
    :with_cursor(0, 9)
    :with_language("lua")
    :with_tree(tree:root())
    :with_file("/project/test.lua")
    :with_symbols(uri, {
      mocks.symbol("foo", utils.LSP_SYMBOL_FUNCTION, 0, 9, 0, 12),
    })
    :with_definition(uri, { line = 0, character = 9 }, {
      mocks.loc(uri, 0, 9, 0, 12),
    })
    :with_references(uri, { line = 0, character = 9 }, {
      mocks.loc(uri, 0, 9, 0, 12),
      mocks.loc(uri, 1, 0, 1, 5),
    }, true)

  local result = s:analyze()
  A.is_not_nil(result.current_function)
  A.length(0, result.callers, "global-scope caller must be discarded")
end

-------------------------------------------------------------------------------
-- Test 4: recursive self-call discarded.
--   function foo()
--       foo()          <- recursive call, must be excluded
--   end
-------------------------------------------------------------------------------
function M.test_recursive_self_call_discarded()
  local tree = TB.tree({
    type = "program", range = {0,0,3,0}, children = {
      { type = "function", range = {0,0,2,3}, children = {
        { type = "identifier", range = {0,9,0,12}, text = "foo" },
        { type = "block", range = {1,4,2,3}, children = {
          { type = "call", range = {1,4,1,8}, text = "foo" },
        }},
      }},
    },
  })
  local uri = utils.path_to_uri("/project/test.lua")
  local s = Scenario.new()
    :with_code("function foo()\n    foo()\nend\n")
    :with_cursor(0, 9)
    :with_language("lua")
    :with_tree(tree:root())
    :with_file("/project/test.lua")
    :with_symbols(uri, {
      mocks.symbol("foo", utils.LSP_SYMBOL_FUNCTION, 0, 9, 0, 12),
    })
    :with_definition(uri, { line = 0, character = 9 }, {
      mocks.loc(uri, 0, 9, 0, 12),
    })
    :with_references(uri, { line = 0, character = 9 }, {
      mocks.loc(uri, 0, 9, 0, 12),
      mocks.loc(uri, 1, 4, 1, 8),  -- recursive call inside foo itself
    }, true)

  local result = s:analyze()
  A.is_not_nil(result.current_function)
  A.length(0, result.callers, "recursive self-call must be excluded from callers")
end

-------------------------------------------------------------------------------
-- Test 5: definition and declaration locations differ (C-style).
--   void foo();           <- declaration at line 0
--   void foo() { }         <- definition at line 2
-- References that match either of these are excluded.
-------------------------------------------------------------------------------
function M.test_decl_vs_def_excluded()
  local tree = TB.tree({
    type = "translation_unit", range = {0,0,5,0}, children = {
      -- declaration
      { type = "declaration", range = {0,0,0,11}, children = {
        { type = "function_declarator", range = {0,5,0,10}, children = {
          { type = "identifier", range = {0,5,0,8}, text = "foo" },
        }},
      }},
      -- definition
      { type = "function_definition", range = {2,0,2,15}, children = {
        { type = "function_declarator", range = {2,5,2,10}, children = {
          { type = "identifier", range = {2,5,2,8}, text = "foo" },
        }},
        { type = "compound_statement", range = {2,11,2,15}, children = {} },
      }},
      -- caller
      { type = "function_definition", range = {4,0,4,14}, children = {
        { type = "function_declarator", range = {4,5,4,10}, children = {
          { type = "identifier", range = {4,5,4,8}, text = "bar" },
        }},
        { type = "compound_statement", range = {4,11,4,14}, children = {
          { type = "call_expression", range = {4,11,4,15}, text = "foo" },
        }},
      }},
    },
  })
  local uri = utils.path_to_uri("/project/test.c")
  local s = Scenario.new()
    :with_code("void foo();\nvoid foo() { }\nvoid bar() { foo(); }\n")
    :with_cursor(2, 5)  -- on the `foo` identifier in the DEFINITION
    :with_language("c")
    :with_tree(tree:root())
    :with_file("/project/test.c")
    :with_symbols(uri, {
      mocks.symbol("foo", utils.LSP_SYMBOL_FUNCTION, 0, 5, 0, 8),  -- declaration
      mocks.symbol("foo", utils.LSP_SYMBOL_FUNCTION, 2, 5, 2, 8),  -- definition
      mocks.symbol("bar", utils.LSP_SYMBOL_FUNCTION, 4, 5, 4, 8),
    })
    -- The LSP returns BOTH definition and declaration locations for a `definition` request.
    :with_definition(uri, { line = 2, character = 5 }, {
      mocks.loc(uri, 0, 5, 0, 8),  -- declaration
      mocks.loc(uri, 2, 5, 2, 8),  -- definition
    })
    :with_declaration(uri, { line = 2, character = 5 }, {
      mocks.loc(uri, 0, 5, 0, 8),
    })
    -- References include: declaration, definition, and the call from bar.
    :with_references(uri, { line = 2, character = 5 }, {
      mocks.loc(uri, 0, 5, 0, 8),  -- declaration (excluded)
      mocks.loc(uri, 2, 5, 2, 8),  -- definition (excluded)
      mocks.loc(uri, 4, 11, 4, 15),  -- call from bar
    }, true)

  local result = s:analyze()
  A.is_not_nil(result.current_function)
  A.length(1, result.callers, "only bar should be a caller; decl/def excluded")
  A.equal("bar", result.callers[1].caller_function.name)
end

-------------------------------------------------------------------------------
-- Test 6: caller body range via treesitter unavailable -> range = nil.
-- We simulate this by building a tree where the caller function node's
-- :range() method returns nil (e.g. an exotic treesitter implementation).
-- The analyzer should still record the caller but set caller_function.range to nil.
-------------------------------------------------------------------------------
function M.test_caller_range_unavailable()
  -- Build a custom Node class whose :range() returns nil.
  local function make_no_range_node(t, parent)
    local n = setmetatable({}, {
      __index = function(_, k)
        if k == "type" then return function() return t end end
        if k == "range" then return function() return nil end end
        if k == "parent" then return function() return parent end end
        if k == "named_child_count" then return function() return 0 end end
        if k == "named_child" then return function(_, _) return nil end end
        if k == "text" then return function() return "" end end
        if k == "has_error" then return false end
        return nil
      end,
    })
    return n
  end

  -- Build foo_node properly using Node.new with a child Node (not a spec table).
  local Node = mocks.Node
  local foo_identifier = Node.new({
    type = "identifier", range = {0,9,0,12}, text = "foo",
  })
  local foo_node = Node.new({
    type = "function", range = {0,0,0,17},
    children = { foo_identifier },
  })

  -- Caller is a custom node with no usable range.
  local caller_node = make_no_range_node("function", nil)

  -- Custom root that returns caller_node for position (1,4).
  local custom_root = setmetatable({
    _type = "program",
    _children = { foo_node, caller_node },
    has_error = false,
  }, {
    __index = function(t, k)
      if k == "type" then return function() return "program" end end
      if k == "range" then return function() return 0, 0, 5, 0 end end
      if k == "parent" then return function() return nil end end
      if k == "named_child_count" then return function() return 2 end end
      if k == "named_child" then
        return function(_, i)
          if i == 0 then return t._children[1] end
          if i == 1 then return t._children[2] end
          return nil
        end
      end
      if k == "text" then return function() return "" end end
      if k == "descendant_for_range" then
        return function(_, sl, sc, el, ec)
          if sl == 1 and sc >= 4 and el <= 1 and ec <= 8 then
            return caller_node
          end
          if sl == 0 then
            return foo_node:descendant_for_range(sl, sc, el, ec)
          end
          return nil
        end
      end
      return nil
    end,
  })
  foo_node._parent = custom_root
  caller_node._parent = custom_root

  local uri = utils.path_to_uri("/project/test.lua")
  local s = Scenario.new()
    :with_code("function foo() end\n???\n")
    :with_cursor(0, 9)
    :with_language("lua")
    :with_tree(custom_root)
    :with_file("/project/test.lua")
    :with_symbols(uri, {
      mocks.symbol("foo", utils.LSP_SYMBOL_FUNCTION, 0, 9, 0, 12),
    })
    :with_definition(uri, { line = 0, character = 9 }, {
      mocks.loc(uri, 0, 9, 0, 12),
    })
    :with_references(uri, { line = 0, character = 9 }, {
      mocks.loc(uri, 0, 9, 0, 12),
      mocks.loc(uri, 1, 4, 1, 8),
    }, true)

  local result = s:analyze()
  A.is_not_nil(result.current_function, "current_function must still be detected")
  A.length(1, result.callers, "caller should still be recorded despite nil range")
  local c = result.callers[1]
  A.is_nil(c.caller_function.range, "range should be nil when treesitter range unavailable")
end

return M
