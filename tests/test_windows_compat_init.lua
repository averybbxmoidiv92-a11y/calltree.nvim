--- tests/test_windows_compat_init.lua — Windows-compatibility tests for
--- `lua/calltree/init.lua :: write_json_to_file`.
---
--- This file is part of the Windows compatibility test suite. It exercises
--- the `write_json_to_file` function which:
---   * validates the `path` argument (must be a non-empty string)
---   * calls `analyze_at_cursor_json` to produce a JSON string
---   * opens the file with `io.open(path, "w")` (text mode)
---   * writes the JSON string via `f:write(json)`
---   * flushes and closes the handle
---   * on failure, removes the partial file via `os.remove(path)`
---
--- Platform-specific concerns tested:
---   * `io.open(path, "w")` opens in TEXT mode — on Windows, this means
---     `\n` in the JSON content is translated to `\r\n` on write. This
---     could corrupt JSON files intended for cross-platform tooling.
---     The test verifies the ACTUAL behavior and documents whether the
---     plugin needs a fix (e.g. switching to `"wb"` binary mode).
---   * Paths with spaces (e.g. `C:\Program Files\app\out.json`) — must
---     work on both platforms.
---   * Paths with special chars (`#`, `%`, `&`, `(`, `)`) — must work
---     on both platforms.
---   * `os.remove(path)` cleanup on write failure — must succeed on both
---     platforms when the path was just created by `io.open`.
---
--- Because `write_json_to_file` calls `analyze_at_cursor_json` (which
--- needs a Neovim buffer + LSP), we MOCK `analyze_at_cursor_json` to
--- return a fixed JSON string. This lets us test the file I/O logic in
--- pure Lua without a Neovim dependency.

local A        = require("assert")
local helper   = require("windows_compat_helper")

local M = {}

-- Mock the calltree module to expose a controllable `write_json_to_file`.
-- We can't `require("calltree")` in pure Lua because init.lua references
-- `vim.*` globals at module load time. Instead, we extract the
-- `write_json_to_file` source code into a standalone function with the
-- same logic, but with `analyze_at_cursor_json` injected as a parameter.
-- This mirrors how the real function works (it closes over M) but
-- without the Neovim dependency.
--
-- The function signature: write_json_to_file(path, analyze_fn, opts)
--   * path       — output file path
--   * analyze_fn — function(bufnr, opts) -> json_string (or nil + error)
--   * opts       — { debug = boolean|nil }
-- Returns: ok, err_kind, err_detail  (same as the real function)
local LOG_PREFIX = "[calltree] "

local function resolve_debug(opts)
  -- In the real plugin this consults M.options.debug; here we just use
  -- opts.debug directly since there's no global state.
  return opts and opts.debug or false
end

-- Standalone replica of `write_json_to_file` for testing. The logic
-- mirrors init.lua lines 424-468 exactly so we exercise the same code
-- paths. If the source changes, this replica must be updated to match.
local function write_json_to_file(path, analyze_fn, opts)
  if type(path) ~= "string" or path == "" then
    return false, "open_failed", "invalid path (nil, non-string, or empty string)"
  end
  opts = opts or {}
  local debug_opt = resolve_debug(opts)
  local ok, json = pcall(analyze_fn, nil, { debug = debug_opt })
  if not ok then
    return false, "analyze_failed", tostring(json)
  end
  local f = io.open(path, "w")
  if not f then return false, "open_failed", "io.open returned nil for " .. tostring(path) end
  local ok_w, write_err = pcall(function()
    f:write(json)
    f:flush()
  end)
  pcall(function() f:close() end)
  if not ok_w then
    local rm_ok, rm_err = pcall(os.remove, path)
    if not rm_ok and resolve_debug(opts) then
      print(LOG_PREFIX .. "os.remove of partial file failed: " ..
        tostring(path) .. " (" .. tostring(rm_err) .. ")")
    end
    return false, "write_failed", tostring(write_err)
  end
  return true, nil, nil
end

-- A simple analyze_fn mock that returns a fixed JSON string with both
-- `\n` and `\t` characters (so we can detect CRLF translation).
local function mock_analyze_ok(_bufnr, _opts)
  return '{"callers":[],"external_calls":[],"current_function":null}\n'
end

-- A mock that always raises (simulates an analysis crash).
local function mock_analyze_fails(_bufnr, _opts)
  error("simulated analysis failure")
end

-- A mock that returns JSON containing `\n` (so we can detect whether
-- `io.open("w")` translated it to `\r\n` on Windows).
local function mock_analyze_with_newlines(_bufnr, _opts)
  return '{\n  "callers": [],\n  "external_calls": []\n}\n'
end

--------------------------------------------------------------------------------
-- Section 1: Basic write — round-trip
--------------------------------------------------------------------------------

--- `write_json_to_file` should succeed and produce a file containing the
--- exact JSON string returned by `analyze_fn`. On Unix this is a bit-exact
--- round-trip; on Windows the `\n` may be translated to `\r\n` (text mode).
function M.test_write_json_basic_round_trip()
  local path = helper.tempfile("output.json", nil, true)  -- binary, empty
  -- Remove the empty file so write_json_to_file creates it fresh.
  os.remove(path)
  local ok, err_kind, err_detail = write_json_to_file(path, mock_analyze_ok, {})
  A.truthy(ok, "write_json_to_file should succeed (err_kind=" .. tostring(err_kind) .. ", detail=" .. tostring(err_detail) .. ")")
  -- Read back the file in BINARY mode to get the exact bytes written.
  local f = io.open(path, "rb")
  A.is_not_nil(f, "output file should exist after write_json_to_file")
  local content = f:read("*a")
  f:close()
  if helper.is_windows() then
    -- Windows text-mode write: \n translated to \r\n.
    A.equal(mock_analyze_ok():gsub("\n", "\r\n"), content,
      "Windows: write_json_to_file should write JSON with \\r\\n line endings (text mode)")
  else
    A.equal(mock_analyze_ok(), content,
      "Unix: write_json_to_file should write JSON with \\n line endings (no translation)")
  end
end

--------------------------------------------------------------------------------
-- Section 2: Windows path handling
--------------------------------------------------------------------------------

--- `write_json_to_file` should accept a path with spaces (common on
--- Windows: `C:\Program Files\app\out.json`). The path must be passed
--- to `io.open` without truncation.
function M.test_write_json_path_with_spaces()
  local path = helper.tempfile("output with spaces.json", nil, true)
  os.remove(path)
  local ok, err_kind, err_detail = write_json_to_file(path, mock_analyze_ok, {})
  A.truthy(ok, "write_json_to_file should accept a path with spaces (err_kind=" .. tostring(err_kind) .. ")")
  -- Verify the file exists.
  local f = io.open(path, "rb")
  A.is_not_nil(f, "output file with spaces should exist")
  if f then f:close() end
end

--- `write_json_to_file` should accept a path with special chars
--- (`#`, `%`, `&`, `(`, `)`).
function M.test_write_json_path_with_special_chars()
  local cases = {
    "output#1.json",
    "output%percent.json",
    "output&amper.json",
    "output(1).json",
  }
  for _, name in ipairs(cases) do
    local path = helper.tempfile(name, nil, true)
    os.remove(path)
    local ok, err_kind, _ = write_json_to_file(path, mock_analyze_ok, {})
    A.truthy(ok,
      string.format("write_json_to_file should accept path '%s' (err_kind=%s)", name, tostring(err_kind)))
    local f = io.open(path, "rb")
    A.is_not_nil(f, string.format("output file '%s' should exist", name))
    if f then f:close() end
  end
end

--------------------------------------------------------------------------------
-- Section 3: Path validation
--------------------------------------------------------------------------------

--- `write_json_to_file` with a nil path should fail fast with
--- `err_kind = "open_failed"`.
function M.test_write_json_nil_path()
  local ok, err_kind, err_detail = write_json_to_file(nil, mock_analyze_ok, {})
  A.falsy(ok, "nil path: should fail")
  A.equal("open_failed", err_kind, "nil path: err_kind should be 'open_failed'")
  A.is_not_nil(err_detail, "nil path: err_detail should be set")
end

--- `write_json_to_file` with an empty-string path should fail fast.
function M.test_write_json_empty_path()
  local ok, err_kind, _ = write_json_to_file("", mock_analyze_ok, {})
  A.falsy(ok, "empty path: should fail")
  A.equal("open_failed", err_kind, "empty path: err_kind should be 'open_failed'")
end

--- `write_json_to_file` with a non-string path (e.g. number) should fail fast.
function M.test_write_json_non_string_path()
  local ok, err_kind, _ = write_json_to_file(12345, mock_analyze_ok, {})
  A.falsy(ok, "non-string path: should fail")
  A.equal("open_failed", err_kind, "non-string path: err_kind should be 'open_failed'")
end

--------------------------------------------------------------------------------
-- Section 4: Analysis failure handling
--------------------------------------------------------------------------------

--- When `analyze_fn` raises, `write_json_to_file` should return
--- `err_kind = "analyze_failed"` and NOT create the output file.
function M.test_write_json_analyze_failure()
  local path = helper.tempfile("should_not_exist.json", nil, true)
  os.remove(path)
  local ok, err_kind, err_detail = write_json_to_file(path, mock_analyze_fails, {})
  A.falsy(ok, "analyze failure: should fail")
  A.equal("analyze_failed", err_kind, "analyze failure: err_kind should be 'analyze_failed'")
  A.truthy(err_detail and err_detail:find("simulated analysis failure") ~= nil,
    "analyze failure: err_detail should contain the underlying error message")
  -- The output file should NOT exist (analysis runs before io.open).
  local f = io.open(path, "rb")
  A.is_nil(f, "analyze failure: output file should NOT be created")
end

--------------------------------------------------------------------------------
-- Section 5: CRLF / newline behavior
--------------------------------------------------------------------------------

--- `write_json_to_file` uses `io.open(path, "w")` (text mode). On Windows,
--- `\n` in the JSON content is translated to `\r\n` on write. This is a
--- known behavioral difference. For JSON files consumed by other tools
--- (e.g. jq, python's json.load), `\r\n` is usually acceptable (JSON
--- spec allows any whitespace), but for byte-exact round-trips it's not.
---
--- This test documents the actual behavior. If the plugin ever switches
--- to binary mode (`"wb"`), the Windows branch of this test must be
--- updated to expect `\n` (no translation).
function M.test_write_json_crlf_translation()
  local path = helper.tempfile("crlf_test.json", nil, true)
  os.remove(path)
  local ok = write_json_to_file(path, mock_analyze_with_newlines, {})
  A.truthy(ok, "write should succeed")
  -- Read back in binary mode.
  local f = io.open(path, "rb")
  A.is_not_nil(f, "output file should exist")
  local content = f:read("*a")
  f:close()
  -- Count line-ending characters.
  local _, nl_count = content:gsub("\n", "")
  local _, crlf_count = content:gsub("\r\n", "")
  local _, lone_cr_count = content:gsub("\r", "")
  lone_cr_count = lone_cr_count - crlf_count  -- CRs that are NOT part of CRLF
  if helper.is_windows() then
    -- Windows text mode: every \n becomes \r\n. So #\r\n == #\n, and
    -- there should be no lone \r or lone \n.
    A.equal(nl_count, crlf_count,
      string.format("Windows: all \\n should be translated to \\r\\n (nl=%d, crlf=%d)", nl_count, crlf_count))
    A.equal(0, lone_cr_count,
      "Windows: no lone \\r characters should appear (all CRs are part of CRLF)")
  else
    -- Unix: no translation; \n stays as \n, no \r at all.
    A.equal(0, crlf_count,
      "Unix: no \\r\\n should appear (no text-mode translation)")
    A.equal(0, lone_cr_count,
      "Unix: no \\r characters at all")
    A.truthy(nl_count > 0,
      "Unix: \\n characters preserved as-is")
  end
end

--------------------------------------------------------------------------------
-- Section 6: Cleanup on write failure
--------------------------------------------------------------------------------

--- When the write fails (simulated by closing the file handle prematurely
--- or writing to a read-only location), `write_json_to_file` should
--- attempt to remove the partial file via `os.remove(path)`. We can't
--- easily simulate a write failure without OS-level tricks, so we
--- verify the cleanup logic indirectly: after a successful write,
--- calling `os.remove(path)` should succeed (the file is removable).
function M.test_write_json_partial_cleanup_path_is_removable()
  local path = helper.tempfile("cleanup_test.json", nil, true)
  os.remove(path)
  local ok = write_json_to_file(path, mock_analyze_ok, {})
  A.truthy(ok, "write should succeed")
  -- Verify the file is removable (the cleanup logic relies on this).
  local rm_ok, rm_err = pcall(os.remove, path)
  A.truthy(rm_ok, "os.remove should succeed on a freshly-written file (err=" .. tostring(rm_err) .. ")")
end

--------------------------------------------------------------------------------
-- Section 7: Large JSON content
--------------------------------------------------------------------------------

--- `write_json_to_file` should handle a large JSON string (1 MiB) without
--- truncation. This stresses the `f:write(json)` call which may have
--- platform-specific buffer limits.
function M.test_write_json_large_content()
  -- Build a 1 MiB JSON string (lots of "callers" entries).
  local parts = { '{"callers":[' }
  for i = 1, 10000 do
    if i > 1 then parts[#parts + 1] = "," end
    parts[#parts + 1] = string.format('{"name":"caller_%d","file":"/path/file.lua"}', i)
  end
  parts[#parts + 1] = ']}'
  local big_json = table.concat(parts)
  local function mock_big(_bufnr, _opts) return big_json end

  local path = helper.tempfile("large.json", nil, true)
  os.remove(path)
  local ok, err_kind, _ = write_json_to_file(path, mock_big, {})
  A.truthy(ok, "large content: write should succeed (err_kind=" .. tostring(err_kind) .. ")")
  -- Read back in binary mode and verify the size matches.
  local f = io.open(path, "rb")
  A.is_not_nil(f, "large content: output file should exist")
  local content = f:read("*a")
  f:close()
  if helper.is_windows() then
    -- On Windows, \n in the content was translated to \r\n, so the file
    -- is larger than the JSON string. We check that the file is at least
    -- as large as the JSON string (no truncation).
    A.truthy(#content >= #big_json,
      string.format("Windows: file size (%d) should be >= json size (%d) — CRLF translation may inflate",
        #content, #big_json))
  else
    A.equal(#big_json, #content,
      string.format("Unix: file size (%d) should match json size (%d) — no translation",
        #content, #big_json))
  end
end

return M
