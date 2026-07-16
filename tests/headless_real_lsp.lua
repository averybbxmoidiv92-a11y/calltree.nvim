--- tests/headless_real_lsp.lua
---
--- Neovim headless integration tests for calltree.nvim using a REAL
--- lua-language-server (lua_ls). These tests exercise the full pipeline
--- end-to-end: nvim -> vim.lsp -> lua_ls -> calltree adapter -> analyzer.
---
--- Run with:
---   nvim --headless -u NORC -c "luafile tests/runner_headless_real_lsp.lua"
---
--- Exits 0 on success, 1 on any failure.

local M = {}

-- Use the shared headless_helpers module for ok/eq (eliminates duplication
-- with headless_integration.lua). The counters are local to this file so
-- they don't interfere with headless_integration.lua's counters.
local HH = require("headless_helpers")
local _counters = HH.new_counters()
local failures = _counters.failures
local passes = 0
local ok, eq = HH.make_ok_eq(_counters)

-- Expose passes as an upvalue reference so the run() function can read it.
local function get_passes() return _counters.passes end

-- Magic numbers centralized as module-level constants (previously scattered
-- inline literals). Overridable via environment variables for slow CI.
local LSP_READY_TIMEOUT_MS = tonumber(os.getenv("CALLTREE_LSP_READY_TIMEOUT_MS") or "30000")
local LSP_POLL_INTERVAL_MS = 200
local LSP_SYNC_TIMEOUT_MS = 3000
local OS_REAP_WAIT_MS = 200

--------------------------------------------------------------------------------
-- Helpers
--------------------------------------------------------------------------------

-- Set up a tiny lua project on disk so the LSP has something stable to index.
-- Uses os.tmpname() for the base path (platform-appropriate temp directory)
-- rather than hardcoding /tmp/. The project name is appended for readability
-- in debug output. cleanup_project() uses the SAME path, so we store a
-- mapping from name -> dir to keep them in sync.
local _project_dirs = {}

local function setup_project(name, files)
  local base = os.tmpname()
  -- os.tmpname() returns a file path; we use it as a directory base by
  -- appending the project name. Remove the temp file if it exists, then
  -- create a directory.
  os.remove(base)
  local dir = base .. "_proj_" .. name
  _project_dirs[name] = dir
  vim.fn.delete(dir, "rf")
  vim.fn.mkdir(dir, "p")
  for fname, content in pairs(files) do
    local f = io.open(dir .. "/" .. fname, "w")
    -- Guard: io.open can return nil on permission denied, disk full, etc.
    -- Previously f:write would crash with "attempt to index a nil value"
    -- if f was nil, obscuring the real cause (file creation failure).
    if not f then
      error("setup_project: could not open " .. dir .. "/" .. fname .. " for writing")
    end
    f:write(content)
    f:close()
  end
  return dir
end

-- Open `file` in buffer 0, attach lua_ls, wait for symbols.
local function open_and_attach(dir, file)
  vim.cmd("cd " .. dir)
  vim.cmd("edit " .. file)
  vim.bo.filetype = "lua"
  _G.start_lua_lsp(0)
  -- Wait for symbols to become available (poll documentSymbol).
  local uri = vim.uri_from_bufnr(0)
  local start = vim.loop.hrtime()
  while (vim.loop.hrtime() - start) / 1e6 < LSP_READY_TIMEOUT_MS do
    local ok_r, result = pcall(vim.lsp.buf_request_sync, 0,
      "textDocument/documentSymbol", { textDocument = { uri = uri } }, LSP_SYNC_TIMEOUT_MS)
    if ok_r and result then
      for _, r in pairs(result) do
        if r.result and type(r.result) == "table" and #r.result > 0 then
          return r.result
        end
      end
    end
    vim.wait(LSP_POLL_INTERVAL_MS)
  end
  return nil
end

local function stop_all_lsps()
  -- Kill every attached LSP client so later tests don't accumulate
  -- dozens of lua-language-server processes (OOM on low-memory hosts).
  local clients = vim.lsp.get_clients and vim.lsp.get_clients()
    or vim.lsp.get_active_clients()
  for _, c in ipairs(clients) do
    pcall(function()
      if vim.lsp.stop_client then
        vim.lsp.stop_client(c.id, true)
      elseif c.stop then
        c.stop(true)
      end
    end)
  end
  -- Give the OS a moment to reap child processes.
  vim.wait(OS_REAP_WAIT_MS)
end

local function cleanup_project(name)
  stop_all_lsps()
  -- Drop all listed buffers so FileType autocmds don't re-attach.
  for _, buf in ipairs(vim.api.nvim_list_bufs()) do
    if vim.api.nvim_buf_is_valid(buf) and vim.api.nvim_buf_get_name(buf) ~= "" then
      pcall(vim.api.nvim_buf_delete, buf, { force = true })
    end
  end
  -- Use the SAME dir path that setup_project() computed (stored in
  -- _project_dirs) rather than recomputing a /tmp/ path.
  local dir = _project_dirs[name]
  if dir then
    vim.fn.delete(dir, "rf")
    _project_dirs[name] = nil
  end
  collectgarbage("collect")
end

--------------------------------------------------------------------------------
-- Test 1: End-to-end analyze_at_cursor with real lua_ls.
--   lib.lua defines `M.greet` and `M.use_greet` (which calls M.greet).
--   Cursor on `greet` definition. Should return:
--     current_function = greet
--     callers = [use_greet]
--     external_calls = [] (no other-project-file calls)
--------------------------------------------------------------------------------
function M.test_analyze_greet_callers()
  local dir = setup_project("greet", {
    ["lib.lua"] = [[
local M = {}

function M.greet(name)
  return "hello " .. name
end

function M.use_greet()
  return M.greet("world")
end

return M
]],
  })

  local symbols = open_and_attach(dir, "lib.lua")
  ok("test1: LSP attached and returned symbols", symbols ~= nil,
    "no symbols returned from lua_ls")
  if not symbols then cleanup_project("greet"); return end

  -- Position cursor on "greet" identifier (the leaf of M.greet) at line 3 col 12.
  -- Line 3 is `function M.greet(name)`: cols 0-7=function, 8=space, 9=M, 10=., 11-15=greet.
  vim.api.nvim_win_set_cursor(0, { 3, 12 })

  -- Give LSP a moment to fully index before triggering analysis.
  vim.wait(500)

  local calltree = require("calltree")
  local result = calltree.analyze_at_cursor(0)

  ok("test1: result is table", type(result) == "table")
  ok("test1: current_function detected", result.current_function ~= nil,
    "current_function is nil; debug.completion_reason=" ..
    (result.debug and result.debug.completion_reason or "?"))
  if result.current_function then
    -- current_function.name comes from the cursor identifier text.
    -- Cursor is on "greet" (leaf of M.greet), so name should be "greet".
    eq("test1: current_function.name", result.current_function.name, "greet")
  end
  ok("test1: at least one caller (use_greet)", #result.callers >= 1,
    "callers count=" .. #result.callers)
  if #result.callers >= 1 then
    local found_use_greet = false
    for _, c in ipairs(result.callers) do
      -- caller name may be "M.use_greet" (dotted) or "use_greet" (leaf) depending
      -- on whether the cursor landed on the dotted name. Both are acceptable.
      if c.caller_function.name == "M.use_greet"
         or c.caller_function.name == "use_greet" then
        found_use_greet = true
        break
      end
    end
    ok("test1: caller is M.use_greet or use_greet", found_use_greet,
      "caller names: " .. table.concat(
        vim.tbl_map(function(c) return c.caller_function.name or "?" end, result.callers), ", "))
  end

  cleanup_project("greet")
end

--------------------------------------------------------------------------------
-- Test 2: External calls — main.lua requires lib.lua and calls lib.func.
--   Cursor on `func` definition in lib.lua. The external_calls analysis
--   is from the cursor function's body; here it has no external calls.
--   But the cursor function is called from main.lua. So callers should
--   include main.lua's calling function.
--------------------------------------------------------------------------------
function M.test_cross_file_caller()
  local dir = setup_project("cross", {
    ["lib.lua"] = [[
local M = {}

function M.helper()
  return 42
end

return M
]],
    ["main.lua"] = [[
local lib = require("lib")

local function caller()
  return lib.helper()
end

caller()
]],
  })

  local symbols = open_and_attach(dir, "lib.lua")
  ok("test2: LSP attached for lib.lua", symbols ~= nil)
  if not symbols then cleanup_project("cross"); return end

  -- Cursor on "helper" identifier (leaf of M.helper) at line 3 col 13.
  -- Line 3 is `function M.helper()`: 9=M, 10=., 11-16=helper.
  vim.api.nvim_win_set_cursor(0, { 3, 13 })
  vim.wait(500)

  local calltree = require("calltree")
  local result = calltree.analyze_at_cursor(0)

  ok("test2: current_function detected", result.current_function ~= nil,
    "current_function is nil; reason=" ..
    (result.debug and result.debug.completion_reason or "?"))
  if result.current_function then
    -- Cursor on "helper" leaf, so name should be "helper".
    eq("test2: current_function.name", result.current_function.name, "helper")
  end

  -- callers should include the function `caller` in main.lua
  local has_main_caller = false
  for _, c in ipairs(result.callers) do
    if c.caller_function.name == "caller" then
      has_main_caller = true
      ok("test2: caller file is main.lua", c.file:find("main.lua") ~= nil,
        "file=" .. c.file)
      break
    end
  end
  ok("test2: caller in main.lua found", has_main_caller,
    "callers count=" .. #result.callers ..
    "; names: " .. table.concat(
      vim.tbl_map(function(c) return c.caller_function.name or "?" end, result.callers), ", "))

  cleanup_project("cross")
end

--------------------------------------------------------------------------------
-- Test 3: External calls from cursor function — main.lua has `caller()`
--   which calls `lib.helper()`. Cursor on `caller` definition.
--   external_calls should include `helper` (resolved to lib.lua).
--------------------------------------------------------------------------------
function M.test_external_call_resolved()
  local dir = setup_project("extcall", {
    ["lib.lua"] = [[
local M = {}

function M.helper()
  return 42
end

return M
]],
    ["main.lua"] = [[
local lib = require("lib")

local function caller()
  return lib.helper()
end

caller()
]],
  })

  local symbols = open_and_attach(dir, "main.lua")
  ok("test3: LSP attached for main.lua", symbols ~= nil)
  if not symbols then cleanup_project("extcall"); return end

  -- Cursor on "caller" identifier (the function-definition name) at line 3 col 22.
  -- Line 3 is `local function caller()`: 0-5=local, 6=space, 7-14=function, 15=space, 16-21=caller.
  -- Wait — actual layout: `local function caller()` so caller starts at col 16.
  -- But cursor positions are 0-based col, so col 18 lands mid-identifier on "caller".
  vim.api.nvim_win_set_cursor(0, { 3, 18 })
  vim.wait(500)

  local calltree = require("calltree")
  local result = calltree.analyze_at_cursor(0)

  ok("test3: current_function detected", result.current_function ~= nil,
    "reason=" .. (result.debug and result.debug.completion_reason or "?"))
  if result.current_function then
    eq("test3: current_function.name", result.current_function.name, "caller")
  end

  -- external_calls should include helper, resolved to lib.lua
  local has_helper = false
  for _, ec in ipairs(result.external_calls) do
    -- function_name may be "lib.helper" (dotted) or just "helper" depending on
    -- how the callee node text is extracted. Both indicate a call to helper.
    if ec.function_name and (ec.function_name:find("helper$") ~= nil) then
      has_helper = true
      ok("test3: helper resolution_status", ec.resolution_status == "resolved",
        "status=" .. tostring(ec.resolution_status) .. " for " .. ec.function_name)
      if ec.definition then
        ok("test3: helper definition file is lib.lua",
          ec.definition.file and ec.definition.file:find("lib.lua") ~= nil,
          "file=" .. tostring(ec.definition.file))
      end
      break
    end
  end
  ok("test3: helper in external_calls", has_helper,
    "external_calls count=" .. #result.external_calls ..
    "; names: " .. table.concat(
      vim.tbl_map(function(e) return e.function_name or "?" end, result.external_calls), ", "))

  cleanup_project("extcall")
end

--------------------------------------------------------------------------------
-- Test 4: analyze_at_cursor_json with real LSP returns valid JSON.
--------------------------------------------------------------------------------
function M.test_json_with_real_lsp()
  local dir = setup_project("jsonlsp", {
    ["lib.lua"] = [[
local M = {}

function M.alpha()
  return 1
end

function M.beta()
  return M.alpha()
end

return M
]],
  })

  local symbols = open_and_attach(dir, "lib.lua")
  ok("test4: LSP attached", symbols ~= nil)
  if not symbols then cleanup_project("jsonlsp"); return end

  vim.api.nvim_win_set_cursor(0, { 3, 13 })  -- on "alpha" (leaf of M.alpha)
  vim.wait(500)

  local calltree = require("calltree")
  local json = calltree.analyze_at_cursor_json(0)

  ok("test4: json is string", type(json) == "string")
  ok("test4: json starts with {", json:sub(1, 1) == "{")
  ok("test4: json ends with }", json:sub(-1) == "}")

  local decoded = vim.json.decode(json)
  ok("test4: json decodes as table", type(decoded) == "table")
  if decoded then
    ok("test4: decoded.current_function present", decoded.current_function ~= nil)
    ok("test4: decoded.callers is array", type(decoded.callers) == "table")
    ok("test4: decoded.external_calls is array", type(decoded.external_calls) == "table")
    ok("test4: decoded.debug is table", type(decoded.debug) == "table")
    if decoded.debug then
      eq("test4: debug.completion_reason", decoded.debug.completion_reason, "analyzed")
    end
  end

  cleanup_project("jsonlsp")
end

--------------------------------------------------------------------------------
-- Test 5: Pre-conditions pass with real LSP (documentSymbol returns symbols).
--------------------------------------------------------------------------------
function M.test_preconditions_pass_with_real_lsp()
  local dir = setup_project("preconds", {
    ["lib.lua"] = [[
local M = {}
function M.foo() return 1 end
return M
]],
  })

  local symbols = open_and_attach(dir, "lib.lua")
  ok("test5: symbols returned", symbols ~= nil and #symbols > 0)
  if not symbols then cleanup_project("preconds"); return end

  -- At least one symbol should be kind=12 (Function).
  local has_function_symbol = false
  for _, s in ipairs(symbols) do
    if s.kind == 12 then has_function_symbol = true; break end
  end
  ok("test5: has Function-kind symbol", has_function_symbol,
    "symbol kinds: " .. table.concat(
      vim.tbl_map(function(s) return tostring(s.kind) end, symbols), ", "))

  -- Run calltree analyze and verify completion_reason is "analyzed"
  -- (not "preconditions_failed").
  vim.api.nvim_win_set_cursor(0, { 2, 13 })  -- on "foo" (leaf of M.foo)
  vim.wait(500)

  local calltree = require("calltree")
  local result = calltree.analyze_at_cursor(0)

  ok("test5: result has debug", result.debug ~= nil)
  if result.debug then
    eq("test5: completion_reason", result.debug.completion_reason, "analyzed")
    -- All preconditions should have passed.
    local all_passed = true
    for _, p in ipairs(result.debug.preconditions) do
      if p.passed == false then all_passed = false; break end
    end
    ok("test5: all preconditions passed", all_passed)
  end

  cleanup_project("preconds")
end

--------------------------------------------------------------------------------
-- Test 6: No LSP attached → preconditions fail (regression test).
--------------------------------------------------------------------------------
function M.test_no_lsp_preconditions_fail()
  -- Create a buffer with lua content but DON'T attach LSP.
  local buf = vim.api.nvim_create_buf(false, true)
  vim.api.nvim_set_current_buf(buf)
  vim.bo[buf].filetype = "lua"
  vim.api.nvim_buf_set_lines(buf, 0, -1, false, {
    "local function foo()",
    "  return 1",
    "end",
  })
  vim.api.nvim_buf_set_name(buf, os.tmpname() .. "_nolsp.lua")
  vim.api.nvim_win_set_cursor(0, { 1, 15 })

  local calltree = require("calltree")
  local result = calltree.analyze_at_cursor(buf)

  ok("test6: result is table", type(result) == "table")
  ok("test6: debug present", result.debug ~= nil)
  if result.debug then
    -- Without LSP, document_symbols precondition must fail.
    local lsp_precond_failed = false
    for _, p in ipairs(result.debug.preconditions) do
      if (p.check == "lsp.document_symbols" or p.check == "lsp.present"
          or p.check:find("lsp%.") == 1) and p.passed == false then
        lsp_precond_failed = true; break
      end
    end
    ok("test6: at least one LSP precondition failed", lsp_precond_failed,
      "all preconditions passed (unexpected with no LSP)")
    eq("test6: completion_reason", result.debug.completion_reason, "preconditions_failed")
  end

  vim.api.nvim_buf_delete(buf, { force = true })
end

--------------------------------------------------------------------------------
-- Test 7: Nested function caller attribution (regression test for #4).
--   function outer() function inner() foo() end end
--   Cursor on `foo` (definition). The call inside `inner` should be
--   attributed to `inner`, not `outer`.
--------------------------------------------------------------------------------
function M.test_nested_caller_attribution()
  local dir = setup_project("nested", {
    ["lib.lua"] = [[
local M = {}

function M.foo()
  return 1
end

function M.outer()
  local function inner()
    return M.foo()
  end
  return inner()
end

return M
]],
  })

  local symbols = open_and_attach(dir, "lib.lua")
  ok("test7: LSP attached", symbols ~= nil)
  if not symbols then cleanup_project("nested"); return end

  vim.api.nvim_win_set_cursor(0, { 3, 13 })  -- on "foo" (leaf of M.foo)
  vim.wait(500)

  local calltree = require("calltree")
  local result = calltree.analyze_at_cursor(0)

  ok("test7: current_function detected", result.current_function ~= nil,
    "reason=" .. (result.debug and result.debug.completion_reason or "?"))
  if result.current_function then
    -- current_function.name comes from the cursor identifier text.
    -- Since cursor is on the leaf "foo", name should be "foo".
    eq("test7: current_function.name", result.current_function.name, "foo")
  end

  -- The caller should be `inner`, NOT `outer` (regression for #4).
  local has_inner = false
  local has_outer = false
  for _, c in ipairs(result.callers) do
    if c.caller_function.name == "inner" then has_inner = true end
    if c.caller_function.name == "M.outer" then has_outer = true end
  end
  ok("test7: caller is `inner` (not `outer`)", has_inner,
    "callers: " .. table.concat(
      vim.tbl_map(function(c) return c.caller_function.name or "?" end, result.callers), ", "))
  -- outer should NOT appear as a caller (the call is inside inner, not directly in outer's body)
  ok("test7: `outer` NOT in callers", not has_outer,
    "outer was incorrectly attributed as caller (bug #4 not fixed)")

  cleanup_project("nested")
end

--------------------------------------------------------------------------------
-- Test 8: dump_at_cursor with debug=false does NOT crash.
--   Regression test for #3.
--------------------------------------------------------------------------------
function M.test_dump_at_cursor_debug_false()
  local dir = setup_project("dumpfalse", {
    ["lib.lua"] = [[
local M = {}
function M.foo() return 1 end
return M
]],
  })

  local symbols = open_and_attach(dir, "lib.lua")
  ok("test8: LSP attached", symbols ~= nil)
  if not symbols then cleanup_project("dumpfalse"); return end

  vim.api.nvim_win_set_cursor(0, { 2, 13 })  -- on "foo" (leaf of M.foo)
  vim.wait(500)

  local calltree = require("calltree")
  calltree.setup({ debug = false })

  -- Capture print output.
  local captured = {}
  local orig_print = _G.print
  _G.print = function(...) table.insert(captured, table.concat({...}, "\t")) end
  local ok_call, err = pcall(function() calltree.dump_at_cursor(0) end)
  _G.print = orig_print

  ok("test8: dump_at_cursor with debug=false doesn't crash", ok_call,
    "error: " .. tostring(err))
  ok("test8: dump_at_cursor produced output", #captured > 0)

  calltree.setup({ debug = true })  -- restore
  cleanup_project("dumpfalse")
end

--------------------------------------------------------------------------------
-- Test 9: setup({ debug = false }) — analyze_at_cursor returns result
--   WITHOUT debug field, and analysis still works.
-- Uses pcall + finally-style restore so a test failure between setup and
-- restore doesn't leak debug=false to subsequent tests.
--------------------------------------------------------------------------------
function M.test_debug_false_with_real_lsp()
  local dir = setup_project("dbgfalse", {
    ["lib.lua"] = [[
local M = {}
function M.foo() return 1 end
function M.bar() return M.foo() end
return M
]],
  })

  local symbols = open_and_attach(dir, "lib.lua")
  ok("test9: LSP attached", symbols ~= nil)
  if not symbols then cleanup_project("dbgfalse"); return end

  vim.api.nvim_win_set_cursor(0, { 2, 13 })  -- on foo (leaf of M.foo)
  vim.wait(500)

  local calltree = require("calltree")
  -- Use pcall so restore ALWAYS runs, even if an assertion fails.
  -- Previously, if an assertion between setup(false) and setup(true) failed,
  -- debug stayed false, leaking to subsequent tests.
  local test_ok, test_err = pcall(function()
    calltree.setup({ debug = false })
    local result = calltree.analyze_at_cursor(0)

    ok("test9: debug field is nil", result.debug == nil,
      "debug unexpectedly present")
    ok("test9: current_function still detected", result.current_function ~= nil)
    if result.current_function then
      eq("test9: name", result.current_function.name, "foo")
    end
    ok("test9: callers is table", type(result.callers) == "table")
    ok("test9: external_calls is table", type(result.external_calls) == "table")
  end)

  -- Always restore default + clean up (finally-style).
  pcall(function() calltree.setup({ debug = true }) end)
  pcall(function() cleanup_project("dbgfalse") end)
  if not test_ok then error(test_err) end
end

--------------------------------------------------------------------------------
-- Test 10: LSP diagnostics snapshot via adapter.get_lsp_diagnostics.
--------------------------------------------------------------------------------
function M.test_adapter_diagnostics_snapshot()
  local dir = setup_project("diag", {
    ["lib.lua"] = [[
local M = {}
function M.foo() return 1 end
return M
]],
  })

  local symbols = open_and_attach(dir, "lib.lua")
  ok("test10: LSP attached", symbols ~= nil)
  if not symbols then cleanup_project("diag"); return end

  vim.api.nvim_win_set_cursor(0, { 2, 13 })  -- on "foo" (leaf of M.foo)
  vim.wait(500)

  local calltree = require("calltree")
  local result = calltree.analyze_at_cursor(0)

  -- After analysis, lsp_adapter_diagnostics should be populated.
  ok("test10: debug present", result.debug ~= nil)
  if result.debug then
    ok("test10: lsp_adapter_diagnostics present",
      result.debug.lsp_adapter_diagnostics ~= nil,
      "lsp_adapter_diagnostics is nil")
    if result.debug.lsp_adapter_diagnostics then
      ok("test10: diagnostics is array",
        type(result.debug.lsp_adapter_diagnostics) == "table")
      -- Should contain entries for at least documentSymbol, definition, references.
      local methods_seen = {}
      for _, d in ipairs(result.debug.lsp_adapter_diagnostics) do
        if d.method then methods_seen[d.method] = true end
      end
      ok("test10: saw textDocument/definition",
        methods_seen["textDocument/definition"] ~= nil)
      ok("test10: saw textDocument/references",
        methods_seen["textDocument/references"] ~= nil)
      ok("test10: saw textDocument/documentSymbol",
        methods_seen["textDocument/documentSymbol"] ~= nil)
    end
  end

  -- Test the adapter.get_lsp_diagnostics() function returns a snapshot.
  local adapter = require("calltree.adapter")
  local snapshot = adapter.get_lsp_diagnostics()
  ok("test10: adapter.get_lsp_diagnostics returns table", type(snapshot) == "table")
  -- Mutating snapshot should NOT affect the live accumulator.
  local original_len = #snapshot
  table.insert(snapshot, { fake = true })
  local snapshot2 = adapter.get_lsp_diagnostics()
  eq("test10: snapshot mutation isolated", #snapshot2, original_len)

  cleanup_project("diag")
end

--------------------------------------------------------------------------------
-- Runner
--------------------------------------------------------------------------------
function M.run()
  print("=== calltree.nvim headless REAL-LSP integration tests ===")
  print("nvim version: " .. vim.version().major .. "." .. vim.version().minor .. "." .. vim.version().patch)
  local clients = vim.lsp.get_clients and vim.lsp.get_clients() or vim.lsp.get_active_clients()
  print(string.format("active LSP clients at start: %d", #clients))
  for _, c in ipairs(clients) do
    print(string.format("  client id=%d name=%s", c.id, c.name))
  end
  print(string.rep("-", 60))

  local tests = {
    "test_analyze_greet_callers",
    "test_cross_file_caller",
    "test_external_call_resolved",
    "test_json_with_real_lsp",
    "test_preconditions_pass_with_real_lsp",
    "test_no_lsp_preconditions_fail",
    "test_nested_caller_attribution",
    "test_dump_at_cursor_debug_false",
    "test_debug_false_with_real_lsp",
    "test_adapter_diagnostics_snapshot",
  }
  for _, name in ipairs(tests) do
    print("\n>>> " .. name)
    local fn = M[name]
    if fn then
      local ok_err, err = pcall(fn)
      if not ok_err then
        print(string.format("  ERROR %s -- %s", name, tostring(err)))
        table.insert(failures, { name = name, msg = tostring(err) })
      end
    end
  end

  print("\n" .. string.rep("=", 60))
  print(string.format("Headless Real-LSP: %d passed, %d failed", _counters.passes, #failures))
  if #failures > 0 then
    print("Failed tests:")
    for _, f in ipairs(failures) do
      print(string.format("  - %s -- %s", f.name, f.msg or "(no message)"))
    end
    vim.cmd("cquit! 1")
  else
    print("All headless Real-LSP tests passed!")
    vim.cmd("q!")
  end
end

return M
