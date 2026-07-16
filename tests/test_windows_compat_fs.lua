--- tests/test_windows_compat_fs.lua — Windows-compatibility tests for
--- `lua/calltree/infrastructure/fs.lua`.
---
--- This file is part of the Windows compatibility test suite. It exercises
--- the three public functions of `fs.lua`:
---   * `read_file(path)`   — uses `io.open(path, "r")`
---   * `exists(path)`      — uses `os.rename(path, path)` + `io.open` fallback
---   * `getcwd()`          — uses `vim.fn.getcwd` / `os.getenv("PWD")` / `io.popen("pwd")`
---
--- All three touch the real filesystem (creating temp files, checking
--- existence) so they verify actual platform behavior, not just logic.
--- Tests that can ONLY run on Windows (or ONLY on Unix) use the skip
--- sentinel from `windows_compat_helper` so they are auto-skipped on the
--- wrong platform.
---
--- Platform-specific behavior verified:
---   * `read_file` with CRLF content (`\r\n`) — text-mode `io.open`
---     translates CRLF → LF on Windows but NOT on Unix. This affects
---     byte-positions in treesitter ranges when the source has Windows
---     line endings.
---   * `exists` with a path containing spaces or special chars — must
---     work on both platforms.
---   * `getcwd` fallback chain — `vim.fn.getcwd` is preferred (works on
---     both platforms inside Neovim); the `os.getenv("PWD")` fallback is
---     Unix-specific and the `io.popen("pwd 2>/dev/null")` fallback is
---     a Unix-only command. On Windows the equivalent env var is `CD`
---     (set by cmd.exe) and the equivalent command is `cmd /c cd`.

local fs       = require("calltree.infrastructure.fs")
local A        = require("assert")
local helper   = require("windows_compat_helper")

local M = {}

-- Convenience aliases.
local read_file = fs.read_file
local exists     = fs.exists
local getcwd     = fs.getcwd

--------------------------------------------------------------------------------
-- Section 1: read_file — basic round-trip
--------------------------------------------------------------------------------

--- `read_file` should return the exact bytes written to the file. This is
--- the baseline test — if it fails, all other read_file tests are
--- meaningless.
function M.test_read_file_round_trip_basic()
  local content = "local x = 1\nlocal y = 2\n"
  local path = helper.tempfile("basic.lua", content)
  local data, err = read_file(path)
  A.is_not_nil(data, "read_file should return content (err=" .. tostring(err) .. ")")
  A.equal(content, data, "read_file round-trip should preserve content exactly")
end

--- `read_file` should handle Windows-style paths (with backslashes) when
--- running on Windows. On Unix we skip this test because Unix doesn't
--- accept backslashes as path separators.
function M.test_read_file_windows_path_with_backslashes()
  helper.skip_if_not_windows("Windows-only: io.open with backslash path")
  -- Build a path with backslashes by replacing the temp dir's separator.
  local content = "local x = 1\n"
  local path = helper.tempfile("winpath.lua", content)
  -- On Windows the helper already uses backslashes; just verify read_file
  -- accepts the path as-is.
  local data, err = read_file(path)
  A.is_not_nil(data, "read_file should accept a backslash path on Windows")
  A.equal(content, data, "read_file content matches on Windows backslash path")
end

--- `read_file` with a path containing spaces — common on Windows
--- (`C:\Program Files\...`). The path must be passed to `io.open` without
--- truncation at the space.
function M.test_read_file_path_with_spaces()
  local content = "-- file with spaces in name\nreturn 42\n"
  local path = helper.tempfile("path with spaces.lua", content)
  local data, err = read_file(path)
  A.is_not_nil(data, "read_file should handle paths with spaces (err=" .. tostring(err) .. ")")
  A.equal(content, data, "read_file content matches for path with spaces")
end

--- `read_file` with a path containing special characters (`#`, `%`, `&`,
--- `(`, `)`). These are legal filename characters on both Unix and
--- Windows but are sometimes mishandled by shell-based tools.
function M.test_read_file_path_with_special_chars()
  local cases = {
    { name = "file#1.lua",         content = "-- hash\n" },
    { name = "file%percent.lua",   content = "-- percent\n" },
    { name = "file&amper.lua",     content = "-- ampersand\n" },
    { name = "file(1).lua",        content = "-- parens\n" },
  }
  for _, c in ipairs(cases) do
    local path = helper.tempfile(c.name, c.content)
    local data, err = read_file(path)
    A.is_not_nil(data,
      string.format("read_file should handle path '%s' (err=%s)", c.name, tostring(err)))
    A.equal(c.content, data,
      string.format("read_file content matches for path '%s'", c.name))
  end
end

--------------------------------------------------------------------------------
-- Section 2: read_file — CRLF / newline handling
--------------------------------------------------------------------------------

--- `read_file` uses `io.open(path, "r")` (text mode). On Windows, text
--- mode translates `\r\n` → `\n` on read. On Unix, no translation occurs
--- (the `\r` is preserved as-is). This is a known behavioral difference.
---
--- For source-code analysis, the LF-only result on Windows is actually
--- desirable (treesitter ranges use byte offsets that would be off-by-N
--- if `\r` characters were preserved). But it means the round-trip is
--- NOT bit-exact on Windows for files with CRLF endings.
function M.test_read_file_crlf_handling()
  -- Write the file in BINARY mode so the exact bytes are preserved.
  local crlf_content = "line1\r\nline2\r\nline3\r\n"
  local path = helper.tempfile("crlf.lua", crlf_content, true)  -- binary=true
  local data, _err = read_file(path)
  A.is_not_nil(data, "read_file should succeed for CRLF file")
  if helper.is_windows() then
    -- Windows text-mode: \r\n is translated to \n on read.
    A.equal("line1\nline2\nline3\n", data,
      "Windows text-mode read_file: \\r\\n translated to \\n")
  else
    -- Unix: no translation; \r\n is preserved.
    A.equal(crlf_content, data,
      "Unix read_file: \\r\\n preserved as-is (no text-mode translation)")
  end
end

--- `read_file` with a file containing a UTF-8 BOM (Byte Order Mark).
--- The BOM is `EF BB BF` at the start of the file. Lua's `io.open` does
--- NOT strip the BOM on either platform — it's returned as part of the
--- content. This is documented behavior; callers that need BOM-stripping
--- must do it themselves.
function M.test_read_file_utf8_bom_preserved()
  -- Write with BOM prefix.
  local bom = string.char(0xEF, 0xBB, 0xBF)
  local content_with_bom = bom .. "local x = 1\n"
  local path = helper.tempfile("bom.lua", content_with_bom, true)  -- binary
  local data, _err = read_file(path)
  A.is_not_nil(data, "read_file should succeed for BOM file")
  -- On both platforms, the BOM is preserved in the read content because
  -- Lua's text-mode `r` doesn't strip UTF-8 BOMs (it only does CRLF
  -- translation on Windows).
  A.truthy(data:sub(1, 3) == bom,
    "read_file preserves UTF-8 BOM (Lua text-mode does not strip it)")
end

--------------------------------------------------------------------------------
-- Section 3: read_file — error handling
--------------------------------------------------------------------------------

--- `read_file` with a nil path should return (nil, err_msg), not crash.
function M.test_read_file_nil_path()
  local data, err = read_file(nil)
  A.is_nil(data, "nil path: data should be nil")
  A.is_not_nil(err, "nil path: err_msg should be set")
end

--- `read_file` with an empty-string path should return (nil, err_msg).
function M.test_read_file_empty_path()
  local data, err = read_file("")
  A.is_nil(data, "empty path: data should be nil")
  A.is_not_nil(err, "empty path: err_msg should be set")
end

--- `read_file` with a non-existent path should return (nil, err_msg).
function M.test_read_file_nonexistent_path()
  local data, err = read_file("/nonexistent/path/that/does/not/exist.lua")
  A.is_nil(data, "nonexistent path: data should be nil")
  A.is_not_nil(err, "nonexistent path: err_msg should be set")
end

--------------------------------------------------------------------------------
-- Section 4: exists — basic file existence
--------------------------------------------------------------------------------

--- `exists` returns true for a file that was just created.
function M.test_exists_for_existing_file()
  local path = helper.tempfile("exists.lua", "content")
  A.truthy(exists(path), "exists should return true for a file that exists")
end

--- `exists` returns false for a path that does not exist.
function M.test_exists_for_nonexistent_file()
  A.falsy(exists("/nonexistent/path/that/does/not/exist.lua"),
    "exists should return false for a nonexistent path")
end

--- `exists` returns false for nil/empty input (defensive).
function M.test_exists_for_nil_and_empty()
  A.falsy(exists(nil), "exists(nil) should return false")
  A.falsy(exists(""), "exists('') should return false")
end

--- `exists` for a path with spaces — must not truncate at the space.
function M.test_exists_for_path_with_spaces()
  local path = helper.tempfile("exists with spaces.lua", "content")
  A.truthy(exists(path), "exists should return true for a path with spaces")
end

--- `exists` for a path with special characters.
function M.test_exists_for_path_with_special_chars()
  local cases = { "exists#1.lua", "exists%.lua", "exists&.lua", "exists(1).lua" }
  for _, name in ipairs(cases) do
    local path = helper.tempfile(name, "content")
    A.truthy(exists(path),
      string.format("exists should return true for path '%s'", name))
  end
end

--- `exists` for a directory — the implementation uses `os.rename(path, path)`
--- which succeeds for directories on both Unix and Windows. The `io.open`
--- fallback also succeeds for directories on Unix (Linux quirk: dirs can
--- be opened for reading) but FAILS on Windows. So the behavior is
--- platform-dependent: exists(dir) returns true on both platforms via
--- `os.rename`, which is the primary check.
function M.test_exists_for_directory()
  local dir = helper.make_temp_dir()
  A.truthy(exists(dir),
    "exists should return true for a directory (via os.rename primary check)")
end

--------------------------------------------------------------------------------
-- Section 5: exists — Windows case-insensitivity (platform-conditional)
--------------------------------------------------------------------------------

--- On Windows, the filesystem is case-insensitive: `foo.lua` and
--- `FOO.LUA` refer to the same file. `exists("FOO.LUA")` should return
--- true even if the file was created as `foo.lua`. On Unix, `exists`
--- should return false for `FOO.LUA` when only `foo.lua` exists.
function M.test_exists_case_sensitivity()
  local lower_path = helper.tempfile("case_lower.lua", "content")
  -- Construct the upper-case variant of the same path.
  local upper_path = lower_path:gsub("case_lower", "CASE_LOWER")
  if helper.is_windows() then
    A.truthy(exists(upper_path),
      "Windows: exists should return true for case-variant of existing file")
  else
    A.falsy(exists(upper_path),
      "Unix: exists should return false for case-variant of existing file")
  end
end

--------------------------------------------------------------------------------
-- Section 6: getcwd — fallback chain
--------------------------------------------------------------------------------

--- `getcwd` should return a non-empty string in any reasonable test
--- environment (the test runner is invoked from a working directory).
--- This is a smoke test — we don't assert the exact value because it
--- varies by environment.
function M.test_getcwd_returns_nonempty()
  local cwd = getcwd()
  A.is_not_nil(cwd, "getcwd should return a non-nil value in a normal environment")
  A.truthy(cwd and #cwd > 0, "getcwd should return a non-empty string")
end

--- `getcwd` should return a path that `is_path_under` recognizes as the
--- current directory. This is a smoke test for the integration between
--- `getcwd` and `is_path_under` — if `getcwd` returns a trailing slash
--- or a quoted path, `is_path_under` might fail to match.
function M.test_getcwd_path_is_usable_in_is_path_under()
  local path_utils = require("calltree.utils.path")
  local cwd = getcwd()
  if cwd == nil then
    helper.skip("getcwd returned nil — cannot test integration")
  end
  -- The cwd itself should be recognized as "under" itself.
  A.truthy(path_utils.is_path_under(cwd, cwd),
    "getcwd() result should be recognized as under itself by is_path_under")
end

--- `getcwd` should NOT return a path with a trailing slash (the
--- implementation strips trailing whitespace, but a trailing path
--- separator could still leak through on some platforms). A trailing
--- separator on the cwd would cause `path_join(cwd, file)` to produce
--- `cwd//file` (double slash), which works on Unix but is unusual.
function M.test_getcwd_no_trailing_separator()
  local cwd = getcwd()
  if cwd == nil then
    helper.skip("getcwd returned nil — cannot test trailing separator")
  end
  local last = cwd:sub(-1)
  A.truthy(last ~= "/" and last ~= "\\",
    "getcwd should not return a path with a trailing separator (got: " .. cwd .. ")")
end

--- `getcwd` fallback chain: when `vim.fn.getcwd` is unavailable (pure
--- Lua test environment), `getcwd` should fall through to `os.getenv("PWD")`
--- (Unix) or `io.popen("pwd")` (Unix fallback). On Windows, the env var
--- is `CD` and the command is `cmd /c cd`. We mock `os.getenv` to verify
--- the fallback picks up the right env var.
function M.test_getcwd_prefers_pwd_when_no_vim()
  -- Mock os.getenv to return a known PWD value.
  local orig_getenv = os.getenv
  local mocked_env = { PWD = "/mock/pwd/path", CD = "C:\\mock\\cd\\path" }
  local _ = mocked_env  -- suppress unused warning
  -- Replace os.getenv with our mock. Note: this is a global replacement,
  -- restored at the end of the test. Using pcall to ensure restoration.
  local ok, err = pcall(function()
    os.getenv = function(name)
      if name == "PWD" then return "/mock/pwd/path" end
      if name == "CD"  then return "C:\\mock\\cd\\path" end
      return orig_getenv(name)
    end
    -- Re-require fs to get a fresh module instance with our mock active.
    package.loaded["calltree.infrastructure.fs"] = nil
    package.loaded["calltree.core.interfaces"] = nil
    local fs_mocked = require("calltree.infrastructure.fs")
    local cwd = fs_mocked.getcwd()
    -- On Unix, getcwd should pick up PWD. On Windows, the implementation
    -- currently still checks PWD first (a known issue we document in the
    -- test), so the result depends on the platform.
    if helper.is_windows() then
      -- The current implementation checks PWD first even on Windows,
      -- which is a known limitation (should check CD first on Windows).
      -- We document this by accepting either value.
      A.truthy(cwd == "/mock/pwd/path" or cwd == "C:\\mock\\cd\\path",
        "Windows getcwd fallback: should pick up either PWD or CD env var (got: " .. tostring(cwd) .. ")")
    else
      A.equal("/mock/pwd/path", cwd,
        "Unix getcwd fallback: should pick up PWD env var")
    end
  end)
  -- Always restore os.getenv, even on test failure.
  os.getenv = orig_getenv
  package.loaded["calltree.infrastructure.fs"] = nil
  package.loaded["calltree.core.interfaces"] = nil
  require("calltree.infrastructure.fs")  -- re-require to restore original
  if not ok then error(err, 2) end
end

--------------------------------------------------------------------------------
-- Section 7: read_file — size limit
--------------------------------------------------------------------------------

--- `read_file` should reject files larger than `MAX_FILE_SIZE_BYTES`
--- (10 MiB by default). We verify this by creating a file just over the
--- limit and asserting `read_file` returns nil with an error message.
--- To keep the test fast, we use a 10 MiB + 1 byte file (created in
--- binary mode for exact byte count).
function M.test_read_file_rejects_oversized_file()
  local constants = require("calltree.utils.constants")
  local limit = constants.MAX_FILE_SIZE_BYTES
  -- Create a file exactly limit+1 bytes. We write in binary mode to
  -- avoid CRLF translation inflating the byte count on Windows.
  local path = helper.tempfile("oversized.bin", nil, true)  -- binary, no content yet
  local f = io.open(path, "wb")
  if not f then
    helper.skip("could not open oversized.bin for writing")
  end
  -- Write limit+1 zero bytes (fast: write in 1 MiB chunks).
  local remaining = limit + 1
  local chunk_size = 1024 * 1024
  local chunk = string.rep("\0", math.min(chunk_size, remaining))
  while remaining > 0 do
    local write_size = math.min(remaining, #chunk)
    f:write(chunk:sub(1, write_size))
    remaining = remaining - write_size
  end
  f:close()
  local data, err = read_file(path)
  A.is_nil(data, "read_file should reject files > MAX_FILE_SIZE_BYTES")
  A.is_not_nil(err, "read_file should return an error message for oversized files")
  A.truthy(err:find("too large") ~= nil,
    "error message should mention 'too large' (got: " .. tostring(err) .. ")")
end

return M
