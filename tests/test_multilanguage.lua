--- tests/test_multilanguage.lua — 5 multi-language tests covering Python,
--- Rust, C/C++, C#, and Go analysis capabilities.
---
--- These tests verify cross-file reference resolution, class/impl method
--- caller detection, declaration/definition separation, nested function
--- handling, and anonymous function exclusion.

local Scenario = require("scenario")
local mocks    = require("mocks")
local TB       = require("tree_builder")
local A        = require("assert")
local utils    = require("calltree.utils")

local M = {}

--------------------------------------------------------------------------------
-- Test 1: Python multi-file + class method as caller
--------------------------------------------------------------------------------
-- utils.py: def helper(): pass
-- main.py:   from utils import helper
--            class App:
--                def run(self):
--                    helper()
-- Cursor on helper() in utils.py.
-- The caller should be App.run (method inside class, class is skipped).

function M.test_python_class_method_caller()
  -- Tree for utils.py (cursor file).
  local utils_tree = TB.tree({
    type = "module", range = {0, 0, 1, 0}, children = {
      { type = "function_definition", range = {0, 0, 0, 15}, children = {
        { type = "identifier", range = {0, 4, 0, 10}, text = "helper" },
        { type = "parameters", range = {0, 10, 0, 12}, children = {} },
        { type = "block", range = {0, 13, 0, 15}, children = {} },
      }},
    },
  })

  -- Tree for main.py (the caller file).
  local main_source = "from utils import helper\nclass App:\n    def run(self):\n        helper()\n"
  local main_tree = TB.tree({
    type = "module", range = {0, 0, 5, 0}, children = {
      { type = "import_statement", range = {0, 0, 0, 24}, children = {} },
      { type = "class_definition", range = {1, 0, 4, 0}, children = {
        { type = "identifier", range = {1, 6, 1, 9}, text = "App" },
        { type = "block", range = {1, 10, 4, 0}, children = {
          { type = "function_definition", range = {2, 4, 4, 0}, children = {
            { type = "identifier", range = {2, 8, 2, 12}, text = "run" },
            { type = "parameters", range = {2, 12, 2, 18}, children = {} },
            { type = "block", range = {2, 19, 4, 0}, children = {
              { type = "call", range = {3, 8, 3, 16}, children = {
                { type = "identifier", range = {3, 8, 3, 14}, text = "helper" },
                { type = "argument_list", range = {3, 14, 3, 16}, children = {} },
              }},
            }},
          }},
        }},
      }},
    },
  })

  local utils_uri = utils.path_to_uri("/project/utils.py")
  local main_uri = utils.path_to_uri("/project/main.py")

  local s = Scenario.new()
    :with_code("def helper():\n    pass\n")
    :with_cursor(0, 4)  -- on "helper"
    :with_language("python")
    :with_tree(utils_tree:root())
    :with_file("/project/utils.py")
    :with_cwd("/project")
    :with_symbols(utils_uri, {
      mocks.symbol("helper", utils.LSP_SYMBOL_FUNCTION, 0, 4, 0, 10),
    })
    :with_definition(utils_uri, { line = 0, character = 4 }, {
      mocks.loc(utils_uri, 0, 4, 0, 10),
    })
    :with_references(utils_uri, { line = 0, character = 4 }, {
      mocks.loc(utils_uri, 0, 4, 0, 10),
      mocks.loc(main_uri, 3, 8, 3, 14),  -- call from App.run
    }, true)
    :with_file_content("/project/main.py", main_source)
    :with_tree_for_source(main_source, main_tree:root())
    :with_definition(utils_uri, { line = 0, character = 4 }, {
      mocks.loc(utils_uri, 0, 4, 0, 10),
    })

  local result = s:analyze()
  A.is_not_nil(result.current_function, "current_function should be detected")
  A.equal("helper", result.current_function.name)
  A.length(1, result.callers, "should find 1 caller (App.run)")
  local caller = result.callers[1]
  A.equal("run", caller.caller_function.name,
    "caller should be 'run' (class App is skipped, method is top-level)")
  A.equal("/project/main.py", caller.file, "caller file should be main.py")
end

--------------------------------------------------------------------------------
-- Test 2: Rust impl block method as caller + cross-module
--------------------------------------------------------------------------------
-- lib.rs:  pub fn target() {}
-- main.rs: mod lib; struct S; impl S { fn method(&self) { lib::target(); } }
-- Cursor on target() in lib.rs.
-- The caller should be method (impl block is skipped).

function M.test_rust_impl_method_caller()
  local lib_tree = TB.tree({
    type = "source_file", range = {0, 0, 1, 0}, children = {
      { type = "function_item", range = {0, 0, 0, 18}, children = {
        { type = "identifier", range = {0, 7, 0, 13}, text = "target" },
        { type = "parameters", range = {0, 13, 0, 15}, children = {} },
        { type = "block", range = {0, 16, 0, 18}, children = {} },
      }},
    },
  })

  local main_source = "mod lib;\nstruct S;\nimpl S {\n    fn method(&self) {\n        lib::target();\n    }\n}\n"
  local main_tree = TB.tree({
    type = "source_file", range = {0, 0, 8, 0}, children = {
      { type = "mod_item", range = {0, 0, 0, 9}, children = {} },
      { type = "struct_item", range = {1, 0, 1, 9}, children = {} },
      { type = "impl_item", range = {2, 0, 6, 1}, children = {
        { type = "function_item", range = {3, 4, 5, 5}, children = {
          { type = "identifier", range = {3, 7, 3, 13}, text = "method" },
          { type = "parameters", range = {3, 13, 3, 22}, children = {} },
          { type = "block", range = {3, 23, 5, 5}, children = {
            { type = "call_expression", range = {4, 8, 4, 22}, children = {
              { type = "field_expression", range = {4, 8, 4, 19}, text = "lib::target" },
              { type = "arguments", range = {4, 19, 4, 21}, children = {} },
            }},
          }},
        }},
      }},
    },
  })

  local lib_uri = utils.path_to_uri("/project/lib.rs")
  local main_uri = utils.path_to_uri("/project/main.rs")

  local s = Scenario.new()
    :with_code("pub fn target() {}\n")
    :with_cursor(0, 7)  -- on "target"
    :with_language("rust")
    :with_tree(lib_tree:root())
    :with_file("/project/lib.rs")
    :with_cwd("/project")
    :with_symbols(lib_uri, {
      mocks.symbol("target", utils.LSP_SYMBOL_FUNCTION, 0, 7, 0, 13),
    })
    :with_definition(lib_uri, { line = 0, character = 7 }, {
      mocks.loc(lib_uri, 0, 7, 0, 13),
    })
    :with_references(lib_uri, { line = 0, character = 7 }, {
      mocks.loc(lib_uri, 0, 7, 0, 13),
      mocks.loc(main_uri, 4, 8, 4, 19),  -- call from method
    }, true)
    :with_file_content("/project/main.rs", main_source)
    :with_tree_for_source(main_source, main_tree:root())

  local result = s:analyze()
  A.is_not_nil(result.current_function)
  A.equal("target", result.current_function.name)
  A.length(1, result.callers, "should find 1 caller (method)")
  A.equal("method", result.callers[1].caller_function.name,
    "caller should be 'method' (impl block is skipped)")
end

--------------------------------------------------------------------------------
-- Test 3: C/C++ header declaration vs source definition separation
--------------------------------------------------------------------------------
-- math.h:  int add(int a, int b);          (declaration)
-- math.c:  int add(int a, int b) { ... }   (definition)
-- main.c:  int main() { return add(1, 2); }
-- Cursor on add() definition in math.c.
-- Callers should be main (from main.c), NOT the declaration in math.h.

function M.test_c_header_decl_vs_source_def()
  local math_c_tree = TB.tree({
    type = "translation_unit", range = {0, 0, 4, 0}, children = {
      { type = "preproc_include", range = {0, 0, 0, 18}, children = {} },
      { type = "function_definition", range = {1, 0, 3, 1}, children = {
        { type = "function_declarator", range = {1, 4, 1, 24}, children = {
          { type = "identifier", range = {1, 4, 1, 7}, text = "add" },
        }},
        { type = "compound_statement", range = {1, 26, 3, 1}, children = {
          { type = "return_statement", range = {2, 4, 2, 17}, children = {} },
        }},
      }},
    },
  })

  local main_source = '#include "math.h"\nint main() {\n    return add(1, 2);\n}\n'
  local main_tree = TB.tree({
    type = "translation_unit", range = {0, 0, 4, 0}, children = {
      { type = "preproc_include", range = {0, 0, 0, 18}, children = {} },
      { type = "function_definition", range = {1, 0, 3, 1}, children = {
        { type = "function_declarator", range = {1, 4, 1, 10}, children = {
          { type = "identifier", range = {1, 4, 1, 8}, text = "main" },
        }},
        { type = "compound_statement", range = {1, 12, 3, 1}, children = {
          { type = "return_statement", range = {2, 4, 2, 21}, children = {
            { type = "call_expression", range = {2, 11, 2, 20}, children = {
              { type = "identifier", range = {2, 11, 2, 14}, text = "add" },
              { type = "argument_list", range = {2, 14, 2, 20}, children = {} },
            }},
          }},
        }},
      }},
    },
  })

  local math_c_uri = utils.path_to_uri("/project/math.c")
  local math_h_uri = utils.path_to_uri("/project/math.h")
  local main_uri = utils.path_to_uri("/project/main.c")

  local s = Scenario.new()
    :with_code('#include "math.h"\nint add(int a, int b) {\n    return a + b;\n}\n')
    :with_cursor(1, 4)  -- on "add" definition
    :with_language("c")
    :with_tree(math_c_tree:root())
    :with_file("/project/math.c")
    :with_cwd("/project")
    :with_symbols(math_c_uri, {
      mocks.symbol("add", utils.LSP_SYMBOL_FUNCTION, 1, 4, 3, 1),
    })
    -- LSP definition returns BOTH the declaration (math.h) and definition (math.c).
    :with_definition(math_c_uri, { line = 1, character = 4 }, {
      mocks.loc(math_h_uri, 0, 4, 0, 7),  -- declaration in math.h
      mocks.loc(math_c_uri, 1, 4, 1, 7),  -- definition in math.c
    })
    :with_declaration(math_c_uri, { line = 1, character = 4 }, {
      mocks.loc(math_h_uri, 0, 4, 0, 7),  -- declaration
    })
    -- References include: declaration, definition, and call from main.
    :with_references(math_c_uri, { line = 1, character = 4 }, {
      mocks.loc(math_h_uri, 0, 4, 0, 7),  -- declaration (excluded)
      mocks.loc(math_c_uri, 1, 4, 1, 7),  -- definition (excluded)
      mocks.loc(main_uri, 2, 11, 2, 14),  -- call from main
    }, true)
    :with_file_content("/project/main.c", main_source)
    :with_tree_for_source(main_source, main_tree:root())

  local result = s:analyze()
  A.is_not_nil(result.current_function)
  A.length(1, result.callers, "only main should be a caller; decl/def excluded")
  A.equal("main", result.callers[1].caller_function.name)
end

--------------------------------------------------------------------------------
-- Test 4: C# expression-body method + local function
--------------------------------------------------------------------------------
-- class Calculator {
--     public int Add(int x, int y) => x + y;       // expression-body
--     public void Test() {
--         int local() => 42;                        // local function
--         Console.WriteLine(local());
--         Console.WriteLine(Add(1, 2));
--     }
-- }
-- Cursor on Add.
-- Caller should be Test. Local function 'local' should not interfere.

function M.test_csharp_expression_body_and_local_function()
  local tree = TB.tree({
    type = "compilation_unit", range = {0, 0, 8, 0}, children = {
      { type = "class_declaration", range = {0, 0, 7, 1}, children = {
        { type = "identifier", range = {0, 6, 0, 16}, text = "Calculator" },
        { type = "declaration_list", range = {0, 17, 7, 1}, children = {
          -- Add method (expression body)
          { type = "method_declaration", range = {1, 4, 1, 35}, children = {
            { type = "identifier", range = {1, 15, 1, 18}, text = "Add" },
            { type = "parameter_list", range = {1, 18, 1, 28}, children = {} },
            { type = "block", range = {1, 32, 1, 35}, children = {} },
          }},
          -- Test method
          { type = "method_declaration", range = {2, 4, 6, 5}, children = {
            { type = "identifier", range = {2, 15, 2, 19}, text = "Test" },
            { type = "parameter_list", range = {2, 19, 2, 21}, children = {} },
            { type = "block", range = {2, 22, 6, 5}, children = {
              -- local function
              { type = "local_function_statement", range = {3, 8, 3, 25}, children = {
                { type = "identifier", range = {3, 12, 3, 17}, text = "local" },
              }},
              -- Console.WriteLine(local())
              { type = "invocation_expression", range = {4, 8, 4, 33}, children = {
                { type = "identifier", range = {4, 8, 4, 15}, text = "Console.WriteLine" },
                { type = "argument_list", range = {4, 15, 4, 33}, children = {} },
              }},
              -- Console.WriteLine(Add(1, 2))
              { type = "invocation_expression", range = {5, 8, 5, 35}, children = {
                { type = "identifier", range = {5, 8, 5, 15}, text = "Console.WriteLine" },
                { type = "argument_list", range = {5, 15, 5, 35}, children = {} },
              }},
            }},
          }},
        }},
      }},
    },
  })

  local uri = utils.path_to_uri("/project/test.cs")
  local s = Scenario.new()
    :with_code("class Calculator {\n    public int Add(int x, int y) => x + y;\n}\n")
    :with_cursor(1, 15)  -- on "Add"
    :with_language("csharp")
    :with_tree(tree:root())
    :with_file("/project/test.cs")
    :with_cwd("/project")
    :with_symbols(uri, {
      mocks.symbol("Add", utils.LSP_SYMBOL_METHOD, 1, 15, 1, 18),
    })
    :with_definition(uri, { line = 1, character = 15 }, {
      mocks.loc(uri, 1, 15, 1, 18),
    })
    :with_references(uri, { line = 1, character = 15 }, {
      mocks.loc(uri, 1, 15, 1, 18),  -- definition
      -- The call to Add(1,2) is inside the Test method.
      -- We simulate LSP finding a reference at line 5 (inside Test).
      mocks.loc(uri, 5, 8, 5, 15),
    }, true)

  local result = s:analyze()
  A.is_not_nil(result.current_function)
  A.equal("Add", result.current_function.name)
  -- The caller should be Test (class is skipped, method is top-level).
  -- Strengthen: previously `A.truthy(#result.callers >= 1, ...)` plus a
  -- brittle `if #result.callers >= 1 then` wrapper silently passed when
  -- the callers list was empty. The scenario registers exactly one caller
  -- (Test), so assert the exact count of 1 and unwrap the conditional.
  A.equal(1, #result.callers, "should find exactly 1 caller (Test)")
  A.equal("Test", result.callers[1].caller_function.name,
    "caller should be 'Test' (class is skipped)")
end

--------------------------------------------------------------------------------
-- Test 5: Go anonymous function + cross-package
--------------------------------------------------------------------------------
-- math.go (package mymath): func Square(n int) int { return n * n }
-- main.go:  func main() { fn := func(x int) int { return x * 2 }; println(fn(3)); println(mymath.Square(4)) }
-- Cursor on Square in math.go.
-- Caller should be main (anonymous function fn doesn't interfere).

function M.test_go_anonymous_function_cross_package()
  local math_tree = TB.tree({
    type = "source_file", range = {0, 0, 2, 0}, children = {
      { type = "package_clause", range = {0, 0, 0, 13}, children = {} },
      { type = "function_declaration", range = {1, 0, 1, 40}, children = {
        { type = "identifier", range = {1, 5, 1, 11}, text = "Square" },
        { type = "parameter_list", range = {1, 11, 1, 20}, children = {} },
        { type = "block", range = {1, 25, 1, 40}, children = {} },
      }},
    },
  })

  local main_source = 'package main\nimport "example/mymath"\nfunc main() {\n    fn := func(x int) int { return x * 2 }\n    println(fn(3))\n    println(mymath.Square(4))\n}\n'
  local main_tree = TB.tree({
    type = "source_file", range = {0, 0, 8, 0}, children = {
      { type = "package_clause", range = {0, 0, 0, 12}, children = {} },
      { type = "import_declaration", range = {1, 0, 1, 24}, children = {} },
      { type = "function_declaration", range = {2, 0, 7, 1}, children = {
        { type = "identifier", range = {2, 5, 2, 9}, text = "main" },
        { type = "parameter_list", range = {2, 9, 2, 11}, children = {} },
        { type = "block", range = {2, 12, 7, 1}, children = {
          -- fn := func(x int) int { ... }
          { type = "short_var_declaration", range = {3, 4, 3, 44}, children = {
            { type = "func_literal", range = {3, 9, 3, 44}, children = {
              { type = "block", range = {3, 28, 3, 44}, children = {} },
            }},
          }},
          -- println(fn(3))
          { type = "call_expression", range = {4, 4, 4, 18}, children = {
            { type = "identifier", range = {4, 4, 4, 11}, text = "println" },
            { type = "argument_list", range = {4, 11, 4, 18}, children = {} },
          }},
          -- println(mymath.Square(4))
          { type = "call_expression", range = {5, 4, 5, 30}, children = {
            { type = "identifier", range = {5, 4, 5, 11}, text = "println" },
            { type = "argument_list", range = {5, 11, 5, 30}, children = {} },
          }},
        }},
      }},
    },
  })

  local math_uri = utils.path_to_uri("/project/math.go")
  local main_uri = utils.path_to_uri("/project/main.go")

  local s = Scenario.new()
    :with_code("package mymath\nfunc Square(n int) int { return n * n }\n")
    :with_cursor(1, 5)  -- on "Square"
    :with_language("go")
    :with_tree(math_tree:root())
    :with_file("/project/math.go")
    :with_cwd("/project")
    :with_symbols(math_uri, {
      mocks.symbol("Square", utils.LSP_SYMBOL_FUNCTION, 1, 5, 1, 11),
    })
    :with_definition(math_uri, { line = 1, character = 5 }, {
      mocks.loc(math_uri, 1, 5, 1, 11),
    })
    :with_references(math_uri, { line = 1, character = 5 }, {
      mocks.loc(math_uri, 1, 5, 1, 11),
      -- The call to mymath.Square(4) is inside main.
      mocks.loc(main_uri, 5, 12, 5, 25),
    }, true)
    :with_file_content("/project/main.go", main_source)
    :with_tree_for_source(main_source, main_tree:root())

  local result = s:analyze()
  A.is_not_nil(result.current_function)
  A.equal("Square", result.current_function.name)
  A.length(1, result.callers, "should find 1 caller (main)")
  A.equal("main", result.callers[1].caller_function.name,
    "caller should be 'main' (anonymous function doesn't interfere)")
end

return M
