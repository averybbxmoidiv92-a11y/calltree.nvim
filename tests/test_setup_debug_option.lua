--- tests/test_setup_debug_option.lua
---
--- Regression tests for the bug where setup({ debug = true }) did not
--- propagate to the CalltreeJson and CalltreeToFile commands. These
--- commands hardcoded debug=false (or defaulted to false), ignoring the
--- user's setup configuration.
---
--- These tests verify that the debug option from setup() is respected by
--- all entry points (analyze_at_cursor, write_json_to_file, and the
--- command closures), and that explicit opts.debug overrides take
--- precedence over the setup default.
---
--- Approach: mock the `vim` global with the minimal APIs init.lua touches,
--- monkey-patch adapter.build_context and analyzer.analyze to capture the
--- debug flag without running the full analysis pipeline, then assert the
--- flag matches expectations.
---
--- Improvements over the original:
---   - `with_mocked_adapter(callback)` helper centralizes the
---     monkey-patching + restore pattern (was duplicated across tests 4-9).
---     The helper uses pcall internally so restore ALWAYS runs, even if the
---     callback errors — fixing the "restore outside pcall" leak.
---   - `restore_vim()` guards against `saved_vim` being nil (previously
---     would set `_G.vim = nil`, breaking subsequent tests).
---   - Test 3 (setup({}) leaves debug unchanged) is split into two
---     independent tests so both branches are reported separately.
---   - Tmpfile names no longer embed test numbers (decoupled from ordering).

local A = require("assert")

local M = {}

-- Load the calltree module (cached across all tests).
local calltree = require("calltree")

-- Save initial state for restoration after all tests.
local initial_debug = calltree.options.debug

-------------------------------------------------------------------------------
-- Mock helpers
-------------------------------------------------------------------------------

local saved_vim
-- Save calltree.options.debug per-test so a setup() call inside one test
-- doesn't leak the debug value into subsequent tests. Previously this was
-- only restored once at module load, so a test that called
-- setup({debug=false}) and then failed would leave debug=false for all
-- following tests, causing cascading failures.
local saved_debug

-- Set up a minimal `vim` global mock with the APIs init.lua touches.
local function mock_vim()
  saved_vim = _G.vim
  saved_debug = calltree.options.debug
  _G.vim = {
    api = {
      nvim_win_get_cursor = function() return { 1, 0 } end,
      nvim_create_user_command = function() end,
      nvim_del_user_command = function() end,
    },
    fn = { json_encode = function() return "{}" end },
    json = { encode = function() return "{}" end },
  }
end

local function restore_vim()
  -- Guard: if mock_vim was never called (e.g. another test errored before
  -- mock_vim), saved_vim is nil and we must NOT set _G.vim = nil (that
  -- would break subsequent tests). Only restore when we actually saved.
  if saved_vim ~= nil then
    _G.vim = saved_vim
    saved_vim = nil
  end
  -- Restore the debug option so the next test starts with clean state.
  if saved_debug ~= nil then
    calltree.options.debug = saved_debug
    saved_debug = nil
  end
end

-------------------------------------------------------------------------------
-- with_mocked_adapter: centralize the monkey-patching + restore pattern.
-- The callback receives (captured_table) where it can store observations.
-- Restore ALWAYS runs (via pcall + finally), even if the callback errors.
-- This fixes the "restore outside pcall" leak from the original tests.
-------------------------------------------------------------------------------
local function with_mocked_adapter(callback)
  mock_vim()
  local adapter = require("calltree.adapter")
  local analyzer = require("calltree.core.analyzer")
  local real_build = adapter.build_context
  local real_analyze = analyzer.analyze
  local captured = {}

  -- Patch adapter.build_context to capture opts.debug.
  adapter.build_context = function(bufnr, pos, lang, opts)
    captured.debug = opts and opts.debug
    return { debug = opts and opts.debug }
  end
  -- Patch analyzer.analyze to return a minimal result without running
  -- the full pipeline.
  analyzer.analyze = function(ctx)
    return { current_function = nil, callers = {}, external_calls = {} }
  end

  local ok, err = pcall(callback, captured)

  -- Always restore, even if the callback errored.
  adapter.build_context = real_build
  analyzer.analyze = real_analyze
  restore_vim()
  if not ok then error(err) end
end

-------------------------------------------------------------------------------
-- Test 1: setup({ debug = true }) persists to M.options.debug
-------------------------------------------------------------------------------
function M.test_setup_persists_debug_true()
  mock_vim()
  local ok, err = pcall(function()
    calltree.setup({ debug = true })
    A.equal(true, calltree.options.debug,
      "setup({debug=true}) should set options.debug to true")
  end)
  restore_vim()
  if not ok then error(err) end
end

-------------------------------------------------------------------------------
-- Test 2: setup({ debug = false }) persists to M.options.debug
-------------------------------------------------------------------------------
function M.test_setup_persists_debug_false()
  mock_vim()
  local ok, err = pcall(function()
    calltree.setup({ debug = false })
    A.equal(false, calltree.options.debug,
      "setup({debug=false}) should set options.debug to false")
  end)
  restore_vim()
  if not ok then error(err) end
end

-------------------------------------------------------------------------------
-- Test 3a: setup({}) does not change M.options.debug when it was true
-- (Split from the original test 3 so both branches are reported separately.)
-------------------------------------------------------------------------------
function M.test_setup_no_debug_key_leaves_true_unchanged()
  mock_vim()
  local ok, err = pcall(function()
    calltree.setup({ debug = true })
    calltree.setup({})
    A.equal(true, calltree.options.debug,
      "setup({}) should not change debug when key is absent (was true)")
  end)
  restore_vim()
  if not ok then error(err) end
end

-------------------------------------------------------------------------------
-- Test 3b: setup({}) does not change M.options.debug when it was false
-------------------------------------------------------------------------------
function M.test_setup_no_debug_key_leaves_false_unchanged()
  mock_vim()
  local ok, err = pcall(function()
    calltree.setup({ debug = false })
    calltree.setup({})
    A.equal(false, calltree.options.debug,
      "setup({}) should not change debug when key is absent (was false)")
  end)
  restore_vim()
  if not ok then error(err) end
end

-------------------------------------------------------------------------------
-- Test 4: analyze_at_cursor uses M.options.debug when no explicit opts
-------------------------------------------------------------------------------
function M.test_analyze_at_cursor_uses_setup_debug()
  with_mocked_adapter(function(captured)
    calltree.setup({ debug = true })
    calltree.analyze_at_cursor(0)
    A.equal(true, captured.debug,
      "analyze_at_cursor() should use debug=true from setup")

    calltree.setup({ debug = false })
    calltree.analyze_at_cursor(0)
    A.equal(false, captured.debug,
      "analyze_at_cursor() should use debug=false from setup")
  end)
end

-------------------------------------------------------------------------------
-- Test 5: explicit opts.debug overrides the setup value in analyze_at_cursor
-------------------------------------------------------------------------------
function M.test_analyze_at_cursor_explicit_opts_overrides_setup()
  with_mocked_adapter(function(captured)
    calltree.setup({ debug = true })
    calltree.analyze_at_cursor(0, { debug = false })
    A.equal(false, captured.debug,
      "explicit opts.debug=false should override setup debug=true")

    calltree.setup({ debug = false })
    calltree.analyze_at_cursor(0, { debug = true })
    A.equal(true, captured.debug,
      "explicit opts.debug=true should override setup debug=false")
  end)
end

-------------------------------------------------------------------------------
-- Test 6: write_json_to_file uses M.options.debug when no explicit opts
-- (This is the core regression test for the bug: previously defaulted to
--  false, ignoring setup({ debug = true }).)
-------------------------------------------------------------------------------
function M.test_write_json_to_file_uses_setup_debug()
  mock_vim()
  local captured
  local real_json = calltree.analyze_at_cursor_json

  local ok, err = pcall(function()
    calltree.analyze_at_cursor_json = function(bufnr, opts)
      captured = opts and opts.debug
      return "{}"
    end

    -- Use os.tmpname() for a portable temp file path (was a hardcoded
    -- /tmp/... path that breaks on Windows / macOS sandboxes where /tmp
    -- may not be writable, and risks collisions when tests run in
    -- parallel). os.tmpname() returns a unique path on all platforms.
    local tmpfile = os.tmpname()

    calltree.setup({ debug = true })
    calltree.write_json_to_file(tmpfile, 0)
    A.equal(true, captured,
      "write_json_to_file() should use debug=true from setup when no explicit opts")

    calltree.setup({ debug = false })
    calltree.write_json_to_file(tmpfile, 0)
    A.equal(false, captured,
      "write_json_to_file() should use debug=false from setup when no explicit opts")

    os.remove(tmpfile)
  end)

  calltree.analyze_at_cursor_json = real_json
  restore_vim()
  if not ok then error(err) end
end

-------------------------------------------------------------------------------
-- Test 7: write_json_to_file explicit opts.debug overrides setup
-------------------------------------------------------------------------------
function M.test_write_json_to_file_explicit_opts_overrides_setup()
  mock_vim()
  local captured
  local real_json = calltree.analyze_at_cursor_json

  local ok, err = pcall(function()
    calltree.analyze_at_cursor_json = function(bufnr, opts)
      captured = opts and opts.debug
      return "{}"
    end

    -- Use os.tmpname() for portability (see the equivalent comment above).
    local tmpfile = os.tmpname()

    calltree.setup({ debug = true })
    calltree.write_json_to_file(tmpfile, 0, { debug = false })
    A.equal(false, captured,
      "write_json_to_file explicit debug=false should override setup true")

    calltree.setup({ debug = false })
    calltree.write_json_to_file(tmpfile, 0, { debug = true })
    A.equal(true, captured,
      "write_json_to_file explicit debug=true should override setup false")

    os.remove(tmpfile)
  end)

  calltree.analyze_at_cursor_json = real_json
  restore_vim()
  if not ok then error(err) end
end

-------------------------------------------------------------------------------
-- Test 8: analyze_at_cursor_json forwards opts.debug to analyze_at_cursor
-------------------------------------------------------------------------------
function M.test_analyze_at_cursor_json_forwards_debug_opt()
  with_mocked_adapter(function(captured)
    calltree.setup({ debug = false })
    calltree.analyze_at_cursor_json(0, { debug = true })
    A.equal(true, captured.debug,
      "analyze_at_cursor_json should forward opts.debug=true to analyze_at_cursor")

    calltree.setup({ debug = true })
    calltree.analyze_at_cursor_json(0, { debug = false })
    A.equal(false, captured.debug,
      "analyze_at_cursor_json should forward opts.debug=false to analyze_at_cursor")
  end)
end

-------------------------------------------------------------------------------
-- Test 9: dump_at_cursor (CalltreeAnalyze) uses M.options.debug
-------------------------------------------------------------------------------
function M.test_dump_at_cursor_uses_setup_debug()
  mock_vim()
  local adapter = require("calltree.adapter")
  local analyzer = require("calltree.core.analyzer")
  local captured
  local real_build = adapter.build_context
  local real_analyze = analyzer.analyze

  local ok, err = pcall(function()
    adapter.build_context = function(bufnr, pos, lang, opts)
      captured = opts and opts.debug
      return { debug = opts and opts.debug }
    end
    analyzer.analyze = function(ctx)
      -- Return a result with debug field when debug is enabled, so
      -- dump_at_cursor's `if result.debug then` branch is exercised.
      return {
        current_function = nil,
        callers = {},
        external_calls = {},
        debug = ctx.debug and { completion_reason = "test", summary = {} } or nil,
      }
    end

    calltree.setup({ debug = true })
    calltree.dump_at_cursor()
    A.equal(true, captured,
      "dump_at_cursor() should use debug=true from setup")

    calltree.setup({ debug = false })
    calltree.dump_at_cursor()
    A.equal(false, captured,
      "dump_at_cursor() should use debug=false from setup")
  end)

  adapter.build_context = real_build
  analyzer.analyze = real_analyze
  restore_vim()
  if not ok then error(err) end
end

-------------------------------------------------------------------------------
-- Restore initial state (runs when this module is loaded, before tests
-- execute). Each test also restores via restore_vim(), so cross-test
-- pollution is now fully prevented.
-------------------------------------------------------------------------------
calltree.options.debug = initial_debug

return M
