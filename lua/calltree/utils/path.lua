--- path.lua — path/URI conversion utilities.
--- Pure Lua, no Neovim dependencies.

local M = {}

-- Length of the "file://" URI scheme prefix. Centralized as a constant so
-- the encode/decode functions share a single source of truth (was a magic
-- `7` and `8` scattered across both functions).
local FILE_URI_PREFIX = "file://"
local FILE_URI_PREFIX_LEN = #FILE_URI_PREFIX  -- 7

--- Convert a file path to a file:// URI.
---
--- Review 4.8: only normalize Windows backslashes on platforms where
--- backslash is NOT a valid filename character (i.e. Windows). On Unix,
--- backslash is a legal filename char and silently replacing it with "/"
--- would change the path semantics (e.g. a file literally named
--- `foo\bar.lua` would be mis-mapped to `foo/bar.lua`). We detect
--- Windows by checking for a drive-letter prefix or UNC prefix in the
--- path; otherwise the path is treated as Unix and backslashes are
--- preserved (percent-encoded as %5C, which is the correct encoding for
--- a literal backslash in a URI).
---
--- Review 1.2.3 (Windows compat): the previous implementation encoded
--- the colon in Windows drive-letter paths (`C:` → `C%3A`), producing
--- non-standard URIs like `file://C%3A/Users/foo`. Neovim's LSP client
--- and most other LSP clients follow RFC 8089, which prescribes the
--- form `file:///C:/Users/foo` (empty authority + absolute path starting
--- with the drive letter, colon UNencoded). The new implementation
--- produces RFC 8089-conformant URIs for both drive-letter and UNC
--- paths:
---
---   * `C:\Users\foo`        → `file:///C:/Users/foo`   (drive-letter)
---   * `\\server\share\foo`  → `file://server/share/foo` (UNC: server is authority)
---   * `/unix/path`          → `file:///unix/path`       (Unix absolute)
---   * `relative/path`       → `file://relative/path`    (relative — informational)
---
--- The percent-encoding covers all bytes outside `[A-Za-z0-9/._~-]`
--- (RFC 3986 unreserved set plus `/`). For Windows drive-letter paths
--- the colon `:` is added to the unreserved set so the drive letter
--- survives the round-trip without percent-encoding.
---
--- @param path string
--- @return string|nil uri (nil only if `path` is nil; otherwise always a string)
function M.path_to_uri(path)
  if path == nil then return nil end
  if path:sub(1, FILE_URI_PREFIX_LEN) == FILE_URI_PREFIX then return path end

  -- Windows UNC path: `\\server\share\...` or `//server/share/...`
  -- Per RFC 8089, the server name becomes the URI authority, so the
  -- output is `file://server/share/...` (two slashes after `file:`).
  if path:sub(1, 2) == "\\\\" or path:sub(1, 2) == "//" then
    -- Normalize backslashes to forward slashes, then strip the leading `//`
    -- (the `file://` prefix already provides the authority-marker slashes).
    local normalized = path:gsub("\\", "/")
    local stripped = normalized:sub(3)
    local encoded = stripped:gsub("([^%w/%._~-])", function(c)
      return string.format("%%%02X", string.byte(c))
    end)
    return FILE_URI_PREFIX .. encoded
  end

  -- Windows drive-letter path: `C:\...` or `C:/...`
  -- Per RFC 8089, the standard form is `file:///C:/...` (empty authority
  -- + absolute path). The colon in the drive letter must NOT be
  -- percent-encoded — LSP clients (Neovim, VS Code) expect the literal
  -- `C:` form. We add `:` to the unreserved set for this branch.
  if path:match("^%a:[/\\]") then
    path = path:gsub("\\", "/")
    local encoded = path:gsub("([^%w/%._~:-])", function(c)
      return string.format("%%%02X", string.byte(c))
    end)
    -- Prepend a `/` so the URI has the form `file:///C:/...`
    -- (empty authority marker before the absolute path).
    return FILE_URI_PREFIX .. "/" .. encoded
  end

  -- Unix absolute path or relative path — backslashes are legal
  -- filename characters on Unix and must be preserved (percent-encoded
  -- as %5C, which is the correct encoding for a literal backslash).
  local encoded = path:gsub("([^%w/%._~-])", function(c)
    return string.format("%%%02X", string.byte(c))
  end)
  return FILE_URI_PREFIX .. encoded
end

--- Convert a file:// URI back to a filesystem path.
---
--- Returns the input unchanged if it doesn't start with `file://` (this
--- allows callers to pass either a URI or a bare path without crashing,
--- though they should be aware that a non-URI string is returned as-is
--- rather than flagged as an error).
---
--- `%2F` / `%2f` (encoded slash) is preserved as-is rather than decoded
--- to a literal `/`, because decoding it would change the path segment
--- count (per RFC 8089, `%2F` represents a `/` character within a path
--- segment, not a path separator).
---
--- Invalid `%XX` sequences (where XX is not a hex pair, e.g. `%GG`) are
--- also preserved as-is to avoid `string.char(nil)` raising.
---
--- Review 1.2.3 (Windows compat): added detection of the three URI
--- shapes produced by `path_to_uri` so the round-trip returns the
--- original filesystem path form:
---   * `file://server/share/...` (UNC) → `//server/share/...`
---   * `file:///C:/...`              (drive) → `C:/...`
---   * `file:///unix/path`           (Unix)  → `/unix/path`
--- For maximum compatibility with existing callers, the UNC round-trip
--- returns the forward-slash form `//server/share/...` (Windows APIs
--- accept both `\\` and `//` for UNC paths).
---
--- @param uri string
--- @return string|nil path
function M.uri_to_path(uri)
  if uri == nil then return nil end
  if uri:sub(1, FILE_URI_PREFIX_LEN) ~= FILE_URI_PREFIX then return uri end
  local rest = uri:sub(FILE_URI_PREFIX_LEN + 1)  -- everything after `file://`

  -- Percent-decode helper (preserves %2F as-is per RFC 8089).
  local function decode(s)
    return (s:gsub("%%(%x%x)", function(hex)
      local lower = hex:lower()
      if lower == "2f" then return "%" .. hex end
      local code = tonumber(hex, 16)
      if code == nil then return "%" .. hex end  -- non-hex chars, preserve
      return string.char(code)
    end))
  end

  -- Case A: `file://server/share/...` — UNC. `rest` starts with the
  -- server name (no leading `/`). Reconstruct the `//server/share/...`
  -- form. We detect this by checking that `rest` does NOT start with `/`
  -- and does NOT match the Windows drive-letter shape `C:/...` (which
  -- would indicate a URI that lost its leading slash — be defensive).
  if rest:sub(1, 1) ~= "/" then
    if rest:match("^%a:/") then
      -- Defensive: should not happen with the new `path_to_uri`, but
      -- accept it as a drive-letter path (strip nothing).
      return decode(rest)
    end
    -- UNC: prepend `//` to mark the authority form.
    return "//" .. decode(rest)
  end

  -- Case B: `rest` starts with `/`. Standard forms are `/unix/path`
  -- (Unix absolute) or `/C:/path` (Windows drive-letter with the
  -- RFC 8089 empty-authority marker). For the drive-letter form, strip
  -- the leading `/` so the round-trip returns `C:/path` (matching the
  -- original input shape).
  local decoded = decode(rest)
  if decoded:match("^/%a:/") then
    -- `file:///C:/foo` → `/C:/foo` → strip leading `/` → `C:/foo`
    return decoded:sub(2)
  end
  return decoded
end

-- Normalize a path by collapsing `.` and `..` segments WITHOUT touching
-- the filesystem (no symlink resolution — that would require `lfs` or
-- `os.execute` and break the "pure Lua" invariant). Symlinks therefore
-- remain opaque; if two paths refer to the same inode via different
-- symlinks, `is_path_under` may return false for what is logically the
-- same directory. For the analyzer's use case (deciding whether a
-- definition file is "in the project"), this is acceptable — the user's
-- `cwd` is the source of truth, not the underlying inode.
--
-- Windows UNC paths (`\\server\share\foo` or `//server/share/foo`)
-- preserve their `\\` or `//` prefix instead of being mis-assembled as
-- `server/share/foo`.
local function normalize_path_segments(path)
  if path == nil then return nil end
  -- Detect the leading prefix (root) BEFORE splitting so we can strip it
  -- from the segment list and avoid duplicating the drive letter.
  -- Previously `gmatch("[^/\\]+")` captured `C:` as the first segment AND
  -- the lead detection captured `C:\`, producing `C:\C:/foo/bar.lua`
  -- (drive letter duplicated). Now we strip the drive prefix from the
  -- path before splitting so `C:` is never captured as a segment.
  local lead = ""
  local rest = path
  if path:sub(1, 2) == "\\\\" then
    -- Windows UNC: \\server\share -> preserve \\ prefix
    lead = "\\\\"
    rest = path:sub(3)
  elseif path:sub(1, 2) == "//" then
    -- Windows UNC (forward-slash form): //server/share -> preserve // prefix
    lead = "//"
    rest = path:sub(3)
  elseif path:sub(1, 1) == "/" then
    lead = "/"
    rest = path:sub(2)
  elseif path:match("^%a:[/\\]") then
    -- Windows drive: C:\... or C:/... -> preserve "C:\" (or "C:/")
    lead = path:sub(1, 3)
    rest = path:sub(4)
  end
  -- Split the remaining path on / and \.
  local parts = {}
  for seg in rest:gmatch("[^/\\]+") do
    if seg == "." then
      -- skip
    elseif seg == ".." then
      -- Pop the last segment (if any). If there's nothing to pop, keep
      -- the ".." so a relative path like "../sibling" stays recognizable.
      if #parts > 0 and parts[#parts] ~= ".." then
        table.remove(parts)
      else
        table.insert(parts, "..")
      end
    else
      table.insert(parts, seg)
    end
  end
  if #parts == 0 then
    -- Path was just "/" or "C:\" — preserve the root.
    return lead ~= "" and lead or "."
  end
  -- Review 4.9: choose the separator based on the lead prefix. For UNC
  -- paths (lead = "\\\\" or "//"), use the same separator as the lead to
  -- avoid mixed-separator output like "\\\\server/share/dir". For
  -- Windows drive-letter paths (lead = "C:\"), use backslash. For Unix
  -- paths, use forward slash.
  local sep = "/"
  if lead:match("\\\\") or lead:match("^%a:[\\\\]$") then
    sep = "\\"
  end
  return lead .. table.concat(parts, sep)
end
M.normalize_path_segments = normalize_path_segments

--- Strip trailing path separators from a directory path. Preserves the root
--- separator on Unix ("/" stays "/") and the root+drive on Windows
--- ("C:\" stays "C:\"). This is the canonical implementation —
--- `module_finder.lua` and `fs.lua` delegate to it instead of maintaining
--- their own copies (which previously drifted in behavior).
--- @param path string|nil
--- @return string|nil
function M.strip_trailing_sep(path)
  if path == nil then return nil end
  while #path > 1 do
    local last = path:sub(-1)
    if last == "/" or last == "\\" then
      -- On Windows, don't strip past "C:\" — stop if the second-to-last
      -- char is ":" (e.g. "C:\" → keep).
      -- (Removed the dead `if #path == 1 then break end` — the loop
      -- condition `#path > 1` already guarantees #path >= 2 here, so
      -- that branch was unreachable.)
      if #path >= 3 and path:sub(-2, -2) == ":" then break end
      path = path:sub(1, -2)
    else
      break
    end
  end
  return path
end

--- Check if `child_path` is under `parent_dir` (prefix match on path segments).
---
--- Both paths are normalized (collapse `.` and `..` segments) before
--- comparison, so `/project/foo/../bar` and `/project/bar` are recognized
--- as equivalent. Trailing separators on EITHER side are tolerated
--- (previously only `parent_dir` was normalized — `child_path = "/project"`
--- would NOT match `parent_dir = "/project/"`, which was a subtle bug).
---
--- Symlink resolution is NOT performed (see `normalize_path_segments`
--- above for why).
---
--- Review 1.2.3 (Windows compat): the previous implementation only
--- compared the raw normalized forms, which could differ in separator
--- choice (e.g. `C:\project\foo.lua` normalized to backslash form vs
--- `C:/project` normalized to forward-slash form). The new implementation
--- normalizes both child and parent to forward slashes before the prefix
--- comparison, so mixed-separator Windows paths compare correctly. We
--- also recognize Windows drive roots (`C:\`, `C:/`) as universal parents
--- for any path on the same drive (analogous to the Unix `/` root).
---
--- @param child_path string
--- @param parent_dir string
--- @return boolean
function M.is_path_under(child_path, parent_dir)
  if child_path == nil or parent_dir == nil then return false end
  -- Normalize both sides: strip trailing separators, collapse . and ...
  -- Reuse the module-level M.strip_trailing_sep(M.normalize_path_segments(p))
  -- instead of the previous inline `norm` closure that duplicated the
  -- strip-trailing-sep logic (which could drift out of sync with the
  -- canonical implementation above).
  local function norm(p)
    return M.strip_trailing_sep(M.normalize_path_segments(p) or p)
  end
  local parent = norm(parent_dir)
  local child  = norm(child_path)
  if child == parent then return true end

  -- Review 4.7: when parent_dir is the filesystem root ("/"), the previous
  -- `child:sub(1, #parent + 1) == parent .. "/"` produced `parent .. "/"`
  -- = "//", which never matches a child path like "/foo" ("/foo" doesn't
  -- start with "//"). Special-case the root: every absolute path is under
  -- "/" by definition.
  if parent == "/" or parent == "\\" then
    -- Every absolute path is under the root. (For Windows drive roots
    -- like "C:\", the parent comparison already short-circuits via the
    -- `child == parent` check above; this branch handles the Unix root
    -- and the bare-backslash Windows root.)
    return true
  end

  -- Review 1.2.3: Windows drive root (`C:\` or `C:/`) is the universal
  -- parent for every absolute path on that drive. The previous code only
  -- treated bare `/` and `\` as universal roots, missing the drive-letter
  -- form — so `C:\Users` was NOT recognized as under `C:\`.
  local parent_drive = parent:match("^(%a):[/\\]$")
  if parent_drive then
    local child_drive = child:match("^(%a):[/\\]")
    if child_drive and child_drive:lower() == parent_drive:lower() then
      return true
    end
    -- If the child doesn't start with the same drive letter, it's not
    -- under this drive root (e.g. `D:\foo` is not under `C:\`).
    return false
  end

  -- Review 1.2.3: normalize both child and parent to forward slashes
  -- BEFORE the prefix comparison. The previous implementation compared
  -- the raw normalized forms, which could differ in separator choice
  -- (backslash vs forward slash) for Windows paths — causing
  -- `C:\project\foo.lua` to NOT match `C:/project` even though they
  -- refer to the same directory.
  local child_fwd  = (child:gsub("\\", "/"))
  local parent_fwd = (parent:gsub("\\", "/"))
  if parent_fwd == "/" then
    return true
  end
  -- Prefix match with a path-segment boundary so "/home/user" does NOT
  -- match "/home/user2" — append "/" to the parent and compare prefix.
  if child_fwd:sub(1, #parent_fwd + 1) == parent_fwd .. "/" then
    return true
  end
  return false
end

return M
