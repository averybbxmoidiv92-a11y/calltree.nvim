--- tests/test_module_import_resolution.lua — verify that when the LSP returns
--- a definition location pointing at a variable binding (e.g.
--- `local analyzer = require("calltree.core.analyzer")`) rather than a
--- function-definition node, the call is still treated as RESOLVED (not
--- discarded as "no body").
---
--- This is a regression test for a real-world bug: lua_ls jumps from
--- `analyzer.analyze(ctx)` to the `analyzer` identifier on the require line
--- (line 8), not to the actual `function M.analyze()` definition in another
--- file. The old code discarded this as "no function-definition ancestor
--- found" — but a module import is NOT a bare declaration; it's a valid
--- resolved binding.

local Scenario = require("scenario")
local mocks    = require("mocks")
local TB       = require("tree_builder")
local A        = require("assert")
local utils    = require("calltree.utils")

-- Default package.path templates used by the require-resolution tests.
-- Extracted as a module-level constant (was an inline list literal in
-- test_resolve_module_import_keeps_call) so future tests that need the
-- same set can reference DEFAULT_PACKAGE_PATHS instead of duplicating
-- the four entries (which risked drifting out of sync with
-- module_finder.DEFAULT_PACKAGE_PATHS in the source).
local DEFAULT_PACKAGE_PATHS = {
  "/?.lua",
  "/?/init.lua",
  "/lua/?.lua",
  "/lua/?/init.lua",
}

local M = {}

--------------------------------------------------------------------------------
-- Test 1: `analyzer.analyze(ctx)` where LSP jumps to `local analyzer = require(...)`
-- Should be RESOLVED with null function_body_range (not discarded_no_body).
--------------------------------------------------------------------------------
function M.test_module_import_resolved()
  -- Tree for the cursor function (init.lua):
  --   function M.analyze_at_cursor(bufnr)
  --       local ctx = ...
  --       local result = analyzer.analyze(ctx)   <- call to analyzer.analyze
  --       return result
  --   end
  local init_tree = TB.tree({
    type = "chunk", range = {0, 0, 15, 0}, children = {
      -- Line 8 (0-based 7): local analyzer = require("calltree.core.analyzer")
      { type = "local_declaration", range = {7, 0, 7, 50}, children = {
        { type = "identifier", range = {7, 6, 7, 14}, text = "analyzer" },
        { type = "function_call", range = {7, 17, 7, 50}, children = {
          { type = "identifier", range = {7, 17, 7, 24}, text = "require" },
          { type = "arguments", range = {7, 24, 7, 50}, children = {
            { type = "string", range = {7, 25, 7, 49}, text = '"calltree.call_analyzer"' },
          }},
        }},
      }},
      -- The cursor function:
      { type = "function_declaration", range = {9, 0, 14, 3}, children = {
        { type = "dot_index_expression", range = {9, 9, 9, 28}, children = {
          { type = "identifier", range = {9, 9, 9, 10}, text = "M" },
          { type = "identifier", range = {9, 11, 9, 28}, text = "analyze_at_cursor" },
        }},
        { type = "parameters", range = {9, 28, 9, 35}, children = {} },
        { type = "block", range = {10, 4, 14, 3}, children = {
          -- analyzer.analyze(ctx)
          { type = "function_call", range = {12, 8, 12, 30}, children = {
            { type = "dot_index_expression", range = {12, 8, 12, 25}, text = "analyzer.analyze" },
            { type = "arguments", range = {12, 25, 12, 30}, children = {} },
          }},
        }},
      }},
    },
  })

  local uri = utils.path_to_uri("/project/init.lua")
  local s = Scenario.new()
    :with_code("-- placeholder\n")
    :with_cursor(9, 15)  -- on "analyze_at_cursor"
    :with_language("lua")
    :with_tree(init_tree:root())
    :with_file("/project/init.lua")
    :with_cwd("/project")
    :with_symbols(uri, {
      mocks.symbol("M.analyze_at_cursor", utils.LSP_SYMBOL_FUNCTION, 9, 9, 14, 3),
    })
    :with_definition(uri, { line = 9, character = 15 }, {
      mocks.loc(uri, 9, 9, 9, 28),
    })
    :with_references(uri, { line = 9, character = 15 }, {
      mocks.loc(uri, 9, 9, 9, 28),
    }, true)
    -- LSP definition for `analyzer.analyze` jumps to the `analyzer` identifier
    -- on line 7 (the require line), NOT to the actual function definition.
    :with_definition(uri, { line = 12, character = 8 }, {
      mocks.loc(uri, 7, 6, 7, 14),  -- `analyzer` identifier in `local analyzer = require(...)`
    })

  -- Register the module file that `require("calltree.core.analyzer")` resolves to.
  -- The module contains `function M.analyze()` which is the actual target.
  local mod_source = "local M = {}\nfunction M.analyze()\nend\nreturn M\n"
  local mod_tree = TB.tree({
    type = "chunk", range = {0, 0, 4, 0}, children = {
      { type = "local_declaration", range = {0, 0, 0, 12}, children = {} },
      { type = "function_declaration", range = {1, 0, 2, 3}, children = {
        { type = "dot_index_expression", range = {1, 9, 1, 17}, text = "M.analyze", children = {
          { type = "identifier", range = {1, 9, 1, 10}, text = "M" },
          { type = "identifier", range = {1, 11, 1, 18}, text = "analyze" },
        }},
        { type = "parameters", range = {1, 18, 1, 20}, children = {} },
        { type = "block", range = {2, 0, 2, 3}, children = {} },
      }},
      { type = "return_statement", range = {3, 0, 3, 8}, children = {} },
    },
  })
  -- The module file is at /project/lua/calltree/call_analyzer.lua (standard Neovim path)
  s:with_file_content("/project/lua/calltree/call_analyzer.lua", mod_source)
  s:with_tree_for_source(mod_source, mod_tree:root())

  -- Set package_paths so the resolver can find the module.
  -- We use the Scenario's analyze() which doesn't expose package_paths directly,
  -- so we'll use the analyzer directly instead.
  local analyzer = require("calltree.core.analyzer")
  local ts = s:_build_treesitter()
  local ctx = {
    source_code = s._source_code,
    file_path = s._file_path,
    cursor_pos = s._cursor_pos,
    language = s._language,
    lsp_client = s._lsp,
    treesitter = ts,
    getcwd = function() return s._cwd end,
    read_file = function(path) return s._files[path] end,
    package_paths = {
      "/?.lua",
      "/?/init.lua",
      "/lua/?.lua",
      "/lua/?/init.lua",
    },
  }
  local result = analyzer.analyze(ctx)

  A.is_not_nil(result.current_function)
  A.length(1, result.external_calls, "the analyzer.analyze call should be kept")

  local ec = result.external_calls[1]
  A.equal("analyzer.analyze", ec.function_name)
  A.equal("resolved", ec.resolution_status,
    "module-import call should be RESOLVED, not discarded_no_body")
  A.is_not_nil(ec.definition,
    "definition should be present (resolved)")
  -- After require-resolution, definition.file should point to the MODULE file,
  -- not init.lua.
  A.equal("/project/lua/calltree/call_analyzer.lua", ec.definition.file,
    "definition.file should be the resolved module file, not init.lua")
  A.is_not_nil(ec.definition.function_body_range,
    "function_body_range should be present after require-resolution (not null)")

  -- Verify the debug decision records the require-resolution.
  local d = result.debug.external_call_decisions[1]
  A.equal("kept_resolved", d.outcome)
  A.truthy(d.module_spec == "calltree.call_analyzer",
    "module_spec should be 'calltree.call_analyzer', got: " .. tostring(d.module_spec))
  A.truthy(d.resolved_module_path,
    "resolved_module_path should be set")
end

--------------------------------------------------------------------------------
-- Test 2: `extern void bar();` (bare C declaration) should STILL be discarded
-- as "no body" — we must not regress on real declarations.
--------------------------------------------------------------------------------
function M.test_bare_declaration_still_discarded()
  -- C tree:
  --   extern void bar();                       <- declaration (line 0)
  --   void foo() { bar(); }                    <- foo calls bar (line 2)
  local c_tree = TB.tree({
    type = "translation_unit", range = {0, 0, 3, 0}, children = {
      -- extern void bar();
      { type = "declaration", range = {0, 0, 0, 18}, children = {
        { type = "function_declarator", range = {0, 11, 0, 16}, children = {
          { type = "identifier", range = {0, 11, 0, 14}, text = "bar" },
        }},
      }},
      -- void foo() { bar(); }
      { type = "function_definition", range = {2, 0, 2, 21}, children = {
        { type = "function_declarator", range = {2, 5, 2, 10}, children = {
          { type = "identifier", range = {2, 5, 2, 8}, text = "foo" },
        }},
        { type = "compound_statement", range = {2, 11, 2, 21}, children = {
          { type = "call_expression", range = {2, 12, 2, 18}, children = {
            { type = "identifier", range = {2, 12, 2, 15}, text = "bar" },
          }},
        }},
      }},
    },
  })
  local uri = utils.path_to_uri("/project/test.c")
  local s = Scenario.new()
    :with_code("extern void bar();\nvoid foo() { bar(); }\n")
    :with_cursor(2, 5)  -- on `foo` definition name
    :with_language("c")
    :with_tree(c_tree:root())
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
    -- LSP says call to bar at (2, 12) resolves to the declaration at (0, 11).
    :with_definition(uri, { line = 2, character = 12 }, {
      mocks.loc(uri, 0, 11, 0, 14),
    })

  local result = s:analyze()
  A.length(0, result.external_calls,
    "call to extern declaration must STILL be discarded (no regression)")

  local d = result.debug.external_call_decisions[1]
  A.equal("discarded_no_body", d.outcome,
    "extern declaration should be discarded_no_body, got: " .. tostring(d.outcome))
end

return M
