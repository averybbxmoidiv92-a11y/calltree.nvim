--- tests/c/run_stress_tests.lua — stress tests using real clangd + tree-sitter-c.
---
--- Run with:
---   nvim --headless -u NORC \
---     -c "luafile tests/c/run_stress_tests.lua"

local this_file = debug.getinfo(1, "S").source
if this_file:sub(1, 1) == "@" then this_file = this_file:sub(2) end
local this_dir = this_file:match("(.*/)") or "./"
local PLUGIN_DIR = vim.fs.normalize(this_dir .. "/../..")
local STRESS_DIR = PLUGIN_DIR .. "/tests/c/stress"
local CLANGD_BIN = os.getenv("CALLTREE_CLANGD_BIN") or "clangd"

vim.opt.runtimepath:prepend(PLUGIN_DIR)
package.path = PLUGIN_DIR .. "/lua/?.lua;" ..
               PLUGIN_DIR .. "/lua/?/init.lua;" ..
               package.path
vim.diagnostic.enable(false)

-- Assertion library (same as run_c_tests.lua)
local failures = {}
local current_scenario = nil
local function record_fail(msg, expected, actual)
  local entry = { scenario = current_scenario or "?", message = msg, expected = expected, actual = actual }
  table.insert(failures, entry)
  error(entry, 2)
end
local A = {}
function A.equal(e, a, m) if e ~= a then record_fail(m or ("expected " .. tostring(e) .. ", got " .. tostring(a)), e, a) end end
function A.is_not_nil(a, m) if a == nil then record_fail(m or "expected non-nil, got nil", "non-nil", nil) end end
function A.length(n, l, m)
  if l == nil then record_fail(m or "expected length " .. n .. ", got nil", n, nil) end
  local got = l and #l or 0
  if got ~= n then record_fail(m or ("expected length " .. n .. ", got " .. got), n, got) end
end
function A.truthy(a, m) if not a then record_fail(m or ("expected truthy, got " .. tostring(a)), "truthy", a) end end
function A.at_least(n, l, m)
  if l == nil then record_fail(m or "expected at least " .. n .. ", got nil", n, nil) end
  local got = l and #l or 0
  if got < n then record_fail(m or ("expected at least " .. n .. ", got " .. got), n, got) end
end

local function setup_and_open(scenario_dir, file_path, cursor_line, cursor_col, wait_ms)
  wait_ms = wait_ms or 10000
  vim.cmd("edit " .. file_path)
  local bufnr = vim.api.nvim_get_current_buf()
  vim.bo[bufnr].filetype = "c"
  vim.lsp.start({
    name = "clangd",
    cmd = { CLANGD_BIN, "--background-index", "--clang-tidy=false", "--log=error",
            "--compile-commands-dir=" .. scenario_dir },
    root_dir = scenario_dir,
    capabilities = vim.lsp.protocol.make_client_capabilities(),
  }, { bufnr = bufnr })
  local attached = vim.wait(wait_ms, function()
    local clients = vim.lsp.get_clients and vim.lsp.get_clients({ bufnr = bufnr })
      or vim.lsp.get_active_clients({ bufnr = bufnr })
    return #clients > 0
  end, 50)
  if not attached then error("clangd did not attach to " .. file_path) end
  vim.wait(wait_ms, function()
    local params = { textDocument = vim.lsp.util.make_text_document_params(bufnr) }
    local r = vim.lsp.buf_request_sync(bufnr, "textDocument/documentSymbol", params, 1000)
    if r == nil then return false end
    for _, res in pairs(r) do
      if res.result and #res.result > 0 then return true end
    end
    return false
  end, 100)
  -- Extra wait for reference index
  vim.wait(3000, function()
    local ref_params = {
      textDocument = vim.lsp.util.make_text_document_params(bufnr),
      position = { line = cursor_line, character = cursor_col },
      context = { includeDeclaration = true },
    }
    local rr = vim.lsp.buf_request_sync(bufnr, "textDocument/references", ref_params, 200)
    if rr == nil then return false end
    for _, res in pairs(rr) do
      if res.result and #res.result > 0 then return true end
    end
    return false
  end, 200)
  return bufnr
end

local function cleanup()
  for _, client in ipairs(vim.lsp.get_clients and vim.lsp.get_clients() or vim.lsp.get_active_clients()) do
    if client.name == "clangd" then vim.lsp.stop_client(client.id, true) end
  end
  for _, b in ipairs(vim.api.nvim_list_bufs()) do
    pcall(vim.api.nvim_buf_delete, b, { force = true })
  end
  vim.wait(500, function() local c = vim.lsp.get_clients and vim.lsp.get_clients() or vim.lsp.get_active_clients(); return #c == 0 end, 50)
end

local total_pass, total_fail = 0, 0
local function run_scenario(name, scenario_dir, file_path, cursor_line, cursor_col, expectations_fn)
  current_scenario = name
  io.write(string.format("[RUN ] %s\n", name)); io.flush()
  local ok, err = pcall(function()
    setup_and_open(scenario_dir, file_path, cursor_line, cursor_col)
    vim.api.nvim_win_set_cursor(0, { cursor_line + 1, cursor_col })
    local calltree = require("calltree")
    -- Pass skip_stdlib_calls=false and deduplicate_external_calls=false
    -- so the raw external_calls list is returned (the stress scenarios
    -- assert on exact counts including unresolved calls whose is_stdlib
    -- is nil, which would be filtered out by the v1.2.0+ default
    -- skip_stdlib_calls=true).
    local result = calltree.analyze_at_cursor(0, {
      skip_stdlib_calls = false,
      deduplicate_external_calls = false,
    })
    expectations_fn(result)
  end)
  if ok then
    io.write(string.format("[PASS] %s\n", name)); io.flush()
    total_pass = total_pass + 1
  else
    io.write(string.format("[FAIL] %s\n", name))
    if type(err) == "table" then
      io.write(string.format("       message: %s\n", tostring(err.message or err)))
      if err.expected ~= nil then io.write(string.format("       expected: %s\n", tostring(err.expected))) end
      if err.actual ~= nil then io.write(string.format("       actual:   %s\n", tostring(err.actual))) end
    else
      for line in tostring(err):gmatch("[^\n]+") do
        io.write(string.format("       %s\n", line)); break
      end
    end
    io.flush()
    total_fail = total_fail + 1
  end
  cleanup()
  current_scenario = nil
end

--------------------------------------------------------------------------------
-- Stress Test 1: Deeply nested function calls + stdlib call
--------------------------------------------------------------------------------
-- Cursor on `complex` function name. The function calls `medium`, which
-- calls `outer`, which calls helper1/2/3. Plus `printf` (stdlib).
-- Expect:
--   - current_function = "complex"
--   - external_calls contains AT LEAST "medium" (the only direct call to a
--     user-defined function from `complex`; printf is stdlib).
--   - printf is either resolved (with body_range nil) or marked as stdlib.
run_scenario("STRESS1 nested + stdlib",
  STRESS_DIR, STRESS_DIR .. "/stress1_nested.c", 22, 4,
  function(r)
    A.is_not_nil(r.current_function, "current_function should be detected")
    A.equal("complex", r.current_function.name, "cursor function name should be 'complex'")
    A.at_least(1, r.external_calls,
      "complex calls at least medium() (and printf); should have >= 1 external call")
    -- Find the 'medium' call
    local found_medium = false
    local found_printf = false
    for _, ec in ipairs(r.external_calls) do
      if ec.function_name == "medium" then
        found_medium = true
        A.equal("resolved", ec.resolution_status, "medium should be resolved")
      end
      if ec.function_name == "printf" then
        found_printf = true
      end
    end
    A.truthy(found_medium, "external_calls should contain 'medium' as a resolved call")
    -- printf may or may not appear depending on stdlib handling; we just
    -- verify no crash.
  end)

--------------------------------------------------------------------------------
-- Stress Test 2: Multiple cross-file callers
--------------------------------------------------------------------------------
-- Cursor on `core` in core.c. Three other files (caller_a/b/c.c) each
-- declare `int core(int)` and call it. Expect 3 callers.
run_scenario("STRESS2 multi-file callers",
  STRESS_DIR .. "/multifile", STRESS_DIR .. "/multifile/core.c", 0, 4,
  function(r)
    A.is_not_nil(r.current_function, "current_function should be detected")
    A.equal("core", r.current_function.name)
    A.equal(3, #r.callers,
      "should find exactly 3 cross-file callers (caller_a, caller_b, caller_c)")
    -- Verify each caller is present
    local found = {}
    for _, c in ipairs(r.callers) do
      found[c.caller_function.name] = c.file
    end
    A.truthy(found["caller_a"] ~= nil, "should have caller_a")
    A.truthy(found["caller_b"] ~= nil, "should have caller_b")
    A.truthy(found["caller_c"] ~= nil, "should have caller_c")
    A.truthy(found["caller_a"]:find("caller_a.c", 1, true) ~= nil, "caller_a file path correct")
    A.truthy(found["caller_b"]:find("caller_b.c", 1, true) ~= nil, "caller_b file path correct")
    A.truthy(found["caller_c"]:find("caller_c.c", 1, true) ~= nil, "caller_c file path correct")
  end)

--------------------------------------------------------------------------------
-- Stress Test 3: Control flow (if/else, loops) with multiple calls
--------------------------------------------------------------------------------
-- Cursor on `process` function name. It calls validate(), transform(),
-- format() (twice in different branches). Expect all three resolved.
run_scenario("STRESS3 control flow + multiple calls",
  STRESS_DIR, STRESS_DIR .. "/stress3_control_flow.c", 24, 4,
  function(r)
    A.is_not_nil(r.current_function, "current_function should be detected")
    A.equal("process", r.current_function.name)
    -- process calls: validate, transform, format (in if), format (in else)
    -- walker.collect_top_level_calls returns ONE entry per call_expression,
    -- so format appears twice (once per branch). Expect 4 entries total.
    -- However, the plugin deduplicates by call_position, so it may be 4.
    -- Verify at least the three distinct function names appear.
    local names = {}
    for _, ec in ipairs(r.external_calls) do
      names[ec.function_name] = true
    end
    A.truthy(names["validate"], "should call validate")
    A.truthy(names["transform"], "should call transform")
    A.truthy(names["format"], "should call format")
    -- All user-defined calls should be resolved (printf is stdlib)
    for _, ec in ipairs(r.external_calls) do
      if ec.function_name ~= "printf" then
        A.equal("resolved", ec.resolution_status,
          ec.function_name .. " should be resolved, got " .. ec.resolution_status)
      end
    end
  end)

--------------------------------------------------------------------------------
-- Final summary
--------------------------------------------------------------------------------
io.write("\n" .. string.rep("=", 60) .. "\n")
io.write(string.format("C stress tests: %d passed, %d failed\n", total_pass, total_fail))
if total_fail > 0 then
  io.write("Failed scenarios:\n")
  for _, f in ipairs(failures) do
    io.write(string.format("  - %s: %s\n", f.scenario, f.message))
  end
end
io.write(string.rep("=", 60) .. "\n")
io.flush()
vim.cmd(total_fail > 0 and "cq" or "qa!")
