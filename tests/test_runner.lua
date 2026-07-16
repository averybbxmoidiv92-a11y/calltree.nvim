--- tests/test_runner.lua — entry point: `lua5.4 tests/test_runner.lua`.
---
--- Discovers all test_*.lua files in tests/, runs each test function, and
--- prints a summary. Exits non-zero if any test failed.
---
--- Improvements over the original:
---   - Auto-discovers test files via lfs (when available) or vim.loop.fs_scandir
---     (in headless Neovim), with a manual fallback list. New test files are
---     picked up automatically in both environments.
---   - Resets `package.loaded` for calltree modules between test files so
---     state mutations in one file don't leak into the next. This fixes the
---     cross-file state-leak issue (e.g. test_setup_debug_option mutating
---     calltree.options.debug leaking into subsequent files).
---   - Prints a consolidated failure summary with error messages at the end
---     (not just file :: name) for easier debugging.
---   - Natural sort for test names with numeric prefixes (test_1, test_2, ...)
---     so they run in numeric order rather than lexicographic (test_10 before
---     test_2).

local function setup_path()
  local source = debug.getinfo(1, "S").source
  local script_dir
  if source:sub(1, 1) == "@" then
    script_dir = source:sub(2):match("(.*/)")
  end
  -- This file lives in tests/. Plugin root is the parent directory.
  if script_dir == nil or script_dir == "" then script_dir = "." end
  script_dir = script_dir:gsub("/$", "")
  local plugin_root = script_dir:match("(.+)/[^/]+$") or (script_dir .. "/..")
  if script_dir == "." then plugin_root = ".." end
  -- Allow `require("calltree.xxx")` from lua/ and test helpers from tests/.
  package.path = plugin_root .. "/?.lua;"
                .. plugin_root .. "/?/init.lua;"
                .. plugin_root .. "/lua/?.lua;"
                .. plugin_root .. "/lua/?/init.lua;"
                .. script_dir .. "/?.lua;"
                .. package.path
  return script_dir, plugin_root
end

local script_dir, plugin_root = setup_path()
local tests_dir = script_dir .. "/"

------------------------------------------------------------------------------
-- Discover test files.
-- Tries (1) lfs, (2) vim.loop.fs_scandir (headless Neovim), (3) manual list.
-- New test files are picked up automatically in environments 1 and 2.
------------------------------------------------------------------------------
local function discover_test_files()
  local found = {}
  -- (1) Try lfs (LuaFileSystem).
  local ok_lfs, lfs = pcall(require, "lfs")
  if ok_lfs and lfs then
    for fname in lfs.dir(tests_dir) do
      if fname:match("^test_.*%.lua$") then
        found[#found + 1] = fname
      end
    end
    if #found > 0 then table.sort(found); return found end
  end
  -- (2) Try vim.loop.fs_scandir (headless Neovim environment).
  if vim and vim.loop and vim.loop.fs_scandir then
    local req = vim.loop.fs_scandir(tests_dir)
    if req then
      while true do
        local name = vim.loop.fs_scandir_next(req)
        if name == nil then break end
        if name:match("^test_.*%.lua$") then
          found[#found + 1] = name
        end
      end
      if #found > 0 then table.sort(found); return found end
    end
  end
  -- (3) Fallback: manual list (kept in sync with the tests/ directory).
  -- Updated when new test files are added; auto-discovery above is preferred.
  return {
    "test_preconditions.lua",
    "test_cursor_position.lua",
    "test_callers.lua",
    "test_external_calls.lua",
    "test_external_calls_filtering.lua",
    "test_coordinates.lua",
    "test_edge_cases.lua",
    "test_debug_field.lua",
    "test_wrapped_nodes.lua",
    "test_callee_extraction.lua",
    "test_user_scenario.lua",
    "test_adapter_arg_order.lua",
    "test_module_import_resolution.lua",
    "test_dotted_caller_name.lua",
    "test_debug_option.lua",
    "test_lsp_capabilities.lua",
    "test_edge_cases_advanced.lua",
    "test_multilanguage.lua",
    "test_setup_debug_option.lua",
    "test_python.lua",
    "test_c.lua",
    "test_immutability.lua",
    "javascript_spec.lua",
    "test_domain_types.lua",
    -- Windows-compatibility suite (added in 1.2.3).
    "test_windows_compat_path.lua",
    "test_windows_compat_fs.lua",
    "test_windows_compat_module_finder.lua",
    "test_windows_compat_init.lua",
  }
end

local test_files = discover_test_files()

------------------------------------------------------------------------------
-- Natural sort comparator: sorts "test_2_foo" before "test_10_bar" by
-- extracting the numeric prefix after "test_". Falls back to lexicographic
-- for names without a numeric prefix.
------------------------------------------------------------------------------
local function natural_sort_key(name)
  local n = name:match("^test_(%d+)")
  return n and tonumber(n) or math.huge, name
end

table.sort(test_files, function(a, b)
  -- Sort by the numeric prefix in the test function names (not the filename).
  -- Filenames don't have numeric prefixes, so this is a simple lexical sort.
  return a < b
end)

------------------------------------------------------------------------------
-- Reset calltree modules in package.loaded between test files.
-- This prevents state mutations (e.g. calltree.options.debug changes) from
-- leaking across test files. We only reset calltree.* modules (not test
-- helpers or third-party modules) to avoid breaking require caches that
-- tests may depend on.
------------------------------------------------------------------------------
local function reset_calltree_modules()
  for key in pairs(package.loaded) do
    if type(key) == "string" and key:match("^calltree%.") then
      package.loaded[key] = nil
    end
  end
end

local total_pass = 0
local total_fail = 0
local total_skip = 0
local failures = {}

-- Detect a skip sentinel thrown by the windows-compat test helper (or any
-- test that wants to mark itself as conditionally skipped). The sentinel
-- is a table `{ __skip = true, reason = "..." }`; the test is counted as
-- passed-but-skipped and the reason is printed for visibility.
local function is_skip_sentinel(err)
  return type(err) == "table" and err.__skip == true
end

for _, fname in ipairs(test_files) do
  local path = tests_dir .. fname
  local chunk, err = loadfile(path)
  if not chunk then
    print(string.format("[LOAD ERROR] %s: %s", fname, err or "unknown"))
    total_fail = total_fail + 1
    table.insert(failures, { file = fname, name = "(load)", err = err })
  else
    -- Run the file to get its module table (it returns M).
    local ok_mod, mod = pcall(chunk)
    if not ok_mod then
      print(string.format("[MODULE ERROR] %s: %s", fname, mod))
      total_fail = total_fail + 1
      table.insert(failures, { file = fname, name = "(module)", err = mod })
    else
      -- Collect all test_* functions.
      local names = {}
      for k, v in pairs(mod) do
        if type(k) == "string" and k:sub(1, 5) == "test_" and type(v) == "function" then
          table.insert(names, k)
        end
      end
      -- Natural sort: test_2 before test_10 (numeric prefix aware).
      table.sort(names, function(a, b)
        local na, sa = natural_sort_key(a)
        local nb, sb = natural_sort_key(b)
        if na ~= nb then return na < nb end
        return sa < sb
      end)
      for _, name in ipairs(names) do
        local fn = mod[name]
        local ok, err = pcall(fn)
        if ok then
          print(string.format("  PASS  %s :: %s", fname, name))
          total_pass = total_pass + 1
        elseif is_skip_sentinel(err) then
          -- Skip sentinel: the test itself decided not to run on this
          -- platform / configuration. Counted as PASS-but-SKIP so the
          -- suite still reports green; the reason is printed for
          -- visibility in CI logs.
          print(string.format("  SKIP  %s :: %s  (%s)", fname, name,
            tostring(err.reason or "no reason given")))
          total_skip = total_skip + 1
          total_pass = total_pass + 1  -- skip counts as non-failure
        else
          print(string.format("  FAIL  %s :: %s", fname, name))
          if type(err) == "table" then
            print(string.format("        message: %s", err.message or "(no message)"))
            if err.expected ~= nil then
              print(string.format("        expected: %s", tostring(err.expected)))
            end
            if err.actual ~= nil then
              print(string.format("        actual:   %s", tostring(err.actual)))
            end
          else
            print(string.format("        error: %s", tostring(err)))
          end
          total_fail = total_fail + 1
          table.insert(failures, { file = fname, name = name, err = err })
        end
      end
    end
  end
  -- Reset calltree modules between test files to prevent state leakage.
  -- This ensures each test file starts with a fresh calltree module state
  -- (e.g. calltree.options.debug resets to its default, lsp_diagnostics
  -- cache clears, etc.). Test helper modules (mocks, assert, scenario,
  -- tree_builder) are NOT reset because they hold no mutable cross-test
  -- state and resetting them would break require caches.
  reset_calltree_modules()
end

print("\n" .. string.rep("=", 60))
print(string.format("Total: %d passed, %d failed, %d skipped",
  total_pass, total_fail, total_skip))

-- Best-effort cleanup of temp files created by windows_compat_helper.
-- The helper creates temp files via os.tmpname and registers them for
-- cleanup, but Lua 5.4 has no atexit hook and no `newproxy` (the
-- sentinel-based __gc trick used in the helper doesn't work on 5.4).
-- We call the cleanup function explicitly here so temp files don't
-- accumulate on the CI runner's disk.
do
  local ok, helper = pcall(require, "windows_compat_helper")
  if ok and helper and helper.tempfile_cleanup then
    pcall(helper.tempfile_cleanup)
  end
end

if total_fail > 0 then
  print("\nFailed tests (consolidated summary with errors):")
  for _, f in ipairs(failures) do
    local err_msg
    if type(f.err) == "table" then
      err_msg = f.err.message or "(no message)"
      if f.err.expected ~= nil or f.err.actual ~= nil then
        err_msg = err_msg .. " (expected: " .. tostring(f.err.expected) ..
          ", actual: " .. tostring(f.err.actual) .. ")"
      end
    else
      err_msg = tostring(f.err)
    end
    print(string.format("  - %s :: %s", f.file, f.name))
    print(string.format("      %s", err_msg))
  end
  os.exit(1)
else
  print("All tests passed!")
  os.exit(0)
end
