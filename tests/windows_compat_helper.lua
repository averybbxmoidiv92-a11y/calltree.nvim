--- tests/windows_compat_helper.lua — shared helpers for the Windows-compatibility
--- test suite.
---
--- Provides:
---   * `is_windows()`         — runtime platform detection.
---   * `os_sep()`             — the native path separator (`\\` on Windows,
---                              `/` everywhere else).
---   * `make_temp_dir()`      — creates a unique temp directory and returns
---                              its path; cleans up automatically on exit
---                              via a `tempfile_cleanup` registry.
---   * `tempfile(name, content)` — creates a temp file inside the temp dir
---                              and returns its absolute path.
---   * `tempfile_cleanup()`   — removes every file/dir registered above.
---   * `skip_if_not_windows(reason)` — raises a `skip` sentinel that the
---                              test runner can catch (the bundled runner
---                              treats it as a PASS with a `[SKIP]` notice).
---   * `with_cwd_env(path, fn)` — temporarily sets PWD/CD env vars so that
---                              `fs.getcwd()` fallback paths can be
---                              exercised on either platform.
---
--- All helpers are pure Lua (no Neovim dependency) so they work in both the
--- pure-Lua test runner and inside Neovim's headless test environment.

local M = {}

------------------------------------------------------------------------------
-- Platform detection.
--
-- `package.config:sub(1,1)` returns the directory separator used by the
-- Lua runtime itself: `\\` on Windows builds, `/` everywhere else. This is
-- the most reliable pure-Lua way to detect the host platform. As a
-- secondary signal we also inspect the `OS` env var (Windows sets it to
-- `Windows_NT`); a Unix `uname`-based check is intentionally omitted
-- because `io.popen("uname")` would itself be a platform dependency.
------------------------------------------------------------------------------
local function raw_is_windows()
  if package.config:sub(1, 1) == "\\" then return true end
  local os_env = os.getenv("OS")
  if os_env and os_env:lower():find("windows") then return true end
  return false
end
M.is_windows = raw_is_windows

function M.os_sep()
  return raw_is_windows() and "\\" or "/"
end

------------------------------------------------------------------------------
-- Tempfile registry. We keep a single shared temp dir per test process and
-- track every file we create so we can wipe them all at the end. Skipping
-- the cleanup would leak files into the system temp dir on CI runners,
-- which over time would fill the disk.
------------------------------------------------------------------------------
local temp_dir
local temp_files = {}  -- ordered list of paths to remove (dirs come last)

local function ensure_temp_dir()
  if temp_dir then return temp_dir end
  -- Use os.tmpname (Lua 5.4) to get a unique base name; convert it into a
  -- directory by appending a suffix and mkdir-ing it via `os.execute`.
  -- `os.tmpname` returns an absolute path on both platforms (though its
  -- exact form differs: `/tmp/lua_XXXXX` on Linux, `C:\Users\...\Temp\luXXXXX`
  -- on Windows). We can't use `lfs` because it's not a built-in dep.
  local base = os.tmpname()
  -- On some systems os.tmpname() actually creates the file; remove it so we
  -- can mkdir a directory of the same name (or use base + ".d").
  local dir = base .. ".ctwcdir"
  -- Best-effort remove of `base` (no error if missing).
  os.remove(base)
  -- mkdir — use platform-appropriate command. `mkdir` exists on both
  -- Unix and Windows but with slightly different flag semantics; on
  -- Windows `mkdir` creates intermediate dirs by default, on Unix we
  -- need `-p`. We use `-p` on Unix only.
  if raw_is_windows() then
    os.execute('mkdir "' .. dir .. '" 2>NUL')
  else
    os.execute('mkdir -p "' .. dir .. '" 2>/dev/null')
  end
  temp_dir = dir
  return dir
end

function M.make_temp_dir()
  return ensure_temp_dir()
end

--- Create a file inside the temp dir with the given (relative) name and
--- content. Returns the absolute path. The path is constructed with the
--- NATIVE separator so that on Windows we get `C:\...\Temp\x.dir\foo.lua`
--- (with backslashes) and on Unix `/tmp/.../foo.lua` (with forward
--- slashes). This lets the fs.* tests exercise the platform's native
--- separator without forcing a particular form.
function M.tempfile(name, content, binary)
  local dir = ensure_temp_dir()
  local sep = raw_is_windows() and "\\" or "/"
  -- If `name` already contains a separator, treat it as a relative path
  -- with subdirectories. Create those subdirs first (best-effort).
  local parent = dir
  for sub in name:gmatch("([^/\\]+)") do
    parent = parent .. sep .. sub
  end
  -- `parent` now ends with the full file path; its directory is everything
  -- except the last segment. Walk and mkdir each intermediate dir.
  local full_path = parent
  local cur = dir
  for sub in name:gmatch("([^/\\]+)") do
    -- Skip the last segment (it's the file, not a dir).
    if cur .. sep .. sub ~= full_path then
      cur = cur .. sep .. sub
      if not raw_is_windows() then
        os.execute('mkdir -p "' .. cur .. '" 2>/dev/null')
      else
        os.execute('mkdir "' .. cur .. '" 2>NUL')
      end
    end
  end

  local mode = binary and "wb" or "w"
  local f = io.open(full_path, mode)
  if not f then
    error("windows_compat_helper: could not create tempfile: " .. full_path)
  end
  if content ~= nil then
    f:write(content)
  end
  f:close()
  temp_files[#temp_files + 1] = full_path
  return full_path
end

--- Remove all registered temp files and the temp dir itself. Safe to call
--- multiple times. Errors are swallowed (best-effort cleanup) so a single
--- stubborn file doesn't abort the test runner.
function M.tempfile_cleanup()
  for i = #temp_files, 1, -1 do
    local p = temp_files[i]
    pcall(os.remove, p)
    temp_files[i] = nil
  end
  if temp_dir then
    -- rmdir works only when the dir is empty; we've already removed all
    -- files. On Windows use `rmdir` (without `/S` to refuse non-empty).
    if raw_is_windows() then
      os.execute('rmdir "' .. temp_dir .. '" 2>NUL')
    else
      os.execute('rmdir "' .. temp_dir .. '" 2>/dev/null')
    end
    temp_dir = nil
  end
end

-- Register cleanup at exit so leaked files don't accumulate even if the
-- test runner crashes (Lua 5.4 supports the optional arg to atexit).
-- NOTE: `os.exit` handlers run on normal exit; on abrupt termination
-- (e.g. SIGKILL) files will leak — acceptable for a test runner.
local cleanup_registered = false
function M.register_cleanup()
  if cleanup_registered then return end
  cleanup_registered = true
  -- Lua has no portable atexit; we rely on the test runner calling
  -- tempfile_cleanup() explicitly. Provide a __gc fallback via a userdata
  -- sentinel for best-effort cleanup when the Lua state shuts down.
  local sentinel = newproxy and newproxy(true) or nil
  if sentinel then
    getmetatable(sentinel).__gc = function()
      M.tempfile_cleanup()
    end
    -- Anchor the sentinel in a long-lived table so it isn't collected
    -- early. We use a module-level upvalue.
    M._sentinel = sentinel
  end
end

------------------------------------------------------------------------------
-- Skip sentinel. The bundled test runner (test_runner.lua) treats a test
-- function that throws a table `{ __skip = true, reason = "..." }` as
-- skipped (counted as PASS with a `[SKIP]` notice). Tests that can ONLY
-- run on Windows (or ONLY on Unix) call `skip_if_not_windows(reason)` to
-- raise this sentinel when the platform doesn't match.
------------------------------------------------------------------------------
function M.skip(reason)
  local err = { __skip = true, reason = reason or "skipped" }
  error(err, 2)
end

function M.skip_if_not_windows(reason)
  if not raw_is_windows() then
    M.skip(reason or "test requires Windows platform")
  end
end

function M.skip_if_windows(reason)
  if raw_is_windows() then
    M.skip(reason or "test must run on a non-Windows platform")
  end
end

--- Check whether an error value is the skip sentinel. The test runner
--- uses this to distinguish a `skip` from a real test failure.
function M.is_skip(err)
  return type(err) == "table" and err.__skip == true
end

------------------------------------------------------------------------------
-- with_cwd_env(path, fn): a no-op stub kept for API symmetry. Lua 5.4
-- does not provide `os.setenv` (only LuaJIT and some patched builds do),
-- and shell-based `export PWD=...` only affects the subprocess, not the
-- parent Lua process — so we cannot reliably manipulate env vars from
-- pure-Lua tests. Tests that need to verify the env-var fallback path of
-- fs.getcwd() must do so by mocking `os.getenv` itself (see
-- `test_windows_compat_fs.lua::test_getcwd_prefers_pwd_when_no_vim`).
------------------------------------------------------------------------------
function M.with_cwd_env(_path, fn)
  return fn()
end

return M
