--- tests/headless_integration.lua
---
--- Neovim headless integration tests for calltree.nvim.
---
--- Run with:
---   nvim --headless -u NORC -c "luafile tests/headless_integration.lua"
---
--- Verifies that the plugin's integration layer (adapter, providers,
--- init.lua, plugin/calltree.lua) loads and runs correctly inside a real
--- Neovim environment with real treesitter parsers. This is complementary
--- to the pure-Lua unit tests in test_runner.lua (which mock everything).
---
--- Exits 0 on success, 1 on any failure.

local M = {}

-- Tiny assert helper. Previously this was duplicated in headless_real_lsp.lua
-- with a comment saying "we don't want to depend on tests/assert.lua in case
-- the package.path isn't set up yet" — but runner_headless.lua sets up
-- package.path before requiring this module, so assert.lua IS available.
-- We keep a local copy here for backward compatibility (some tests call
-- ok/eq directly), but headless_real_lsp.lua now delegates to a shared
-- headless_helpers module to eliminate the duplication.
local failures = {}
local passes = 0

local function ok(name, cond, msg)
  if cond then
    passes = passes + 1
    print(string.format("  PASS  %s", name))
  else
    print(string.format("  FAIL  %s -- %s", name, msg or "(no message)"))
    table.insert(failures, { name = name, msg = msg })
  end
end

local function eq(name, a, b)
  if a == b then
    ok(name, true)
  else
    ok(name, false, string.format("expected %s, got %s", tostring(b), tostring(a)))
  end
end

-- Monotonic counter for unique buffer names. Previously
-- `_G._calltree_test_counter` was referenced but NEVER incremented, so two
-- tests running in the same second got the same buffer name, causing
-- collisions. This helper increments the counter on every call, guaranteeing
-- uniqueness even within the same second.
local function unique_suffix()
  _G._calltree_test_counter = (_G._calltree_test_counter or 0) + 1
  return tostring(os.time()) .. "_" .. tostring(_G._calltree_test_counter)
end

--------------------------------------------------------------------------------
-- Test 1: plugin loads via require("calltree")
--------------------------------------------------------------------------------
function M.test_require_calltree()
  local cb = require("calltree")
  ok("require('calltree') returns table", type(cb) == "table")
  ok("calltree.setup is a function", type(cb.setup) == "function")
  ok("calltree.analyze_at_cursor is a function", type(cb.analyze_at_cursor) == "function")
  ok("calltree.analyze_at_cursor_json is a function", type(cb.analyze_at_cursor_json) == "function")
  ok("calltree.encode_json is a function", type(cb.encode_json) == "function")
  ok("calltree.dump_at_cursor is a function", type(cb.dump_at_cursor) == "function")
  ok("calltree.write_json_to_file is a function", type(cb.write_json_to_file) == "function")
end

--------------------------------------------------------------------------------
-- Test 2: adapter module loads
--------------------------------------------------------------------------------
function M.test_adapter_loads()
  local adapter = require("calltree.adapter")
  ok("adapter is table", type(adapter) == "table")
  ok("adapter.build_context is function", type(adapter.build_context) == "function")
  ok("adapter.read_file is function", type(adapter.read_file) == "function")
  ok("adapter.getcwd is function", type(adapter.getcwd) == "function")
  ok("adapter.lsp_client is table", type(adapter.lsp_client) == "table")
  ok("adapter.treesitter is table", type(adapter.treesitter) == "table")
end

--------------------------------------------------------------------------------
-- Test 3: setup() registers user commands
--------------------------------------------------------------------------------
function M.test_setup_registers_commands()
  require("calltree").setup()
  local cmds = vim.api.nvim_get_commands({})
  ok("CalltreeAnalyze registered", cmds["CalltreeAnalyze"] ~= nil, "CalltreeAnalyze missing")
  ok("CalltreeJson registered", cmds["CalltreeJson"] ~= nil, "CalltreeJson missing")
  ok("CalltreeJsonDebug registered", cmds["CalltreeJsonDebug"] ~= nil, "CalltreeJsonDebug missing")
  ok("CalltreeToFile registered", cmds["CalltreeToFile"] ~= nil, "CalltreeToFile missing")
end

--------------------------------------------------------------------------------
-- Test 4: plugin/calltree.lua auto-load guard works
--------------------------------------------------------------------------------
function M.test_plugin_autoload_guard()
  -- Set the guard and require again — should not crash.
  vim.g.loaded_calltree = true
  local ok_err, err = pcall(function()
    vim.cmd("runtime plugin/calltree.lua")
  end)
  ok("plugin runtime guard doesn't error", ok_err, tostring(err))
  vim.g.loaded_calltree = nil
end

--------------------------------------------------------------------------------
-- Test 5: treesitter provider parses lua source
--------------------------------------------------------------------------------
function M.test_treesitter_provider_parses_lua()
  local ts_provider = require("calltree.providers.treesitter")
  local buf = vim.api.nvim_create_buf(false, true)
  vim.api.nvim_set_current_buf(buf)
  vim.bo[buf].filetype = "lua"
  local src = "local function foo()\n  return 1\nend\n"
  vim.api.nvim_buf_set_lines(buf, 0, -1, false, vim.split(src, "\n"))
  local svc = ts_provider.new(buf)
  ok("treesitter service constructed", type(svc) == "table")
  ok("svc.parse is function", type(svc.parse) == "function")
  ok("svc.descendant_for_range is function", type(svc.descendant_for_range) == "function")
  local tree = svc:parse(src, "lua")
  ok("parse returns tree", tree ~= nil, "parse returned nil")
  if tree then
    ok("tree.root is function", type(tree.root) == "function")
    ok("tree.has_error is false", tree.has_error == false,
      "tree.has_error=" .. tostring(tree.has_error))
    local root = tree.root()
    ok("root is wrapped node", root ~= nil and type(root.type) == "function")
    if root then
      -- Lua tree-sitter grammar names the root node "chunk" (some grammars use "program").
      local rt = root:type()
      ok("root type is chunk or program", rt == "chunk" or rt == "program",
        "unexpected root type: " .. tostring(rt))
    end
  end
  vim.api.nvim_buf_delete(buf, { force = true })
end

--------------------------------------------------------------------------------
-- Test 6: treesitter provider string parser for foreign source
--------------------------------------------------------------------------------
function M.test_treesitter_string_parser()
  local ts_provider = require("calltree.providers.treesitter")
  local buf = vim.api.nvim_create_buf(false, true)
  vim.api.nvim_set_current_buf(buf)
  vim.bo[buf].filetype = "lua"
  vim.api.nvim_buf_set_lines(buf, 0, -1, false, { "local x = 1" })
  local svc = ts_provider.new(buf)
  -- Different source from buffer content → should use string parser.
  local foreign_src = "local function bar()\n  print('hi')\nend\n"
  local tree = svc:parse(foreign_src, "lua")
  ok("string parser returns tree", tree ~= nil)
  if tree then
    local root = tree.root()
    ok("string-parsed root is non-nil", root ~= nil)
    if root then
      local rt = root:type()
      ok("string-parsed root type is chunk or program",
        rt == "chunk" or rt == "program", "unexpected root type: " .. tostring(rt))
      -- descendant_for_range should return a node.
      local node = svc:descendant_for_range(root, 0, 6, 0, 15)
      ok("descendant_for_range returns node", node ~= nil)
    end
  end
  vim.api.nvim_buf_delete(buf, { force = true })
end

--------------------------------------------------------------------------------
-- Test 7: context.build with a real buffer
--------------------------------------------------------------------------------
function M.test_context_build()
  local context = require("calltree.core.context")
  local buf = vim.api.nvim_create_buf(false, true)
  vim.api.nvim_set_current_buf(buf)
  vim.bo[buf].filetype = "lua"
  local src = "local function greet()\n  print('hi')\nend\n"
  vim.api.nvim_buf_set_lines(buf, 0, -1, false, vim.split(src, "\n"))
  vim.api.nvim_buf_set_name(buf, os.tmpname() .. ".lua")
  local ctx = context.build(buf, { line = 0, character = 15 }, nil, { debug = true })
  ok("ctx is table", type(ctx) == "table")
  ok("ctx.source_code ends with newline", ctx.source_code:sub(-1) == "\n")
  ok("ctx.file_path set", ctx.file_path ~= "")
  eq("ctx.cursor_pos.line", ctx.cursor_pos.line, 0)
  eq("ctx.cursor_pos.character", ctx.cursor_pos.character, 15)
  eq("ctx.language", ctx.language, "lua")
  ok("ctx.lsp_client is table", type(ctx.lsp_client) == "table")
  ok("ctx.treesitter is table", type(ctx.treesitter) == "table")
  ok("ctx.getcwd is function", type(ctx.getcwd) == "function")
  ok("ctx.read_file is function", type(ctx.read_file) == "function")
  ok("ctx.package_paths is table", type(ctx.package_paths) == "table")
  ok("ctx.package_paths non-empty", #ctx.package_paths > 0)
  eq("ctx.debug", ctx.debug, true)
  vim.api.nvim_buf_delete(buf, { force = true })
end

--------------------------------------------------------------------------------
-- Test 8: analyzer runs end-to-end with treesitter (no LSP attached)
--------------------------------------------------------------------------------
function M.test_analyze_at_cursor_no_lsp()
  local calltree = require("calltree")
  local buf = vim.api.nvim_create_buf(false, true)
  vim.api.nvim_set_current_buf(buf)
  vim.bo[buf].filetype = "lua"
  local src = {
    "local function foo()",
    "  return 1",
    "end",
    "",
    "local function bar()",
    "  foo()",
    "end",
  }
  vim.api.nvim_buf_set_lines(buf, 0, -1, false, src)
  vim.api.nvim_buf_set_name(buf, os.tmpname() .. ".lua")
  -- Position cursor on "foo" at line 0 (function definition name).
  vim.api.nvim_win_set_cursor(0, { 1, 15 })
  local result = calltree.analyze_at_cursor(buf)
  ok("analyze_at_cursor returns table", type(result) == "table")
  ok("result.callers is table", type(result.callers) == "table")
  ok("result.external_calls is table", type(result.external_calls) == "table")
  ok("result.debug is table (no LSP, but debug should still be present)",
    type(result.debug) == "table")
  if result.debug then
    ok("debug.completion_reason is string",
      type(result.debug.completion_reason) == "string")
    ok("debug.preconditions is table",
      type(result.debug.preconditions) == "table")
    -- Without LSP attached, preconditions should fail (no document symbols).
    local any_failed = false
    for _, p in ipairs(result.debug.preconditions) do
      if not p.passed then any_failed = true; break end
    end
    ok("at least one precondition failed (no LSP)", any_failed,
      "all preconditions passed without LSP?")
  end
  vim.api.nvim_buf_delete(buf, { force = true })
end

--------------------------------------------------------------------------------
-- Test 9: analyze_at_cursor_json returns valid JSON string
--------------------------------------------------------------------------------
function M.test_analyze_at_cursor_json()
  local calltree = require("calltree")
  local buf = vim.api.nvim_create_buf(false, true)
  vim.api.nvim_set_current_buf(buf)
  vim.bo[buf].filetype = "lua"
  vim.api.nvim_buf_set_lines(buf, 0, -1, false, {
    "local function hello()",
    "  print('world')",
    "end",
  })
  vim.api.nvim_buf_set_name(buf, os.tmpname() .. ".lua")
  vim.api.nvim_win_set_cursor(0, { 1, 15 })
  local json = calltree.analyze_at_cursor_json(buf)
  ok("analyze_at_cursor_json returns string", type(json) == "string")
  ok("json starts with {", json:sub(1, 1) == "{", "json starts with: " .. json:sub(1, 1))
  ok("json ends with }", json:sub(-1) == "}", "json ends with: " .. json:sub(-1))
  -- Round-trip via vim.json.decode.
  local decoded = vim.json.decode(json)
  ok("json round-trips via vim.json.decode", type(decoded) == "table")
  if decoded then
    ok("decoded has callers", type(decoded.callers) == "table")
    ok("decoded has external_calls", type(decoded.external_calls) == "table")
  end
  vim.api.nvim_buf_delete(buf, { force = true })
end

--------------------------------------------------------------------------------
-- Test 10: write_json_to_file writes a valid JSON file
--------------------------------------------------------------------------------
function M.test_write_json_to_file()
  local calltree = require("calltree")
  local buf = vim.api.nvim_create_buf(false, true)
  vim.api.nvim_set_current_buf(buf)
  vim.bo[buf].filetype = "lua"
  vim.api.nvim_buf_set_lines(buf, 0, -1, false, {
    "local function f()",
    "  return 42",
    "end",
  })
  vim.api.nvim_buf_set_name(buf, os.tmpname() .. ".lua")
  vim.api.nvim_win_set_cursor(0, { 1, 15 })
  local out = os.tmpname() .. "_out.json"
  os.remove(out)
  local wrote = calltree.write_json_to_file(out, buf, { debug = true })
  ok("write_json_to_file returns true", wrote == true)
  local f = io.open(out, "r")
  ok("output file exists", f ~= nil)
  if f then
    local content = f:read("*a")
    f:close()
    ok("file content non-empty", #content > 0)
    ok("file content starts with {", content:sub(1, 1) == "{")
    local decoded = vim.json.decode(content)
    ok("file content decodes as table", type(decoded) == "table")
    -- debug was requested → field should be present.
    ok("file content has debug field", decoded.debug ~= nil)
  end
  os.remove(out)
  vim.api.nvim_buf_delete(buf, { force = true })
end

--------------------------------------------------------------------------------
-- Test 11: CalltreeJson user command executes without error
--------------------------------------------------------------------------------
function M.test_calltree_json_command()
  local buf = vim.api.nvim_create_buf(false, true)
  vim.api.nvim_set_current_buf(buf)
  vim.bo[buf].filetype = "lua"
  vim.api.nvim_buf_set_lines(buf, 0, -1, false, {
    "local function baz()",
    "  return 'x'",
    "end",
  })
  vim.api.nvim_buf_set_name(buf, os.tmpname() .. ".lua")
  vim.api.nvim_win_set_cursor(0, { 1, 15 })
  local captured = nil
  -- Capture print output via overriding print temporarily.
  local orig_print = _G.print
  _G.print = function(...) captured = (captured or "") .. table.concat({...}, "\t") end
  local ok_err, err = pcall(function() vim.cmd("CalltreeJson") end)
  _G.print = orig_print
  ok("CalltreeJson command runs", ok_err, tostring(err))
  ok("CalltreeJson produced output", captured ~= nil and #captured > 0,
    "no output captured")
  if captured then
    ok("CalltreeJson output starts with {", captured:sub(1, 1) == "{",
      "starts with: " .. captured:sub(1, 1))
  end
  vim.api.nvim_buf_delete(buf, { force = true })
end

--------------------------------------------------------------------------------
-- Test 12: CalltreeToFile user command writes a file
--------------------------------------------------------------------------------
function M.test_calltree_tofile_command()
  local buf = vim.api.nvim_create_buf(false, true)
  vim.api.nvim_set_current_buf(buf)
  vim.bo[buf].filetype = "lua"
  vim.api.nvim_buf_set_lines(buf, 0, -1, false, {
    "local function qux()",
    "  return true",
    "end",
  })
  vim.api.nvim_buf_set_name(buf, os.tmpname() .. ".lua")
  vim.api.nvim_win_set_cursor(0, { 1, 15 })
  local out = os.tmpname() .. "_cmd_out.json"
  os.remove(out)
  local ok_err, err = pcall(function() vim.cmd("CalltreeToFile " .. out) end)
  ok("CalltreeToFile command runs", ok_err, tostring(err))
  local f = io.open(out, "r")
  ok("CalltreeToFile produced file", f ~= nil)
  if f then
    local content = f:read("*a")
    f:close()
    ok("CalltreeToFile file content decodes", type(vim.json.decode(content)) == "table")
  end
  os.remove(out)
  vim.api.nvim_buf_delete(buf, { force = true })
end

--------------------------------------------------------------------------------
-- Test 13: setup({ debug = false }) is respected on subsequent analyze
-- Uses pcall + finally-style restore so a test failure between setup and
-- restore doesn't leak debug=false to subsequent tests.
--------------------------------------------------------------------------------
function M.test_setup_debug_false()
  local calltree = require("calltree")
  local buf = vim.api.nvim_create_buf(false, true)
  vim.api.nvim_set_current_buf(buf)
  vim.bo[buf].filetype = "lua"
  vim.api.nvim_buf_set_lines(buf, 0, -1, false, {
    "local function f()",
    "  return 1",
    "end",
  })
  vim.api.nvim_buf_set_name(buf, os.tmpname() .. ".lua")
  vim.api.nvim_win_set_cursor(0, { 1, 15 })
  -- Use pcall so restore ALWAYS runs, even if the assertion fails.
  -- Previously, if the assertion at line 379 failed, the restore at
  -- line 382 (calltree.setup({ debug = true })) never ran, leaking
  -- debug=false to subsequent tests.
  local test_ok, test_err = pcall(function()
    calltree.setup({ debug = false })
    local result = calltree.analyze_at_cursor(buf)
    ok("debug=false omits debug field", result.debug == nil,
      "debug field present: " .. tostring(result.debug ~= nil))
  end)
  -- Always restore default + clean up buffer (finally-style).
  pcall(function() calltree.setup({ debug = true }) end)
  pcall(function() vim.api.nvim_buf_delete(buf, { force = true }) end)
  if not test_ok then error(test_err) end
end

--------------------------------------------------------------------------------
-- Test 14: lsp_client provider methods exist on constructed object
--------------------------------------------------------------------------------
function M.test_lsp_client_methods()
  local lsp = require("calltree.providers.lsp_client")
  local buf = vim.api.nvim_create_buf(false, true)
  vim.api.nvim_set_current_buf(buf)
  vim.bo[buf].filetype = "lua"
  vim.api.nvim_buf_set_lines(buf, 0, -1, false, { "local x = 1" })
  local client = lsp.new(buf)
  ok("lsp.new returns table", type(client) == "table")
  ok("client.definition is function", type(client.definition) == "function")
  ok("client.declaration is function", type(client.declaration) == "function")
  ok("client.references is function", type(client.references) == "function")
  ok("client.document_symbols is function", type(client.document_symbols) == "function")
  ok("client._diagnostics is function", type(client._diagnostics) == "function")
  -- Without an attached LSP server, calls should return nil/empty gracefully.
  local defs = client:definition("file:///fake.lua", { line = 0, character = 0 })
  ok("definition returns table (empty when no LSP)", type(defs) == "table")
  local syms = client:document_symbols("file:///fake.lua")
  ok("document_symbols returns table (empty when no LSP)", type(syms) == "table")
  -- Diagnostics should be collected.
  local diag = client:_diagnostics()
  ok("diagnostics is table", type(diag) == "table")
  ok("at least one diagnostic entry (the failed definition call)",
    #diag >= 1, "diag count=" .. #diag)
  vim.api.nvim_buf_delete(buf, { force = true })
end

--------------------------------------------------------------------------------
-- Test 15: lsp_client capability map exposes required methods
--------------------------------------------------------------------------------
function M.test_lsp_capability_map()
  local lsp = require("calltree.providers.lsp_client")
  ok("METHOD_CAPABILITY_MAP is table", type(lsp.METHOD_CAPABILITY_MAP) == "table")
  local required = {
    "textDocument/definition",
    "textDocument/declaration",
    "textDocument/references",
    "textDocument/documentSymbol",
  }
  for _, m in ipairs(required) do
    ok("capability map has " .. m, lsp.METHOD_CAPABILITY_MAP[m] ~= nil)
  end
  ok("method_supported is function", type(lsp.method_supported) == "function")
  -- Test with empty clients list.
  local supported, reason = lsp.method_supported({}, "textDocument/definition")
  ok("no clients → not supported", supported == false, "expected false, got true")
  ok("reason is string", type(reason) == "string")
  -- Test with a fake client that has the capability.
  local fake_clients = {
    { name = "fake_lsp", id = 1, server_capabilities = { definitionProvider = true } },
  }
  local s2 = lsp.method_supported(fake_clients, "textDocument/definition")
  ok("fake client with definitionProvider → supported", s2 == true)
  -- Test with a client that has the capability as a table (some servers do this).
  local fake_clients_table = {
    { name = "fake_lsp2", id = 2, server_capabilities = { declarationProvider = { workDoneProgress = true } } },
  }
  local s3 = lsp.method_supported(fake_clients_table, "textDocument/declaration")
  ok("fake client with table capability → supported", s3 == true)
end

--------------------------------------------------------------------------------
-- Test 16: preconditions module works with real treesitter
--------------------------------------------------------------------------------
function M.test_preconditions_with_real_ts()
  local preconditions = require("calltree.analysis.preconditions")
  local debug_mod    = require("calltree.utils.debug")
  local buf = vim.api.nvim_create_buf(false, true)
  vim.api.nvim_set_current_buf(buf)
  vim.bo[buf].filetype = "lua"
  vim.api.nvim_buf_set_lines(buf, 0, -1, false, {
    "local function f()",
    "  return 1",
    "end",
  })
  vim.api.nvim_buf_set_name(buf, os.tmpname() .. ".lua")
  local ctx = require("calltree.core.context").build(buf, { line = 0, character = 15 }, nil, { debug = true })
  -- DebugCollector.new(ctx) requires a ctx table to snapshot inputs.
  local dbg = debug_mod.new(ctx)
  ok("debug collector constructed", type(dbg) == "table")
  -- preconditions.check returns (passed:bool, root:node|nil, symbols:table|nil)
  local passed, root, symbols = preconditions.check(ctx, dbg)
  ok("preconditions.check returns boolean passed", type(passed) == "boolean")
  -- Without an LSP attached, preconditions should FAIL (empty document symbols).
  -- (If somehow passed=true, that would be suspicious — no LSP is attached.)
  ok("preconditions fail without LSP", passed == false,
    "preconditions passed without any LSP server attached")
  -- The debug collector should have recorded the precondition checks.
  local data = dbg:get()
  ok("dbg.data is table", type(data) == "table")
  ok("dbg.data.preconditions is table", type(data.preconditions) == "table")
  ok("at least one precondition recorded", #data.preconditions >= 1)
  -- Treesitter check should have passed (we have a real lua parser).
  local ts_passed = false
  for _, c in ipairs(data.preconditions) do
    if c.check == "treesitter" and c.passed == true then
      ts_passed = true; break
    end
  end
  ok("treesitter precondition passed", ts_passed,
    "no treesitter precondition with passed=true recorded")
  -- Verify root type recorded in ts_parse (should be "chunk" for lua).
  ok("dbg.data.ts_parses is table", type(data.ts_parses) == "table")
  if #data.ts_parses > 0 then
    local rt = data.ts_parses[1].root_type
    ok("ts_parses[1].root_type is chunk or program",
      rt == "chunk" or rt == "program" or rt == nil,
      "root_type=" .. tostring(rt))
  end
  vim.api.nvim_buf_delete(buf, { force = true })
end

--------------------------------------------------------------------------------
-- Test 17: real lua file analysis — file actually exists on disk
--------------------------------------------------------------------------------
function M.test_real_file_on_disk()
  -- Write a real .lua file to /tmp and edit it.
  local path = os.tmpname() .. "_on_disk.lua"
  local f = io.open(path, "w")
  if f then
    f:write("local function alpha()\n  return 1\nend\n\nlocal function beta()\n  alpha()\nend\n")
    f:close()
  end
  vim.cmd("edit " .. path)
  vim.bo.filetype = "lua"
  -- Cursor on "alpha" function name.
  vim.api.nvim_win_set_cursor(0, { 1, 15 })
  local calltree = require("calltree")
  local result = calltree.analyze_at_cursor(0)
  ok("real-file analyze returns table", type(result) == "table")
  ok("real-file result.debug is table", type(result.debug) == "table")
  if result.debug then
    -- Treesitter should parse the real file successfully.
    local ts_ok = false
    if result.debug.ts_parses then
      for _, p in ipairs(result.debug.ts_parses) do
        if p.ok then ts_ok = true; break end
      end
    end
    ok("real-file treesitter parse ok", ts_ok, "no successful ts_parse recorded")
  end
  vim.cmd("bdelete! " .. path)
  os.remove(path)
end

--------------------------------------------------------------------------------
-- Test 18: read_file and getcwd helpers
--------------------------------------------------------------------------------
function M.test_helpers()
  local adapter = require("calltree.adapter")
  local tmp = os.tmpname() .. "_helper.txt"
  local f = io.open(tmp, "w")
  -- Guard: io.open can return nil; previously f:write would crash.
  if not f then
    ok("setup: could not open " .. tmp .. " for writing", false)
    return
  end
  f:write("hello\nworld\n")
  f:close()
  local content = adapter.read_file(tmp)
  ok("read_file returns content", content == "hello\nworld\n",
    "got: " .. tostring(content))
  local none = adapter.read_file("/nonexistent/path/12345.lua")
  ok("read_file returns nil for missing", none == nil)
  local cwd = adapter.getcwd()
  ok("getcwd returns string", type(cwd) == "string")
  ok("getcwd non-empty", #cwd > 0)
  os.remove(tmp)
end

--------------------------------------------------------------------------------
-- Runner
--------------------------------------------------------------------------------
function M.run()
  print("=== calltree.nvim headless integration tests ===")
  print("nvim version: " .. vim.version().major .. "." .. vim.version().minor .. "." .. vim.version().patch)
  local tests = {
    "test_require_calltree",
    "test_adapter_loads",
    "test_setup_registers_commands",
    "test_plugin_autoload_guard",
    "test_treesitter_provider_parses_lua",
    "test_treesitter_string_parser",
    "test_context_build",
    "test_analyze_at_cursor_no_lsp",
    "test_analyze_at_cursor_json",
    "test_write_json_to_file",
    "test_calltree_json_command",
    "test_calltree_tofile_command",
    "test_setup_debug_false",
    "test_lsp_client_methods",
    "test_lsp_capability_map",
    "test_preconditions_with_real_ts",
    "test_real_file_on_disk",
    "test_helpers",
  }
  for _, name in ipairs(tests) do
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
  print(string.format("Headless: %d passed, %d failed", passes, #failures))
  if #failures > 0 then
    print("Failed tests:")
    for _, f in ipairs(failures) do
      print(string.format("  - %s -- %s", f.name, f.msg or "(no message)"))
    end
    -- cquit! with non-zero exit code so the shell can detect failure.
    vim.cmd("cquit! 1")
  else
    print("All headless tests passed!")
    vim.cmd("q!")
  end
end

return M
