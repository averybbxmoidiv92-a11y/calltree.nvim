--- tests/test_c.lua — C language adapter unit tests.
---
--- 10 scenarios covering C language analysis adaptation:
---   1.  Simple function definition identification.
---   2.  Direct caller lookup (single file) with self-recursion exclusion.
---   3.  External call (same file) resolution.
---   4.  Function pointer call — graceful unresolved degradation.
---   5.  Struct method (function pointer member call) — resolution via LSP.
---   6.  typedef type alias — function name extraction still works.
---   7.  Conditional compilation (#ifdef) — active branch only.
---   8.  Macro function call — filtered out (not a real call).
---   9.  Complex pointer declaration — robust name extraction.
---  10.  Cross-file reference — caller/definition in separate files.
---
--- All tests use the existing mock infrastructure (mocks.lua /
--- scenario.lua / tree_builder.lua) — no real C treesitter parser is
--- required. Mock trees use C tree-sitter node type names:
---   translation_unit, function_definition, function_declarator,
---   compound_statement, call_expression, argument_list,
---   parameter_list, preproc_*, struct_specifier, field_declaration_list,
---   field_expression, pointer_declarator, etc.

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
-- Test 1: Simple function definition identification.
--
-- Code:
--   int add(int a, int b) {
--       return a + b;
--   }
--
-- Cursor on `add` definition name (line 0, col 4).
-- Expect: current_function.name = "add", range = [1,3] (1-based closed),
--         no callers, no external_calls.
--------------------------------------------------------------------------------
function M.test_c_simple_function_definition()
  -- C AST (simplified, ranges are 0-based {sl,sc,el,ec}):
  -- translation_unit [0,0,3,0]
  --   function_definition [0,0,2,1]
  --     primitive_type "int" [0,0,0,3]
  --     function_declarator [0,4,0,20]
  --       identifier "add" [0,4,0,7]
  --       parameter_list [0,7,0,19]
  --     compound_statement [0,21,2,1]
  --       return_statement [1,4,1,17]
  local tree = TB.tree({
    type = "translation_unit", range = {0,0,3,0}, children = {
      { type = "function_definition", range = {0,0,2,1}, children = {
        { type = "primitive_type", range = {0,0,0,3}, text = "int" },
        { type = "function_declarator", range = {0,4,0,20}, children = {
          { type = "identifier", range = {0,4,0,7}, text = "add" },
          { type = "parameter_list", range = {0,7,0,19}, children = {} },
        }},
        { type = "compound_statement", range = {0,21,2,1}, children = {
          { type = "return_statement", range = {1,4,1,17}, text = "return a + b;" },
        }},
      }},
    },
  })

  local uri = utils.path_to_uri("/project/test.c")
  local s = Scenario.new()
    :with_code("int add(int a, int b) {\n    return a + b;\n}\n")
    :with_cursor(0, 4)  -- on `add` name
    :with_language("c")
    :with_tree(tree:root())
    :with_file("/project/test.c")
    :with_cwd("/project")
    :with_symbols(uri, {
      mocks.symbol("add", LSP_FUNCTION, 0, 4, 2, 1),
    })
    -- LSP definition for `add` cursor position -> itself.
    :with_definition(uri, { line = 0, character = 4 }, {
      mocks.loc(uri, 0, 4, 2, 1),
    })

  local result = s:analyze()
  A.is_not_nil(result.current_function, "current_function should be detected")
  A.equal("add", result.current_function.name)
  -- Range should be [1, 3] (1-based closed): start_line 0 -> 1, end_line 2 -> 3
  A.equal(1, result.current_function.range[1], "range start line should be 1 (1-based)")
  A.equal(3, result.current_function.range[2], "range end line should be 3 (1-based closed)")
  A.equal("/project/test.c", result.current_function.file)
  A.length(0, result.callers, "no callers expected")
  A.length(0, result.external_calls, "no external calls expected (add has no nested calls)")
end

--------------------------------------------------------------------------------
-- Test 2: Direct caller lookup (single file) — self-recursion excluded.
--
-- Code:
--   void foo() {}
--   void bar() { foo(); }
--   void baz() { foo(); }
--
-- Cursor on `foo` definition name (line 0, col 5).
-- Expect: callers has 2 entries (bar, baz); no foo self-reference.
--------------------------------------------------------------------------------
function M.test_c_direct_callers_single_file()
  local tree = TB.tree({
    type = "translation_unit", range = {0,0,3,0}, children = {
      -- void foo() {}
      { type = "function_definition", range = {0,0,0,13}, children = {
        { type = "primitive_type", range = {0,0,0,4}, text = "void" },
        { type = "function_declarator", range = {0,5,0,9}, children = {
          { type = "identifier", range = {0,5,0,8}, text = "foo" },
          { type = "parameter_list", range = {0,8,0,9}, children = {} },
        }},
        { type = "compound_statement", range = {0,10,0,12}, children = {} },
      }},
      -- void bar() { foo(); }
      { type = "function_definition", range = {1,0,1,21}, children = {
        { type = "primitive_type", range = {1,0,1,4}, text = "void" },
        { type = "function_declarator", range = {1,5,1,9}, children = {
          { type = "identifier", range = {1,5,1,8}, text = "bar" },
          { type = "parameter_list", range = {1,8,1,9}, children = {} },
        }},
        { type = "compound_statement", range = {1,10,1,20}, children = {
          { type = "expression_statement", range = {1,12,1,19}, children = {
            { type = "call_expression", range = {1,12,1,18}, children = {
              { type = "identifier", range = {1,12,1,15}, text = "foo" },
              { type = "argument_list", range = {1,15,1,18}, children = {} },
            }},
          }},
        }},
      }},
      -- void baz() { foo(); }
      { type = "function_definition", range = {2,0,2,21}, children = {
        { type = "primitive_type", range = {2,0,2,4}, text = "void" },
        { type = "function_declarator", range = {2,5,2,9}, children = {
          { type = "identifier", range = {2,5,2,8}, text = "baz" },
          { type = "parameter_list", range = {2,8,2,9}, children = {} },
        }},
        { type = "compound_statement", range = {2,10,2,20}, children = {
          { type = "expression_statement", range = {2,12,2,19}, children = {
            { type = "call_expression", range = {2,12,2,18}, children = {
              { type = "identifier", range = {2,12,2,15}, text = "foo" },
              { type = "argument_list", range = {2,15,2,18}, children = {} },
            }},
          }},
        }},
      }},
    },
  })

  local uri = utils.path_to_uri("/project/test.c")
  local s = Scenario.new()
    :with_code("void foo() {}\nvoid bar() { foo(); }\nvoid baz() { foo(); }\n")
    :with_cursor(0, 5)  -- on `foo` name
    :with_language("c")
    :with_tree(tree:root())
    :with_file("/project/test.c")
    :with_cwd("/project")
    :with_symbols(uri, {
      mocks.symbol("foo", LSP_FUNCTION, 0, 5, 0, 13),
      mocks.symbol("bar", LSP_FUNCTION, 1, 5, 1, 21),
      mocks.symbol("baz", LSP_FUNCTION, 2, 5, 2, 21),
    })
    :with_definition(uri, { line = 0, character = 5 }, {
      mocks.loc(uri, 0, 5, 0, 13),
    })
    -- references(includeDecl=true): self def + 2 call sites.
    :with_references(uri, { line = 0, character = 5 }, {
      mocks.loc(uri, 0, 5, 0, 13),     -- self def (excluded)
      mocks.loc(uri, 1, 12, 1, 15),    -- call inside bar
      mocks.loc(uri, 2, 12, 2, 15),    -- call inside baz
    }, true)

  local result = s:analyze()
  A.is_not_nil(result.current_function)
  A.equal("foo", result.current_function.name)
  A.length(2, result.callers, "exactly two callers (bar, baz); foo self excluded")
  -- Verify both bar and baz are present (order may vary)
  local caller_names = {}
  for _, c in ipairs(result.callers) do
    table.insert(caller_names, c.caller_function.name)
  end
  table.sort(caller_names)
  A.equal("bar", caller_names[1])
  A.equal("baz", caller_names[2])
end

--------------------------------------------------------------------------------
-- Test 3: External call (same file) — resolution.
--
-- Code:
--   int helper(int x) { return x; }
--   int calc(int y) { return helper(y + 1); }
--
-- Cursor on `calc` definition name (line 1, col 4).
-- Expect: external_calls has 1 entry for `helper`, resolved, with body range
--         pointing to the same file.
--------------------------------------------------------------------------------
function M.test_c_external_call_same_file()
  local tree = TB.tree({
    type = "translation_unit", range = {0,0,2,0}, children = {
      -- int helper(int x) { return x; }
      { type = "function_definition", range = {0,0,0,28}, children = {
        { type = "primitive_type", range = {0,0,0,3}, text = "int" },
        { type = "function_declarator", range = {0,4,0,18}, children = {
          { type = "identifier", range = {0,4,0,10}, text = "helper" },
          { type = "parameter_list", range = {0,10,0,17}, children = {} },
        }},
        { type = "compound_statement", range = {0,19,0,28}, children = {
          { type = "return_statement", range = {0,21,0,27}, text = "return x;" },
        }},
      }},
      -- int calc(int y) { return helper(y + 1); }
      { type = "function_definition", range = {1,0,1,36}, children = {
        { type = "primitive_type", range = {1,0,1,3}, text = "int" },
        { type = "function_declarator", range = {1,4,1,16}, children = {
          { type = "identifier", range = {1,4,1,8}, text = "calc" },
          { type = "parameter_list", range = {1,8,1,15}, children = {} },
        }},
        { type = "compound_statement", range = {1,17,1,36}, children = {
          { type = "return_statement", range = {1,19,1,35}, children = {
            { type = "call_expression", range = {1,26,1,35}, children = {
              { type = "identifier", range = {1,26,1,32}, text = "helper" },
              { type = "argument_list", range = {1,32,1,35}, children = {} },
            }},
          }},
        }},
      }},
    },
  })

  local uri = utils.path_to_uri("/project/test.c")
  local s = Scenario.new()
    :with_code("int helper(int x) { return x; }\nint calc(int y) { return helper(y + 1); }\n")
    :with_cursor(1, 4)  -- on `calc` name
    :with_language("c")
    :with_tree(tree:root())
    :with_file("/project/test.c")
    :with_cwd("/project")
    :with_symbols(uri, {
      mocks.symbol("helper", LSP_FUNCTION, 0, 4, 0, 28),
      mocks.symbol("calc",   LSP_FUNCTION, 1, 4, 1, 36),
    })
    :with_definition(uri, { line = 1, character = 4 }, {
      mocks.loc(uri, 1, 4, 1, 36),
    })
    -- LSP definition for `helper()` call at line 1, col 26 -> helper's def.
    :with_definition(uri, { line = 1, character = 26 }, {
      mocks.loc(uri, 0, 4, 0, 28),
    })

  local result = s:analyze()
  A.is_not_nil(result.current_function)
  A.equal("calc", result.current_function.name)
  A.length(1, result.external_calls, "exactly one external call (helper)")
  local ec = result.external_calls[1]
  A.equal("helper", ec.function_name)
  A.equal("resolved", ec.resolution_status)
  A.is_not_nil(ec.definition, "definition must be present")
  A.equal("/project/test.c", ec.definition.file)
  A.is_not_nil(ec.definition.function_body_range,
    "function_body_range must be present (helper has a body)")
end

--------------------------------------------------------------------------------
-- Test 4: Function pointer call — graceful unresolved degradation.
--
-- Code:
--   void target() {}
--   void dispatcher(void (*fp)()) {
--       fp();
--   }
--
-- Cursor on `dispatcher` definition name (line 1, col 5).
-- LSP cannot resolve the function pointer target; plugin must mark the call
-- as `unresolved` rather than crashing.
--------------------------------------------------------------------------------
function M.test_c_function_pointer_call_unresolved()
  local tree = TB.tree({
    type = "translation_unit", range = {0,0,4,0}, children = {
      -- void target() {}
      { type = "function_definition", range = {0,0,0,15}, children = {
        { type = "primitive_type", range = {0,0,0,4}, text = "void" },
        { type = "function_declarator", range = {0,5,0,11}, children = {
          { type = "identifier", range = {0,5,0,11}, text = "target" },
          { type = "parameter_list", range = {0,11,0,12}, children = {} },
        }},
        { type = "compound_statement", range = {0,13,0,15}, children = {} },
      }},
      -- void dispatcher(void (*fp)()) { fp(); }
      { type = "function_definition", range = {1,0,3,1}, children = {
        { type = "primitive_type", range = {1,0,1,4}, text = "void" },
        { type = "function_declarator", range = {1,5,1,28}, children = {
          { type = "identifier", range = {1,5,1,15}, text = "dispatcher" },
          { type = "parameter_list", range = {1,15,1,28}, children = {} },
        }},
        { type = "compound_statement", range = {1,30,3,1}, children = {
          { type = "expression_statement", range = {2,4,2,9}, children = {
            { type = "call_expression", range = {2,4,2,8}, children = {
              { type = "identifier", range = {2,4,2,6}, text = "fp" },
              { type = "argument_list", range = {2,6,2,8}, children = {} },
            }},
          }},
        }},
      }},
    },
  })

  local uri = utils.path_to_uri("/project/test.c")
  local s = Scenario.new()
    :with_code("void target() {}\nvoid dispatcher(void (*fp)()) {\n    fp();\n}\n")
    :with_cursor(1, 5)  -- on `dispatcher` name
    :with_language("c")
    :with_tree(tree:root())
    :with_file("/project/test.c")
    :with_cwd("/project")
    :with_symbols(uri, {
      mocks.symbol("target",     LSP_FUNCTION, 0, 5, 0, 15),
      mocks.symbol("dispatcher", LSP_FUNCTION, 1, 5, 3, 1),
    })
    :with_definition(uri, { line = 1, character = 5 }, {
      mocks.loc(uri, 1, 5, 3, 1),
    })
    -- Intentionally NO definition registered for `fp()` call at (2, 4):
    -- LSP cannot resolve function pointer indirections. The mock returns nil,
    -- and the plugin should mark the call as unresolved (not crash).

  local result = s:analyze({ skip_stdlib_calls = false, deduplicate_external_calls = false })
  A.is_not_nil(result.current_function)
  A.equal("dispatcher", result.current_function.name)
  A.length(1, result.external_calls, "exactly one external call (fp)")
  local ec = result.external_calls[1]
  A.equal("fp", ec.function_name)
  A.equal("unresolved", ec.resolution_status,
    "function pointer call must be unresolved (LSP cannot track the target)")
  A.is_nil(ec.definition, "definition must be nil for unresolved call")
end

--------------------------------------------------------------------------------
-- Test 5: Struct method (function pointer member call) — LSP resolves.
--
-- Code:
--   struct Math { int (*add)(int, int); };
--   int real_add(int a, int b) { return a+b; }
--   void use() {
--       struct Math m = { .add = real_add };
--       m.add(2,3);
--   }
--
-- Cursor on `use` definition name (line 2, col 5).
-- LSP definition for `m.add(2,3)` call (queried at the field_expression
-- start position) returns real_add's def.
-- Expect: external_calls resolves to real_add; function_name = "m.add"
--         (callee node text), definition.file = same file, body range present.
--------------------------------------------------------------------------------
function M.test_c_struct_member_call_resolved()
  local tree = TB.tree({
    type = "translation_unit", range = {0,0,6,0}, children = {
      -- struct Math { int (*add)(int, int); };
      { type = "struct_specifier", range = {0,0,0,39}, children = {
        { type = "type_identifier", range = {0,7,0,11}, text = "Math" },
        { type = "field_declaration_list", range = {0,12,0,38}, children = {
          { type = "field_declaration", range = {0,14,0,36}, children = {} },
        }},
      }},
      -- int real_add(int a, int b) { return a+b; }
      { type = "function_definition", range = {1,0,1,40}, children = {
        { type = "primitive_type", range = {1,0,1,3}, text = "int" },
        { type = "function_declarator", range = {1,4,1,28}, children = {
          { type = "identifier", range = {1,4,1,12}, text = "real_add" },
          { type = "parameter_list", range = {1,12,1,28}, children = {} },
        }},
        { type = "compound_statement", range = {1,30,1,40}, children = {
          { type = "return_statement", range = {1,32,1,39}, text = "return a+b;" },
        }},
      }},
      -- void use() { ... m.add(2,3); }
      { type = "function_definition", range = {2,0,5,1}, children = {
        { type = "primitive_type", range = {2,0,2,4}, text = "void" },
        { type = "function_declarator", range = {2,5,2,9}, children = {
          { type = "identifier", range = {2,5,2,8}, text = "use" },
          { type = "parameter_list", range = {2,8,2,9}, children = {} },
        }},
        { type = "compound_statement", range = {2,11,5,1}, children = {
          -- struct Math m = { .add = real_add };
          { type = "declaration", range = {3,4,3,41}, children = {} },
          -- m.add(2,3);
          { type = "expression_statement", range = {4,4,4,15}, children = {
            { type = "call_expression", range = {4,4,4,14}, children = {
              { type = "field_expression", range = {4,4,4,9}, text = "m.add", children = {
                { type = "identifier", range = {4,4,4,5}, text = "m" },
                { type = "field_identifier", range = {4,6,4,9}, text = "add" },
              }},
              { type = "argument_list", range = {4,9,4,14}, children = {} },
            }},
          }},
        }},
      }},
    },
  })

  local uri = utils.path_to_uri("/project/test.c")
  local s = Scenario.new()
    :with_code("struct Math { int (*add)(int, int); };\nint real_add(int a, int b) { return a+b; }\nvoid use() {\n    struct Math m = { .add = real_add };\n    m.add(2,3);\n}\n")
    :with_cursor(2, 5)  -- on `use` name
    :with_language("c")
    :with_tree(tree:root())
    :with_file("/project/test.c")
    :with_cwd("/project")
    :with_symbols(uri, {
      mocks.symbol("real_add", LSP_FUNCTION, 1, 4, 1, 40),
      mocks.symbol("use",      LSP_FUNCTION, 2, 5, 5, 1),
    })
    :with_definition(uri, { line = 2, character = 5 }, {
      mocks.loc(uri, 2, 5, 5, 1),
    })
    -- LSP definition for `m.add(2,3)` call. The plugin queries at the
    -- callee_node's start position. callee_node is the field_expression
    -- node `m.add` whose range starts at (4, 4).
    :with_definition(uri, { line = 4, character = 4 }, {
      mocks.loc(uri, 1, 4, 1, 40),  -- resolves to real_add's def
    })

  local result = s:analyze()
  A.is_not_nil(result.current_function)
  A.equal("use", result.current_function.name)
  A.length(1, result.external_calls, "exactly one external call (m.add)")
  local ec = result.external_calls[1]
  -- callee_text should be "m.add" (the field_expression node's text).
  A.equal("m.add", ec.function_name)
  A.equal("resolved", ec.resolution_status)
  A.is_not_nil(ec.definition, "definition must be present")
  A.equal("/project/test.c", ec.definition.file)
  A.is_not_nil(ec.definition.function_body_range,
    "function_body_range must be present (real_add has a body)")
end

--------------------------------------------------------------------------------
-- Test 6: typedef type alias — function name still extracted.
--
-- Code:
--   typedef int (*Op)(int, int);
--   int apply(Op op, int a, int b) { return op(a, b); }
--
-- Cursor on `apply` definition name (line 1, col 4).
-- Expect: current_function.name = "apply", range correct.
--         The `op(a, b)` call (function pointer parameter) is marked unresolved.
--------------------------------------------------------------------------------
function M.test_c_typedef_alias_function_name()
  local tree = TB.tree({
    type = "translation_unit", range = {0,0,2,0}, children = {
      -- typedef int (*Op)(int, int);
      { type = "type_definition", range = {0,0,0,28}, children = {
        { type = "primitive_type", range = {0,8,0,11}, text = "int" },
        { type = "function_declarator", range = {0,13,0,26}, children = {
          { type = "type_identifier", range = {0,15,0,17}, text = "Op" },
          { type = "parameter_list", range = {0,18,0,26}, children = {} },
        }},
      }},
      -- int apply(Op op, int a, int b) { return op(a, b); }
      { type = "function_definition", range = {1,0,1,46}, children = {
        { type = "primitive_type", range = {1,0,1,3}, text = "int" },
        { type = "function_declarator", range = {1,4,1,30}, children = {
          { type = "identifier", range = {1,4,1,9}, text = "apply" },
          { type = "parameter_list", range = {1,9,1,29}, children = {} },
        }},
        { type = "compound_statement", range = {1,31,1,46}, children = {
          { type = "return_statement", range = {1,33,1,45}, children = {
            { type = "call_expression", range = {1,40,1,45}, children = {
              { type = "identifier", range = {1,40,1,42}, text = "op" },
              { type = "argument_list", range = {1,42,1,45}, children = {} },
            }},
          }},
        }},
      }},
    },
  })

  local uri = utils.path_to_uri("/project/test.c")
  local s = Scenario.new()
    :with_code("typedef int (*Op)(int, int);\nint apply(Op op, int a, int b) { return op(a, b); }\n")
    :with_cursor(1, 4)  -- on `apply` name
    :with_language("c")
    :with_tree(tree:root())
    :with_file("/project/test.c")
    :with_cwd("/project")
    :with_symbols(uri, {
      mocks.symbol("apply", LSP_FUNCTION, 1, 4, 1, 46),
    })
    :with_definition(uri, { line = 1, character = 4 }, {
      mocks.loc(uri, 1, 4, 1, 46),
    })
    -- No definition registered for `op(a, b)` call at (1, 40) — function
    -- pointer parameter; LSP cannot statically resolve the target.

  local result = s:analyze({ skip_stdlib_calls = false, deduplicate_external_calls = false })
  A.is_not_nil(result.current_function, "current_function must be detected despite typedef")
  A.equal("apply", result.current_function.name)
  A.equal(2, result.current_function.range[1], "range start line = 2 (1-based)")
  A.equal(2, result.current_function.range[2], "range end line = 2 (1-based closed)")
  A.length(1, result.external_calls, "exactly one external call (op)")
  local ec = result.external_calls[1]
  A.equal("op", ec.function_name)
  A.equal("unresolved", ec.resolution_status,
    "function pointer parameter call must be unresolved (graceful degradation)")
end

--------------------------------------------------------------------------------
-- Test 7: Conditional compilation (#ifdef) — active branch only.
--
-- Code:
--   #define FEATURE
--   int real_add(int a, int b) { return a+b; }
--   void calc(int x) {
--   #ifdef FEATURE
--       real_add(x, 1);
--   #else
--       dummy(x);
--   #endif
--   }
--
-- Cursor on `calc` definition name (line 2, col 5).
-- The active branch (#ifdef FEATURE) contains the real_add call; the #else
-- branch's dummy() call must be ignored (tree-sitter only parses the
-- active branch's content into named nodes).
-- Expect: external_calls contains only `real_add`, resolved.
--------------------------------------------------------------------------------
function M.test_c_conditional_compilation_active_branch()
  local tree = TB.tree({
    type = "translation_unit", range = {0,0,9,0}, children = {
      -- #define FEATURE
      { type = "preproc_def", range = {0,0,0,16}, children = {} },
      -- int real_add(int a, int b) { return a+b; }
      { type = "function_definition", range = {1,0,1,40}, children = {
        { type = "primitive_type", range = {1,0,1,3}, text = "int" },
        { type = "function_declarator", range = {1,4,1,28}, children = {
          { type = "identifier", range = {1,4,1,12}, text = "real_add" },
          { type = "parameter_list", range = {1,12,1,28}, children = {} },
        }},
        { type = "compound_statement", range = {1,30,1,40}, children = {
          { type = "return_statement", range = {1,32,1,39}, text = "return a+b;" },
        }},
      }},
      -- void calc(int x) { ... }
      { type = "function_definition", range = {2,0,8,1}, children = {
        { type = "primitive_type", range = {2,0,2,4}, text = "void" },
        { type = "function_declarator", range = {2,5,2,18}, children = {
          { type = "identifier", range = {2,5,2,9}, text = "calc" },
          { type = "parameter_list", range = {2,9,2,18}, children = {} },
        }},
        { type = "compound_statement", range = {2,20,8,1}, children = {
          -- #ifdef FEATURE ... #else ... #endif wraps the active branch.
          { type = "preproc_if", range = {3,0,7,7}, children = {
            -- Active branch: real_add(x, 1);
            { type = "expression_statement", range = {4,4,4,19}, children = {
              { type = "call_expression", range = {4,4,4,18}, children = {
                { type = "identifier", range = {4,4,4,12}, text = "real_add" },
                { type = "argument_list", range = {4,12,4,18}, children = {} },
              }},
            }},
            -- Inactive branch (#else dummy(x); #endif) is NOT in the named
            -- tree — tree-sitter only emits named nodes for the active branch.
            -- We model this by simply not including a call_expression for dummy.
          }},
        }},
      }},
    },
  })

  local uri = utils.path_to_uri("/project/test.c")
  local s = Scenario.new()
    :with_code("#define FEATURE\nint real_add(int a, int b) { return a+b; }\nvoid calc(int x) {\n#ifdef FEATURE\n    real_add(x, 1);\n#else\n    dummy(x);\n#endif\n}\n")
    :with_cursor(2, 5)  -- on `calc` name
    :with_language("c")
    :with_tree(tree:root())
    :with_file("/project/test.c")
    :with_cwd("/project")
    :with_symbols(uri, {
      mocks.symbol("real_add", LSP_FUNCTION, 1, 4, 1, 40),
      mocks.symbol("calc",     LSP_FUNCTION, 2, 5, 8, 1),
    })
    :with_definition(uri, { line = 2, character = 5 }, {
      mocks.loc(uri, 2, 5, 8, 1),
    })
    -- LSP definition for `real_add(x, 1)` call at line 4, col 4 -> real_add's def.
    :with_definition(uri, { line = 4, character = 4 }, {
      mocks.loc(uri, 1, 4, 1, 40),
    })

  local result = s:analyze()
  A.is_not_nil(result.current_function)
  A.equal("calc", result.current_function.name)
  A.length(1, result.external_calls,
    "exactly one external call (real_add); #else dummy must be ignored")
  local ec = result.external_calls[1]
  A.equal("real_add", ec.function_name)
  A.equal("resolved", ec.resolution_status)
  A.is_not_nil(ec.definition)
end

--------------------------------------------------------------------------------
-- Test 8: Macro function call — must be filtered out.
--
-- Code:
--   #define SQUARE(x) ((x)*(x))
--   int compute(int v) {
--       return SQUARE(v);
--   }
--
-- Cursor on `compute` definition name (line 1, col 4).
-- In C tree-sitter, `SQUARE(v)` after a #define macro is parsed as a
-- `macro_invocation` (NOT a call_expression), so walker.collect_top_level_calls
-- does not pick it up.
-- Expect: external_calls is empty (no real call_expression in the body).
--------------------------------------------------------------------------------
function M.test_c_macro_call_filtered()
  local tree = TB.tree({
    type = "translation_unit", range = {0,0,4,0}, children = {
      -- #define SQUARE(x) ((x)*(x))
      { type = "preproc_def", range = {0,0,0,27}, children = {} },
      -- int compute(int v) { return SQUARE(v); }
      { type = "function_definition", range = {1,0,3,1}, children = {
        { type = "primitive_type", range = {1,0,1,3}, text = "int" },
        { type = "function_declarator", range = {1,4,1,19}, children = {
          { type = "identifier", range = {1,4,1,11}, text = "compute" },
          { type = "parameter_list", range = {1,11,1,19}, children = {} },
        }},
        { type = "compound_statement", range = {1,21,3,1}, children = {
          { type = "return_statement", range = {2,4,2,19}, children = {
            -- SQUARE(v) is a macro_invocation, NOT a call_expression.
            -- Walker.collect_top_level_calls skips it because CALL_NODE_TYPES
            -- does not include "macro_invocation".
            { type = "macro_invocation", range = {2,11,2,20}, children = {
              { type = "identifier", range = {2,11,2,17}, text = "SQUARE" },
            }},
          }},
        }},
      }},
    },
  })

  local uri = utils.path_to_uri("/project/test.c")
  local s = Scenario.new()
    :with_code("#define SQUARE(x) ((x)*(x))\nint compute(int v) {\n    return SQUARE(v);\n}\n")
    :with_cursor(1, 4)  -- on `compute` name
    :with_language("c")
    :with_tree(tree:root())
    :with_file("/project/test.c")
    :with_cwd("/project")
    :with_symbols(uri, {
      mocks.symbol("compute", LSP_FUNCTION, 1, 4, 3, 1),
    })
    :with_definition(uri, { line = 1, character = 4 }, {
      mocks.loc(uri, 1, 4, 3, 1),
    })

  local result = s:analyze()
  A.is_not_nil(result.current_function)
  A.equal("compute", result.current_function.name)
  A.length(0, result.external_calls,
    "macro calls must NOT appear in external_calls (SQUARE is a macro, not a function)")
end

--------------------------------------------------------------------------------
-- Test 9: Complex pointer declaration — robust name extraction.
--
-- Code (function returning function pointer, with function pointer parameter):
--   int (*callback(int x, void (*handler)(int)))(int) {
--       return NULL;
--   }
--
-- Cursor on `callback` function name (line 0, col 7).
-- The signature nests multiple function_declarator + pointer_declarator
-- wrappers around the `callback` identifier. The analyzer must still
-- extract the function name without crashing.
-- Expect: current_function.name = "callback", range correct.
--------------------------------------------------------------------------------
function M.test_c_complex_pointer_declaration()
  -- The nested declarator structure for
  --   int (*callback(int x, void (*handler)(int)))(int) { ... }
  -- has the identifier `callback` wrapped in:
  --   function_definition
  --     function_declarator (outer, returns int (*)(int))
  --       pointer_declarator
  --         function_declarator (inner, declares callback with params)
  --           identifier "callback"
  --           parameter_list
  --             parameter_declaration (int x)
  --             parameter_declaration (void (*handler)(int))
  --               pointer_declarator -> function_declarator -> identifier "handler"
  --     compound_statement
  local tree = TB.tree({
    type = "translation_unit", range = {0,0,3,0}, children = {
      { type = "function_definition", range = {0,0,2,1}, children = {
        { type = "primitive_type", range = {0,0,0,3}, text = "int" },
        -- Outer function_declarator: int (*NAME(params))(int)
        { type = "function_declarator", range = {0,4,0,52}, children = {
          { type = "pointer_declarator", range = {0,4,0,52}, children = {
            -- Inner function_declarator declares `callback`.
            { type = "function_declarator", range = {0,5,0,42}, children = {
              { type = "identifier", range = {0,7,0,15}, text = "callback" },
              { type = "parameter_list", range = {0,15,0,42}, children = {
                -- int x
                { type = "parameter_declaration", range = {0,16,0,21}, children = {
                  { type = "primitive_type", range = {0,16,0,19}, text = "int" },
                  { type = "identifier", range = {0,20,0,21}, text = "x" },
                }},
                -- void (*handler)(int)
                { type = "parameter_declaration", range = {0,23,0,41}, children = {
                  { type = "primitive_type", range = {0,23,0,27}, text = "void" },
                  { type = "pointer_declarator", range = {0,28,0,41}, children = {
                    { type = "function_declarator", range = {0,29,0,41}, children = {
                      { type = "identifier", range = {0,30,0,37}, text = "handler" },
                      { type = "parameter_list", range = {0,37,0,41}, children = {} },
                    }},
                  }},
                }},
              }},
            }},
          }},
          -- Outer parameter list: (int)
          { type = "parameter_list", range = {0,52,0,56}, children = {} },
        }},
        { type = "compound_statement", range = {0,58,2,1}, children = {
          { type = "return_statement", range = {1,4,1,16}, text = "return NULL;" },
        }},
      }},
    },
  })

  local uri = utils.path_to_uri("/project/test.c")
  local s = Scenario.new()
    :with_code("int (*callback(int x, void (*handler)(int)))(int) {\n    return NULL;\n}\n")
    :with_cursor(0, 7)  -- on `callback` name
    :with_language("c")
    :with_tree(tree:root())
    :with_file("/project/test.c")
    :with_cwd("/project")
    :with_symbols(uri, {
      mocks.symbol("callback", LSP_FUNCTION, 0, 7, 2, 1),
    })
    :with_definition(uri, { line = 0, character = 7 }, {
      mocks.loc(uri, 0, 7, 2, 1),
    })

  local result = s:analyze()
  A.is_not_nil(result.current_function,
    "current_function must be detected despite complex nested declarators")
  A.equal("callback", result.current_function.name,
    "function name must be 'callback' even with nested function_declarator/pointer_declarator wrappers")
  A.equal(1, result.current_function.range[1], "range start line = 1 (1-based)")
  A.equal(3, result.current_function.range[2], "range end line = 3 (1-based closed)")
end

--------------------------------------------------------------------------------
-- Test 10: Cross-file reference — caller and definition in separate files.
--
-- math.h:  int add(int, int);                (declaration)
-- math.c:  int add(int a, int b) { return a+b; }   (definition, cursor here)
-- main.c:  #include "math.h"
--          void run() { add(1,2); }
--
-- Cursor on `add` definition in math.c (line 1, col 4).
-- Expect: callers contains `run` from main.c with correct call_position.
--------------------------------------------------------------------------------
function M.test_c_cross_file_caller_resolution()
  -- Tree for math.c (cursor file).
  local math_c_tree = TB.tree({
    type = "translation_unit", range = {0,0,2,0}, children = {
      { type = "preproc_include", range = {0,0,0,18}, children = {} },
      { type = "function_definition", range = {1,0,1,34}, children = {
        { type = "primitive_type", range = {1,0,1,3}, text = "int" },
        { type = "function_declarator", range = {1,4,1,20}, children = {
          { type = "identifier", range = {1,4,1,7}, text = "add" },
          { type = "parameter_list", range = {1,7,1,20}, children = {} },
        }},
        { type = "compound_statement", range = {1,22,1,34}, children = {
          { type = "return_statement", range = {1,24,1,33}, text = "return a+b;" },
        }},
      }},
    },
  })

  -- Tree for main.c (the caller file).
  local main_source = '#include "math.h"\nvoid run() { add(1,2); }\n'
  local main_tree = TB.tree({
    type = "translation_unit", range = {0,0,2,0}, children = {
      { type = "preproc_include", range = {0,0,0,18}, children = {} },
      { type = "function_definition", range = {1,0,1,24}, children = {
        { type = "primitive_type", range = {1,0,1,4}, text = "void" },
        { type = "function_declarator", range = {1,5,1,9}, children = {
          { type = "identifier", range = {1,5,1,8}, text = "run" },
          { type = "parameter_list", range = {1,8,1,9}, children = {} },
        }},
        { type = "compound_statement", range = {1,10,1,24}, children = {
          { type = "expression_statement", range = {1,12,1,21}, children = {
            { type = "call_expression", range = {1,12,1,21}, children = {
              { type = "identifier", range = {1,12,1,15}, text = "add" },
              { type = "argument_list", range = {1,15,1,21}, children = {} },
            }},
          }},
        }},
      }},
    },
  })

  local math_c_uri = utils.path_to_uri("/project/math.c")
  local math_h_uri = utils.path_to_uri("/project/math.h")
  local main_uri   = utils.path_to_uri("/project/main.c")

  local s = Scenario.new()
    :with_code('#include "math.h"\nint add(int a, int b) { return a+b; }\n')
    :with_cursor(1, 4)  -- on "add" definition in math.c
    :with_language("c")
    :with_tree(math_c_tree:root())
    :with_file("/project/math.c")
    :with_cwd("/project")
    :with_symbols(math_c_uri, {
      mocks.symbol("add", LSP_FUNCTION, 1, 4, 1, 34),
    })
    -- LSP definition returns BOTH the declaration (math.h) and definition (math.c).
    :with_definition(math_c_uri, { line = 1, character = 4 }, {
      mocks.loc(math_h_uri, 0, 4, 0, 7),   -- declaration in math.h
      mocks.loc(math_c_uri, 1, 4, 1, 34),  -- definition in math.c
    })
    :with_declaration(math_c_uri, { line = 1, character = 4 }, {
      mocks.loc(math_h_uri, 0, 4, 0, 7),
    })
    -- References include: math.h declaration (excluded),
    -- math.c definition (excluded), main.c call (kept).
    :with_references(math_c_uri, { line = 1, character = 4 }, {
      mocks.loc(math_h_uri, 0, 4, 0, 7),    -- declaration (excluded)
      mocks.loc(math_c_uri, 1, 4, 1, 7),    -- definition (excluded)
      mocks.loc(main_uri,   1, 12, 1, 15),  -- call from main.c run()
    }, true)
    :with_file_content("/project/main.c", main_source)
    :with_tree_for_source(main_source, main_tree:root())

  local result = s:analyze()
  A.is_not_nil(result.current_function)
  A.equal("add", result.current_function.name)
  A.equal("/project/math.c", result.current_function.file)
  A.length(1, result.callers, "exactly one caller (run from main.c)")
  local caller = result.callers[1]
  A.equal("run", caller.caller_function.name,
    "caller should be 'run' from main.c")
  A.equal("/project/main.c", caller.file, "caller file should be main.c")
  -- call_position is 1-based: original 0-based (1, 12) -> (2, 13).
  A.equal(2, caller.call_position.line, "call line 0->1 +1 = 2")
  A.equal(13, caller.call_position.character, "call col 12+1 = 13")
end

return M
