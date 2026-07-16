-- scripts/run_rust_tests.lua
--
-- 10 Rust end-to-end test cases for calltree.nvim with rust-analyzer.
--
-- Each scenario:
--   1. Opens a Rust source file in a headless nvim buffer.
--   2. Locates the target function by name (via documentSymbol search,
--      not hardcoded line numbers — more robust to formatting drift).
--   3. Places the cursor on the function name identifier.
--   4. Waits for rust-analyzer to be ready + return symbols.
--   5. Calls require("calltree").analyze_at_cursor(0).
--   6. Asserts the expected outcome per the test case spec.
--
-- Run:
--   nvim --headless -u NORC -c "luafile /path/to/run_rust_tests.lua"
--
-- Exit code 0 = all passed, 1 = at least one failure.

-- Reuse the rust nvim init (sets up runtimepath + rust-analyzer).
local this_file = debug.getinfo(1, "S").source
if this_file:sub(1, 1) == "@" then this_file = this_file:sub(2) end
local script_dir = this_file:match("(.*/)") or "."
script_dir = script_dir:gsub("/$", "")
vim.cmd("luafile " .. script_dir .. "/rust_nvim_init.lua")

local PROJECT_DIR = os.getenv("CALLTREE_RUST_PROJECT")
if not PROJECT_DIR or PROJECT_DIR == "" then
  -- Prefer tests/fixtures/rust_test (sibling of tests/rust/).
  PROJECT_DIR = vim.fn.fnamemodify(script_dir .. "/../fixtures/rust_test", ":p"):gsub("/$", "")
end
-- Always absolutize env-provided paths too.
PROJECT_DIR = vim.fn.fnamemodify(PROJECT_DIR, ":p"):gsub("/$", "")

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

local function stop_rust_lsps()
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
  for _, buf in ipairs(vim.api.nvim_list_bufs()) do
    if vim.api.nvim_buf_is_valid(buf) and vim.api.nvim_buf_get_name(buf) ~= "" then
      pcall(vim.api.nvim_buf_delete, buf, { force = true })
    end
  end
  vim.wait(300)
  collectgarbage("collect")
end

-- Wait for rust-analyzer to be ready + return non-empty document symbols.
local function wait_for_symbols(bufnr, timeout_ms)
  timeout_ms = timeout_ms or 45000  -- rust-analyzer needs longer warmup
  local uri = vim.uri_from_bufnr(bufnr)
  local start = vim.loop.hrtime()
  while (vim.loop.hrtime() - start) / 1e6 < timeout_ms do
    local clients = vim.lsp.get_clients and vim.lsp.get_clients({ bufnr = bufnr })
      or vim.lsp.get_active_clients({ bufnr = bufnr })
    if #clients > 0 then
      local ok_r, r = pcall(vim.lsp.buf_request_sync, bufnr,
        "textDocument/documentSymbol",
        { textDocument = { uri = uri } }, 5000)
      if ok_r and r then
        local found = false
        for _, v in pairs(r) do
          if v.result and type(v.result) == "table" and #v.result > 0 then
            found = true
            break
          end
        end
        if found then return true end
      end
    end
    vim.wait(300)
  end
  return false
end

-- Recursively search symbols for one matching `name` (depth-bounded).
-- When multiple symbols share the same name (e.g. Rust trait method:
-- one declaration in the trait, one implementation in the impl block),
-- prefer the one with the LONGEST range (the implementation, which has
-- a real body, vs. the declaration which is a single line). This is
-- critical for Rust where `impl Trait for Struct { fn trait_method(&self) { ... } }`
-- produces two DocumentSymbols named `trait_method`.
local function find_symbol_by_name(symbols, name, depth)
  depth = depth or 1
  if depth > 64 then return nil end
  local best = nil
  local best_span = -1
  for _, sym in ipairs(symbols) do
    if sym.name == name then
      -- Compute range span (line count) to prefer multi-line bodies.
      local span = 0
      if sym.range and sym.range.start and sym.range["end"] then
        span = sym.range["end"].line - sym.range.start.line
      end
      if span > best_span then
        best = sym
        best_span = span
      end
    end
    if sym.children and #sym.children > 0 then
      local deeper = find_symbol_by_name(sym.children, name, depth + 1)
      if deeper then
        -- Compute deeper's span too; might beat `best`.
        local dspan = 0
        if deeper.range and deeper.range.start and deeper.range["end"] then
          dspan = deeper.range["end"].line - deeper.range.start.line
        end
        if dspan > best_span then
          best = deeper
          best_span = dspan
        end
      end
    end
  end
  return best
end

-- Find the cursor position for a function name identifier by:
--   1. Query documentSymbol for the function name.
--   2. Use the symbol's `selectionRange.start` as the cursor position
--      (NOT `range.start`). LSP spec: `range` covers the whole symbol
--      (including attributes/visibility modifiers in Rust), while
--      `selectionRange` points at the identifier itself. Placing the
--      cursor on the identifier lets calltree's treesitter-based
--      `is_function_name_node` correctly classify the node.
-- Returns { line = 0-based, character = 0-based } or nil.
local function find_cursor_for_function(bufnr, fn_name)
  local uri = vim.uri_from_bufnr(bufnr)
  local symbols = nil
  -- Retry a few times: rust-analyzer can return empty/partial symbols
  -- immediately after attach, and multi-client responses may be nil on some ids.
  for _ = 1, 20 do
    local ok_r, r = pcall(vim.lsp.buf_request_sync, bufnr,
      "textDocument/documentSymbol",
      { textDocument = { uri = uri } }, 5000)
    if ok_r and r then
      for _, v in pairs(r) do
        if v.result and type(v.result) == "table" and #v.result > 0 then
          symbols = v.result
          break
        end
      end
    end
    if symbols then
      local sym = find_symbol_by_name(symbols, fn_name)
      if sym then
        -- Prefer selectionRange.start (the identifier), fall back to range.start.
        local pos
        if sym.selectionRange and sym.selectionRange.start then
          pos = sym.selectionRange.start
        elseif sym.range and sym.range.start then
          pos = sym.range.start
        else
          return nil
        end
        return { line = pos.line, character = pos.character }
      end
    end
    vim.wait(250)
  end
  return nil
end


-- Open a file in a new buffer, force-attach rust-analyzer, wait for symbols.
-- Returns bufnr or nil on failure.
local function open_rust_file(rel_path)
  local abs_path = PROJECT_DIR .. "/" .. rel_path
  vim.cmd("edit " .. abs_path)
  vim.bo.filetype = "rust"
  local bufnr = vim.api.nvim_get_current_buf()
  _G.start_rust_analyzer(bufnr)
  if not wait_for_symbols(bufnr, 60000) then
    return nil
  end
  -- Extra warm-up: rust-analyzer's references request needs the project
  -- to be fully indexed, which can take longer than the initial
  -- documentSymbol response. Previously this was a fixed 2s sleep, which
  -- was insufficient on slow machines (causing flaky cross-file caller
  -- tests). Now we poll: try a references request and wait until it
  -- returns non-empty OR a 5s timeout. The first test pays the warmup cost;
  -- subsequent tests benefit from the already-warm index.
  local uri = vim.uri_from_bufnr(bufnr)
  local warmed = false
  local warm_start = vim.loop.hrtime()
  while (vim.loop.hrtime() - warm_start) / 1e6 < 5000 do
    local ok_r, r = pcall(vim.lsp.buf_request_sync, bufnr,
      "textDocument/references",
      { textDocument = { uri = uri }, position = { line = 0, character = 0 },
        context = { includeDeclaration = true } }, 1000)
    if ok_r and r then
      for _, v in pairs(r) do
        if v.result and type(v.result) == "table" and #v.result > 0 then
          warmed = true
          break
        end
      end
    end
    if warmed then break end
    vim.wait(300)
  end
  return bufnr
end

-- Run analyze_at_cursor with cursor on `fn_name` in the current buffer.
-- Returns the result table, or nil + err on pcall failure.
local function analyze_at_function(fn_name)
  local bufnr = vim.api.nvim_get_current_buf()
  local pos = find_cursor_for_function(bufnr, fn_name)
  if not pos then
    return nil, "could not locate function '" .. fn_name .. "' via documentSymbol"
  end
  -- nvim_win_set_cursor takes {1-based row, 0-based col}.
  vim.api.nvim_win_set_cursor(0, { pos.line + 1, pos.character })
  vim.wait(300)  -- let LSP settle after cursor move
  local calltree = require("calltree")
  -- Pass skip_stdlib_calls=false and deduplicate_external_calls=false
  -- so the raw external_calls list is returned (the Rust scenarios
  -- assert on exact counts including stdlib and unresolved calls,
  -- which would be filtered/deduped by the v1.2.0+ defaults).
  local ok_a, result = pcall(calltree.analyze_at_cursor, 0, {
    skip_stdlib_calls = false,
    deduplicate_external_calls = false,
  })
  if not ok_a then
    return nil, "analyze_at_cursor raised: " .. tostring(result)
  end
  return result
end

-- Same as analyze_at_function, but moves cursor to a specific call-site
-- position (used by test case 3 where we cursor on the call, not the def).
local function analyze_at_position(line_0based, char_0based)
  vim.api.nvim_win_set_cursor(0, { line_0based + 1, char_0based })
  vim.wait(300)
  local calltree = require("calltree")
  local ok_a, result = pcall(calltree.analyze_at_cursor, 0, {
    skip_stdlib_calls = false,
    deduplicate_external_calls = false,
  })
  if not ok_a then
    return nil, "analyze_at_cursor raised: " .. tostring(result)
  end
  return result
end

-- Helper: does result.callers contain an entry whose caller_function.name
-- matches `name`? Returns the entry or nil.
local function find_caller_by_name(result, name)
  if not result or not result.callers then return nil end
  for _, c in ipairs(result.callers) do
    if c.caller_function and c.caller_function.name == name then
      return c
    end
  end
  return nil
end

-- Helper: does result.external_calls contain an entry whose function_name
-- matches `name`? Matches as a substring (e.g. "to_string" matches
-- "serde_json::to_string(&42).unwrap_or_default"). Returns the entry or nil.
local function find_external_call_by_name(result, name)
  if not result or not result.external_calls then return nil end
  for _, ec in ipairs(result.external_calls) do
    if ec.function_name == name then return ec end
    -- Substring match: handles cases where the LSP / treesitter returns
    -- the full call expression (e.g. "serde_json::to_string(&42).unwrap_or_default")
    -- as the function_name.
    if ec.function_name and ec.function_name:find(name, 1, true) then
      return ec
    end
  end
  return nil
end

local function basename(p) return p and p:match("[^/]+$") or p end

--================================================================================
-- Test cases
--================================================================================

--================================================================================
-- Test 1: foo — cross-file + same-file caller aggregation
--================================================================================
local function test_01_foo_cross_file_callers()
  print("\n>>> test_01_foo_cross_file_callers")
  local bufnr = open_rust_file("src/lib.rs")
  ok("test1: rust-analyzer attached", bufnr ~= nil)
  if not bufnr then return end

  local result, err = analyze_at_function("foo")
  ok("test1: analyze_at_cursor did not raise", result ~= nil, err)
  if not result then return end

  ok("test1: current_function detected", result.current_function ~= nil)
  if result.current_function then
    ok("test1: current_function.name == 'foo'",
       result.current_function.name == "foo",
       "got: " .. tostring(result.current_function.name))
    ok("test1: file ends with lib.rs",
       result.current_function.file and result.current_function.file:find("lib.rs$") ~= nil,
       "got: " .. tostring(result.current_function.file))
  end

  -- Expect at least 3 callers: bar (same file), main (main.rs), module_func (module.rs).
  local bar = find_caller_by_name(result, "bar")
  local main_caller = find_caller_by_name(result, "main")
  local module_func = find_caller_by_name(result, "module_func")
  ok("test1: callers contains 'bar' (same-file)", bar ~= nil)
  ok("test1: callers contains 'main' (cross-file main.rs)", main_caller ~= nil)
  ok("test1: callers contains 'module_func' (cross-module)", module_func ~= nil)

  if bar then
    ok("test1: bar.file ends with lib.rs",
       bar.file and bar.file:find("lib.rs$") ~= nil,
       "got: " .. tostring(bar.file))
  end
  if main_caller then
    ok("test1: main.file ends with main.rs",
       main_caller.file and main_caller.file:find("main.rs$") ~= nil,
       "got: " .. tostring(main_caller.file))
  end
  if module_func then
    ok("test1: module_func.file ends with module.rs",
       module_func.file and module_func.file:find("module.rs$") ~= nil,
       "got: " .. tostring(module_func.file))
  end

  ok("test1: external_calls is empty (# == 0)",
     type(result.external_calls) == "table" and #result.external_calls == 0,
     "got: " .. tostring(result.external_calls and #result.external_calls))
end

--================================================================================
-- Test 2: helper — only same-file caller (uses_helper)
--================================================================================
local function test_02_helper_private_same_file()
  print("\n>>> test_02_helper_private_same_file")
  local bufnr = open_rust_file("src/lib.rs")
  ok("test2: rust-analyzer attached", bufnr ~= nil)
  if not bufnr then return end

  local result, err = analyze_at_function("helper")
  ok("test2: analyze_at_cursor did not raise", result ~= nil, err)
  if not result then return end

  ok("test2: current_function detected", result.current_function ~= nil)
  if result.current_function then
    ok("test2: current_function.name == 'helper'",
       result.current_function.name == "helper",
       "got: " .. tostring(result.current_function.name))
  end

  -- Expect EXACTLY one caller: uses_helper.
  local uses_helper = find_caller_by_name(result, "uses_helper")
  ok("test2: callers contains 'uses_helper'", uses_helper ~= nil)
  ok("test2: callers count == 1",
     type(result.callers) == "table" and #result.callers == 1,
     "got: " .. tostring(result.callers and #result.callers))
  ok("test2: 'main' NOT in callers", find_caller_by_name(result, "main") == nil)

  ok("test2: external_calls is empty",
     type(result.external_calls) == "table" and #result.external_calls == 0)
end

--================================================================================
-- Test 3: crate::foo cross-module reference resolution
--
-- Note on plugin semantics: analyze_at_cursor() identifies the function
-- UNDER the cursor (the function whose definition contains the cursor
-- position), not the function being CALLED at the cursor. To exercise
-- the cross-module call (`crate::foo()` called from `module_func`), we
-- place the cursor on the DEFINITION of `module_func` in module.rs,
-- then check that:
--   - current_function is module_func (in module.rs).
--   - The external_calls list contains a resolved call to `foo`
--     (whose definition lives in lib.rs — cross-module).
--================================================================================
local function test_03_crate_path_cross_module()
  print("\n>>> test_03_crate_path_cross_module")
  local bufnr = open_rust_file("src/module.rs")
  ok("test3: rust-analyzer attached", bufnr ~= nil)
  if not bufnr then return end

  -- Verify the call site exists in module.rs (sanity check).
  local lines = vim.api.nvim_buf_get_lines(bufnr, 0, -1, false)
  local found_call_site = false
  for _, line in ipairs(lines) do
    if line:find("crate::", 1, true) and line:find("foo", 1, true) then
      found_call_site = true
      break
    end
  end
  ok("test3: `crate::foo()` call site present in module.rs", found_call_site)

  -- Place cursor on `module_func` definition (in module.rs) and analyze.
  local result, err = analyze_at_function("module_func")
  ok("test3: analyze_at_cursor did not raise", result ~= nil, err)
  if not result then return end

  ok("test3: current_function detected", result.current_function ~= nil)
  if result.current_function then
    ok("test3: current_function.name == 'module_func'",
       result.current_function.name == "module_func",
       "got: " .. tostring(result.current_function.name))
    ok("test3: current_function.file ends with module.rs",
       result.current_function.file and result.current_function.file:find("module.rs$") ~= nil,
       "got: " .. tostring(result.current_function.file))
  end

  -- The call `crate::foo()` inside module_func should appear as an
  -- external_call (resolved to lib.rs in the same project).
  local foo_ec = find_external_call_by_name(result, "foo")
  ok("test3: external_calls contains a 'foo' call", foo_ec ~= nil,
     "external_calls: " .. vim.inspect(result.external_calls))
  if foo_ec then
    ok("test3: foo call resolution_status == 'resolved'",
       foo_ec.resolution_status == "resolved",
       "got: " .. tostring(foo_ec.resolution_status))
    -- Definition file should be lib.rs (the cross-module target).
    if foo_ec.definition and foo_ec.definition.file then
      ok("test3: foo definition file ends with lib.rs",
         foo_ec.definition.file:find("lib.rs$") ~= nil,
         "got: " .. tostring(foo_ec.definition.file))
    end
  end
end

--================================================================================
-- Test 4: impl-block method recognition + cross-file caller
--================================================================================
local function test_04_impl_method()
  print("\n>>> test_04_impl_method")
  local bufnr = open_rust_file("src/lib.rs")
  ok("test4: rust-analyzer attached", bufnr ~= nil)
  if not bufnr then return end

  local result, err = analyze_at_function("method")
  ok("test4: analyze_at_cursor did not raise", result ~= nil, err)
  if not result then return end

  ok("test4: current_function detected", result.current_function ~= nil)
  if result.current_function then
    -- Accept either "method" or "MyStruct::method".
    local name = result.current_function.name or ""
    ok("test4: current_function.name contains 'method'",
       name:find("method") ~= nil,
       "got: " .. tostring(name))
  end

  local main_caller = find_caller_by_name(result, "main")
  ok("test4: callers contains 'main' (from main.rs)", main_caller ~= nil)
  if main_caller then
    ok("test4: main.file ends with main.rs",
       main_caller.file and main_caller.file:find("main.rs$") ~= nil,
       "got: " .. tostring(main_caller.file))
  end

  ok("test4: external_calls is empty",
     type(result.external_calls) == "table" and #result.external_calls == 0)
end

--================================================================================
-- Test 5: trait method impl recognition (no caller required)
--================================================================================
local function test_05_trait_method_impl()
  print("\n>>> test_05_trait_method_impl")
  local bufnr = open_rust_file("src/lib.rs")
  ok("test5: rust-analyzer attached", bufnr ~= nil)
  if not bufnr then return end

  local result, err = analyze_at_function("trait_method")
  ok("test5: analyze_at_cursor did not raise", result ~= nil, err)
  if not result then return end

  ok("test5: current_function detected", result.current_function ~= nil)
  if result.current_function then
    local name = result.current_function.name or ""
    ok("test5: current_function.name contains 'trait_method'",
       name:find("trait_method") ~= nil,
       "got: " .. tostring(name))
    ok("test5: current_function.range is a 2-element table",
       type(result.current_function.range) == "table" and #result.current_function.range == 2,
       "got: " .. tostring(result.current_function.range))
  end

  -- No fatal errors. Caller list may be empty (s.trait_method() is in main.rs,
  -- but trait_method has no body of interest).
  if result.debug and result.debug.errors then
    ok("test5: no fatal errors in debug.errors (# == 0)",
       #result.debug.errors == 0,
       "got: " .. vim.inspect(result.debug.errors))
  end
end

--================================================================================
-- Test 6: closure-internal caller attribution
--================================================================================
local function test_06_closure_caller()
  print("\n>>> test_06_closure_caller")
  local bufnr = open_rust_file("src/lib.rs")
  ok("test6: rust-analyzer attached", bufnr ~= nil)
  if not bufnr then return end

  local result, err = analyze_at_function("closure_target")
  ok("test6: analyze_at_cursor did not raise", result ~= nil, err)
  if not result then return end

  ok("test6: current_function detected", result.current_function ~= nil)
  if result.current_function then
    ok("test6: current_function.name == 'closure_target'",
       result.current_function.name == "closure_target",
       "got: " .. tostring(result.current_function.name))
  end

  -- Expect callers to contain closure_caller (the outer fn containing the closure).
  -- The closure itself is NOT a caller (closures have no name).
  local cc = find_caller_by_name(result, "closure_caller")
  ok("test6: callers contains 'closure_caller'", cc ~= nil)
  if cc then
    ok("test6: closure_caller.file ends with lib.rs",
       cc.file and cc.file:find("lib.rs$") ~= nil,
       "got: " .. tostring(cc.file))
  end
  -- Also verify no anonymous closure shows up as a caller.
  if result.callers then
    for _, c in ipairs(result.callers) do
      local nm = c.caller_function and c.caller_function.name or "<nil>"
      ok("test6: caller '" .. tostring(nm) .. "' is not anonymous (closure)",
         nm ~= nil and nm ~= "" and nm ~= "<closure>" and nm ~= "<anonymous>")
    end
  end
end

--================================================================================
-- Test 7: stdlib function is_stdlib flag (uses_std)
--================================================================================
local function test_07_stdlib_call()
  print("\n>>> test_07_stdlib_call")
  local bufnr = open_rust_file("src/lib.rs")
  ok("test7: rust-analyzer attached", bufnr ~= nil)
  if not bufnr then return end

  local result, err = analyze_at_function("uses_std")
  ok("test7: analyze_at_cursor did not raise", result ~= nil, err)
  if not result then return end

  ok("test7: current_function detected", result.current_function ~= nil)
  if result.current_function then
    ok("test7: current_function.name == 'uses_std'",
       result.current_function.name == "uses_std",
       "got: " .. tostring(result.current_function.name))
  end

  -- external_calls should contain read_to_string with is_stdlib=true.
  -- rust-analyzer tags std library symbols; the calltree plugin checks
  -- both the LSP tag (256) and the string forms "system"/"library".
  local ec = find_external_call_by_name(result, "read_to_string")
  ok("test7: external_calls contains 'read_to_string'", ec ~= nil)
  if ec then
    ok("test7: read_to_string.is_stdlib == true",
       ec.is_stdlib == true,
       "got: " .. tostring(ec.is_stdlib))
    ok("test7: read_to_string.resolution_status == 'resolved'",
       ec.resolution_status == "resolved",
       "got: " .. tostring(ec.resolution_status))
  end
end

--================================================================================
-- Test 8: external crate call (serde_json::to_string)
--================================================================================
local function test_08_external_crate_call()
  print("\n>>> test_08_external_crate_call")
  local bufnr = open_rust_file("src/lib.rs")
  ok("test8: rust-analyzer attached", bufnr ~= nil)
  if not bufnr then return end

  local result, err = analyze_at_function("uses_serde")
  ok("test8: analyze_at_cursor did not raise", result ~= nil, err)
  if not result then return end

  ok("test8: current_function detected", result.current_function ~= nil)
  if result.current_function then
    ok("test8: current_function.name == 'uses_serde'",
       result.current_function.name == "uses_serde",
       "got: " .. tostring(result.current_function.name))
  end

  local ec = find_external_call_by_name(result, "to_string")
  ok("test8: external_calls contains 'to_string'", ec ~= nil,
     "external_calls: " .. vim.inspect(result.external_calls))
  if ec then
    ok("test8: to_string.is_stdlib != true (it's a third-party crate)",
       ec.is_stdlib ~= true,
       "got: " .. tostring(ec.is_stdlib))
  end
end

--================================================================================
-- Test 9: #[cfg] conditional compilation stability
--================================================================================
local function test_09_cfg_conditional()
  print("\n>>> test_09_cfg_conditional")
  local bufnr = open_rust_file("src/lib.rs")
  ok("test9: rust-analyzer attached", bufnr ~= nil)
  if not bufnr then return end

  local result, err = analyze_at_function("conditional_func")
  ok("test9: analyze_at_cursor did not raise", result ~= nil, err)
  if not result then return end

  ok("test9: current_function detected", result.current_function ~= nil,
     "result: " .. vim.inspect(result))
  if result.current_function then
    ok("test9: current_function.name == 'conditional_func'",
       result.current_function.name == "conditional_func",
       "got: " .. tostring(result.current_function.name))
    ok("test9: current_function.range is array of 2",
       type(result.current_function.range) == "table"
         and #result.current_function.range == 2,
       "got: " .. tostring(result.current_function.range))
  end

  -- completion_reason should indicate success (or partial success), NOT a panic.
  if result.debug then
    local reason = result.debug.completion_reason
    ok("test9: completion_reason is success-like",
       reason == "analyzed" or reason == "analyzed_with_phase_errors"
         or reason == "preconditions_failed",
       "got: " .. tostring(reason))
    if result.debug.errors and #result.debug.errors > 0 then
      -- Allow non-fatal warnings/errors but warn about them in the output.
      print("        note: debug.errors has " .. #result.debug.errors .. " entries")
    end
  end
end

--================================================================================
-- Test 10: syntax-error recovery (broken function)
--================================================================================
local function test_10_syntax_error_recovery()
  print("\n>>> test_10_syntax_error_recovery")
  -- `broken.rs` is intentionally NOT included in lib.rs's mod tree so
  -- that its syntax error doesn't poison the rest of the crate's
  -- treesitter parse. rust-analyzer still parses it standalone when
  -- opened in nvim.
  local bufnr = open_rust_file("src/broken.rs")
  ok("test10: rust-analyzer attached", bufnr ~= nil)
  if not bufnr then return end

  local result, err = analyze_at_function("broken")
  ok("test10: analyze_at_cursor did not raise (pcall caught)", result ~= nil, err)
  if not result then return end

  -- The result table itself must always be valid (callers/external_calls are arrays).
  ok("test10: result is a table", type(result) == "table")
  ok("test10: result.callers is a table (possibly empty)",
     type(result.callers) == "table")
  ok("test10: result.external_calls is a table (possibly empty)",
     type(result.external_calls) == "table")

  -- completion_reason should NOT be "cursor_error" or a panic.
  if result.debug then
    local reason = result.debug.completion_reason
    ok("test10: completion_reason is not 'cursor_error'",
       reason ~= "cursor_error",
       "got: " .. tostring(reason))
    -- Accepted reasons: preconditions_failed, analyzed_with_phase_errors,
    -- analyzed, cursor_no_node, etc. — anything but a panic / cursor_error.
    ok("test10: completion_reason indicates graceful handling",
       reason == "preconditions_failed"
         or reason == "analyzed_with_phase_errors"
         or reason == "analyzed"
         or reason == "cursor_no_node"
         or reason == "cursor_not_on_function_name"
         or reason == "cursor_no_lsp_symbol"
         or reason == "cursor_symbol_wrong_kind",
       "got: " .. tostring(reason))
  end

  -- If current_function was detected despite the syntax error, that's fine —
  -- we just need the plugin to NOT crash. If it wasn't detected, also fine.
  if result.current_function then
    ok("test10: current_function detected (partial recovery)",
       result.current_function.name == "broken")
  else
    ok("test10: current_function is nil (acceptable for syntax error)", true)
  end
end

--================================================================================
-- Main runner
--================================================================================

local tests = {
  test_01_foo_cross_file_callers,
  test_02_helper_private_same_file,
  test_03_crate_path_cross_module,
  test_04_impl_method,
  test_05_trait_method_impl,
  test_06_closure_caller,
  test_07_stdlib_call,
  test_08_external_crate_call,
  test_09_cfg_conditional,
  test_10_syntax_error_recovery,
}

print("============================================================")
print("calltree.nvim Rust end-to-end tests (10 scenarios)")
print("Project: " .. PROJECT_DIR)
print("============================================================")

-- Make sure we cd into the project dir so rust-analyzer picks up Cargo.toml.
vim.cmd("cd " .. PROJECT_DIR)

for _, t in ipairs(tests) do
  local ok_t, err = pcall(t)
  if not ok_t then
    total_fail = total_fail + 1
    print(string.format("  FAIL  (test function raised: %s)", tostring(err)))
    table.insert(failures, { name = "(test function)", detail = tostring(err) })
  end
  -- Always tear down rust-analyzer between scenarios (low-memory hosts).
  pcall(stop_rust_lsps)
end

print("\n" .. string.rep("=", 60))
print(string.format("Rust E2E: %d passed, %d failed", total_pass, total_fail))
if total_fail > 0 then
  print("Failed assertions:")
  for _, f in ipairs(failures) do
    print(string.format("  - %s%s", f.name, f.detail and (" — " .. tostring(f.detail)) or ""))
  end
  vim.cmd("cquit! 1")
else
  print("All Rust E2E tests passed!")
  vim.cmd("qa!")
end
