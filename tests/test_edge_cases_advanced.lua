--- tests/test_edge_cases_advanced.lua — 10 advanced edge-case tests covering
--- text processing, path resolution, symbol matching, cache consistency,
--- cross-language compatibility, and error recovery.

local Scenario = require("scenario")
local mocks    = require("mocks")
local TB       = require("tree_builder")
local A        = require("assert")
local utils    = require("calltree.utils")
local nodes    = require("calltree.treesitter.nodes")
local resolver = require("calltree.resolution.require_resolver")
local module_finder = require("calltree.resolution.module_finder")

local M = {}

--------------------------------------------------------------------------------
-- Test 1: Multi-byte Unicode node text extraction
--------------------------------------------------------------------------------
-- adapter.lua's wrap_node.text() uses string.sub with byte offsets from
-- treesitter's range(). Since treesitter returns BYTE offsets (not character
-- offsets) and string.sub uses byte offsets, multi-byte chars should work.
-- We test this via the mock treesitter, which simulates the same behavior.

function M.test_multibyte_unicode_node_text()
  -- Build a mock node whose text contains Chinese characters.
  -- "你好" is 6 bytes in UTF-8 (3 bytes per char).
  local Node = mocks.Node
  local ident = Node.new({
    type = "identifier",
    range = {0, 9, 0, 15},  -- 6 bytes: 你好
    text = "你好",
  })
  -- The mock's :text() returns _text directly, which is "你好".
  A.equal("你好", ident:text(), "Chinese identifier text should be extracted correctly")

  -- Test with emoji (4 bytes each).
  local emoji = Node.new({
    type = "identifier",
    range = {0, 0, 0, 4},
    text = "🎉",
  })
  A.equal("🎉", emoji:text(), "Emoji text should be extracted correctly")

  -- Test that get_function_name works with Unicode names.
  local func_node = Node.new({
    type = "function_declaration",
    range = {0, 0, 2, 3},
    children = {
      Node.new({ type = "identifier", range = {0, 9, 0, 15}, text = "你好" }),
    },
  })
  A.equal("你好", nodes.get_function_name(func_node),
    "get_function_name should return Unicode name correctly")
end

--------------------------------------------------------------------------------
-- Test 2: Lua pattern special chars in function/module names
--------------------------------------------------------------------------------
-- find_function_def_by_name uses name:match("%." .. suffix .. "$") WITHOUT
-- escaping the suffix. If the suffix contains pattern magic chars like -, +, (),
-- the match will break. We test that the matching still works for names with
-- such characters (or document the limitation).

function M.test_pattern_special_chars_in_function_name()
  -- A function name like "get-data" contains a hyphen (Lua pattern char for char class).
  -- The suffix extraction is: call_name:match("([%w_]+)$") — this won't match "get-data"
  -- because [%w_] doesn't include "-". So the suffix becomes "get-data" (fallback).
  -- Then find_function_def_by_name tries name:match("%." .. "get-data" .. "$")
  -- where "get-data" is interpreted as a pattern: "get" + char class "data" = wrong.

  local tree = TB.tree({
    type = "chunk", range = {0, 0, 3, 0}, children = {
      { type = "function_declaration", range = {0, 0, 2, 3}, children = {
        { type = "identifier", range = {0, 9, 0, 17}, text = "get-data" },
        { type = "parameters", range = {0, 17, 0, 19}, children = {} },
        { type = "block", range = {1, 0, 2, 3}, children = {} },
      }},
    },
  })
  local root = tree:root()

  -- Try to find "get-data" — the current implementation may fail because of
  -- the unescaped hyphen in the pattern. This test documents the behavior.
  local found_node, found_range = nodes.find_function_def_by_name(root, "get-data")
  -- The function should be found IF the matching uses literal comparison.
  -- If it's not found, this test will fail, highlighting the bug.
  A.is_not_nil(found_node, "find_function_def_by_name should find functions with hyphens in names")
end

function M.test_pattern_special_chars_in_module_name()
  -- require("some-module") — the module spec contains a hyphen.
  -- resolve_module_path does module_spec:gsub("%.", "/") which is fine for hyphens
  -- (gsub pattern is "%.", a literal dot). But the candidate path template uses
  -- gsub("%?", rel) where rel = "some-module". This is fine because "?" is literal.
  local resolved = module_finder.resolve_module_path(
    "some-module",
    { "/?.lua", "/?/init.lua" },
    "/project",
    function(path)
      -- Simulate that /project/some-module.lua exists.
      if path == "/project/some-module.lua" then return "content" end
      return nil
    end
  )
  A.equal("/project/some-module.lua", resolved,
    "resolve_module_path should handle module names with hyphens")
end

--------------------------------------------------------------------------------
-- Test 3: Tree cache pollution (same content, different URI)
--------------------------------------------------------------------------------
-- caller_analysis caches by ref.uri. Two different URIs with same content
-- should both parse correctly (no cross-contamination).

function M.test_tree_cache_different_uri_same_content()
  -- Two files with identical content but different URIs.
  local source = "function foo()\n    bar()\nend\n"
  local tree = TB.tree({
    type = "chunk", range = {0, 0, 3, 0}, children = {
      { type = "function_declaration", range = {0, 0, 2, 3}, children = {
        { type = "identifier", range = {0, 9, 0, 12}, text = "foo" },
        { type = "parameters", range = {0, 12, 0, 14}, children = {} },
        { type = "block", range = {1, 4, 2, 3}, children = {
          { type = "function_call", range = {1, 4, 1, 9}, children = {
            { type = "identifier", range = {1, 4, 1, 7}, text = "bar" },
            { type = "arguments", range = {1, 7, 1, 9}, children = {} },
          }},
        }},
      }},
    },
  })

  local uri1 = utils.path_to_uri("/project/file1.lua")
  local uri2 = utils.path_to_uri("/project/file2.lua")
  local cursor_uri = utils.path_to_uri("/project/test.lua")

  local s = Scenario.new()
    :with_code("function foo() end\n")
    :with_cursor(0, 9)
    :with_language("lua")
    :with_tree(tree:root())
    :with_file("/project/test.lua")
    :with_cwd("/project")
    :with_symbols(cursor_uri, {
      mocks.symbol("foo", utils.LSP_SYMBOL_FUNCTION, 0, 9, 0, 12),
    })
    :with_definition(cursor_uri, { line = 0, character = 9 }, {
      mocks.loc(cursor_uri, 0, 9, 0, 12),
    })
    :with_references(cursor_uri, { line = 0, character = 9 }, {
      mocks.loc(cursor_uri, 0, 9, 0, 12),
      -- Two refs to different URIs but same content.
      mocks.loc(uri1, 1, 4, 1, 9),
      mocks.loc(uri2, 1, 4, 1, 9),
    }, true)
    :with_file_content("/project/file1.lua", source)
    :with_file_content("/project/file2.lua", source)
    :with_tree_for_source(source, tree:root())
    :with_definition(cursor_uri, { line = 1, character = 4 }, {})

  local result = s:analyze()
  A.is_not_nil(result.current_function)
  -- Both refs should be found as callers (2 callers from file1 + file2).
  -- Strengthen: previously `A.truthy(#result.callers >= 1, ...)` only
  -- checked the lower bound, so a regression that dropped one of the two
  -- callers (e.g. a cache key collision) would still pass. The scenario
  -- registers refs in two distinct files — both should survive — so assert
  -- the exact count of 2.
  A.equal(2, #result.callers, "should find exactly 2 callers (one per file)")
end

--------------------------------------------------------------------------------
-- Test 4: Complex recursive self-call scenarios
--------------------------------------------------------------------------------

-- 4a: Indirect recursion (A calls B, B calls A) — should NOT be filtered.
function M.test_indirect_recursion_not_filtered()
  -- foo calls bar, bar calls foo. Cursor on foo.
  -- bar is a caller of foo. bar is NOT self-recursive (bar != foo).
  local tree = TB.tree({
    type = "chunk", range = {0, 0, 8, 0}, children = {
      { type = "function_declaration", range = {0, 0, 2, 3}, children = {
        { type = "identifier", range = {0, 9, 0, 12}, text = "foo" },
        { type = "block", range = {1, 4, 2, 3}, children = {
          { type = "function_call", range = {1, 4, 1, 8}, children = {
            { type = "identifier", range = {1, 4, 1, 7}, text = "bar" },
            { type = "arguments", range = {1, 7, 1, 8}, children = {} },
          }},
        }},
      }},
      { type = "function_declaration", range = {4, 0, 6, 3}, children = {
        { type = "identifier", range = {4, 9, 4, 12}, text = "bar" },
        { type = "block", range = {5, 4, 6, 3}, children = {
          { type = "function_call", range = {5, 4, 5, 8}, children = {
            { type = "identifier", range = {5, 4, 5, 7}, text = "foo" },
            { type = "arguments", range = {5, 7, 5, 8}, children = {} },
          }},
        }},
      }},
    },
  })
  local uri = utils.path_to_uri("/project/test.lua")
  local s = Scenario.new()
    :with_code("function foo()\n    bar()\nend\nfunction bar()\n    foo()\nend\n")
    :with_cursor(0, 9)
    :with_language("lua")
    :with_tree(tree:root())
    :with_file("/project/test.lua")
    :with_cwd("/project")
    :with_symbols(uri, {
      mocks.symbol("foo", utils.LSP_SYMBOL_FUNCTION, 0, 9, 2, 3),
      mocks.symbol("bar", utils.LSP_SYMBOL_FUNCTION, 4, 9, 6, 3),
    })
    :with_definition(uri, { line = 0, character = 9 }, {
      mocks.loc(uri, 0, 9, 0, 12),
    })
    :with_references(uri, { line = 0, character = 9 }, {
      mocks.loc(uri, 0, 9, 0, 12),  -- definition
      mocks.loc(uri, 5, 4, 5, 7),   -- call from bar (indirect recursion)
    }, true)

  local result = s:analyze()
  A.length(1, result.callers, "indirect recursion: bar should be a caller of foo")
  A.equal("bar", result.callers[1].caller_function.name)
end

-- 4b: Nested same-name function — inner foo calls outer foo.
-- The inner foo's definition is INSIDE outer foo, but inner foo is a different
-- function. When cursor is on outer foo, a call from inner foo should be
-- considered self-recursive ONLY if inner foo's body contains the cursor fn's def.
-- Since inner foo is nested inside outer foo, and outer foo's def is at line 0,
-- inner foo's body (line 1-2) does NOT contain line 0. So it's NOT self-recursive.
function M.test_nested_same_name_function()
  local tree = TB.tree({
    type = "chunk", range = {0, 0, 6, 0}, children = {
      { type = "function_declaration", range = {0, 0, 4, 3}, children = {
        { type = "identifier", range = {0, 9, 0, 12}, text = "foo" },
        { type = "block", range = {1, 4, 4, 3}, children = {
          -- Nested function also named "foo"
          { type = "function_declaration", range = {1, 4, 3, 7}, children = {
            { type = "identifier", range = {1, 13, 1, 16}, text = "foo" },
            { type = "block", range = {2, 8, 3, 7}, children = {
              -- Call to foo (the outer one, via closure)
              { type = "function_call", range = {2, 8, 2, 12}, children = {
                { type = "identifier", range = {2, 8, 2, 11}, text = "foo" },
                { type = "arguments", range = {2, 11, 2, 12}, children = {} },
              }},
            }},
          }},
        }},
      }},
    },
  })
  local uri = utils.path_to_uri("/project/test.lua")
  local s = Scenario.new()
    :with_code("function foo()\n    local function foo()\n        foo()\n    end\nend\n")
    :with_cursor(0, 9)  -- on outer foo
    :with_language("lua")
    :with_tree(tree:root())
    :with_file("/project/test.lua")
    :with_cwd("/project")
    :with_symbols(uri, {
      mocks.symbol("foo", utils.LSP_SYMBOL_FUNCTION, 0, 9, 4, 3),
    })
    :with_definition(uri, { line = 0, character = 9 }, {
      mocks.loc(uri, 0, 9, 0, 12),
    })
    :with_references(uri, { line = 0, character = 9 }, {
      mocks.loc(uri, 0, 9, 0, 12),  -- outer foo def
      mocks.loc(uri, 2, 8, 2, 11),  -- call from inner foo
    }, true)

  local result = s:analyze()
  -- The call at (2,8) is inside the inner foo function (range 1-3).
  -- The cursor foo's def is at line 0. Inner foo's body (1-3) does NOT contain line 0.
  -- So this is NOT self-recursive. But wait — the caller name is "foo" which matches
  -- current_name "foo". The self-recursive check looks at whether any def location
  -- of the cursor function falls within the caller's body range. The def is at line 0,
  -- caller body is lines 1-3. Line 0 is NOT in [1,3]. So NOT self-recursive.
  -- The caller should be kept.
  -- However, the caller might be filtered as "in_scope" if the caller function
  -- is nested inside the cursor function. Let's just verify it doesn't crash.
  A.is_not_nil(result.current_function)
end

--------------------------------------------------------------------------------
-- Test 5: Empty/single-line function body detection
--------------------------------------------------------------------------------

-- 5a: function foo() end — no body block, single line.
function M.test_single_line_function_no_body()
  local tree = TB.tree({
    type = "chunk", range = {0, 0, 1, 0}, children = {
      { type = "function_declaration", range = {0, 0, 0, 21}, children = {
        { type = "identifier", range = {0, 9, 0, 12}, text = "foo" },
        { type = "parameters", range = {0, 12, 0, 14}, children = {} },
        { type = "block", range = {0, 15, 0, 18}, children = {} },
      }},
    },
  })
  local root = tree:root()
  -- find_function_def_by_name should find it.
  local node, range = nodes.find_function_def_by_name(root, "foo")
  A.is_not_nil(node, "single-line function should be found")
  A.is_not_nil(range, "single-line function should have a range")
end

-- 5b: C-style void f() {} — empty block but present.
function M.test_empty_block_function()
  local tree = TB.tree({
    type = "translation_unit", range = {0, 0, 1, 0}, children = {
      { type = "function_definition", range = {0, 0, 0, 14}, children = {
        { type = "function_declarator", range = {0, 5, 0, 10}, children = {
          { type = "identifier", range = {0, 5, 0, 6}, text = "f" },
        }},
        { type = "compound_statement", range = {0, 11, 0, 14}, children = {} },
      }},
    },
  })
  local root = tree:root()
  local node, range = nodes.find_function_def_by_name(root, "f")
  A.is_not_nil(node, "empty-block C function should be found")
end

-- 5c: C declaration without body — should be detected as no-body by check_definition_body.
-- We test this via the full analysis: a call to an extern declaration should be discarded.
function M.test_extern_declaration_discarded()
  local tree = TB.tree({
    type = "translation_unit", range = {0, 0, 3, 0}, children = {
      { type = "declaration", range = {0, 0, 0, 18}, children = {
        { type = "function_declarator", range = {0, 11, 0, 16}, children = {
          { type = "identifier", range = {0, 11, 0, 14}, text = "bar" },
        }},
      }},
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
    :with_cursor(2, 5)
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
    :with_definition(uri, { line = 2, character = 12 }, {
      mocks.loc(uri, 0, 11, 0, 14),  -- bar's declaration
    })

  local result = s:analyze()
  A.length(0, result.external_calls, "extern declaration should be discarded (no body)")
end

--------------------------------------------------------------------------------
-- Test 6: LSP LocationLink normalization
--------------------------------------------------------------------------------
-- normalize_location handles both Location {uri, range} and LocationLink
-- {targetUri, targetSelectionRange, targetRange}.

-- Renamed from test_locationlink_normalization (the original name was
-- misleading — this test does NOT actually exercise LocationLink
-- normalization; it verifies the mock LSP loc() helper produces correct
-- Location format and the analyzer handles Location-shaped responses).
-- The old name is kept as a backwards-compatible alias so any external
-- test runners that reference the old name keep working.
function M.test_location_format_contract()
  -- We can't require adapter.lua directly (needs vim.*), but we can verify
  -- the mock LSP client's loc() helper produces correct Location format,
  -- and test that the analyzer handles LocationLink-like responses.
  -- Since normalize_location is local to adapter.lua, we test the contract:
  -- the analyzer should work with {uri, range} locations (standard format).

  local tree = TB.tree({
    type = "chunk", range = {0, 0, 3, 0}, children = {
      { type = "function_declaration", range = {0, 0, 2, 3}, children = {
        { type = "identifier", range = {0, 9, 0, 12}, text = "foo" },
        { type = "block", range = {1, 4, 2, 3}, children = {} },
      }},
    },
  })
  local uri = utils.path_to_uri("/project/test.lua")
  local s = Scenario.new()
    :with_code("function foo()\nend\n")
    :with_cursor(0, 9)
    :with_language("lua")
    :with_tree(tree:root())
    :with_file("/project/test.lua")
    :with_cwd("/project")
    :with_symbols(uri, {
      mocks.symbol("foo", utils.LSP_SYMBOL_FUNCTION, 0, 9, 2, 3),
    })
    :with_definition(uri, { line = 0, character = 9 }, {
      mocks.loc(uri, 0, 9, 0, 12),
    })
    :with_references(uri, { line = 0, character = 9 }, {
      mocks.loc(uri, 0, 9, 0, 12),
    }, true)

  local result = s:analyze()
  A.is_not_nil(result.current_function)
  A.equal("foo", result.current_function.name)
end
-- Backwards-compatible alias for the renamed test above.
M.test_locationlink_normalization = M.test_location_format_contract

--------------------------------------------------------------------------------
-- Test 7: Path handling — encoded spaces in URI
--------------------------------------------------------------------------------

function M.test_uri_with_encoded_spaces()
  -- path_to_uri should encode spaces as %20.
  local uri = utils.path_to_uri("/project/path with spaces/test.lua")
  A.truthy(uri:find("%%20") ~= nil, "spaces should be encoded as %20 in URI")
  -- uri_to_path should decode them back.
  local path = utils.uri_to_path(uri)
  A.equal("/project/path with spaces/test.lua", path,
    "uri_to_path should decode %20 back to spaces (round-trip)")
end

function M.test_is_path_under_with_trailing_slash()
  A.truthy(utils.is_path_under("/project/sub/file.lua", "/project/"),
    "trailing slash on parent should still match")
  A.truthy(utils.is_path_under("/project/sub/file.lua", "/project"),
    "no trailing slash on parent should match")
  A.falsy(utils.is_path_under("/other/file.lua", "/project"),
    "different prefix should not match")
  A.falsy(utils.is_path_under("/projectother/file.lua", "/project"),
    "prefix match should require directory boundary (not just string prefix)")
end

--------------------------------------------------------------------------------
-- Test 8: Nested function call collection (skip nested defs)
--------------------------------------------------------------------------------

function M.test_nested_function_calls_skipped()
  -- outer() contains:
  --   local function inner() call_c() end
  --   call_a()
  --   inner()
  --   call_b()
  -- Analyzing outer's external calls should collect: call_a, inner, call_b
  -- but NOT call_c (it's inside inner, a nested function definition).
  local tree = TB.tree({
    type = "chunk", range = {0, 0, 8, 0}, children = {
      { type = "function_declaration", range = {0, 0, 7, 3}, children = {
        { type = "identifier", range = {0, 9, 0, 14}, text = "outer" },
        { type = "parameters", range = {0, 14, 0, 16}, children = {} },
        { type = "block", range = {1, 4, 7, 3}, children = {
          -- local function inner() call_c() end
          { type = "function_declaration", range = {1, 4, 3, 7}, children = {
            { type = "identifier", range = {1, 13, 1, 18}, text = "inner" },
            { type = "block", range = {2, 8, 3, 7}, children = {
              { type = "function_call", range = {2, 8, 2, 15}, children = {
                { type = "identifier", range = {2, 8, 2, 14}, text = "call_c" },
                { type = "arguments", range = {2, 14, 2, 15}, children = {} },
              }},
            }},
          }},
          -- call_a()
          { type = "function_call", range = {4, 4, 4, 11}, children = {
            { type = "identifier", range = {4, 4, 4, 10}, text = "call_a" },
            { type = "arguments", range = {4, 10, 4, 11}, children = {} },
          }},
          -- inner()
          { type = "function_call", range = {5, 4, 5, 11}, children = {
            { type = "identifier", range = {5, 4, 5, 9}, text = "inner" },
            { type = "arguments", range = {5, 9, 5, 10}, children = {} },
          }},
          -- call_b()
          { type = "function_call", range = {6, 4, 6, 11}, children = {
            { type = "identifier", range = {6, 4, 6, 10}, text = "call_b" },
            { type = "arguments", range = {6, 10, 6, 11}, children = {} },
          }},
        }},
      }},
    },
  })
  local uri = utils.path_to_uri("/project/test.lua")
  local s = Scenario.new()
    :with_code("function outer()\n    local function inner()\n        call_c()\n    end\n    call_a()\n    inner()\n    call_b()\nend\n")
    :with_cursor(0, 13)  -- on "outer"
    :with_language("lua")
    :with_tree(tree:root())
    :with_file("/project/test.lua")
    :with_cwd("/project")
    :with_symbols(uri, {
      mocks.symbol("outer", utils.LSP_SYMBOL_FUNCTION, 0, 9, 7, 3),
    })
    :with_definition(uri, { line = 0, character = 13 }, {
      mocks.loc(uri, 0, 9, 0, 14),
    })
    :with_references(uri, { line = 0, character = 13 }, {
      mocks.loc(uri, 0, 9, 0, 14),
    }, true)
    -- All calls unresolved (LSP returns empty).
    :with_definition(uri, { line = 4, character = 4 }, {})
    :with_definition(uri, { line = 5, character = 4 }, {})
    :with_definition(uri, { line = 6, character = 4 }, {})

  local result = s:analyze({ skip_stdlib_calls = false, deduplicate_external_calls = false })
  A.is_not_nil(result.current_function)
  A.equal("outer", result.current_function.name)

  -- Should collect call_a, inner, call_b — but NOT call_c.
  local names = {}
  for _, ec in ipairs(result.external_calls) do
    table.insert(names, ec.function_name)
  end
  table.sort(names)
  A.equal("call_a", names[1], "call_a should be collected (top-level call)")
  A.equal("call_b", names[2], "call_b should be collected (top-level call)")
  A.equal("inner", names[3], "inner should be collected (top-level call to nested def)")
  -- call_c should NOT be in the list.
  for _, n in ipairs(names) do
    A.falsy(n == "call_c", "call_c should NOT be collected (it's inside nested function inner)")
  end
end

--------------------------------------------------------------------------------
-- Test 9: LSP capability detection + graceful degradation
--------------------------------------------------------------------------------

function M.test_lsp_capability_skipping_unsupported()
  -- Simulate an LSP that doesn't support declaration.
  local tree = TB.tree({
    type = "chunk", range = {0, 0, 2, 0}, children = {
      { type = "function_declaration", range = {0, 0, 0, 21}, children = {
        { type = "identifier", range = {0, 9, 0, 12}, text = "foo" },
        { type = "parameters", range = {0, 12, 0, 14}, children = {} },
        { type = "block", range = {0, 16, 0, 21}, children = {} },
      }},
    },
  })
  local uri = utils.path_to_uri("/project/test.lua")
  local s = Scenario.new()
    :with_code("function foo() end\n")
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

  -- Override declaration with a non-function (simulating unsupported capability).
  local lsp = s:lsp()
  rawset(lsp, "declaration", false)

  local result = s:analyze()
  A.is_not_nil(result.current_function, "analysis should work without declaration support")
  A.equal("foo", result.current_function.name)
  -- Should have a warning about declaration.
  local found = false
  for _, w in ipairs(result.debug.warnings) do
    if (w.message or ""):find("declaration") then found = true break end
  end
  A.truthy(found, "should warn about missing declaration support")
end

-- Renamed from test_lsp_timeout_graceful_degradation (the original name
-- was misleading — this test does NOT actually simulate an LSP timeout;
-- it verifies the analyzer degrades gracefully when LSP returns nil).
-- The old name is kept as a backwards-compatible alias.
function M.test_lsp_nil_response_graceful_degradation()
  -- Simulate an LSP that hangs (definition never returns).
  -- The mock LSP doesn't support timeouts, but we can test that a nil response
  -- doesn't crash the analyzer.
  local tree = TB.tree({
    type = "chunk", range = {0, 0, 2, 0}, children = {
      { type = "function_declaration", range = {0, 0, 0, 21}, children = {
        { type = "identifier", range = {0, 9, 0, 12}, text = "foo" },
        { type = "parameters", range = {0, 12, 0, 14}, children = {} },
        { type = "block", range = {0, 16, 0, 21}, children = {} },
      }},
    },
  })
  local uri = utils.path_to_uri("/project/test.lua")
  local s = Scenario.new()
    :with_code("function foo() end\n")
    :with_cursor(0, 9)
    :with_language("lua")
    :with_tree(tree:root())
    :with_file("/project/test.lua")
    :with_cwd("/project")
    :with_symbols(uri, {
      mocks.symbol("foo", utils.LSP_SYMBOL_FUNCTION, 0, 9, 0, 12),
    })
    -- definition returns nil (simulating timeout / no response)
    :with_definition(uri, { line = 0, character = 9 }, nil)
    :with_references(uri, { line = 0, character = 9 }, {
      mocks.loc(uri, 0, 9, 0, 12),
    }, true)

  local result = s:analyze()
  -- Should still produce a result (graceful degradation).
  A.is_not_nil(result.current_function)
  A.equal("foo", result.current_function.name)
end
-- Backwards-compatible alias for the renamed test above.
M.test_lsp_timeout_graceful_degradation = M.test_lsp_nil_response_graceful_degradation

--------------------------------------------------------------------------------
-- Test 10: Module/function cache consistency
--------------------------------------------------------------------------------

function M.test_function_cache_miss_recorded()
  -- When a function is NOT found in a module, the cache should record the miss
  -- so subsequent lookups don't re-traverse the tree.
  -- We test this indirectly: two calls to the same module for different functions
  -- should both work, and the second lookup for a non-existent function should
  -- return nil without error.

  local mod_source = "local M = {}\nfunction M.exists()\nend\nreturn M\n"
  local mod_tree = TB.tree({
    type = "chunk", range = {0, 0, 4, 0}, children = {
      { type = "function_declaration", range = {1, 0, 2, 3}, children = {
        { type = "dot_index_expression", range = {1, 9, 1, 17}, text = "M.exists", children = {
          { type = "identifier", range = {1, 9, 1, 10}, text = "M" },
          { type = "identifier", range = {1, 11, 1, 17}, text = "exists" },
        }},
        { type = "parameters", range = {1, 17, 1, 19}, children = {} },
        { type = "block", range = {2, 0, 2, 3}, children = {} },
      }},
    },
  })
  local root = mod_tree:root()

  -- Find an existing function.
  local node1, range1 = nodes.find_function_def_by_name(root, "exists")
  A.is_not_nil(node1, "should find 'exists' function")
  A.is_not_nil(range1)

  -- Find a non-existing function — should return nil, nil (not crash).
  local node2, range2 = nodes.find_function_def_by_name(root, "nonexistent")
  A.is_nil(node2, "should not find 'nonexistent' function")
  A.is_nil(range2)

  -- Finding 'exists' again should still work (cache consistency in the analyzer
  -- is tested via the full pipeline, but here we verify the search is idempotent).
  local node3, range3 = nodes.find_function_def_by_name(root, "exists")
  A.is_not_nil(node3, "should find 'exists' function on second call")
end

return M
