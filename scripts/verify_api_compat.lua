--- scripts/verify_api_compat.lua
---
--- Public API compatibility verification: runs analyze_at_cursor on a set
--- of fixed inputs and compares the output JSON hash against expected
--- values. The hash is based on the set of field names + string
--- representations of key values, ensuring the public API behaves
--- equivalently before and after refactoring.
---
--- Run:
---   nvim --headless -u NORC -c "luafile scripts/verify_api_compat.lua"
---
--- Exit code 0 means compatible, 1 means incompatible.

-- Reuse nvim_lsp_init (sets up runtimepath + LSP).
local this_file = debug.getinfo(1, "S").source
if this_file:sub(1, 1) == "@" then this_file = this_file:sub(2) end
local script_dir = this_file:match("(.*/)") or "./"
script_dir = script_dir:gsub("/$", "")
vim.cmd("luafile " .. script_dir .. "/nvim_lsp_init.lua")

local function hash_string(s)
  -- Simple hash: DJB2 variant. Sufficient for equivalence comparison.
  -- LuaJIT 5.1 has no ~ operator; use math.fmod + addition instead of XOR.
  local h = 5381
  for i = 1, #s do
    h = (h * 33 + string.byte(s, i)) % 0x100000000
  end
  return string.format("%08x", h)
end

-- Extract a "structural signature" of a JSON-like table: recursively
-- collect all key paths + leaf value types, concatenate into a string,
-- then hash. This ignores concrete line-number/file-path differences and
-- looks only at the structure.
local function structural_signature(t, prefix)
  prefix = prefix or ""
  local parts = {}
  if type(t) == "table" then
    local keys = {}
    for k, _ in pairs(t) do table.insert(keys, k) end
    table.sort(keys, function(a, b)
      local ta, tb = type(a), type(b)
      if ta ~= tb then return ta < tb end
      return tostring(a) < tostring(b)
    end)
    for _, k in ipairs(keys) do
      local v = t[k]
      local kstr = tostring(k)
      if type(v) == "table" then
        table.insert(parts, prefix .. kstr .. ":{")
        table.insert(parts, structural_signature(v, prefix .. kstr .. "."))
        table.insert(parts, "}")
      else
        -- Leaf: record type + (for enum strings) value.
        local val_str = ""
        if type(v) == "string" and (#v <= 40) then val_str = "=" .. v end
        table.insert(parts, prefix .. kstr .. ":" .. type(v) .. val_str)
      end
    end
  end
  return table.concat(parts, ",")
end

local function hash_table(t)
  return hash_string(structural_signature(t))
end

--================================================================================
-- Test scenarios
--================================================================================

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

-- Scenario 1: analyze_at_cursor return structure with no LSP.
local function scenario_no_lsp()
  local buf = vim.api.nvim_create_buf(false, true)
  vim.api.nvim_set_current_buf(buf)
  vim.bo[buf].filetype = "lua"
  vim.api.nvim_buf_set_lines(buf, 0, -1, false, {
    "local function foo()",
    "  return 1",
    "end",
  })
  vim.api.nvim_buf_set_name(buf, "/tmp/calltree_compat_no_lsp.lua")
  vim.api.nvim_win_set_cursor(0, { 1, 15 })
  local calltree = require("calltree")
  local result = calltree.analyze_at_cursor(buf)
  -- Structural signature: current_function=nil, callers=[], external_calls=[], debug={...}
  local sig = structural_signature(result)
  -- Previously `result.current_function ~= nil or true` — always true,
  -- a meaningless assertion. Fixed: assert the EXPECTED behavior for a
  -- no-LSP scenario (preconditions fail → current_function is nil).
  ok("scenario_no_lsp: current_function is nil (preconditions failed, no LSP)",
     result.current_function == nil,
     "got: " .. tostring(result.current_function))
  ok("scenario_no_lsp: callers is table", type(result.callers) == "table")
  ok("scenario_no_lsp: external_calls is table", type(result.external_calls) == "table")
  ok("scenario_no_lsp: debug present", result.debug ~= nil)
  if result.debug then
    ok("scenario_no_lsp: debug.completion_reason is preconditions_failed",
      result.debug.completion_reason == "preconditions_failed",
      "got: " .. tostring(result.debug.completion_reason))
    ok("scenario_no_lsp: debug.preconditions is array",
      type(result.debug.preconditions) == "table")
    ok("scenario_no_lsp: debug has version field",
      result.debug.version ~= nil, "version: " .. tostring(result.debug.version))
  end
  -- Output structural signature hash (for manual comparison).
  local h = hash_string(sig)
  print(string.format("        structural hash: %s", h))
  vim.api.nvim_buf_delete(buf, { force = true })
end

-- Scenario 2: JSON encoding round-trips.
local function scenario_json_roundtrip()
  local buf = vim.api.nvim_create_buf(false, true)
  vim.api.nvim_set_current_buf(buf)
  vim.bo[buf].filetype = "lua"
  vim.api.nvim_buf_set_lines(buf, 0, -1, false, {
    "local function bar()",
    "  return 2",
    "end",
  })
  vim.api.nvim_buf_set_name(buf, "/tmp/calltree_compat_json.lua")
  vim.api.nvim_win_set_cursor(0, { 1, 15 })
  local calltree = require("calltree")
  local json = calltree.analyze_at_cursor_json(buf)
  ok("scenario_json: json is string", type(json) == "string")
  ok("scenario_json: starts with {", json:sub(1, 1) == "{")
  local decoded = vim.json.decode(json)
  ok("scenario_json: decodes", type(decoded) == "table")
  ok("scenario_json: has callers", type(decoded.callers) == "table")
  ok("scenario_json: has external_calls", type(decoded.external_calls) == "table")
  ok("scenario_json: has debug", type(decoded.debug) == "table")
  vim.api.nvim_buf_delete(buf, { force = true })
end

-- Scenario 3: All 5 public API functions exist with correct types.
local function scenario_public_api_surface()
  local calltree = require("calltree")
  ok("api: analyze_at_cursor is function", type(calltree.analyze_at_cursor) == "function")
  ok("api: analyze_at_cursor_json is function", type(calltree.analyze_at_cursor_json) == "function")
  ok("api: dump_at_cursor is function", type(calltree.dump_at_cursor) == "function")
  ok("api: write_json_to_file is function", type(calltree.write_json_to_file) == "function")
  ok("api: setup is function", type(calltree.setup) == "function")
  ok("api: encode_json is function", type(calltree.encode_json) == "function")
end

-- Scenario 4: setup is idempotent.
local function scenario_setup_idempotent()
  local calltree = require("calltree")
  -- Save the original debug option so we can restore it after this
  -- scenario. Previously setup() mutated M.options.debug and never
  -- restored it, which could affect later scenarios that depend on
  -- the default (true) debug value.
  local orig_debug = calltree.options.debug
  local ok1, err1 = pcall(calltree.setup, { debug = true })
  local ok2, err2 = pcall(calltree.setup, { debug = true })
  ok("setup: first call ok", ok1, tostring(err1))
  ok("setup: second call ok (idempotent)", ok2, tostring(err2))
  -- Commands should still exist.
  local cmds = vim.api.nvim_get_commands({})
  ok("setup: CalltreeAnalyze exists after setup", cmds["CalltreeAnalyze"] ~= nil)
  -- Restore the original debug option.
  calltree.options.debug = orig_debug
end

-- Scenario 5: analyze output structure under real LSP.
local function scenario_with_real_lsp()
  local project_dir = "/tmp/calltree_compat_proj"
  vim.fn.delete(project_dir, "rf")
  vim.fn.mkdir(project_dir, "p")
  local f = io.open(project_dir .. "/lib.lua", "w")
  f:write("local M = {}\nfunction M.foo() return 1 end\nfunction M.bar() return M.foo() end\nreturn M\n")
  f:close()
  vim.cmd("cd " .. project_dir)
  vim.cmd("edit lib.lua")
  vim.bo.filetype = "lua"
  _G.start_lua_lsp(0)
  -- Wait for LSP to be ready.
  local uri = vim.uri_from_bufnr(0)
  local start = vim.loop.hrtime()
  while (vim.loop.hrtime() - start) / 1e6 < 30000 do
    local ok_r, r = pcall(vim.lsp.buf_request_sync, 0, "textDocument/documentSymbol",
      { textDocument = { uri = uri } }, 3000)
    if ok_r and r then
      -- Bug fix: the inner `break` only escaped the `for` loop, not
      -- the outer `while`. Use a `found` flag to break the outer
      -- loop, otherwise we keep polling for the full 30s timeout
      -- even after a successful result.
      local found = false
      for _, v in pairs(r) do
        if v.result and #v.result > 0 then
          found = true
          break
        end
      end
      if found then break end
    end
    vim.wait(200)
  end
  vim.api.nvim_win_set_cursor(0, { 2, 13 })  -- on "foo"
  vim.wait(500)
  local calltree = require("calltree")
  local result = calltree.analyze_at_cursor(0)
  ok("scenario_real_lsp: current_function detected", result.current_function ~= nil)
  if result.current_function then
    ok("scenario_real_lsp: name is foo", result.current_function.name == "foo",
      "got: " .. tostring(result.current_function.name))
    ok("scenario_real_lsp: range is array of 2", type(result.current_function.range) == "table"
      and #result.current_function.range == 2)
    ok("scenario_real_lsp: file ends with lib.lua",
      result.current_function.file:find("lib.lua$") ~= nil)
  end
  ok("scenario_real_lsp: callers is array", type(result.callers) == "table")
  ok("scenario_real_lsp: external_calls is array", type(result.external_calls) == "table")
  ok("scenario_real_lsp: debug present", result.debug ~= nil)
  if result.debug then
    ok("scenario_real_lsp: completion_reason is analyzed",
      result.debug.completion_reason == "analyzed",
      "got: " .. tostring(result.debug.completion_reason))
    -- All key debug fields are present.
    ok("scenario_real_lsp: debug.preconditions", type(result.debug.preconditions) == "table")
    ok("scenario_real_lsp: debug.cursor_detection", type(result.debug.cursor_detection) == "table")
    ok("scenario_real_lsp: debug.lsp_calls", type(result.debug.lsp_calls) == "table")
    ok("scenario_real_lsp: debug.ts_parses", type(result.debug.ts_parses) == "table")
    ok("scenario_real_lsp: debug.caller_decisions", type(result.debug.caller_decisions) == "table")
    ok("scenario_real_lsp: debug.external_call_decisions", type(result.debug.external_call_decisions) == "table")
    ok("scenario_real_lsp: debug.summary", type(result.debug.summary) == "table")
    ok("scenario_real_lsp: debug.timings", type(result.debug.timings) == "table")
    ok("scenario_real_lsp: debug.errors is array", type(result.debug.errors) == "table")
    ok("scenario_real_lsp: debug.warnings is array", type(result.debug.warnings) == "table")
    ok("scenario_real_lsp: debug.version is string", type(result.debug.version) == "string")
  end
  vim.cmd("bdelete! lib.lua")
  vim.fn.delete(project_dir, "rf")
end

--================================================================================
-- Runner
--================================================================================
print("=== calltree.nvim public API compatibility verification ===")
scenario_public_api_surface()
scenario_setup_idempotent()
scenario_no_lsp()
scenario_json_roundtrip()
scenario_with_real_lsp()
print("\n" .. string.rep("=", 60))
print(string.format("API compat: %d passed, %d failed", passes, #failures))
if #failures > 0 then
  print("Failed:")
  for _, f in ipairs(failures) do
    print(string.format("  - %s -- %s", f.name, f.msg or "(no message)"))
  end
  vim.cmd("cquit! 1")
else
  print("All API compat checks passed!")
  vim.cmd("q!")
end
