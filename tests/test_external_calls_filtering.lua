--- tests/test_external_calls_filtering.lua — v1.2.0 post-collection filtering.
---
--- Covers the two new setup() options:
---   - skip_stdlib_calls (default true): drop is_stdlib=true entries
---   - deduplicate_external_calls (default true): drop entries sharing
---     the same (function_name, definition.file) pair
---
--- Processing order is MANDATORY: dedup FIRST (on the full list including
--- stdlib), then stdlib filter (on the deduplicated list). This file
--- exercises both the default-true behavior and the explicit-false
--- opt-out, plus the order-sensitive edge case where a stdlib entry and
--- a project entry share the same (name, file) pair.

local Scenario = require("scenario")
local mocks    = require("mocks")
local TB       = require("tree_builder")
local A        = require("assert")
local utils    = require("calltree.utils")

local LSP_TAG_SYSTEM = utils.LSP_TAG_SYSTEM_LIBRARY or 256

local M = {}

--------------------------------------------------------------------------------
-- Helper: build a scenario with two call sites to the same function.
-- Returns the scenario ready for analyze().
--------------------------------------------------------------------------------
local function _build_two_calls_same_target_scenario()
  local uri = utils.path_to_uri("/project/test.lua")
  -- foo calls bar() twice (at lines 1 and 2). bar is defined at line 4.
  local tree = TB.tree({
    type = "program", range = {0,0,6,0}, children = {
      { type = "function", range = {0,0,3,3}, children = {
        { type = "identifier", range = {0,9,0,12}, text = "foo" },
        { type = "block", range = {1,4,3,3}, children = {
          { type = "call", range = {1,4,1,8}, text = "bar" },
          { type = "call", range = {2,4,2,8}, text = "bar" },
        }},
      }},
      { type = "function", range = {4,0,5,3}, children = {
        { type = "identifier", range = {4,9,4,12}, text = "bar" },
        { type = "block", range = {5,4,5,3}, children = {} },
      }},
    },
  })
  return Scenario.new()
    :with_code("function foo()\n    bar()\n    bar()\nend\nfunction bar()\nend\n")
    :with_cursor(0, 9)
    :with_language("lua")
    :with_tree(tree:root())
    :with_file("/project/test.lua")
    :with_cwd("/project")
    :with_symbols(uri, {
      mocks.symbol("foo", utils.LSP_SYMBOL_FUNCTION, 0, 9, 0, 12),
      mocks.symbol("bar", utils.LSP_SYMBOL_FUNCTION, 4, 9, 4, 12),
    })
    :with_definition(uri, { line = 0, character = 9 }, {
      mocks.loc(uri, 0, 9, 0, 12),
    })
    :with_references(uri, { line = 0, character = 9 }, {
      mocks.loc(uri, 0, 9, 0, 12),
    }, true)
    -- Both bar() call sites resolve to the same definition (line 4).
    :with_definition(uri, { line = 1, character = 4 }, {
      mocks.loc(uri, 4, 9, 4, 12),
    })
    :with_definition(uri, { line = 2, character = 4 }, {
      mocks.loc(uri, 4, 9, 4, 12),
    })
end

--------------------------------------------------------------------------------
-- Test 1: default behavior (both flags true) deduplicates two calls to
-- the same function into a single entry.
--------------------------------------------------------------------------------
function M.test_default_deduplicates_two_calls_to_same_function()
  local s = _build_two_calls_same_target_scenario()
  -- Default: both flags nil -> analyzer treats as true -> dedup applies.
  local result = s:analyze()
  A.length(1, result.external_calls,
    "default dedup should collapse two calls to same (name, file) into one")
  A.equal("bar", result.external_calls[1].function_name)
  A.equal("resolved", result.external_calls[1].resolution_status)
end

--------------------------------------------------------------------------------
-- Test 2: explicit deduplicate_external_calls=false keeps both entries.
--------------------------------------------------------------------------------
function M.test_dedup_disabled_keeps_both_calls()
  local s = _build_two_calls_same_target_scenario()
  local result = s:analyze({ deduplicate_external_calls = false })
  A.length(2, result.external_calls,
    "with dedup disabled, both call sites should be kept")
  -- Both should have the same function_name (bar) and the same definition.file.
  A.equal("bar", result.external_calls[1].function_name)
  A.equal("bar", result.external_calls[2].function_name)
end

--------------------------------------------------------------------------------
-- Test 3: skip_stdlib_calls=true (default) drops stdlib entries.
--------------------------------------------------------------------------------
function M.test_default_skips_stdlib_calls()
  local uri = utils.path_to_uri("/project/test.lua")
  -- foo calls print() which LSP tags as stdlib (LSP_TAG_SYSTEM).
  local tree = TB.tree({
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
  local s = Scenario.new()
    :with_code("function foo()\n    print()\nend\nfunction print()\nend\n")
    :with_cursor(0, 9)
    :with_language("lua")
    :with_tree(tree:root())
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

  -- Default: skip_stdlib_calls=true -> stdlib entry dropped.
  local result = s:analyze()
  A.length(0, result.external_calls,
    "default skip_stdlib_calls=true should drop the stdlib print() entry")
end

--------------------------------------------------------------------------------
-- Test 4: skip_stdlib_calls=false keeps the stdlib entry.
--------------------------------------------------------------------------------
function M.test_skip_stdlib_disabled_keeps_stdlib_call()
  local uri = utils.path_to_uri("/project/test.lua")
  local tree = TB.tree({
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
  local s = Scenario.new()
    :with_code("function foo()\n    print()\nend\nfunction print()\nend\n")
    :with_cursor(0, 9)
    :with_language("lua")
    :with_tree(tree:root())
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

  local result = s:analyze({ skip_stdlib_calls = false, deduplicate_external_calls = false })
  A.length(1, result.external_calls,
    "with skip_stdlib_calls=false, the stdlib entry should be kept")
  A.equal(true, result.external_calls[1].is_stdlib,
    "is_stdlib flag should be true on the kept entry")
end

--------------------------------------------------------------------------------
-- Test 5: summary counts reflect the FINAL (post-filter) array length.
-- Two calls to bar (same target) + default dedup → calls_kept=1.
--------------------------------------------------------------------------------
function M.test_summary_calls_kept_reflects_post_dedup_count()
  local s = _build_two_calls_same_target_scenario()
  local result = s:analyze()
  A.is_not_nil(result.debug, "debug should be present (default debug=true)")
  A.is_not_nil(result.debug.summary, "summary should be present")
  A.equal(1, result.debug.summary.calls_kept,
    "calls_kept should be 1 after dedup (not 2)")
end

--------------------------------------------------------------------------------
-- Test 6: raw_external_calls_before_filter is recorded in debug.inputs
-- when filtering actually changes the list.
--------------------------------------------------------------------------------
function M.test_raw_count_recorded_in_debug_when_filtering_applies()
  local s = _build_two_calls_same_target_scenario()
  local result = s:analyze()
  A.is_not_nil(result.debug, "debug should be present")
  A.is_not_nil(result.debug.inputs, "debug.inputs should be present")
  A.equal(2, result.debug.inputs.raw_external_calls_before_filter,
    "raw_external_calls_before_filter should record the pre-dedup count (2)")
  A.equal(1, result.debug.inputs.external_calls_dedup_removed,
    "external_calls_dedup_removed should be 1 (one duplicate dropped)")
end

--------------------------------------------------------------------------------
-- Test 7: processing order — dedup runs BEFORE stdlib filter.
-- Construct a scenario with TWO stdlib calls to the same function. With
-- default flags, dedup collapses them to 1, then the stdlib filter drops
-- that 1, leaving 0. If the order were reversed (filter first → 0, then
-- dedup on empty → 0), the final count would still be 0 — so this test
-- alone doesn't fully prove the order. We add a second assertion: the
-- debug.inputs.external_calls_dedup_removed should be 1 (proving dedup
-- ran on the full list of 2, not on the post-filter list of 0).
--------------------------------------------------------------------------------
function M.test_dedup_runs_before_stdlib_filter()
  local uri = utils.path_to_uri("/project/test.lua")
  -- foo calls print() twice; both resolve to the same stdlib definition.
  local tree = TB.tree({
    type = "program", range = {0,0,8,0}, children = {
      { type = "function", range = {0,0,3,3}, children = {
        { type = "identifier", range = {0,9,0,12}, text = "foo" },
        { type = "block", range = {1,4,3,3}, children = {
          { type = "call", range = {1,4,1,11}, text = "print" },
          { type = "call", range = {2,4,2,11}, text = "print" },
        }},
      }},
      { type = "function", range = {5,0,7,3}, children = {
        { type = "identifier", range = {5,9,5,14}, text = "print" },
        { type = "block", range = {6,4,7,3}, children = {} },
      }},
    },
  })
  local s = Scenario.new()
    :with_code("function foo()\n    print()\n    print()\nend\nfunction print()\nend\n")
    :with_cursor(0, 9)
    :with_language("lua")
    :with_tree(tree:root())
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
    :with_definition(uri, { line = 2, character = 4 }, {
      mocks.loc(uri, 5, 9, 5, 14, { LSP_TAG_SYSTEM }),
    })

  local result = s:analyze()
  -- Final list: 0 (both stdlib, deduped to 1, then filtered to 0).
  A.length(0, result.external_calls,
    "two stdlib calls should dedup to 1, then filter to 0")
  -- Prove dedup ran on the FULL list (2 entries), not the post-filter list (0):
  A.equal(1, result.debug.inputs.external_calls_dedup_removed,
    "dedup should have removed 1 duplicate (proving it ran before the stdlib filter)")
  A.equal(1, result.debug.inputs.external_calls_stdlib_removed,
    "stdlib filter should have removed 1 entry (the deduped survivor)")
end

--------------------------------------------------------------------------------
-- Test 8: both flags false → raw list preserved (no dedup, no filter).
--------------------------------------------------------------------------------
function M.test_both_flags_false_preserves_raw_list()
  local s = _build_two_calls_same_target_scenario()
  local result = s:analyze({ skip_stdlib_calls = false, deduplicate_external_calls = false })
  A.length(2, result.external_calls,
    "with both flags false, both call sites should be kept")
  -- raw_external_calls_before_filter should NOT be recorded (no filtering applied).
  if result.debug and result.debug.inputs then
    A.is_nil(result.debug.inputs.raw_external_calls_before_filter,
      "raw_external_calls_before_filter should not be set when no filtering ran")
  end
end

return M
