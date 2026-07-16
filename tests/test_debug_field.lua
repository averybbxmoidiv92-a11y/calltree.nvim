--- tests/test_debug_field.lua — verify the `debug` field is always present
--- and populated with comprehensive diagnostics.
---
--- The spec requires the `debug` field in EVERY result, success or failure.
--- We check:
---   - Empty results (precondition failures) still carry `debug`.
---   - Empty results (cursor not on function name) carry `debug` with a reason.
---   - Full results carry `debug` with summary counts matching the lists.
---   - The debug trace records each LSP call and each per-item decision.

local Scenario = require("scenario")
local mocks    = require("mocks")
local TB       = require("tree_builder")
local A        = require("assert")
local utils    = require("calltree.utils")

local M = {}

--------------------------------------------------------------------------------
-- Helper: assert that `t` has the structure of a debug field.
--------------------------------------------------------------------------------
local function assert_debug_shape(d)
  A.is_not_nil(d, "debug field must be present")
  A.is_not_nil(d.inputs, "debug.inputs must be present")
  A.is_not_nil(d.preconditions, "debug.preconditions must be present")
  A.is_not_nil(d.cursor_detection, "debug.cursor_detection must be present")
  A.is_not_nil(d.lsp_calls, "debug.lsp_calls must be present")
  A.is_not_nil(d.ts_parses, "debug.ts_parses must be present")
  A.is_not_nil(d.caller_decisions, "debug.caller_decisions must be present")
  A.is_not_nil(d.external_call_decisions, "debug.external_call_decisions must be present")
  A.is_not_nil(d.summary, "debug.summary must be present")
  A.is_not_nil(d.timings, "debug.timings must be present")
  A.is_not_nil(d.completion_reason, "debug.completion_reason must be present")
  A.is_not_nil(d.version, "debug.version must be present")
end

--------------------------------------------------------------------------------
-- 1. Empty result from missing treesitter object — debug still present.
--------------------------------------------------------------------------------
function M.test_debug_present_when_preconditions_fail()
  local analyzer = require("calltree.core.analyzer")
  local lsp = mocks.new_lsp_client()
  local uri = utils.path_to_uri("/project/test.lua")
  lsp:define_symbols(uri, { mocks.symbol("foo", utils.LSP_SYMBOL_FUNCTION, 0,0,1,0) })
  local ctx = {
    source_code = "function foo() end\n",
    file_path = "/project/test.lua",
    cursor_pos = { line = 0, character = 9 },
    language = "lua",
    lsp_client = lsp,
    treesitter = nil,
    getcwd = function() return "/project" end,
  }
  local result = analyzer.analyze(ctx)
  A.is_nil(result.current_function)
  A.is_not_nil(result.debug, "debug field must be present even when preconditions fail")
  assert_debug_shape(result.debug)
  A.equal("preconditions_failed", result.debug.completion_reason)
  -- At least one precondition entry should record the failure.
  local found_ts_failure = false
  for _, p in ipairs(result.debug.preconditions) do
    if not p.passed and p.check:match("treesitter") then
      found_ts_failure = true
      break
    end
  end
  A.truthy(found_ts_failure, "should record the treesitter precondition failure")
end

--------------------------------------------------------------------------------
-- 2. Empty result from empty document symbols — debug records the cause.
--------------------------------------------------------------------------------
function M.test_debug_records_empty_symbols()
  local tree = TB.tree({
    type = "program", range = {0,0,1,0}, children = {
      { type = "function", range = {0,0,0,17}, children = {
        { type = "identifier", range = {0,9,0,12}, text = "foo" },
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
    -- No symbols registered -> document_symbols returns {} -> precondition fails
  local result = s:analyze()
  A.is_nil(result.current_function)
  A.is_not_nil(result.debug)
  A.equal("preconditions_failed", result.debug.completion_reason)
  -- Find the document_symbols precondition entry.
  local found = false
  for _, p in ipairs(result.debug.preconditions) do
    if p.check == "lsp.document_symbols" and not p.passed then
      found = true
      A.equal("empty symbol list", p.detail)
      break
    end
  end
  A.truthy(found, "should record the empty-symbols precondition failure with detail")
end

--------------------------------------------------------------------------------
-- 3. Empty result from cursor not on function name — debug records reason.
--------------------------------------------------------------------------------
function M.test_debug_records_cursor_rejection()
  local tree = TB.tree({
    type = "module", range = {0,0,4,0}, children = {
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
    :with_cursor(3, 4)  -- on the call site `foo()` (NOT a function name)
    :with_language("python")
    :with_tree(tree:root())
    :with_file("/project/test.py")
    :with_symbols(uri, {
      mocks.symbol("foo", utils.LSP_SYMBOL_FUNCTION, 0, 4, 1, 8),
      mocks.symbol("bar", utils.LSP_SYMBOL_FUNCTION, 2, 4, 4, 8),
    })
  local result = s:analyze()
  A.is_nil(result.current_function)
  A.is_not_nil(result.debug)
  A.equal("cursor_not_on_function_name", result.debug.completion_reason)
  A.is_not_nil(result.debug.cursor_detection.reason,
    "cursor_detection.reason must be set when cursor is rejected")
  A.truthy(result.debug.cursor_detection.node_at_cursor,
    "cursor_detection.node_at_cursor must be set")
end

--------------------------------------------------------------------------------
-- 4. Full analysis result — debug has summary counts matching the lists.
--------------------------------------------------------------------------------
function M.test_debug_summary_counts_on_full_result()
  -- Two callers (c1, c2) call foo; foo calls two external functions (bar, baz).
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
    :with_tree_for_source("function bar() end\n", bar_tree:root())
    :with_tree_for_source("function baz() end\n", baz_tree:root())
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
    :with_definition(uri, { line = 1, character = 4 }, {
      mocks.loc(bar_uri, 0, 9, 0, 12),
    })
    :with_definition(uri, { line = 2, character = 4 }, {
      mocks.loc(baz_uri, 0, 9, 0, 12),
    })

  local result = s:analyze()
  A.is_not_nil(result.current_function)
  A.is_not_nil(result.debug)
  assert_debug_shape(result.debug)
  A.equal("analyzed", result.debug.completion_reason)

  -- Summary counts must match the actual lists.
  A.equal(2, result.debug.summary.callers_kept,
    "summary.callers_kept must equal #callers")
  A.equal(2, result.debug.summary.calls_kept,
    "summary.calls_kept must equal #external_calls")
  A.equal(2, #result.callers)
  A.equal(2, #result.external_calls)

  -- Total refs = 3 (foo def + c1 call + c2 call).
  A.equal(3, result.debug.summary.total_refs)
  -- 1 ref excluded as def/decl (the foo definition itself).
  A.equal(1, result.debug.summary.refs_excluded_defdecl)

  -- 2 external calls total (bar + baz).
  A.equal(2, result.debug.summary.total_calls)

  -- Each caller decision should have an "outcome".
  for _, d in ipairs(result.debug.caller_decisions) do
    A.is_not_nil(d.outcome, "every caller decision must have an outcome")
  end
  -- Each external call decision should have an outcome.
  for _, d in ipairs(result.debug.external_call_decisions) do
    A.is_not_nil(d.outcome, "every external call decision must have an outcome")
  end

  -- LSP calls should include at least: document_symbols, definition (cursor),
  -- references, definition (bar call), definition (baz call).
  local lsp_methods = {}
  for _, c in ipairs(result.debug.lsp_calls) do
    table.insert(lsp_methods, c.method)
  end
  -- At least 4 definition calls + 1 references + 1 documentSymbol.
  local def_count = 0
  for _, m in ipairs(lsp_methods) do
    if m == "textDocument/definition" then def_count = def_count + 1 end
  end
  -- Strengthen: previously `A.truthy(def_count >= 3, ...)` only checked
  -- the lower bound. With the scenario above (1 cursor def + 2 call defs),
  -- the exact expected count is 3 — assert equality so a future change
  -- that accidentally issues extra or fewer definition requests surfaces
  -- here rather than silently passing.
  A.equal(3, def_count, "should have exactly 3 definition calls (cursor + 2 calls)")
end

--------------------------------------------------------------------------------
-- 5. Debug records the reason when a caller is rejected as self-recursive.
--------------------------------------------------------------------------------
function M.test_debug_records_self_recursive_caller()
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
      mocks.loc(uri, 1, 4, 1, 8),
    }, true)

  local result = s:analyze()
  A.length(0, result.callers, "self-recursive caller must be discarded")
  A.equal(1, result.debug.summary.refs_self_recursive,
    "summary should record 1 self-recursive ref")
  -- Find the self-recursive decision and verify its reason.
  local found = false
  for _, d in ipairs(result.debug.caller_decisions) do
    if d.outcome == "self_recursive" then
      found = true
      A.is_not_nil(d.reason, "self_recursive decision must have a reason")
      break
    end
  end
  A.truthy(found, "should have a caller_decision with outcome=self_recursive")
end

--------------------------------------------------------------------------------
-- 6. Debug records the reason when an external call is outside-project.
-- New behavior: outside-project calls are kept as external-crate calls
-- (outcome="kept_external_crate", is_stdlib=false) rather than discarded.
-- The summary counter calls_outside_project is still incremented so
-- callers can detect "this call went out of the project".
--------------------------------------------------------------------------------
function M.test_debug_records_outside_project_call()
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
  local ext_uri = utils.path_to_uri("/usr/lib/somelib.lua")
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
    :with_definition(uri, { line = 1, character = 4 }, {
      mocks.loc(ext_uri, 0, 0, 0, 3),
    })

  local result = s:analyze()
  -- New behavior: external-crate calls are KEPT, not discarded.
  A.length(1, result.external_calls, "outside-project call is kept as external-crate")
  A.equal(1, result.debug.summary.calls_outside_project,
    "calls_outside_project counter is still incremented")
  local found = false
  for _, d in ipairs(result.debug.external_call_decisions) do
    if d.outcome == "kept_external_crate" then
      found = true
      A.is_not_nil(d.reason)
      A.equal(false, d.in_project)
      break
    end
  end
  A.truthy(found, "should have an external_call_decision with outcome=kept_external_crate")
end

--------------------------------------------------------------------------------
-- 7. Debug records unresolved status for external calls with no LSP definition.
--------------------------------------------------------------------------------
function M.test_debug_records_unresolved_call()
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
    :with_definition(uri, { line = 1, character = 4 }, {})

  local result = s:analyze({ skip_stdlib_calls = false, deduplicate_external_calls = false })
  A.length(1, result.external_calls)
  A.equal(1, result.debug.summary.calls_unresolved)
  local found = false
  for _, d in ipairs(result.debug.external_call_decisions) do
    if d.outcome == "kept_unresolved" then
      found = true
      A.is_not_nil(d.reason)
      break
    end
  end
  A.truthy(found, "should have an external_call_decision with outcome=kept_unresolved")
end

--------------------------------------------------------------------------------
-- 8. Debug timings should be present and non-negative.
--------------------------------------------------------------------------------
function M.test_debug_timings_present()
  local tree = TB.tree({
    type = "program", range = {0,0,2,0}, children = {
      { type = "function", range = {0,0,0,17}, children = {
        { type = "identifier", range = {0,9,0,12}, text = "foo" },
        { type = "block", range = {0,15,0,17}, children = {} },
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
    :with_symbols(uri, {
      mocks.symbol("foo", utils.LSP_SYMBOL_FUNCTION, 0, 9, 0, 12),
    })
    :with_definition(uri, { line = 0, character = 9 }, {
      mocks.loc(uri, 0, 9, 0, 12),
    })
    :with_references(uri, { line = 0, character = 9 }, {
      mocks.loc(uri, 0, 9, 0, 12),
    }, true)
  local result = s:analyze()
  A.is_not_nil(result.debug.timings.total_seconds)
  A.truthy(result.debug.timings.total_seconds >= 0, "total_seconds should be non-negative")
  -- Upper bound: a single analyze call should never take more than 60
  -- seconds (even on a slow CI box, the mock-LSP scenario above completes
  -- in milliseconds). Adding the upper bound catches accidental
  -- infinite-loop / O(n²) regressions that the >= 0 check would miss.
  A.truthy(result.debug.timings.total_seconds <= 60,
    "total_seconds should be <= 60 (sanity upper bound)")
  A.truthy(result.debug.timings.preconditions_seconds >= 0)
end

--------------------------------------------------------------------------------
-- 9. Debug inputs snapshot.
--------------------------------------------------------------------------------
function M.test_debug_inputs_snapshot()
  local tree = TB.tree({
    type = "program", range = {0,0,2,0}, children = {
      { type = "function", range = {0,0,0,17}, children = {
        { type = "identifier", range = {0,9,0,12}, text = "foo" },
        { type = "block", range = {0,15,0,17}, children = {} },
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
  local result = s:analyze()
  A.equal("/project/test.lua", result.debug.inputs.file_path)
  A.equal("lua", result.debug.inputs.language)
  A.equal(0, result.debug.inputs.cursor_pos.line)
  A.equal(9, result.debug.inputs.cursor_pos.character)
  A.equal("/project", result.debug.inputs.cwd)
  A.is_not_nil(result.debug.inputs.source_line_count)
  A.is_not_nil(result.debug.inputs.source_size_bytes)
end

return M
