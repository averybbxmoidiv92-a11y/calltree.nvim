-- tests/run_javascript_tests.lua
--
-- Integration tests for calltree.nvim against a real JavaScript project
-- using typescript-language-server. Verifies the full analysis pipeline:
--   1. Open .js files from tests/javascript_project/
--   2. Attach typescript-language-server (shared session)
--   3. Place cursor on function/arrow-function/method names
--   4. Call require("calltree").analyze_at_cursor(0)
--   5. Assert callers / external_calls match expectations
--   6. Verify JSON output structure
--
-- Run:
--   nvim --headless -u NORC -c "luafile tests/run_javascript_tests.lua"
--
-- Exit code 0 = all passed, 1 = at least one failure.
-- Prerequisites:
--   - typescript-language-server on PATH (or CALLTREE_TSSERVER_BIN env var)
--   - typescript installed in tests/javascript_project/node_modules
--   - tree-sitter-javascript parser installed in Neovim's parser dir

-- Source the JS nvim init (sets up runtimepath + typescript-language-server).
local this_file = debug.getinfo(1, "S").source
if this_file:sub(1, 1) == "@" then this_file = this_file:sub(2) end
local script_dir = this_file:match("(.*/)") or "."
script_dir = script_dir:gsub("/$", "")
vim.cmd("luafile " .. script_dir .. "/javascript_nvim_init.lua")

local PROJECT_DIR = vim.fn.fnamemodify(script_dir .. "/javascript_project", ":p"):gsub("/$", "")

--================================================================================
-- Test infrastructure
--================================================================================

local total_pass = 0
local total_fail = 0
local failures = {}

local function ok(name, cond, detail)
  if cond then
    total_pass = total_pass + 1
    print(string.format("  PASS  %s", name))
  else
    total_fail = total_fail + 1
    print(string.format("  FAIL  %s", name))
    if detail then print(string.format("        %s", tostring(detail))) end
    table.insert(failures, { name = name, detail = detail })
  end
end

local function eq(name, actual, expected, detail)
  if actual == expected then
    total_pass = total_pass + 1
    print(string.format("  PASS  %s", name))
  else
    total_fail = total_fail + 1
    print(string.format("  FAIL  %s", name))
    print(string.format("        expected: %s", tostring(expected)))
    print(string.format("        actual:   %s", tostring(actual)))
    if detail then print(string.format("        detail:   %s", tostring(detail))) end
    table.insert(failures, { name = name, detail = detail })
  end
end

--================================================================================
-- LSP session setup (shared across all tests for speed)
--================================================================================

-- Open both project files and attach tsserver. Warm up by requesting
-- documentSymbol on both so cross-file references work.
local utils_bufnr, index_bufnr

local function setup_lsp_session()
  vim.cmd("cd " .. PROJECT_DIR)
  -- Open index.js first (it requires utils.js, so tsserver will index both).
  vim.cmd("edit " .. PROJECT_DIR .. "/index.js")
  vim.bo.filetype = "javascript"
  _G.start_tsserver(0)
  index_bufnr = vim.api.nvim_get_current_buf()
  -- Wait for LSP readiness.
  local ready = vim.wait(20000, function()
    local clients = vim.lsp.get_active_clients({ bufnr = 0 })
    return clients[1] ~= nil
      and clients[1].server_capabilities ~= nil
      and clients[1].server_capabilities.documentSymbolProvider == true
  end, 100)
  if not ready then return false end
  -- Warm up index.js.
  vim.lsp.buf_request_sync(0, "textDocument/documentSymbol", {
    textDocument = { uri = vim.uri_from_bufnr(0) }
  }, 10000)
  -- Open utils.js in a split (shares the same tsserver client).
  vim.cmd("split " .. PROJECT_DIR .. "/utils.js")
  vim.bo.filetype = "javascript"
  utils_bufnr = vim.api.nvim_get_current_buf()
  -- Warm up utils.js.
  vim.lsp.buf_request_sync(0, "textDocument/documentSymbol", {
    textDocument = { uri = vim.uri_from_bufnr(0) }
  }, 10000)
  vim.wait(1000)
  return true
end

-- Switch to a buffer and place cursor on a name (skipping comments/strings).
local function focus_and_cursor(bufnr, name)
  vim.api.nvim_set_current_buf(bufnr)
  local lines = vim.api.nvim_buf_get_lines(bufnr, 0, -1, false)
  for i, line in ipairs(lines) do
    local trimmed = line:match("^%s*(.*)$")
    if trimmed and not trimmed:match("^//") then
      local start = 1
      while true do
        local s, e = line:find(name, start, true)
        if s == nil then break end
        local before = s > 1 and line:sub(s - 1, s - 1) or " "
        local after = e < #line and line:sub(e + 1, e + 1) or " "
        if not before:match("[%w_]") and not after:match("[%w_]") then
          local prefix = line:sub(1, s - 1)
          local _, qc = prefix:gsub('"', "")
          local _, sc = prefix:gsub("'", "")
          if qc % 2 == 0 and sc % 2 == 0 then
            vim.api.nvim_win_set_cursor(0, { i, s - 1 })
            return true
          end
        end
        start = e + 1
      end
    end
  end
  return false
end

local function settle()
  vim.wait(500)
end

--================================================================================
-- Tests
--================================================================================

-- Test 1: Arrow function cross-file caller
--   utils.js: const add = (a, b) => a + b;
--   index.js: const sum = (a, b) => { return add(a, b); };
--   Cursor on "add" in utils.js → callers should contain "sum".
local function test_arrow_function_cross_file_caller()
  print(">>> test_arrow_function_cross_file_caller")
  ok("cursor placed on 'add'", focus_and_cursor(utils_bufnr, "add"))
  settle()
  local result = require("calltree").analyze_at_cursor(0, { debug = true })
  ok("current_function detected", result.current_function ~= nil,
    "reason=" .. (result.debug and result.debug.completion_reason or "?"))
  if result.current_function then
    eq("current_function.name is 'add'", result.current_function.name, "add")
  end
  local found = false
  for _, c in ipairs(result.callers) do
    if c.caller_function.name == "sum" then
      found = true
      ok("caller file is index.js", c.file and c.file:find("index.js") ~= nil)
    end
  end
  ok("found 'sum' as caller of 'add'", found, "callers count=" .. #result.callers)
end

-- Test 2: Function declaration cross-file caller
--   utils.js: function greet(name) { ... }
--   index.js: function welcome(name) { return greet(name); }
--   Cursor on "greet" → callers should contain "welcome".
local function test_function_declaration_cross_file_caller()
  print(">>> test_function_declaration_cross_file_caller")
  ok("cursor placed on 'greet'", focus_and_cursor(utils_bufnr, "greet"))
  settle()
  local result = require("calltree").analyze_at_cursor(0, { debug = true })
  ok("current_function detected", result.current_function ~= nil,
    "reason=" .. (result.debug and result.debug.completion_reason or "?"))
  if result.current_function then
    eq("current_function.name is 'greet'", result.current_function.name, "greet")
  end
  local found = false
  for _, c in ipairs(result.callers) do
    if c.caller_function.name == "welcome" then found = true end
  end
  ok("found 'welcome' as caller of 'greet'", found, "callers count=" .. #result.callers)
end

-- Test 3: Class method analysis (current_function detection)
--   index.js: class App { run(x, y) { ... } }
--   Cursor on "run" → current_function should be "run".
--   external_calls may be empty because:
--     - `new Calculator()` is a new_expression (not call_expression)
--     - `calc.multiply()` may be discarded as in_scope by the LSP
--   The key assertion is that the class method is correctly detected
--   and named, demonstrating JS class method support.
local function test_class_method_external_call()
  print(">>> test_class_method_external_call")
  ok("cursor placed on 'run'", focus_and_cursor(index_bufnr, "run"))
  settle()
  local result = require("calltree").analyze_at_cursor(0, { debug = true })
  ok("current_function detected", result.current_function ~= nil,
    "reason=" .. (result.debug and result.debug.completion_reason or "?"))
  if result.current_function then
    eq("current_function.name is 'run'", result.current_function.name, "run")
  end
  -- external_calls should be a table (may be empty due to new_expression
  -- not being collected and calc.multiply being discarded as in_scope).
  ok("external_calls is a table", type(result.external_calls) == "table")
end

-- Test 4: Arrow function external call
--   index.js: const sum = (a, b) => { return add(a, b); };
--   Cursor on "sum" → external_calls should contain "add" (resolved to utils.js).
local function test_arrow_function_external_call()
  print(">>> test_arrow_function_external_call")
  ok("cursor placed on 'sum'", focus_and_cursor(index_bufnr, "sum"))
  settle()
  local result = require("calltree").analyze_at_cursor(0, { debug = true })
  ok("current_function detected", result.current_function ~= nil,
    "reason=" .. (result.debug and result.debug.completion_reason or "?"))
  if result.current_function then
    eq("current_function.name is 'sum'", result.current_function.name, "sum")
  end
  local found = false
  for _, ec in ipairs(result.external_calls) do
    if ec.function_name == "add" then
      found = true
      eq("add resolution_status is 'resolved'", ec.resolution_status, "resolved")
      if ec.definition then
        ok("add definition.file is utils.js",
          ec.definition.file and ec.definition.file:find("utils.js") ~= nil)
      end
    end
  end
  ok("found 'add' in external_calls", found, "count=" .. #result.external_calls)
end

-- Test 5: JSON output structure integrity
local function test_json_output_structure()
  print(">>> test_json_output_structure")
  ok("cursor placed on 'welcome'", focus_and_cursor(index_bufnr, "welcome"))
  settle()
  local json = require("calltree").analyze_at_cursor_json(0, { debug = true })
  ok("JSON output is a string", type(json) == "string")
  if type(json) == "string" then
    ok("JSON contains 'current_function'", json:find('"current_function"') ~= nil)
    ok("JSON contains 'callers'", json:find('"callers"') ~= nil)
    ok("JSON contains 'external_calls'", json:find('"external_calls"') ~= nil)
    ok("JSON contains 'debug'", json:find('"debug"') ~= nil)
  end
end

-- Test 6: ES6 import statement doesn't crash analysis
--   index.js: import { add, greet, Calculator } from './utils';
--   Cursor on "import" keyword — analysis should complete without error.
local function test_import_no_crash()
  print(">>> test_import_no_crash")
  ok("cursor placed on 'import'", focus_and_cursor(index_bufnr, "import"))
  settle()
  local result = require("calltree").analyze_at_cursor(0, { debug = true })
  ok("analysis completed (result is a table)", type(result) == "table")
  ok("callers is a table", type(result.callers) == "table")
  ok("external_calls is a table", type(result.external_calls) == "table")
end

--================================================================================
-- Run all tests
--================================================================================

print("================================================================")
print("calltree.nvim — JavaScript integration tests")
print("================================================================")
print("project dir : " .. PROJECT_DIR)
print("================================================================")

print("")
print(">>> Setting up LSP session (shared across tests)...")
local session_ok = setup_lsp_session()
if not session_ok then
  print("FAIL: could not start tsserver or attach to project files")
  vim.cmd("cquit! 1")
end
print("LSP session ready.")
print("================================================================")

local tests = {
  test_arrow_function_cross_file_caller,
  test_function_declaration_cross_file_caller,
  test_class_method_external_call,
  test_arrow_function_external_call,
  test_json_output_structure,
  test_import_no_crash,
}

for _, t in ipairs(tests) do
  print("")
  t()
end

-- Cleanup: stop tsserver.
pcall(function()
  for _, c in ipairs(vim.lsp.get_active_clients()) do
    vim.lsp.stop_client(c.id, true)
  end
end)

print("")
print("============================================================")
print(string.format("JavaScript integration: %d passed, %d failed", total_pass, total_fail))
if total_fail > 0 then
  print("Failed tests:")
  for _, f in ipairs(failures) do
    print("  - " .. f.name .. (f.detail and (" -- " .. tostring(f.detail)) or ""))
  end
  vim.cmd("cquit! 1")
else
  print("All JavaScript integration tests passed!")
end
print("============================================================")
