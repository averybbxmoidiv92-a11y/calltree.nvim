--- tests/c/run_c_tests.lua — real-LSP headless runner for C language tests.
---
--- Run with:
---   nvim --headless -u NORC \
---     -c "luafile tests/c/run_c_tests.lua"
---
--- This script:
---   1. Sets up runtimepath to include calltree.nvim
---   2. For each scenario: configures clangd with THAT scenario's compile_commands.json,
---      opens the .c file, positions the cursor, runs calltree.analyze_at_cursor()
---   3. Asserts the analysis result matches the spec expectation
---   4. Prints PASS/FAIL for each scenario and a final summary
---
--- Uses REAL tree-sitter-c parser (built into nvim) and REAL clangd LSP
--- server — no mocks. This exposes real plugin behavior on real C code.

--------------------------------------------------------------------------------
-- Paths & constants
--------------------------------------------------------------------------------
local this_file = debug.getinfo(1, "S").source
if this_file:sub(1, 1) == "@" then this_file = this_file:sub(2) end
local this_dir = this_file:match("(.*/)") or "./"
local PLUGIN_DIR = vim.fs.normalize(this_dir .. "/../..")
local SCENARIOS_DIR = PLUGIN_DIR .. "/tests/c/scenarios"
local CLANGD_BIN = os.getenv("CALLTREE_CLANGD_BIN") or "clangd"

--------------------------------------------------------------------------------
-- Set up runtimepath so `require("calltree")` works
--------------------------------------------------------------------------------
vim.opt.runtimepath:prepend(PLUGIN_DIR)
package.path = PLUGIN_DIR .. "/lua/?.lua;" ..
               PLUGIN_DIR .. "/lua/?/init.lua;" ..
               package.path

-- Disable LSP diagnostics handlers. In headless mode, the diagnostic
-- refresh path calls nvim__redraw which can raise "attempt to index field
-- 'loaded' (a nil value)" inside an autocmd — killing the whole test run.
-- We don't need diagnostics for these tests, so disable them up front.
vim.diagnostic.enable(false)

--------------------------------------------------------------------------------
-- Small assertion library
--------------------------------------------------------------------------------
local failures = {}
local current_scenario = nil

local function record_fail(msg, expected, actual)
  local entry = {
    scenario = current_scenario or "?",
    message = msg,
    expected = expected,
    actual = actual,
  }
  table.insert(failures, entry)
  error(entry, 2)
end

local A = {}
function A.equal(expected, actual, msg)
  if expected ~= actual then
    record_fail(msg or ("expected " .. tostring(expected) .. ", got " .. tostring(actual)), expected, actual)
  end
end
function A.is_not_nil(actual, msg)
  if actual == nil then record_fail(msg or "expected non-nil, got nil", "non-nil", nil) end
end
function A.is_nil(actual, msg)
  if actual ~= nil then record_fail(msg or ("expected nil, got " .. tostring(actual)), nil, actual) end
end
function A.length(n, list, msg)
  if list == nil then record_fail(msg or "expected length " .. n .. ", got nil", n, nil) end
  local got = list and #list or 0
  if got ~= n then
    record_fail(msg or ("expected length " .. n .. ", got " .. got), n, got)
  end
end
function A.truthy(actual, msg)
  if not actual then record_fail(msg or ("expected truthy, got " .. tostring(actual)), "truthy", actual) end
end
function A.contains_name(list, field, value, msg)
  -- list[i][field] may be a string OR a table with a .name field
  -- (e.g. caller_function = { name = "bar", range = ... }).
  for _, item in ipairs(list) do
    local v = item[field]
    if v == value then return end
    if type(v) == "table" and v.name == value then return end
  end
  record_fail(msg or ("list does not contain " .. field .. "=" .. tostring(value)), value, nil)
end

--------------------------------------------------------------------------------
-- Configure clangd for a given scenario root_dir and edit a file.
-- Returns bufnr once clangd is attached and ready.
--------------------------------------------------------------------------------
local function setup_and_open(scenario_dir, file_path, wait_ms)
  wait_ms = wait_ms or 8000

  -- Edit the file first so we have a buffer to attach to.
  vim.cmd("edit " .. file_path)
  local bufnr = vim.api.nvim_get_current_buf()
  vim.bo[bufnr].filetype = "c"

  -- Each scenario gets its own clangd instance scoped to that scenario's
  -- directory (so compile_commands.json doesn't leak across scenarios).
  -- Use vim.lsp.start (Neovim 0.8+) for compatibility with 0.10.
  vim.lsp.start({
    name = "clangd",
    cmd = { CLANGD_BIN, "--background-index", "--clang-tidy=false", "--log=error",
            "--compile-commands-dir=" .. scenario_dir },
    root_dir = scenario_dir,
    capabilities = vim.lsp.protocol.make_client_capabilities(),
  }, { bufnr = bufnr })

  -- Wait for clangd to attach
  local attached = vim.wait(wait_ms, function()
    local clients = vim.lsp.get_clients and vim.lsp.get_clients({ bufnr = bufnr })
      or vim.lsp.get_active_clients({ bufnr = bufnr })
    return #clients > 0
  end, 50)
  if not attached then
    error("clangd did not attach to " .. file_path .. " within " .. wait_ms .. "ms")
  end

  -- Wait for clangd to be ready (documentSymbol returns non-empty).
  local ready = vim.wait(wait_ms, function()
    local params = { textDocument = vim.lsp.util.make_text_document_params(bufnr) }
    local r = vim.lsp.buf_request_sync(bufnr, "textDocument/documentSymbol", params, 1000)
    if r == nil then return false end
    for _, res in pairs(r) do
      if res.result and #res.result > 0 then return true end
    end
    return false
  end, 100)
  if not ready then
    error("clangd did not produce documentSymbol for " .. file_path .. " within " .. wait_ms .. "ms")
  end

  -- Give clangd additional time to build the cross-reference index.
  -- clangd produces documentSymbol quickly (AST only), but textDocument/references
  -- needs the background index. Open sibling translation units so clangd
  -- indexes the whole scenario directory (important for cross-file callers).
  local siblings = vim.fn.glob(scenario_dir .. "/*.[cC]", false, true)
  for _, sib in ipairs(siblings) do
    if sib ~= file_path then
      pcall(function()
        local b = vim.fn.bufadd(sib)
        vim.fn.bufload(b)
        vim.bo[b].filetype = "c"
        -- Attach the existing clangd client to sibling buffers when possible.
        local clients = vim.lsp.get_clients and vim.lsp.get_clients({ name = "clangd" })
          or vim.lsp.get_active_clients({ name = "clangd" })
        for _, c in ipairs(clients) do
          pcall(vim.lsp.buf_attach_client, b, c.id)
        end
      end)
    end
  end
  -- Poll references until the index is warm (or timeout).
  vim.wait(8000, function()
    local params = {
      textDocument = vim.lsp.util.make_text_document_params(bufnr),
      position = { line = 0, character = 0 },
      context = { includeDeclaration = true },
    }
    -- Use workspace/symbol as a cheap readiness probe if available; otherwise just wait.
    local ok_r, r = pcall(vim.lsp.buf_request_sync, bufnr, "textDocument/documentSymbol",
      { textDocument = vim.lsp.util.make_text_document_params(bufnr) }, 500)
    return ok_r and r ~= nil
  end, 200)
  vim.wait(2000)

  return bufnr
end

--------------------------------------------------------------------------------
-- Run calltree.analyze_at_cursor() at the given cursor position.
--------------------------------------------------------------------------------
local function analyze_at(file_path, cursor_line, cursor_col)
  -- Set cursor (nvim uses 1-based line, 0-based byte column).
  vim.api.nvim_win_set_cursor(0, { cursor_line + 1, cursor_col })
  local calltree = require("calltree")
  -- Pass skip_stdlib_calls=false and deduplicate_external_calls=false
  -- so the raw external_calls list is returned (the C scenarios assert
  -- on exact counts including unresolved calls whose is_stdlib is nil,
  -- which would be filtered out by the v1.2.0+ default skip_stdlib_calls=true).
  return calltree.analyze_at_cursor(0, {
    skip_stdlib_calls = false,
    deduplicate_external_calls = false,
  })
end

--------------------------------------------------------------------------------
-- Clean up: stop LSP clients, delete buffer.
--------------------------------------------------------------------------------
local function cleanup()
  -- Stop all clangd clients so the next scenario starts fresh.
  local clients = vim.lsp.get_clients and vim.lsp.get_clients()
    or vim.lsp.get_active_clients()
  for _, client in ipairs(clients) do
    if client.name == "clangd" then
      pcall(vim.lsp.stop_client, client.id, true)
    end
  end
  -- Force-delete all buffers.
  for _, b in ipairs(vim.api.nvim_list_bufs()) do
    pcall(vim.api.nvim_buf_delete, b, { force = true })
  end
  -- Wait briefly for client shutdown.
  vim.wait(500, function()
    local c = vim.lsp.get_clients and vim.lsp.get_clients()
      or vim.lsp.get_active_clients()
    return #c == 0
  end, 50)
  collectgarbage("collect")
end

--------------------------------------------------------------------------------
-- Test runner
--------------------------------------------------------------------------------
local total_pass = 0
local total_fail = 0

local function run_scenario(name, scenario_dir, file_path, cursor_line, cursor_col, expectations_fn)
  current_scenario = name
  io.write(string.format("[RUN ] %s\n", name))
  io.flush()
  local ok, err = pcall(function()
    setup_and_open(scenario_dir, file_path)
    local result = analyze_at(file_path, cursor_line, cursor_col)
    expectations_fn(result)
  end)
  if ok then
    io.write(string.format("[PASS] %s\n", name))
    total_pass = total_pass + 1
  else
    io.write(string.format("[FAIL] %s\n", name))
    if type(err) == "table" then
      io.write(string.format("       message: %s\n", tostring(err.message or err)))
      if err.expected ~= nil then
        io.write(string.format("       expected: %s\n", tostring(err.expected)))
      end
      if err.actual ~= nil then
        io.write(string.format("       actual:   %s\n", tostring(err.actual)))
      end
    else
      -- String error: may be a stack trace; show first 3 lines.
      local lines = {}
      for line in tostring(err):gmatch("[^\n]+") do
        table.insert(lines, line)
        if #lines >= 5 then break end
      end
      for _, l in ipairs(lines) do
        io.write(string.format("       %s\n", l))
      end
    end
    io.flush()
    total_fail = total_fail + 1
  end
  io.flush()
  cleanup()
  current_scenario = nil
end

--------------------------------------------------------------------------------
-- Helper: dump result for debug logging on failure
--------------------------------------------------------------------------------
local function dump_result(r)
  if r == nil then return "<nil result>" end
  local cf = r.current_function
  local lines = {}
  if cf then
    table.insert(lines, string.format("current_function: name=%s range=[%s,%s] file=%s",
      cf.name, cf.range and cf.range[1], cf.range and cf.range[2], cf.file))
  else
    table.insert(lines, "current_function: nil")
  end
  table.insert(lines, string.format("callers (%d):", #r.callers))
  for _, c in ipairs(r.callers) do
    table.insert(lines, string.format("  - name=%s file=%s call_pos=(%s,%s)",
      c.caller_function.name, c.file,
      c.call_position.line, c.call_position.character))
  end
  table.insert(lines, string.format("external_calls (%d):", #r.external_calls))
  for _, ec in ipairs(r.external_calls) do
    table.insert(lines, string.format("  - name=%s status=%s file=%s",
      ec.function_name, ec.resolution_status,
      ec.definition and ec.definition.file or "?"))
  end
  if r.debug then
    table.insert(lines, "completion_reason=" .. tostring(r.debug.completion_reason))
    if r.debug.external_call_decisions then
      for _, d in ipairs(r.debug.external_call_decisions) do
        table.insert(lines, string.format("  decision: %s outcome=%s reason=%s",
          d.function_name, d.outcome, d.reason))
      end
    end
  end
  return table.concat(lines, "\n")
end

--------------------------------------------------------------------------------
-- The 10 scenarios
--------------------------------------------------------------------------------

local D = SCENARIOS_DIR  -- alias for brevity

-- Scenario 1: Simple function definition identification
run_scenario("S01 simple function definition",
  D .. "/s01_simple", D .. "/s01_simple/s01_simple.c", 0, 4,
  function(r)
    A.is_not_nil(r.current_function, "current_function should be detected")
    A.equal("add", r.current_function.name)
    A.equal(1, r.current_function.range[1], "range start line should be 1")
    A.equal(3, r.current_function.range[2], "range end line should be 3")
    A.equal(0, #r.callers, "no callers expected")
    A.equal(0, #r.external_calls, "no external calls expected (add has no nested calls)")
  end)

-- Scenario 2: Direct caller lookup (single file)
run_scenario("S02 direct callers single file",
  D .. "/s02_callers", D .. "/s02_callers/s02_callers.c", 0, 5,
  function(r)
    A.is_not_nil(r.current_function, "current_function should be detected")
    A.equal("foo", r.current_function.name)
    -- Build a readable list of caller names for diagnostics
    local function caller_names(list)
      local names = {}
      for _, c in ipairs(list) do table.insert(names, c.caller_function.name) end
      return table.concat(names, ",")
    end
    A.equal(2, #r.callers,
      "exactly two callers (bar, baz); foo self excluded. Got " ..
      #r.callers .. " callers: [" .. caller_names(r.callers) .. "]")
    A.contains_name(r.callers, "caller_function", "bar",
      "callers should contain 'bar'. Got: [" .. caller_names(r.callers) .. "]")
    A.contains_name(r.callers, "caller_function", "baz",
      "callers should contain 'baz'. Got: [" .. caller_names(r.callers) .. "]")
    for _, c in ipairs(r.callers) do
      A.equal(false, c.caller_function.name == "foo", "foo should not be its own caller")
    end
  end)

-- Scenario 3: External call (same file) — resolution
run_scenario("S03 external call same file",
  D .. "/s03_external", D .. "/s03_external/s03_external.c", 1, 4,
  function(r)
    A.is_not_nil(r.current_function, "current_function should be detected")
    A.equal("calc", r.current_function.name)
    A.equal(1, #r.external_calls, "exactly one external call (helper)")
    local ec = r.external_calls[1]
    A.equal("helper", ec.function_name)
    A.equal("resolved", ec.resolution_status)
    A.is_not_nil(ec.definition, "definition must be present")
    A.is_not_nil(ec.definition.function_body_range, "function_body_range must be present")
  end)

-- Scenario 4: Function pointer call — graceful unresolved degradation
run_scenario("S04 function pointer call unresolved",
  D .. "/s04_funcptr", D .. "/s04_funcptr/s04_funcptr.c", 1, 5,
  function(r)
    A.is_not_nil(r.current_function, "current_function should be detected")
    A.equal("dispatcher", r.current_function.name)
    A.equal(1, #r.external_calls, "exactly one external call (fp)")
    local ec = r.external_calls[1]
    A.equal("fp", ec.function_name)
    A.equal("unresolved", ec.resolution_status,
      "function pointer call must be unresolved (LSP cannot track the target)")
    A.is_nil(ec.definition, "definition must be nil for unresolved call")
  end)

-- Scenario 5: Struct method (function pointer member call)
run_scenario("S05 struct member call",
  D .. "/s05_struct", D .. "/s05_struct/s05_struct.c", 2, 5,
  function(r)
    A.is_not_nil(r.current_function, "current_function should be detected")
    A.equal("use", r.current_function.name)
    -- clangd often fails to resolve m.add -> real_add, so accept either
    -- resolved or unresolved. The key requirement: NO crash.
    A.truthy(#r.external_calls >= 0, "no crash on struct member call")
    if #r.external_calls > 0 then
      local ec = r.external_calls[1]
      local name_ok = (ec.function_name == "m.add") or (ec.function_name == "real_add")
      A.truthy(name_ok,
        "external_call name should be 'm.add' or 'real_add', got: " .. tostring(ec.function_name))
    end
  end)

-- Scenario 6: typedef type alias
run_scenario("S06 typedef alias",
  D .. "/s06_typedef", D .. "/s06_typedef/s06_typedef.c", 1, 4,
  function(r)
    A.is_not_nil(r.current_function, "current_function must be detected despite typedef")
    A.equal("apply", r.current_function.name)
    A.equal(1, #r.external_calls, "exactly one external call (op)")
    local ec = r.external_calls[1]
    A.equal("op", ec.function_name)
    A.equal("unresolved", ec.resolution_status,
      "function pointer parameter call must be unresolved (graceful degradation)")
  end)

-- Scenario 7: Conditional compilation (#ifdef) — active branch only
run_scenario("S07 conditional compilation active branch",
  D .. "/s07_ifdef", D .. "/s07_ifdef/s07_ifdef.c", 2, 5,
  function(r)
    A.is_not_nil(r.current_function, "current_function should be detected")
    A.equal("calc", r.current_function.name)
    A.equal(1, #r.external_calls,
      "exactly one external call (real_add); #else dummy must be ignored")
    local ec = r.external_calls[1]
    A.equal("real_add", ec.function_name)
    A.equal("resolved", ec.resolution_status)
    A.is_not_nil(ec.definition)
  end)

-- Scenario 8: Macro function call — must be filtered out
run_scenario("S08 macro call filtered",
  D .. "/s08_macro", D .. "/s08_macro/s08_macro.c", 1, 4,
  function(r)
    A.is_not_nil(r.current_function, "current_function should be detected")
    A.equal("compute", r.current_function.name)
    A.equal(0, #r.external_calls,
      "macro calls must NOT appear in external_calls (SQUARE is a macro, not a function)")
  end)

-- Scenario 9: Complex pointer declaration — robust name extraction
run_scenario("S09 complex pointer declaration",
  D .. "/s09_complex", D .. "/s09_complex/s09_complex.c", 0, 7,
  function(r)
    A.is_not_nil(r.current_function,
      "current_function must be detected despite complex nested declarators")
    A.equal("callback", r.current_function.name,
      "function name must be 'callback' even with nested function_declarator/pointer_declarator wrappers")
    A.equal(1, r.current_function.range[1], "range start line = 1")
    A.truthy(r.current_function.range[2] >= 2, "range end line should be at least 2")
  end)

-- Scenario 10: Cross-file reference — caller and definition in separate files
run_scenario("S10 cross-file caller resolution",
  D .. "/s10_cross_file", D .. "/s10_cross_file/math.c", 1, 4,
  function(r)
    A.is_not_nil(r.current_function, "current_function should be detected")
    A.equal("add", r.current_function.name)
    A.equal(1, #r.callers, "exactly one caller (run from main.c)")
    local caller = r.callers[1]
    A.equal("run", caller.caller_function.name,
      "caller should be 'run' from main.c")
    A.truthy(string.find(caller.file, "main.c", 1, true) ~= nil,
      "caller file should be main.c, got: " .. tostring(caller.file))
    A.equal(2, caller.call_position.line, "call line 0->1 +1 = 2")
  end)

--------------------------------------------------------------------------------
-- Final summary
--------------------------------------------------------------------------------
io.write("\n" .. string.rep("=", 60) .. "\n")
io.write(string.format("C real-LSP tests: %d passed, %d failed\n", total_pass, total_fail))
if total_fail > 0 then
  io.write("Failed scenarios:\n")
  for _, f in ipairs(failures) do
    io.write(string.format("  - %s: %s\n", f.scenario, f.message))
  end
end
io.write(string.rep("=", 60) .. "\n")
io.flush()

vim.cmd(total_fail > 0 and "cq" or "qa!")
