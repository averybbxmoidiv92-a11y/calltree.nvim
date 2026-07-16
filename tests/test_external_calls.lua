--- tests/test_external_calls.lua — cross-function calls (external_calls) cases.
---
--- Covers:
---   d1. Call to a top-level function in another file of the project -> resolved.
---   d2. Call to an external-project file -> discarded (path not under getcwd).
---   d3. Call to a local nested function -> discarded (in-scope).
---   d4. LSP definition tags contain "system" -> is_stdlib = true.
---   d5. Call to a declaration-only function (e.g. extern) -> discarded.
---   d6. LSP cannot jump to definition (returns nil/empty) -> unresolved.
---   d7. Complex call expressions (obj:method, module.sub.func) -> full text kept.

local Scenario = require("scenario")
local mocks    = require("mocks")
local TB       = require("tree_builder")
local A        = require("assert")
local utils    = require("calltree.utils")

-- Centralized stdlib tag string constant. Was a magic string "system"
-- inline at the d4 test (and "system"/"library" also appear in the
-- source external_calls.lua). Using the constant here keeps the test
-- in sync with the source if the tag string ever changes.
local LSP_TAG_SYSTEM = utils.LSP_TAG_STR_SYSTEM  -- "system"

local M = {}

-------------------------------------------------------------------------------
-- d1: call another top-level function in a different file of the same project.
-------------------------------------------------------------------------------
function M.test_call_to_other_project_file()
  -- File under test:
  --   function foo()
  --       bar()
  --   end
  -- bar is defined in /project/other.lua at line 0.
  local tree = TB.tree({
    type = "program", range = {0,0,3,0}, children = {
      { type = "function", range = {0,0,2,3}, children = {
        { type = "identifier", range = {0,9,0,12}, text = "foo" },
        { type = "block", range = {1,4,2,3}, children = {
          { type = "call", range = {1,4,1,9}, text = "bar" },
        }},
      }},
    },
  })
  -- bar's file tree (used to extract function body range for the definition).
  local bar_tree = TB.tree({
    type = "program", range = {0,0,2,0}, children = {
      { type = "function", range = {0,0,0,18}, children = {
        { type = "identifier", range = {0,9,0,12}, text = "bar" },
        { type = "block", range = {0,15,0,18}, children = {} },
      }},
    },
  })

  local uri = utils.path_to_uri("/project/main.lua")
  local bar_uri = utils.path_to_uri("/project/other.lua")
  local s = Scenario.new()
    :with_code("function foo()\n    bar()\nend\n")
    :with_cursor(0, 9)  -- on `foo` name
    :with_language("lua")
    :with_tree(tree:root())
    :with_file("/project/main.lua")
    :with_cwd("/project")
    :with_file_content("/project/other.lua", "function bar() end\n")
    :with_tree_for_source("function bar() end\n", bar_tree:root())
    :with_symbols(uri, {
      mocks.symbol("foo", utils.LSP_SYMBOL_FUNCTION, 0, 9, 0, 12),
    })
    :with_definition(uri, { line = 0, character = 9 }, {
      mocks.loc(uri, 0, 9, 0, 12),
    })
    :with_references(uri, { line = 0, character = 9 }, {
      mocks.loc(uri, 0, 9, 0, 12),
    }, true)
    -- LSP definition for the call to `bar` at line 1, char 4
    :with_definition(uri, { line = 1, character = 4 }, {
      mocks.loc(bar_uri, 0, 9, 0, 12),
    })

  local result = s:analyze()
  A.is_not_nil(result.current_function)
  A.equal("foo", result.current_function.name)
  A.length(1, result.external_calls, "exactly one external call (bar)")
  local ec = result.external_calls[1]
  A.equal("bar", ec.function_name)
  A.equal("resolved", ec.resolution_status)
  A.is_not_nil(ec.definition)
  A.equal("/project/other.lua", ec.definition.file)
  A.is_not_nil(ec.definition.function_body_range, "function_body_range should be present")
  A.equal(false, ec.is_stdlib, "is_stdlib should be false when no tags")
  -- call_position is 1-based
  A.equal(2, ec.call_position.line, "call line 0->1 +1")
  A.equal(5, ec.call_position.character, "call col 4+1=5")
end

-------------------------------------------------------------------------------
-- d2: call to a file outside the project (path not under getcwd) is
-- kept as an external-crate call (is_stdlib=false). Previously the
-- plugin discarded these silently; the behavior was changed so that
-- third-party crate calls (Rust serde_json, etc.) remain visible in
-- external_calls. The call is kept with is_stdlib=false and
-- resolution_status="resolved".
-------------------------------------------------------------------------------
function M.test_call_outside_project_discarded()
  local tree = TB.tree({
    type = "program", range = {0,0,3,0}, children = {
      { type = "function", range = {0,0,2,3}, children = {
        { type = "identifier", range = {0,9,0,12}, text = "foo" },
        { type = "block", range = {1,4,2,3}, children = {
          { type = "call", range = {1,4,1,9}, text = "bar" },
        }},
      }},
    },
  })
  local uri = utils.path_to_uri("/project/main.lua")
  local ext_uri = utils.path_to_uri("/usr/lib/somelib.lua")
  local s = Scenario.new()
    :with_code("function foo()\n    bar()\nend\n")
    :with_cursor(0, 9)
    :with_language("lua")
    :with_tree(tree:root())
    :with_file("/project/main.lua")
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
    :with_definition(uri, { line = 1, character = 4 }, {
      mocks.loc(ext_uri, 0, 0, 0, 3),
    })

  local result = s:analyze()
  A.is_not_nil(result.current_function)
  -- New behavior: external-crate calls are kept (not discarded) so users
  -- can see "you're calling out to somelib.lua here". The call has
  -- is_stdlib=false and resolution_status="resolved".
  A.length(1, result.external_calls, "external-crate call must be kept")
  -- Previously the assertions below were wrapped in `if #result.external_calls
  -- == 1 then`, which silently passed when the list was empty — masking
  -- regressions where the call was wrongly discarded. The A.length above
  -- already guarantees length==1, so we unwrap and also add a decision-
  -- outcome assertion to verify the call was classified as kept_external_crate.
  local ec = result.external_calls[1]
  A.is_not_nil(ec, "ec must be present (length already asserted == 1)")
  A.equal(false, ec.is_stdlib, "is_stdlib must be false for non-stdlib external crate")
  A.equal("resolved", ec.resolution_status, "resolution_status must be resolved")
  -- Decision-outcome assertion: verify the analyzer actually classified this
  -- as kept_external_crate (not e.g. kept_resolved or kept_stdlib). Requires
  -- debug to be present (default debug=true).
  A.is_not_nil(result.debug, "debug must be present (default debug=true)")
  local found_external_crate = false
  if result.debug.external_call_decisions then
    for _, d in ipairs(result.debug.external_call_decisions) do
      if d.outcome == "kept_external_crate" then
        found_external_crate = true
        break
      end
    end
  end
  A.truthy(found_external_crate,
    "debug should record an external_call_decision with outcome=kept_external_crate")
end

-------------------------------------------------------------------------------
-- d3: call to a local nested function -> discarded (in lexical scope).
-------------------------------------------------------------------------------
function M.test_call_to_local_nested_function_discarded()
  local tree = TB.tree({
    type = "program", range = {0,0,5,0}, children = {
      { type = "function", range = {0,0,4,3}, children = {
        { type = "identifier", range = {0,9,0,12}, text = "foo" },
        { type = "block", range = {1,4,4,3}, children = {
          -- local function inner() end
          { type = "function", range = {1,4,1,30}, children = {
            { type = "identifier", range = {1,13,1,18}, text = "inner" },
            { type = "block", range = {1,21,1,30}, children = {} },
          }},
          -- inner()  <- call to local nested function
          { type = "call", range = {2,4,2,10}, text = "inner" },
        }},
      }},
    },
  })
  local uri = utils.path_to_uri("/project/test.lua")
  local s = Scenario.new()
    :with_code("function foo()\n    local function inner() end\n    inner()\nend\n")
    :with_cursor(0, 9)
    :with_language("lua")
    :with_tree(tree:root())
    :with_file("/project/test.lua")
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
    -- LSP says the call to `inner` resolves to a definition INSIDE foo's body.
    :with_definition(uri, { line = 2, character = 4 }, {
      mocks.loc(uri, 1, 13, 1, 18),  -- inside foo's range
    })

  local result = s:analyze()
  A.length(0, result.external_calls, "call to local nested function must be discarded")
end

-------------------------------------------------------------------------------
-- d4: LSP definition tags contain "system" -> is_stdlib = true.
-------------------------------------------------------------------------------
function M.test_call_to_stdlib_function()
  -- Construct the s2 scenario directly (the previously-unused `s` scenario
  -- and `stdlib_tree` construction code have been removed).
  local uri = utils.path_to_uri("/project/test.lua")

  -- Register a function at line 5 with a body in our tree so it has a body.
  -- Rebuild the tree to include a print function definition at line 5.
  local tree_with_print = TB.tree({
    type = "program", range = {0,0,8,0}, children = {
      { type = "function", range = {0,0,2,3}, children = {
        { type = "identifier", range = {0,9,0,12}, text = "foo" },
        { type = "block", range = {1,4,2,3}, children = {
          { type = "call", range = {1,4,1,11}, text = "print" },
        }},
      }},
      { type = "function", range = {5,0,7,3}, children = {
        { type = "identifier", range = {5,9,5,14}, text = "print" },
        { type = "block", range = {6,4,7,3}, children = {} },
      }},
    },
  })
  -- Replace the scenario's tree by creating a fresh scenario with the new tree.
  local s2 = Scenario.new()
    :with_code("function foo()\n    print()\nend\nfunction print()\nend\n")
    :with_cursor(0, 9)
    :with_language("lua")
    :with_tree(tree_with_print:root())
    :with_file("/project/test.lua")
    :with_cwd("/project")
    :with_symbols(uri, {
      mocks.symbol("foo", utils.LSP_SYMBOL_FUNCTION, 0, 9, 0, 12),
      mocks.symbol("print", utils.LSP_SYMBOL_FUNCTION, 5, 9, 5, 14),
    })
    :with_definition(uri, { line = 0, character = 9 }, {
      mocks.loc(uri, 0, 9, 0, 12),
    })
    :with_references(uri, { line = 0, character = 9 }, {
      mocks.loc(uri, 0, 9, 0, 12),
    }, true)
    :with_definition(uri, { line = 1, character = 4 }, {
      mocks.loc(uri, 5, 9, 5, 14, { LSP_TAG_SYSTEM }),
    })

  local result = s2:analyze({ skip_stdlib_calls = false, deduplicate_external_calls = false })
  A.length(1, result.external_calls, "stdlib call should be kept")
  local ec = result.external_calls[1]
  A.equal(true, ec.is_stdlib, "is_stdlib should be true when LSP tags include 'system'")
  A.equal("resolved", ec.resolution_status)
  -- Decision-outcome assertion: verify the analyzer classified this as
  -- kept_stdlib (the stdlib short-circuit path), not kept_resolved.
  A.is_not_nil(result.debug, "debug must be present (default debug=true)")
  local found_stdlib = false
  if result.debug.external_call_decisions then
    for _, d in ipairs(result.debug.external_call_decisions) do
      if d.outcome == "kept_stdlib" then
        found_stdlib = true
        break
      end
    end
  end
  A.truthy(found_stdlib,
    "debug should record an external_call_decision with outcome=kept_stdlib")
end

-------------------------------------------------------------------------------
-- d5: call to a declaration-only function (extern) -> discarded.
-------------------------------------------------------------------------------
function M.test_call_to_declaration_only_discarded()
  -- The "definition" LSP returns points to a node that is NOT a function_definition
  -- (e.g. an `extern` declaration). The analyzer should detect the absence of a body.
  local tree = TB.tree({
    type = "translation_unit", range = {0,0,5,0}, children = {
      -- extern void bar();
      { type = "declaration", range = {0,0,0,18}, children = {
        { type = "function_declarator", range = {0,11,0,16}, children = {
          { type = "identifier", range = {0,11,0,14}, text = "bar" },
        }},
      }},
      -- void foo() { bar(); }
      { type = "function_definition", range = {2,0,2,21}, children = {
        { type = "function_declarator", range = {2,5,2,10}, children = {
          { type = "identifier", range = {2,5,2,8}, text = "foo" },
        }},
        { type = "compound_statement", range = {2,11,2,21}, children = {
          { type = "call_expression", range = {2,12,2,18}, text = "bar" },
        }},
      }},
    },
  })
  local uri = utils.path_to_uri("/project/test.c")
  local s = Scenario.new()
    :with_code("extern void bar();\nvoid foo() { bar(); }\n")
    :with_cursor(2, 5)  -- on `foo` definition name
    :with_language("c")
    :with_tree(tree:root())
    :with_file("/project/test.c")
    :with_cwd("/project")
    :with_symbols(uri, {
      mocks.symbol("foo", utils.LSP_SYMBOL_FUNCTION, 2, 5, 2, 8),
    })
    :with_definition(uri, { line = 2, character = 5 }, {
      mocks.loc(uri, 2, 5, 2, 8),
    })
    :with_references(uri, { line = 2, character = 5 }, {
      mocks.loc(uri, 2, 5, 2, 8),
    }, true)
    -- LSP says call to bar at (2, 12) resolves to a declaration-only node at (0, 11).
    :with_definition(uri, { line = 2, character = 12 }, {
      mocks.loc(uri, 0, 11, 0, 14),
    })

  local result = s:analyze()
  A.length(0, result.external_calls, "call to declaration-only function must be discarded")
end

-------------------------------------------------------------------------------
-- d6: LSP cannot jump to definition (returns nil/empty) -> unresolved.
-------------------------------------------------------------------------------
function M.test_call_unresolved()
  local tree = TB.tree({
    type = "program", range = {0,0,3,0}, children = {
      { type = "function", range = {0,0,2,3}, children = {
        { type = "identifier", range = {0,9,0,12}, text = "foo" },
        { type = "block", range = {1,4,2,3}, children = {
          { type = "call", range = {1,4,1,9}, text = "bar" },
        }},
      }},
    },
  })
  local uri = utils.path_to_uri("/project/test.lua")
  local s = Scenario.new()
    :with_code("function foo()\n    bar()\nend\n")
    :with_cursor(0, 9)
    :with_language("lua")
    :with_tree(tree:root())
    :with_file("/project/test.lua")
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
    -- LSP returns empty for the call to bar.
    :with_definition(uri, { line = 1, character = 4 }, {})

  local result = s:analyze({ skip_stdlib_calls = false, deduplicate_external_calls = false })
  A.length(1, result.external_calls, "unresolved call should still be recorded")
  local ec = result.external_calls[1]
  A.equal("bar", ec.function_name)
  A.equal("unresolved", ec.resolution_status)
  A.is_nil(ec.definition)
  A.is_nil(ec.is_stdlib, "is_stdlib is null when unresolved")
end

-------------------------------------------------------------------------------
-- d7: complex call expressions (obj:method, module.sub.func).
-- function_name should be the full expression text.
-------------------------------------------------------------------------------
function M.test_complex_call_expressions()
  local tree = TB.tree({
    type = "program", range = {0,0,6,0}, children = {
      { type = "function", range = {0,0,5,3}, children = {
        { type = "identifier", range = {0,9,0,12}, text = "foo" },
        { type = "block", range = {1,4,5,3}, children = {
          { type = "call", range = {1,4,1,14}, text = "obj:method" },
          { type = "call", range = {2,4,2,22}, text = "module.sub.func" },
        }},
      }},
    },
  })
  local uri = utils.path_to_uri("/project/test.lua")
  local s = Scenario.new()
    :with_code("function foo()\n    obj:method()\n    module.sub.func()\nend\n")
    :with_cursor(0, 9)
    :with_language("lua")
    :with_tree(tree:root())
    :with_file("/project/test.lua")
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
    -- Both calls unresolved -> function_name must preserve the full text.
    :with_definition(uri, { line = 1, character = 4 }, {})
    :with_definition(uri, { line = 2, character = 4 }, {})

  local result = s:analyze({ skip_stdlib_calls = false, deduplicate_external_calls = false })
  A.length(2, result.external_calls)
  local names = {}
  for _, ec in ipairs(result.external_calls) do
    table.insert(names, ec.function_name)
  end
  -- Order of calls may vary based on tree traversal; sort to compare.
  table.sort(names)
  A.equal("module.sub.func", names[1])
  A.equal("obj:method", names[2])
end

return M
