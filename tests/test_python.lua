--- tests/test_python.lua — Python language adapter unit tests.
---
--- 10 scenarios covering:
---   1. Simple function: outbound external call resolution.
---   2. Simple function: inbound caller lookup.
---   3. Class method: calling another method of the same class.
---   4. Nested function: external call filtered (in-scope).
---   5. Nested function: inbound caller lookup.
---   6. Lambda callee: discarded (no body).
---   7. Decorator: inbound caller is global_scope (filtered).
---   8. Cross-file external call: resolving helper in another module.
---   9. Self-recursive function: filtered as self_recursive.
---  10. Syntax error: graceful degradation (preconditions_failed).
---
--- All tests use the existing mock infrastructure (mocks.lua /
--- scenario.lua / tree_builder.lua) — no real Python treesitter parser
--- is required. Mock trees use Python tree-sitter node type names:
---   program, function_definition, block, identifier, call, attribute,
---   lambda, decorator, etc.

local Scenario = require("scenario")
local mocks    = require("mocks")
local TB       = require("tree_builder")
local A        = require("assert")
local utils    = require("calltree.utils")

local M = {}

-- LSP SymbolKind constants (from utils.constants).
local LSP_FUNCTION = utils.LSP_SYMBOL_FUNCTION  -- 12
local LSP_METHOD   = utils.LSP_SYMBOL_METHOD    -- 6

--------------------------------------------------------------------------------
-- Test 1: Simple function — outbound external call resolution.
--
-- Code:
--   def bar():
--       pass
--   def foo():
--       bar()
--
-- Cursor on `foo` definition name (line 2, col 4).
-- Expect: external_calls has 1 entry for `bar`, resolved, with body range.
--------------------------------------------------------------------------------
function M.test_python_external_call_simple_function()
  -- Python AST (simplified, ranges are 0-based {sl,sc,el,ec}):
  -- program [0,0,4,0]
  --   function_definition "bar" [0,0,1,8]
  --     identifier "bar" [0,4,0,7]
  --     block [0,8,1,8]
  --       pass_statement [1,4,1,8]
  --   function_definition "foo" [2,0,3,8]
  --     identifier "foo" [2,4,2,7]
  --     block [2,8,3,8]
  --       call [3,4,3,8]
  --         identifier "bar" [3,4,3,7]
  --         argument_list [3,7,3,8]
  local tree = TB.tree({
    type = "module", range = {0,0,4,0}, children = {
      { type = "function_definition", range = {0,0,1,8}, children = {
        { type = "identifier", range = {0,4,0,7}, text = "bar" },
        { type = "block", range = {0,8,1,8}, children = {
          { type = "pass_statement", range = {1,4,1,8}, text = "pass" },
        }},
      }},
      { type = "function_definition", range = {2,0,3,8}, children = {
        { type = "identifier", range = {2,4,2,7}, text = "foo" },
        { type = "block", range = {2,8,3,8}, children = {
          { type = "call", range = {3,4,3,9}, children = {
            { type = "identifier", range = {3,4,3,7}, text = "bar" },
            { type = "argument_list", range = {3,7,3,9}, text = "()" },
          }},
        }},
      }},
    },
  })

  local uri = utils.path_to_uri("/project/test.py")
  local s = Scenario.new()
    :with_code("def bar():\n    pass\ndef foo():\n    bar()\n")
    :with_cursor(2, 4)  -- on `foo` name
    :with_language("python")
    :with_tree(tree:root())
    :with_file("/project/test.py")
    :with_cwd("/project")
    :with_symbols(uri, {
      mocks.symbol("bar", LSP_FUNCTION, 0, 4, 1, 8),
      mocks.symbol("foo", LSP_FUNCTION, 2, 4, 3, 8),
    })
    -- LSP definition for `foo` cursor position → itself.
    :with_definition(uri, { line = 2, character = 4 }, {
      mocks.loc(uri, 2, 4, 3, 8),
    })
    -- LSP definition for the call `bar()` at line 3, col 4 → bar's def.
    :with_definition(uri, { line = 3, character = 4 }, {
      mocks.loc(uri, 0, 4, 1, 8),
    })

  local result = s:analyze()
  A.is_not_nil(result.current_function, "current_function should be detected")
  A.equal("foo", result.current_function.name)
  A.length(1, result.external_calls, "exactly one external call (bar)")
  local ec = result.external_calls[1]
  A.equal("bar", ec.function_name)
  A.equal("resolved", ec.resolution_status)
  A.is_not_nil(ec.definition, "definition must be present")
  A.equal("/project/test.py", ec.definition.file)
  A.is_not_nil(ec.definition.function_body_range,
    "function_body_range must be present (bar has a body)")
end

--------------------------------------------------------------------------------
-- Test 2: Simple function — inbound caller lookup.
--
-- Same code as Test 1, cursor on `bar` definition name (line 0, col 4).
-- Expect: callers has 1 entry — foo, call_position 1-based {4, 5}.
--------------------------------------------------------------------------------
function M.test_python_inbound_callers_simple_function()
  local tree = TB.tree({
    type = "module", range = {0,0,4,0}, children = {
      { type = "function_definition", range = {0,0,1,8}, children = {
        { type = "identifier", range = {0,4,0,7}, text = "bar" },
        { type = "block", range = {0,8,1,8}, children = {
          { type = "pass_statement", range = {1,4,1,8}, text = "pass" },
        }},
      }},
      { type = "function_definition", range = {2,0,3,8}, children = {
        { type = "identifier", range = {2,4,2,7}, text = "foo" },
        { type = "block", range = {2,8,3,8}, children = {
          { type = "call", range = {3,4,3,9}, children = {
            { type = "identifier", range = {3,4,3,7}, text = "bar" },
            { type = "argument_list", range = {3,7,3,9}, text = "()" },
          }},
        }},
      }},
    },
  })

  local uri = utils.path_to_uri("/project/test.py")
  local s = Scenario.new()
    :with_code("def bar():\n    pass\ndef foo():\n    bar()\n")
    :with_cursor(0, 4)  -- on `bar` name
    :with_language("python")
    :with_tree(tree:root())
    :with_file("/project/test.py")
    :with_cwd("/project")
    :with_symbols(uri, {
      mocks.symbol("bar", LSP_FUNCTION, 0, 4, 1, 8),
      mocks.symbol("foo", LSP_FUNCTION, 2, 4, 3, 8),
    })
    -- LSP definition for `bar` cursor → itself.
    :with_definition(uri, { line = 0, character = 4 }, {
      mocks.loc(uri, 0, 4, 0, 7),
    })
    -- references(includeDecl=true) returns: self def + foo's call site.
    :with_references(uri, { line = 0, character = 4 }, {
      mocks.loc(uri, 0, 4, 0, 7),     -- self def (excluded)
      mocks.loc(uri, 3, 4, 3, 7),     -- call inside foo
    }, true)

  local result = s:analyze()
  A.is_not_nil(result.current_function)
  A.equal("bar", result.current_function.name)
  A.length(1, result.callers, "exactly one caller (foo)")
  local caller = result.callers[1]
  A.equal("foo", caller.caller_function.name)
  -- call_position is 1-based; original 0-based was (3, 4).
  A.equal(4, caller.call_position.line, "call line 0->1 +1 = 4")
  A.equal(5, caller.call_position.character, "call col 4+1 = 5")
end

--------------------------------------------------------------------------------
-- Test 3: Class method — calling another method of the same class.
--
-- Code:
--   class MyClass:
--       def method(self):
--           self.helper()
--       def helper(self):
--           pass
--
-- Cursor on `method` definition name (line 1, col 8).
-- Expect: external_calls has 1 entry for `self.helper`.
--------------------------------------------------------------------------------
function M.test_python_method_external_call()
  -- Python AST (simplified):
  -- module
  --   class_definition "MyClass" [0,0,4,12]
  --     identifier "MyClass" [0,6,0,13]
  --     block [0,14,4,12]
  --       function_definition "method" [1,4,2,20]
  --         identifier "method" [1,8,1,14]
  --         block [1,22,2,20]
  --           call [2,8,2,20]
  --             attribute "self.helper" [2,8,2,18]
  --               identifier "self" [2,8,2,12]
  --               identifier "helper" [2,13,2,19]
  --             argument_list [2,19,2,20]
  --       function_definition "helper" [3,4,4,12]
  --         identifier "helper" [3,8,3,14]
  --         block [3,22,4,12]
  --           pass_statement [4,8,4,12]
  local tree = TB.tree({
    type = "module", range = {0,0,5,0}, children = {
      { type = "class_definition", range = {0,0,4,12}, children = {
        { type = "identifier", range = {0,6,0,13}, text = "MyClass" },
        { type = "block", range = {0,14,4,12}, children = {
          { type = "function_definition", range = {1,4,2,20}, children = {
            { type = "identifier", range = {1,8,1,14}, text = "method" },
            { type = "block", range = {1,22,2,20}, children = {
              { type = "call", range = {2,8,2,21}, children = {
                { type = "attribute", range = {2,8,2,18}, text = "self.helper", children = {
                  { type = "identifier", range = {2,8,2,12}, text = "self" },
                  { type = "identifier", range = {2,13,2,19}, text = "helper" },
                }},
                { type = "argument_list", range = {2,19,2,21}, text = "()" },
              }},
            }},
          }},
          { type = "function_definition", range = {3,4,4,12}, children = {
            { type = "identifier", range = {3,8,3,14}, text = "helper" },
            { type = "block", range = {3,22,4,12}, children = {
              { type = "pass_statement", range = {4,8,4,12}, text = "pass" },
            }},
          }},
        }},
      }},
    },
  })

  local uri = utils.path_to_uri("/project/test.py")
  local s = Scenario.new()
    :with_code("class MyClass:\n    def method(self):\n        self.helper()\n    def helper(self):\n        pass\n")
    :with_cursor(1, 8)  -- on `method` name
    :with_language("python")
    :with_tree(tree:root())
    :with_file("/project/test.py")
    :with_cwd("/project")
    :with_symbols(uri, {
      mocks.symbol("MyClass", 5, 0, 0, 4, 12, {
        mocks.symbol("method", LSP_METHOD, 1, 8, 2, 20),
        mocks.symbol("helper", LSP_METHOD, 3, 8, 4, 12),
      }),
    })
    :with_definition(uri, { line = 1, character = 8 }, {
      mocks.loc(uri, 1, 8, 2, 20),
    })
    -- LSP definition for the call `self.helper()`. The plugin queries at
    -- the callee_node's start position. callee_node is the `attribute`
    -- node `self.helper` whose range starts at (2, 8).
    :with_definition(uri, { line = 2, character = 8 }, {
      mocks.loc(uri, 3, 8, 4, 12),
    })

  local result = s:analyze()
  A.is_not_nil(result.current_function)
  A.equal("method", result.current_function.name)
  A.length(1, result.external_calls, "exactly one external call (self.helper)")
  local ec = result.external_calls[1]
  -- callee_text should be "self.helper" (the attribute node's text).
  A.equal("self.helper", ec.function_name)
  A.equal("resolved", ec.resolution_status)
  A.is_not_nil(ec.definition)
  A.equal("/project/test.py", ec.definition.file)
  A.is_not_nil(ec.definition.function_body_range,
    "function_body_range present (helper has a body)")
end

--------------------------------------------------------------------------------
-- Test 4: Nested function — external call filtered (in-scope).
--
-- Code:
--   def outer():
--       def inner():
--           print("inner")
--       inner()
--
-- Cursor on `outer` name (line 0, col 4).
-- LSP definition for `inner()` call → inner's def (line 1, col 8) which is
-- INSIDE outer's range → _check_in_scope discards.
-- Expect: external_calls is empty.
--------------------------------------------------------------------------------
function M.test_python_nested_function_external_call_filtered()
  local tree = TB.tree({
    type = "module", range = {0,0,4,0}, children = {
      { type = "function_definition", range = {0,0,3,12}, children = {
        { type = "identifier", range = {0,4,0,9}, text = "outer" },
        { type = "block", range = {0,11,3,12}, children = {
          { type = "function_definition", range = {1,4,2,21}, children = {
            { type = "identifier", range = {1,8,1,13}, text = "inner" },
            { type = "block", range = {1,16,2,21}, children = {
              { type = "call", range = {2,8,2,21}, children = {
                { type = "identifier", range = {2,8,2,13}, text = "print" },
                { type = "argument_list", range = {2,13,2,21}, text = "(\"inner\")" },
              }},
            }},
          }},
          { type = "call", range = {3,4,3,11}, children = {
            { type = "identifier", range = {3,4,3,9}, text = "inner" },
            { type = "argument_list", range = {3,9,3,11}, text = "()" },
          }},
        }},
      }},
    },
  })

  local uri = utils.path_to_uri("/project/test.py")
  local s = Scenario.new()
    :with_code("def outer():\n    def inner():\n        print(\"inner\")\n    inner()\n")
    :with_cursor(0, 4)  -- on `outer` name
    :with_language("python")
    :with_tree(tree:root())
    :with_file("/project/test.py")
    :with_cwd("/project")
    :with_symbols(uri, {
      mocks.symbol("outer", LSP_FUNCTION, 0, 4, 3, 12, {
        mocks.symbol("inner", LSP_FUNCTION, 1, 8, 2, 21),
      }),
    })
    :with_definition(uri, { line = 0, character = 4 }, {
      mocks.loc(uri, 0, 4, 3, 12),
    })
    -- LSP definition for `inner()` call at line 3, col 4 → inner's def
    -- (line 1, col 4) which is INSIDE outer's range [0,0,3,12].
    :with_definition(uri, { line = 3, character = 4 }, {
      mocks.loc(uri, 1, 4, 2, 21),
    })

  local result = s:analyze()
  A.is_not_nil(result.current_function)
  A.equal("outer", result.current_function.name)
  -- inner's def is inside outer's range → in-scope → discarded.
  A.length(0, result.external_calls,
    "external_calls must be empty (inner is in-scope)")
end

--------------------------------------------------------------------------------
-- Test 5: Nested function — inbound caller lookup.
--
-- Same code as Test 4, cursor on `inner` definition name (line 1, col 8).
-- Expect: callers has 1 entry — outer.
--------------------------------------------------------------------------------
function M.test_python_inbound_callers_nested_function()
  local tree = TB.tree({
    type = "module", range = {0,0,4,0}, children = {
      { type = "function_definition", range = {0,0,3,12}, children = {
        { type = "identifier", range = {0,4,0,9}, text = "outer" },
        { type = "block", range = {0,11,3,12}, children = {
          { type = "function_definition", range = {1,4,2,21}, children = {
            { type = "identifier", range = {1,8,1,13}, text = "inner" },
            { type = "block", range = {1,16,2,21}, children = {
              { type = "call", range = {2,8,2,21}, children = {
                { type = "identifier", range = {2,8,2,13}, text = "print" },
                { type = "argument_list", range = {2,13,2,21}, text = "(\"inner\")" },
              }},
            }},
          }},
          { type = "call", range = {3,4,3,11}, children = {
            { type = "identifier", range = {3,4,3,9}, text = "inner" },
            { type = "argument_list", range = {3,9,3,11}, text = "()" },
          }},
        }},
      }},
    },
  })

  local uri = utils.path_to_uri("/project/test.py")
  local s = Scenario.new()
    :with_code("def outer():\n    def inner():\n        print(\"inner\")\n    inner()\n")
    :with_cursor(1, 8)  -- on `inner` name (the def, not the call)
    :with_language("python")
    :with_tree(tree:root())
    :with_file("/project/test.py")
    :with_cwd("/project")
    :with_symbols(uri, {
      mocks.symbol("outer", LSP_FUNCTION, 0, 4, 3, 12, {
        mocks.symbol("inner", LSP_FUNCTION, 1, 8, 2, 21),
      }),
    })
    :with_definition(uri, { line = 1, character = 8 }, {
      mocks.loc(uri, 1, 4, 2, 21),
    })
    -- references(includeDecl=true): self def + outer's call site.
    :with_references(uri, { line = 1, character = 8 }, {
      mocks.loc(uri, 1, 4, 2, 21),     -- self def (excluded)
      mocks.loc(uri, 3, 4, 3, 9),      -- call inside outer
    }, true)

  local result = s:analyze()
  A.is_not_nil(result.current_function)
  A.equal("inner", result.current_function.name)
  A.length(1, result.callers, "exactly one caller (outer)")
  local caller = result.callers[1]
  A.equal("outer", caller.caller_function.name)
end

--------------------------------------------------------------------------------
-- Test 6: Lambda callee — discarded (no body).
--
-- Code:
--   f = lambda x: x + 1     # module-level assignment to a lambda
--   def foo():
--       f(5)
--
-- Cursor on `foo` name (line 1, col 4).
-- LSP definition for `f(5)` call returns the lambda assignment location
-- at line 0, col 0 (the `assignment` node). definition_body.check:
--   - def_node is `assignment` (in DECLARATION_NODE_TYPES)
--   - _scan_rhs_for_function looks for FUNCTION_NODE_TYPES children in
--     the RHS; `lambda` is NOT in FUNCTION_NODE_TYPES → returns nil
--   - has_body = false → discarded_no_body
-- The lambda lives at module scope (outside foo), so it does NOT trigger
-- the in-scope filter — the call reaches the body check.
-- Expect: external_calls is empty; debug records discarded_no_body.
--------------------------------------------------------------------------------
function M.test_python_lambda_callee_discarded()
  local tree = TB.tree({
    type = "module", range = {0,0,3,0}, children = {
      -- f = lambda x: x + 1   (module-level)
      { type = "assignment", range = {0,0,0,19}, children = {
        { type = "identifier", range = {0,0,0,1}, text = "f" },
        { type = "lambda", range = {0,4,0,19}, text = "lambda x: x + 1", children = {
          { type = "identifier", range = {0,11,0,12}, text = "x" },
        }},
      }},
      { type = "function_definition", range = {1,0,2,7}, children = {
        { type = "identifier", range = {1,4,1,7}, text = "foo" },
        { type = "block", range = {1,8,2,7}, children = {
          { type = "call", range = {2,4,2,8}, children = {
            { type = "identifier", range = {2,4,2,5}, text = "f" },
            { type = "argument_list", range = {2,5,2,8}, text = "(5)" },
          }},
        }},
      }},
    },
  })

  local uri = utils.path_to_uri("/project/test.py")
  local s = Scenario.new()
    :with_code("f = lambda x: x + 1\ndef foo():\n    f(5)\n")
    :with_cursor(1, 4)  -- on `foo` name
    :with_language("python")
    :with_tree(tree:root())
    :with_file("/project/test.py")
    :with_cwd("/project")
    :with_symbols(uri, {
      mocks.symbol("foo", LSP_FUNCTION, 1, 4, 2, 7),
    })
    :with_definition(uri, { line = 1, character = 4 }, {
      mocks.loc(uri, 1, 4, 2, 7),
    })
    -- LSP definition for `f(5)` call at line 2, col 4 → assignment at line 0.
    -- The assignment node is NOT a function_definition; RHS scan for
    -- FUNCTION_NODE_TYPES children finds only `lambda` (not in the set),
    -- so has_body=false.
    :with_definition(uri, { line = 2, character = 4 }, {
      mocks.loc(uri, 0, 0, 0, 19),
    })

  local result = s:analyze()
  A.is_not_nil(result.current_function)
  A.equal("foo", result.current_function.name)
  -- Lambda RHS is not a function_definition → discarded_no_body.
  A.length(0, result.external_calls,
    "external_calls must be empty (lambda callee has no body)")
  -- Verify the discard reason in debug decisions.
  -- Previously this was wrapped in `if result.debug and ... then`, which
  -- silently passed the test when debug was nil (a brittle guard that
  -- masked real regressions). Now we assert debug is present first, so
  -- a future change that accidentally disables debug collection surfaces
  -- as a test failure here rather than a silent pass.
  A.is_not_nil(result.debug, "debug must be present (default debug=true)")
  A.is_not_nil(result.debug.external_call_decisions,
    "debug.external_call_decisions must be present")
  local found_no_body = false
  for _, d in ipairs(result.debug.external_call_decisions) do
    if d.outcome == "discarded_no_body" then
      found_no_body = true
      break
    end
  end
  A.truthy(found_no_body,
    "debug should record an external_call_decision with outcome=discarded_no_body")
end

--------------------------------------------------------------------------------
-- Test 7: Decorator — inbound caller is global_scope (filtered).
--
-- Code:
--   def decorator(func):
--       return func
--   @decorator
--   def foo():
--       pass
--
-- Cursor on `decorator` name (line 0, col 4).
-- references returns the @decorator application at line 2, col 1 — which
-- is at module scope (not inside any function) → global_scope → filtered.
-- Expect: callers is empty.
--------------------------------------------------------------------------------
function M.test_python_decorator_inbound_global_scope()
  local tree = TB.tree({
    type = "module", range = {0,0,5,0}, children = {
      { type = "function_definition", range = {0,0,1,15}, children = {
        { type = "identifier", range = {0,4,0,13}, text = "decorator" },
        { type = "block", range = {0,15,1,15}, children = {
          { type = "return_statement", range = {1,4,1,15}, text = "return func" },
        }},
      }},
      -- @decorator application (decorated_definition).
      { type = "decorated_definition", range = {2,0,4,8}, children = {
        { type = "decorator", range = {2,0,2,10}, children = {
          { type = "call", range = {2,1,2,10}, children = {
            { type = "identifier", range = {2,1,2,10}, text = "decorator" },
          }},
        }},
        { type = "function_definition", range = {3,0,4,8}, children = {
          { type = "identifier", range = {3,4,3,7}, text = "foo" },
          { type = "block", range = {3,8,4,8}, children = {
            { type = "pass_statement", range = {4,4,4,8}, text = "pass" },
          }},
        }},
      }},
    },
  })

  local uri = utils.path_to_uri("/project/test.py")
  local s = Scenario.new()
    :with_code("def decorator(func):\n    return func\n@decorator\ndef foo():\n    pass\n")
    :with_cursor(0, 4)  -- on `decorator` name (the def)
    :with_language("python")
    :with_tree(tree:root())
    :with_file("/project/test.py")
    :with_cwd("/project")
    :with_symbols(uri, {
      mocks.symbol("decorator", LSP_FUNCTION, 0, 4, 1, 15),
      mocks.symbol("foo", LSP_FUNCTION, 3, 4, 4, 8),
    })
    :with_definition(uri, { line = 0, character = 4 }, {
      mocks.loc(uri, 0, 4, 1, 15),
    })
    -- references returns: self def + @decorator application at line 2, col 1.
    -- The @decorator position is NOT inside any function_definition →
    -- find_top_level_calling_function returns nil → global_scope.
    :with_references(uri, { line = 0, character = 4 }, {
      mocks.loc(uri, 0, 4, 1, 15),    -- self def (excluded)
      mocks.loc(uri, 2, 1, 2, 10),    -- @decorator (global scope)
    }, true)

  local result = s:analyze()
  A.is_not_nil(result.current_function)
  A.equal("decorator", result.current_function.name)
  A.length(0, result.callers,
    "callers must be empty (@decorator is at global scope)")
end

--------------------------------------------------------------------------------
-- Test 8: Cross-file external call — resolving helper in another module.
--
-- main.py:
--   import utils
--   def foo():
--       utils.helper()
-- utils.py:
--   def helper():
--       pass
--
-- Cursor on `foo` name (line 1, col 4).
-- LSP definition for `utils.helper()` call → utils.py helper def.
-- Expect: external_calls has 1 entry, function_name="utils.helper",
--         definition.file="/project/utils.py", is_stdlib=false.
--------------------------------------------------------------------------------
function M.test_python_cross_file_external_call()
  local tree = TB.tree({
    type = "module", range = {0,0,3,0}, children = {
      { type = "import_statement", range = {0,0,0,11}, text = "import utils" },
      { type = "function_definition", range = {1,0,2,18}, children = {
        { type = "identifier", range = {1,4,1,7}, text = "foo" },
        { type = "block", range = {1,8,2,18}, children = {
          { type = "call", range = {2,4,2,18}, children = {
            { type = "attribute", range = {2,4,2,16}, text = "utils.helper", children = {
              { type = "identifier", range = {2,4,2,9}, text = "utils" },
              { type = "identifier", range = {2,10,2,16}, text = "helper" },
            }},
            { type = "argument_list", range = {2,16,2,18}, text = "()" },
          }},
        }},
      }},
    },
  })
  -- utils.py tree (used to extract helper's body range).
  local utils_tree = TB.tree({
    type = "module", range = {0,0,2,0}, children = {
      { type = "function_definition", range = {0,0,1,8}, children = {
        { type = "identifier", range = {0,4,0,10}, text = "helper" },
        { type = "block", range = {0,11,1,8}, children = {
          { type = "pass_statement", range = {1,4,1,8}, text = "pass" },
        }},
      }},
    },
  })

  local main_uri = utils.path_to_uri("/project/main.py")
  local utils_uri = utils.path_to_uri("/project/utils.py")
  local utils_source = "def helper():\n    pass\n"
  local s = Scenario.new()
    :with_code("import utils\ndef foo():\n    utils.helper()\n")
    :with_cursor(1, 4)  -- on `foo` name
    :with_language("python")
    :with_tree(tree:root())
    :with_file("/project/main.py")
    :with_cwd("/project")
    :with_file_content("/project/utils.py", utils_source)
    :with_tree_for_source(utils_source, utils_tree:root())
    :with_symbols(main_uri, {
      mocks.symbol("foo", LSP_FUNCTION, 1, 4, 2, 18),
    })
    :with_definition(main_uri, { line = 1, character = 4 }, {
      mocks.loc(main_uri, 1, 4, 2, 18),
    })
    -- LSP definition for `utils.helper()` call. The plugin queries at
    -- the callee_node's start position. callee_node is the `attribute`
    -- node `utils.helper` whose range starts at (2, 4).
    :with_definition(main_uri, { line = 2, character = 4 }, {
      mocks.loc(utils_uri, 0, 4, 1, 8),
    })

  local result = s:analyze()
  A.is_not_nil(result.current_function)
  A.equal("foo", result.current_function.name)
  A.length(1, result.external_calls, "exactly one external call (utils.helper)")
  local ec = result.external_calls[1]
  A.equal("utils.helper", ec.function_name)
  A.equal("resolved", ec.resolution_status)
  A.is_not_nil(ec.definition)
  A.equal("/project/utils.py", ec.definition.file)
  A.is_not_nil(ec.definition.function_body_range,
    "function_body_range must be present (helper has a body)")
  A.equal(false, ec.is_stdlib, "is_stdlib must be false (in-project path)")
end

--------------------------------------------------------------------------------
-- Test 9: Self-recursive function — filtered as self_recursive.
--
-- Code:
--   def factorial(n):
--       if n <= 1: return 1
--       return n * factorial(n-1)
--
-- Cursor on `factorial` name (line 0, col 4).
-- references returns: self def + recursive call at line 2, col 18.
-- The recursive call's enclosing function is `factorial` itself →
-- _check_self_recursive filters it.
-- Expect: callers is empty.
--------------------------------------------------------------------------------
function M.test_python_self_recursive_filter()
  local tree = TB.tree({
    type = "module", range = {0,0,3,0}, children = {
      { type = "function_definition", range = {0,0,2,28}, children = {
        { type = "identifier", range = {0,4,0,13}, text = "factorial" },
        { type = "block", range = {0,15,2,28}, children = {
          { type = "if_statement", range = {1,4,1,25}, text = "if n <= 1: return 1" },
          { type = "return_statement", range = {2,4,2,28}, children = {
            { type = "call", range = {2,12,2,28}, children = {
              { type = "identifier", range = {2,12,2,21}, text = "factorial" },
              { type = "argument_list", range = {2,21,2,28}, text = "(n-1)" },
            }},
          }},
        }},
      }},
    },
  })

  local uri = utils.path_to_uri("/project/test.py")
  local s = Scenario.new()
    :with_code("def factorial(n):\n    if n <= 1: return 1\n    return n * factorial(n-1)\n")
    :with_cursor(0, 4)  -- on `factorial` name (the def)
    :with_language("python")
    :with_tree(tree:root())
    :with_file("/project/test.py")
    :with_cwd("/project")
    :with_symbols(uri, {
      mocks.symbol("factorial", LSP_FUNCTION, 0, 4, 2, 28),
    })
    :with_definition(uri, { line = 0, character = 4 }, {
      mocks.loc(uri, 0, 4, 2, 28),
    })
    -- references: self def + recursive call.
    :with_references(uri, { line = 0, character = 4 }, {
      mocks.loc(uri, 0, 4, 2, 28),     -- self def (excluded)
      mocks.loc(uri, 2, 12, 2, 21),    -- recursive call inside factorial
    }, true)

  local result = s:analyze()
  A.is_not_nil(result.current_function)
  A.equal("factorial", result.current_function.name)
  A.length(0, result.callers,
    "callers must be empty (self-recursive call is filtered)")
  -- Verify the filter reason in debug decisions.
  -- (See the equivalent fix above for the discarded_no_body test: we now
  -- assert debug presence first rather than wrapping in a brittle
  -- `if result.debug then` that silently passes when debug is nil.)
  A.is_not_nil(result.debug, "debug must be present (default debug=true)")
  A.is_not_nil(result.debug.caller_decisions,
    "debug.caller_decisions must be present")
  local found_self_rec = false
  for _, d in ipairs(result.debug.caller_decisions) do
    if d.outcome == "self_recursive" then
      found_self_rec = true
      break
    end
  end
  A.truthy(found_self_rec,
    "debug should record a caller_decision with outcome=self_recursive")
end

--------------------------------------------------------------------------------
-- Test 10: Syntax error — graceful degradation (preconditions_failed).
--
-- Code (missing colon after `def foo()`):
--   def foo()
--       pass
--
-- Cursor on `foo` name (line 0, col 4).
-- Treesitter parse marks tree.has_error = true → preconditions.check
-- returns false → completion_reason = "preconditions_failed".
-- Expect: current_function is nil, callers/external_calls empty.
--------------------------------------------------------------------------------
function M.test_python_syntax_error_graceful()
  -- Build a tree with has_error=true at the root.
  local tree = TB.tree({
    type = "module", range = {0,0,2,0}, has_error = true, children = {
      { type = "function_definition", range = {0,0,1,8}, children = {
        { type = "identifier", range = {0,4,0,7}, text = "foo" },
        { type = "block", range = {0,8,1,8}, children = {
          { type = "pass_statement", range = {1,4,1,8}, text = "pass" },
        }},
      }},
    },
  }, true)  -- has_error=true passed to Tree.new

  local uri = utils.path_to_uri("/project/test.py")
  local s = Scenario.new()
    :with_code("def foo()\n    pass\n")
    :with_cursor(0, 4)  -- on `foo` name
    :with_language("python")
    :with_tree(tree:root())
    :with_file("/project/test.py")
    :with_cwd("/project")
    :with_symbols(uri, {
      mocks.symbol("foo", LSP_FUNCTION, 0, 4, 1, 8),
    })

  local result = s:analyze()
  A.is_nil(result.current_function,
    "current_function must be nil (preconditions failed)")
  A.length(0, result.callers, "callers must be empty")
  A.length(0, result.external_calls, "external_calls must be empty")
  if result.debug then
    A.equal("preconditions_failed", result.debug.completion_reason,
      "completion_reason must be 'preconditions_failed'")
  end
  -- Strengthen: also assert debug is present (the previous `if result.debug
  -- then` silently passed when debug was nil — which would mask a regression
  -- where debug collection breaks for the preconditions_failed path).
  A.is_not_nil(result.debug,
    "debug must be present even on preconditions_failed (default debug=true)")
  A.equal("preconditions_failed", result.debug.completion_reason,
    "completion_reason must be 'preconditions_failed'")
end

return M
