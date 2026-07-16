--- infrastructure/fs.lua — concrete IFileSystem implementation (infrastructure layer).
---
--- Provides file reading, file existence checks, and current working
--- directory queries. All I/O operations are wrapped in pcall, returning
--- nil/false on error instead of raising. The `read_file` handle is closed
--- in a finally-style pcall to avoid leaks.
---
--- This module belongs to the infrastructure layer and may use io.* and
--- vim.*; the analysis layer does not reference this module directly but
--- calls through the injected IFileSystem interface.

local M = {}

-- Default file size limit to prevent reading huge files and exhausting
-- memory. Reference the centralized constant from utils/constants.lua
-- (was a local literal `10 * 1024 * 1024` that could drift out of sync
-- with `constants.MAX_FILE_SIZE_BYTES`). The constant is required lazily
-- to avoid a circular dependency at module load time (constants.lua has
-- no dependency on fs.lua, but this keeps the require explicit and visible).
local constants = require("calltree.utils.constants")
local MAX_FILE_SIZE = constants.MAX_FILE_SIZE_BYTES

--- Read the entire file contents. Returns (nil, err_msg) on failure
--- (permissions, I/O error, file too large). The error message is
--- returned as a second value so callers can diagnose WHY the read
--- failed — previously the error was silently swallowed and callers
--- could only observe "source is nil".
--- @param path string
--- @return string|nil content, string|nil err_msg
function M.read_file(path)
  if path == nil or path == "" then return nil, "nil or empty path" end
  local f = io.open(path, "r")
  if not f then return nil, "io.open failed for " .. tostring(path) end
  -- try/finally style: the handle is ALWAYS closed, even when the read
  -- path raises an error inside the pcall. Previously a seek/read
  -- failure left the close to the trailing pcall, but the error path
  -- through `not ok` returned nil without surfacing the underlying
  -- reason — making diagnosis hard.
  local content, err_msg
  local ok, pcall_err = pcall(function()
    -- Check the file size (seek to end); reject if over the limit.
    -- If seek fails we cannot determine the size, so safely reject by
    -- returning nil instead of defaulting size to 0 (which would bypass
    -- the size check).
    local size_ok, size = pcall(function() return f:seek("end") end)
    if not size_ok or size == nil then
      err_msg = "seek(end) failed for " .. tostring(path)
      return
    end
    -- Wrap the seek-back in pcall too — pipe files and certain
    -- streams can fail on seek even when they succeeded once before.
    -- If we can't rewind, we can't safely read from the start, so
    -- reject rather than returning a partial/incorrect read.
    local seek_back_ok = pcall(function() f:seek("set") end)
    if not seek_back_ok then
      err_msg = "seek(set) failed for " .. tostring(path)
      return
    end
    if size > MAX_FILE_SIZE then
      err_msg = "file too large (" .. tostring(size) .. " > " ..
        tostring(MAX_FILE_SIZE) .. "): " .. tostring(path)
      return
    end
    content = f:read("*a")
    if content == nil then
      err_msg = "f:read('*a') returned nil for " .. tostring(path)
    end
  end)
  -- Always close, even if the inner pcall raised.
  pcall(function() f:close() end)
  if not ok then
    -- The pcall itself raised (shouldn't normally happen since the body
    -- is itself defensive); surface the pcall error message.
    return nil, "read_file body raised: " .. tostring(pcall_err)
  end
  if err_msg ~= nil then
    return nil, err_msg
  end
  return content, nil
end

--- Check whether a file exists (without reading contents).
--- Uses `os.rename` instead of `io.open` because the latter returns a
--- non-nil handle for directories on Linux, which would falsely report
--- directories as existing files.
--- @param path string
--- @return boolean
function M.exists(path)
  if path == nil or path == "" then return false end
  -- os.rename returns (true) on success, (nil, err) on failure. It works
  -- for both files and directories, returning false when the path does
  -- not exist (errno = ENOENT). It does NOT require opening the file.
  local ok, _err = os.rename(path, path)
  if ok then return true end
  -- Fallback: os.rename can fail on read-only filesystems, permission-
  -- restricted paths, or certain symlinks even when the path exists.
  -- Try io.open("rb") as a secondary check. On Linux, io.open succeeds
  -- for both files AND directories (directories can be opened for reading),
  -- so this fallback may report directories as existing — that's
  -- acceptable for the calltree use case (we only check existence, not
  -- whether it's a regular file). On Windows, io.open fails for dirs.
  -- Previously the comment said "fall back to io.open" but the code
  -- directly returned false — the fallback was never implemented.
  local f = io.open(path, "rb")
  if f then
    f:close()
    return true
  end
  return false
end

--- Get the current working directory. vim.fn.getcwd is unavailable
--- outside nvim; falls back to environment variables and shell commands.
---
--- Review 1.2.3 (Windows compat): the previous implementation only
--- consulted Unix-specific sources for the fallbacks:
---   * `os.getenv("PWD")` — Unix shell convention; Windows cmd.exe
---     doesn't set PWD, it sets `CD` instead.
---   * `io.popen("pwd 2>/dev/null")` — `pwd` is a Unix command; on
---     Windows the equivalent is `cmd /c cd` (which prints the current
---     directory without arguments).
--- The new implementation tries BOTH Unix and Windows env vars and
--- BOTH Unix and Windows shell commands, so `getcwd` works on either
--- platform when running outside Neovim (e.g. in the pure-Lua test
--- runner or a CLI script).
---
--- All fallback return values are stripped of trailing whitespace
--- (e.g. newlines from `pwd` / `cd` output, surrounding quotes from
--- Windows cmd.exe in some configurations).
---
--- Returns nil when no method succeeded — callers MUST handle nil by
--- skipping project-scope filtering (do NOT default to "/" which would
--- make `is_path_under` treat every absolute path as "in project").
--- @return string|nil
function M.getcwd()
  -- Internal helper: strip trailing whitespace (newlines, spaces, tabs)
  -- and surrounding double-quotes (Windows cmd.exe sometimes wraps the
  -- CD output in quotes when the path contains spaces).
  local function strip_trailing_ws(s)
    if s == nil then return nil end
    s = s:gsub("%s+$", "")
    -- Strip a matching pair of surrounding double-quotes (Windows).
    if s:sub(1, 1) == '"' and s:sub(-1) == '"' and #s >= 2 then
      s = s:sub(2, -2)
    end
    return s
  end

  if vim and vim.fn and vim.fn.getcwd then
    local ok, cwd = pcall(vim.fn.getcwd)
    if ok and cwd then
      cwd = strip_trailing_ws(cwd)
      if cwd ~= "" then return cwd end
    end
  end

  -- Fallback 1a: PWD environment variable (Unix shell convention).
  local pwd = os.getenv("PWD")
  if pwd and pwd ~= "" then
    pwd = strip_trailing_ws(pwd)
    if pwd ~= "" then return pwd end
  end
  -- Fallback 1b: CD environment variable (Windows cmd.exe convention).
  -- On Windows, cmd.exe sets CD to the current directory; on Unix this
  -- returns nil and is skipped.
  local cd_env = os.getenv("CD")
  if cd_env and cd_env ~= "" then
    cd_env = strip_trailing_ws(cd_env)
    if cd_env ~= "" then return cd_env end
  end

  -- Fallback 2a: io.popen pwd command (Unix; last resort; may fail in
  -- restricted environments). Wrapped in pcall to prevent popen from
  -- raising.
  local ok_p, h = pcall(io.popen, "pwd 2>/dev/null")
  if ok_p and h then
    local cwd = h:read("*l") or ""
    pcall(function() h:close() end)
    cwd = strip_trailing_ws(cwd)
    if cwd ~= "" then return cwd end
  end
  -- Fallback 2b: io.popen cmd /c cd command (Windows; last resort).
  -- `cd` with no arguments prints the current directory on Windows.
  -- The `2>NUL` redirect silences stderr (matches the Unix pattern).
  local ok_p2, h2 = pcall(io.popen, "cmd /c cd 2>NUL")
  if ok_p2 and h2 then
    local cwd = h2:read("*l") or ""
    pcall(function() h2:close() end)
    cwd = strip_trailing_ws(cwd)
    if cwd ~= "" then return cwd end
  end

  -- All fallbacks failed: return nil. Callers should treat nil as
  -- "cwd unknown" and skip project-scope filtering rather than assume
  -- the filesystem root (which would make is_path_under accept any
  -- absolute path).
  return nil
end

-- Validate this module against the IFileSystem interface contract
-- (development-time self-check).
local interfaces = require("calltree.core.interfaces")
interfaces.assert_interface(M, "IFileSystem", false)

return M
