--- tests/javascript_spec.lua — JavaScript unit tests for calltree.nvim.
---
--- Verifies the core analysis functions (function-name extraction, call
--- collection, callers, external_calls, nested-scope handling) against
--- hand-built mock treesitter trees that mirror the structure produced
--- by tree-sitter-javascript.
---
--- These tests are PURE UNIT tests: no Neovim UI, no real LSP, no real
--- treesitter parser. They use the same Scenario / mocks / tree_builder
--- infrastructure as the other language test suites.
---
--- JavaScript treesitter node types exercised:
---   - function_declaration     (function foo() {})
---   - arrow_function           (const add = (a,b) => a+b)
---   - method_definition        (class Foo { bar() {} })
---   - class_declaration        (class Foo {})
---   - lexical_declaration      (const/let)
---   - variable_declarator      (the `name = value` inside a declaration)
---   - call_expression          (foo(), obj.method())
---   - member_expression        (obj.method — dotted callee)
---   - statement_block          ({ ... } body)
---   - formal_parameters        ((a, b) parameter list)
---   - property_identifier      (method name inside class body)
---   - import_statement / import_clause  (ES6 import)

local Scenario = require("scenario")
local mocks    = require("mocks")
local TB       = require("tree_builder")
local A        = require("assert")
local utils    = require("calltree.utils")

local M = {}

--------------------------------------------------------------------------------
-- Test 1: Arrow function name extraction
--   const add = (a, b) => a + b;
-- Cursor on "add" identifier.
-- current_function.name should be "add" (extracted from the variable_declarator,
-- NOT nil — the arrow_function itself has no name child).
--------------------------------------------------------------------------------
function M.test_arrow_function_name_extraction()
  local tree = TB.tree({
    type = "program", range = {0, 0, 1, 0}, children = {
      { type = "lexical_declaration", range = {0, 0, 0, 27}, children = {
        { type = "variable_declarator", range = {0, 6, 0, 27}, children = {
          { type = "identifier", range = {0, 6, 0, 9}, text = "add" },
          { type = "arrow_function", range = {0, 12, 0, 27}, children = {
            { type = "formal_parameters", range = {0, 12, 0, 18}, children = {} },
          }},
        }},
      }},
    },
  })
  local uri = utils.path_to_uri("/project/test.js")
  local s = Scenario.new()
    :with_code("const add = (a, b) => a + b;\n")
    :with_cursor(0, 6)
    :with_language("javascript")
    :with_tree(tree:root())
    :with_file("/project/test.js")
    :with_cwd("/project")
    :with_symbols(uri, {
      mocks.symbol("add", 14, 0, 6, 0, 27),  -- kind=14 (Constant)
    })
    :with_definition(uri, { line = 0, character = 6 }, {
      mocks.loc(uri, 0, 6, 0, 27),
    })
    :with_references(uri, { line = 0, character = 6 }, {
      mocks.loc(uri, 0, 6, 0, 27),
    }, true)

  local result = s:analyze({ skip_stdlib_calls = false, deduplicate_external_calls = false })
  A.is_not_nil(result.current_function, "arrow function should be detected as current_function")
  A.equal("add", result.current_function.name,
    "arrow function name should be 'add' (extracted from variable_declarator)")
end

--------------------------------------------------------------------------------
-- Test 2: Function declaration name extraction
--   function foo() { return 1; }
-- Cursor on "foo" identifier.
--------------------------------------------------------------------------------
function M.test_function_declaration_name_extraction()
  local tree = TB.tree({
    type = "program", range = {0, 0, 1, 0}, children = {
      { type = "function_declaration", range = {0, 0, 0, 27}, children = {
        { type = "identifier", range = {0, 9, 0, 12}, text = "foo" },
        { type = "formal_parameters", range = {0, 12, 0, 14}, children = {} },
        { type = "statement_block", range = {0, 15, 0, 27}, children = {} },
      }},
    },
  })
  local uri = utils.path_to_uri("/project/test.js")
  local s = Scenario.new()
    :with_code("function foo() { return 1; }\n")
    :with_cursor(0, 9)
    :with_language("javascript")
    :with_tree(tree:root())
    :with_file("/project/test.js")
    :with_cwd("/project")
    :with_symbols(uri, {
      mocks.symbol("foo", utils.LSP_SYMBOL_FUNCTION, 0, 9, 0, 12),
    })
    :with_definition(uri, { line = 0, character = 9 }, {
      mocks.loc(uri, 0, 9, 0, 12),
    })
    :with_references(uri, { line = 0, character = 9 }, {
      mocks.loc(uri, 0, 9, 0, 12),
    }, true)

  local result = s:analyze({ skip_stdlib_calls = false, deduplicate_external_calls = false })
  A.is_not_nil(result.current_function)
  A.equal("foo", result.current_function.name)
end

--------------------------------------------------------------------------------
-- Test 3: Class method name extraction
--   class Foo { bar() { return 1; } }
-- Cursor on "bar" (property_identifier).
--------------------------------------------------------------------------------
function M.test_class_method_name_extraction()
  local tree = TB.tree({
    type = "program", range = {0, 0, 1, 0}, children = {
      { type = "class_declaration", range = {0, 0, 0, 33}, children = {
        { type = "identifier", range = {0, 6, 0, 9}, text = "Foo" },
        { type = "class_body", range = {0, 10, 0, 33}, children = {
          { type = "method_definition", range = {0, 12, 0, 31}, children = {
            { type = "property_identifier", range = {0, 12, 0, 15}, text = "bar" },
            { type = "formal_parameters", range = {0, 15, 0, 17}, children = {} },
            { type = "statement_block", range = {0, 18, 0, 31}, children = {} },
          }},
        }},
      }},
    },
  })
  local uri = utils.path_to_uri("/project/test.js")
  local s = Scenario.new()
    :with_code("class Foo { bar() { return 1; } }\n")
    :with_cursor(0, 12)
    :with_language("javascript")
    :with_tree(tree:root())
    :with_file("/project/test.js")
    :with_cwd("/project")
    :with_symbols(uri, {
      mocks.symbol("Foo", 5, 0, 6, 0, 9),  -- kind=5 (Class)
      mocks.symbol("bar", utils.LSP_SYMBOL_METHOD, 0, 12, 0, 15),
    })
    :with_definition(uri, { line = 0, character = 12 }, {
      mocks.loc(uri, 0, 12, 0, 15),
    })
    :with_references(uri, { line = 0, character = 12 }, {
      mocks.loc(uri, 0, 12, 0, 15),
    }, true)

  local result = s:analyze({ skip_stdlib_calls = false, deduplicate_external_calls = false })
  A.is_not_nil(result.current_function)
  A.equal("bar", result.current_function.name,
    "class method name should be 'bar' (class Foo is skipped)")
end

--------------------------------------------------------------------------------
-- Test 4: Call expression collection (external_calls)
--   function foo() { bar(); }
-- Cursor on "foo". external_calls should contain bar.
--------------------------------------------------------------------------------
function M.test_external_call_collection()
  local tree = TB.tree({
    type = "program", range = {0, 0, 1, 0}, children = {
      { type = "function_declaration", range = {0, 0, 0, 25}, children = {
        { type = "identifier", range = {0, 9, 0, 12}, text = "foo" },
        { type = "formal_parameters", range = {0, 12, 0, 14}, children = {} },
        { type = "statement_block", range = {0, 15, 0, 25}, children = {
          { type = "call_expression", range = {0, 17, 0, 23}, children = {
            { type = "identifier", range = {0, 17, 0, 20}, text = "bar" },
            { type = "arguments", range = {0, 20, 0, 23}, children = {} },
          }},
        }},
      }},
    },
  })
  local uri = utils.path_to_uri("/project/test.js")
  local s = Scenario.new()
    :with_code("function foo() { bar(); }\n")
    :with_cursor(0, 9)
    :with_language("javascript")
    :with_tree(tree:root())
    :with_file("/project/test.js")
    :with_cwd("/project")
    :with_symbols(uri, {
      mocks.symbol("foo", utils.LSP_SYMBOL_FUNCTION, 0, 9, 0, 12),
    })
    :with_definition(uri, { line = 0, character = 9 }, {
      mocks.loc(uri, 0, 9, 0, 12),
    })
    :with_references(uri, { line = 0, character = 9 }, {
      mocks.loc(uri, 0, 9, 0, 12),
    }, true)
    -- bar is in another file; LSP returns a definition there.
    :with_definition(uri, { line = 0, character = 17 }, {
      mocks.loc(utils.path_to_uri("/project/utils.js"), 0, 9, 0, 12),
    })

  local result = s:analyze({ skip_stdlib_calls = false, deduplicate_external_calls = false })
  A.is_not_nil(result.current_function)
  A.equal("foo", result.current_function.name)
  A.length(1, result.external_calls, "foo calls bar — should be 1 external call")
  A.equal("bar", result.external_calls[1].function_name)
end

--------------------------------------------------------------------------------
-- Test 5: Member/method call expression (obj.method())
--   function foo() { obj.method(); }
-- The callee is a member_expression; function_name should be "obj.method".
--------------------------------------------------------------------------------
function M.test_member_call_expression()
  local tree = TB.tree({
    type = "program", range = {0, 0, 1, 0}, children = {
      { type = "function_declaration", range = {0, 0, 0, 29}, children = {
        { type = "identifier", range = {0, 9, 0, 12}, text = "foo" },
        { type = "formal_parameters", range = {0, 12, 0, 14}, children = {} },
        { type = "statement_block", range = {0, 15, 0, 29}, children = {
          { type = "call_expression", range = {0, 17, 0, 27}, children = {
            -- The member_expression carries text="obj.method" so the callee
            -- extraction picks up the full dotted name (mock nodes don't
            -- auto-concatenate child text).
            { type = "member_expression", range = {0, 17, 0, 26}, text = "obj.method", children = {
              { type = "identifier", range = {0, 17, 0, 20}, text = "obj" },
              { type = "property_identifier", range = {0, 21, 0, 27}, text = "method" },
            }},
            { type = "arguments", range = {0, 26, 0, 27}, children = {} },
          }},
        }},
      }},
    },
  })
  local uri = utils.path_to_uri("/project/test.js")
  local s = Scenario.new()
    :with_code("function foo() { obj.method(); }\n")
    :with_cursor(0, 9)
    :with_language("javascript")
    :with_tree(tree:root())
    :with_file("/project/test.js")
    :with_cwd("/project")
    :with_symbols(uri, {
      mocks.symbol("foo", utils.LSP_SYMBOL_FUNCTION, 0, 9, 0, 12),
    })
    :with_definition(uri, { line = 0, character = 9 }, {
      mocks.loc(uri, 0, 9, 0, 12),
    })
    :with_references(uri, { line = 0, character = 9 }, {
      mocks.loc(uri, 0, 9, 0, 12),
    }, true)
    :with_definition(uri, { line = 0, character = 17 }, {})

  local result = s:analyze({ skip_stdlib_calls = false, deduplicate_external_calls = false })
  A.is_not_nil(result.current_function)
  A.length(1, result.external_calls, "should detect 1 call (obj.method)")
  A.equal("obj.method", result.external_calls[1].function_name,
    "member call name should be 'obj.method'")
end

--------------------------------------------------------------------------------
-- Test 6: Callers analysis (who calls the cursor function)
--   function bar() {}
--   function foo() { bar(); }
-- Cursor on "bar". callers should contain foo.
--------------------------------------------------------------------------------
function M.test_callers_analysis()
  local tree = TB.tree({
    type = "program", range = {0, 0, 2, 0}, children = {
      { type = "function_declaration", range = {0, 0, 0, 19}, children = {
        { type = "identifier", range = {0, 9, 0, 12}, text = "bar" },
        { type = "formal_parameters", range = {0, 12, 0, 14}, children = {} },
        { type = "statement_block", range = {0, 15, 0, 19}, children = {} },
      }},
      { type = "function_declaration", range = {1, 0, 1, 26}, children = {
        { type = "identifier", range = {1, 9, 1, 12}, text = "foo" },
        { type = "formal_parameters", range = {1, 12, 1, 14}, children = {} },
        { type = "statement_block", range = {1, 15, 1, 26}, children = {
          { type = "call_expression", range = {1, 17, 1, 23}, children = {
            { type = "identifier", range = {1, 17, 1, 20}, text = "bar" },
            { type = "arguments", range = {1, 20, 1, 23}, children = {} },
          }},
        }},
      }},
    },
  })
  local uri = utils.path_to_uri("/project/test.js")
  local s = Scenario.new()
    :with_code("function bar() {}\nfunction foo() { bar(); }\n")
    :with_cursor(0, 9)
    :with_language("javascript")
    :with_tree(tree:root())
    :with_file("/project/test.js")
    :with_cwd("/project")
    :with_symbols(uri, {
      mocks.symbol("bar", utils.LSP_SYMBOL_FUNCTION, 0, 9, 0, 12),
      mocks.symbol("foo", utils.LSP_SYMBOL_FUNCTION, 1, 9, 1, 12),
    })
    :with_definition(uri, { line = 0, character = 9 }, {
      mocks.loc(uri, 0, 9, 0, 12),
    })
    :with_references(uri, { line = 0, character = 9 }, {
      mocks.loc(uri, 0, 9, 0, 12),
      mocks.loc(uri, 1, 17, 1, 20),  -- bar() called inside foo
    }, true)

  local result = s:analyze({ skip_stdlib_calls = false, deduplicate_external_calls = false })
  A.is_not_nil(result.current_function)
  A.equal("bar", result.current_function.name)
  A.length(1, result.callers, "should find 1 caller (foo)")
  A.equal("foo", result.callers[1].caller_function.name)
end

--------------------------------------------------------------------------------
-- Test 7: Nested function — inner calls should NOT be attributed to outer
--   function outer() { function inner() { helper(); } inner(); }
-- Cursor on "outer". external_calls should contain inner (top-level call),
-- NOT helper (it's inside the nested function inner).
--------------------------------------------------------------------------------
function M.test_nested_function_scope()
  local tree = TB.tree({
    type = "program", range = {0, 0, 1, 0}, children = {
      { type = "function_declaration", range = {0, 0, 0, 53}, children = {
        { type = "identifier", range = {0, 9, 0, 14}, text = "outer" },
        { type = "formal_parameters", range = {0, 14, 0, 16}, children = {} },
        { type = "statement_block", range = {0, 17, 0, 53}, children = {
          -- function inner() { helper(); }
          { type = "function_declaration", range = {0, 19, 0, 45}, children = {
            { type = "identifier", range = {0, 28, 0, 33}, text = "inner" },
            { type = "formal_parameters", range = {0, 33, 0, 35}, children = {} },
            { type = "statement_block", range = {0, 36, 0, 45}, children = {
              { type = "call_expression", range = {0, 38, 0, 44}, children = {
                { type = "identifier", range = {0, 38, 0, 44}, text = "helper" },
                { type = "arguments", range = {0, 44, 0, 45}, children = {} },
              }},
            }},
          }},
          -- inner()
          { type = "call_expression", range = {0, 46, 0, 52}, children = {
            { type = "identifier", range = {0, 46, 0, 51}, text = "inner" },
            { type = "arguments", range = {0, 51, 0, 52}, children = {} },
          }},
        }},
      }},
    },
  })
  local uri = utils.path_to_uri("/project/test.js")
  local s = Scenario.new()
    :with_code("function outer() { function inner() { helper(); } inner(); }\n")
    :with_cursor(0, 9)
    :with_language("javascript")
    :with_tree(tree:root())
    :with_file("/project/test.js")
    :with_cwd("/project")
    :with_symbols(uri, {
      mocks.symbol("outer", utils.LSP_SYMBOL_FUNCTION, 0, 9, 0, 14),
    })
    :with_definition(uri, { line = 0, character = 9 }, {
      mocks.loc(uri, 0, 9, 0, 14),
    })
    :with_references(uri, { line = 0, character = 9 }, {
      mocks.loc(uri, 0, 9, 0, 14),
    }, true)
    :with_definition(uri, { line = 0, character = 46 }, {})

  local result = s:analyze({ skip_stdlib_calls = false, deduplicate_external_calls = false })
  A.is_not_nil(result.current_function)
  A.equal("outer", result.current_function.name)
  -- Should collect inner() but NOT helper() (helper is inside nested inner).
  A.length(1, result.external_calls,
    "should collect 1 top-level call (inner), not helper (nested)")
  A.equal("inner", result.external_calls[1].function_name)
end

--------------------------------------------------------------------------------
-- Test 8: CommonJS require() call (does not crash analysis)
--   const utils = require('./utils');
-- A `require()` call returns a module object, NOT a function. The
-- `utils` binding is a Constant, not a function definition, so
-- current_function should be nil (the analyzer correctly refuses to
-- treat a require binding as a function). This test verifies the
-- analysis completes without crashing and returns a clean empty result.
--------------------------------------------------------------------------------
function M.test_commonjs_require_call()
  local tree = TB.tree({
    type = "program", range = {0, 0, 1, 0}, children = {
      { type = "lexical_declaration", range = {0, 0, 0, 33}, children = {
        { type = "variable_declarator", range = {0, 6, 0, 33}, children = {
          { type = "identifier", range = {0, 6, 0, 11}, text = "utils" },
          { type = "call_expression", range = {0, 14, 0, 33}, children = {
            { type = "identifier", range = {0, 14, 0, 21}, text = "require" },
            { type = "arguments", range = {0, 21, 0, 33}, children = {} },
          }},
        }},
      }},
    },
  })
  local uri = utils.path_to_uri("/project/test.js")
  local s = Scenario.new()
    :with_code("const utils = require('./utils');\n")
    :with_cursor(0, 6)  -- on "utils" identifier
    :with_language("javascript")
    :with_tree(tree:root())
    :with_file("/project/test.js")
    :with_cwd("/project")
    :with_symbols(uri, {
      mocks.symbol("utils", 14, 0, 6, 0, 33),
    })
    :with_definition(uri, { line = 0, character = 6 }, {
      mocks.loc(uri, 0, 6, 0, 33),
    })
    :with_references(uri, { line = 0, character = 6 }, {
      mocks.loc(uri, 0, 6, 0, 33),
    }, true)

  local result = s:analyze({ skip_stdlib_calls = false, deduplicate_external_calls = false })
  -- A require() binding is NOT a function definition: the RHS is a
  -- call_expression, not arrow_function / function_expression. The
  -- analyzer correctly returns current_function = nil (cursor is not
  -- on a function-definition name). This verifies the analysis doesn't
  -- crash and produces a clean empty result.
  A.is_nil(result.current_function,
    "require() binding should NOT be detected as a function definition")
  A.equal("table", type(result.callers), "callers should be an empty table")
  A.equal("table", type(result.external_calls), "external_calls should be an empty table")
end

--------------------------------------------------------------------------------
-- Test 9: ES6 import statement (does NOT crash analysis)
--   import { x } from './mod';
--   function foo() {}
-- Cursor on foo. The import statement should be skipped (not a call).
--------------------------------------------------------------------------------
function M.test_es6_import_statement()
  local tree = TB.tree({
    type = "program", range = {0, 0, 2, 0}, children = {
      { type = "import_statement", range = {0, 0, 0, 26}, children = {} },
      { type = "function_declaration", range = {1, 0, 1, 19}, children = {
        { type = "identifier", range = {1, 9, 1, 12}, text = "foo" },
        { type = "formal_parameters", range = {1, 12, 1, 14}, children = {} },
        { type = "statement_block", range = {1, 15, 1, 19}, children = {} },
      }},
    },
  })
  local uri = utils.path_to_uri("/project/test.js")
  local s = Scenario.new()
    :with_code("import { x } from './mod';\nfunction foo() {}\n")
    :with_cursor(1, 9)
    :with_language("javascript")
    :with_tree(tree:root())
    :with_file("/project/test.js")
    :with_cwd("/project")
    :with_symbols(uri, {
      mocks.symbol("foo", utils.LSP_SYMBOL_FUNCTION, 1, 9, 1, 12),
    })
    :with_definition(uri, { line = 1, character = 9 }, {
      mocks.loc(uri, 1, 9, 1, 12),
    })
    :with_references(uri, { line = 1, character = 9 }, {
      mocks.loc(uri, 1, 9, 1, 12),
    }, true)

  local result = s:analyze({ skip_stdlib_calls = false, deduplicate_external_calls = false })
  A.is_not_nil(result.current_function)
  A.equal("foo", result.current_function.name)
  A.length(0, result.external_calls, "foo has no external calls; import is not a call")
end

--------------------------------------------------------------------------------
-- Test 10: Cross-file caller (analogous to test_multilanguage Python test)
--   utils.js: function helper() {}
--   main.js:   function caller() { helper(); }
-- Cursor on "helper" in utils.js. callers should contain caller from main.js.
--------------------------------------------------------------------------------
function M.test_cross_file_caller()
  local utils_tree = TB.tree({
    type = "program", range = {0, 0, 1, 0}, children = {
      { type = "function_declaration", range = {0, 0, 0, 21}, children = {
        { type = "identifier", range = {0, 9, 0, 15}, text = "helper" },
        { type = "formal_parameters", range = {0, 15, 0, 17}, children = {} },
        { type = "statement_block", range = {0, 18, 0, 21}, children = {} },
      }},
    },
  })

  local main_source = "function caller() { helper(); }\n"
  local main_tree = TB.tree({
    type = "program", range = {0, 0, 1, 0}, children = {
      { type = "function_declaration", range = {0, 0, 0, 30}, children = {
        { type = "identifier", range = {0, 9, 0, 15}, text = "caller" },
        { type = "formal_parameters", range = {0, 15, 0, 17}, children = {} },
        { type = "statement_block", range = {0, 18, 0, 30}, children = {
          { type = "call_expression", range = {0, 20, 0, 28}, children = {
            { type = "identifier", range = {0, 20, 0, 26}, text = "helper" },
            { type = "arguments", range = {0, 26, 0, 28}, children = {} },
          }},
        }},
      }},
    },
  })

  local utils_uri = utils.path_to_uri("/project/utils.js")
  local main_uri = utils.path_to_uri("/project/main.js")

  local s = Scenario.new()
    :with_code("function helper() {}\n")
    :with_cursor(0, 9)
    :with_language("javascript")
    :with_tree(utils_tree:root())
    :with_file("/project/utils.js")
    :with_cwd("/project")
    :with_symbols(utils_uri, {
      mocks.symbol("helper", utils.LSP_SYMBOL_FUNCTION, 0, 9, 0, 15),
    })
    :with_definition(utils_uri, { line = 0, character = 9 }, {
      mocks.loc(utils_uri, 0, 9, 0, 15),
    })
    :with_references(utils_uri, { line = 0, character = 9 }, {
      mocks.loc(utils_uri, 0, 9, 0, 15),
      mocks.loc(main_uri, 0, 20, 0, 26),  -- helper() called from main.js caller()
    }, true)
    :with_file_content("/project/main.js", main_source)
    :with_tree_for_source(main_source, main_tree:root())

  local result = s:analyze({ skip_stdlib_calls = false, deduplicate_external_calls = false })
  A.is_not_nil(result.current_function)
  A.equal("helper", result.current_function.name)
  A.length(1, result.callers, "should find 1 caller (caller) in main.js")
  A.equal("caller", result.callers[1].caller_function.name)
  A.equal("/project/main.js", result.callers[1].file)
end

--------------------------------------------------------------------------------
-- Test 11: Closure assigned to const (function_expression, not arrow)
--   const fn = function() { return 1; };
-- Cursor on "fn". current_function.name should be "fn".
--------------------------------------------------------------------------------
function M.test_function_expression_name_extraction()
  local tree = TB.tree({
    type = "program", range = {0, 0, 1, 0}, children = {
      { type = "lexical_declaration", range = {0, 0, 0, 34}, children = {
        { type = "variable_declarator", range = {0, 6, 0, 34}, children = {
          { type = "identifier", range = {0, 6, 0, 8}, text = "fn" },
          { type = "function_expression", range = {0, 11, 0, 34}, children = {
            { type = "formal_parameters", range = {0, 19, 0, 21}, children = {} },
            { type = "statement_block", range = {0, 22, 0, 34}, children = {} },
          }},
        }},
      }},
    },
  })
  local uri = utils.path_to_uri("/project/test.js")
  local s = Scenario.new()
    :with_code("const fn = function() { return 1; };\n")
    :with_cursor(0, 6)
    :with_language("javascript")
    :with_tree(tree:root())
    :with_file("/project/test.js")
    :with_cwd("/project")
    :with_symbols(uri, {
      mocks.symbol("fn", 14, 0, 6, 0, 34),
    })
    :with_definition(uri, { line = 0, character = 6 }, {
      mocks.loc(uri, 0, 6, 0, 34),
    })
    :with_references(uri, { line = 0, character = 6 }, {
      mocks.loc(uri, 0, 6, 0, 34),
    }, true)

  local result = s:analyze({ skip_stdlib_calls = false, deduplicate_external_calls = false })
  A.is_not_nil(result.current_function)
  A.equal("fn", result.current_function.name,
    "function_expression assigned to const should extract name 'fn'")
end

return M
