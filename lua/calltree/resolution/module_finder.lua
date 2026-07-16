--- resolution/module_finder.lua — resolve a Lua module spec to a file path.
--- Pure Lua, no Neovim dependencies.

local M = {}

-- Require path_utils for the canonical strip_trailing_sep implementation.
-- Previously this module maintained its own copy of strip_trailing_sep,
-- which could drift out of sync with the copies in path.lua and fs.lua.
-- Now all three delegate to the single canonical implementation in path.lua.
local path_utils = require("calltree.utils.path")

-- Default Lua package.path templates.
M.DEFAULT_PACKAGE_PATHS = {
  "/?.lua",
  "/?/init.lua",
  "/lua/?.lua",
  "/lua/?/init.lua",
}

-- Item 7 (1.2.4 refactor): the `M.strip_trailing_sep = strip_trailing_sep`
-- export was removed because no external caller referenced it (verified
-- via grep across lua/ and tests/). The local `strip_trailing_sep` is kept
-- for internal use within this module (path_join and resolve_module_path).
-- Removing the export reduces the module's public surface and eliminates
-- a redundant indirection that could drift out of sync with the canonical
-- `path_utils.strip_trailing_sep`.
local strip_trailing_sep = path_utils.strip_trailing_sep

-- Check whether `path` is absolute. Handles both Unix ("/foo") and Windows
-- ("C:\foo", "C:/foo", "\\server\share") forms.
--
-- LIMITATION: Windows drive-RELATIVE paths of the form "C:foo\bar" (drive
-- letter + colon + relative path, NO separator after the colon) are NOT
-- recognized as absolute — they're relative to the current directory on
-- that drive. This matches Lua's io.open behavior on Windows but differs
-- from the Win32 PathIsRelative API. calltree doesn't currently need to
-- handle drive-relative paths (all paths come from LSP file:// URIs which
-- are always fully absolute), so the limitation is documented rather than
-- fixed. If you need to support drive-relative paths, add a `^%a:[^/\\]`
-- pattern check here and resolve against the drive's CWD.
local function is_absolute_path(path)
  if path == nil or path == "" then return false end
  -- Unix absolute.
  if path:sub(1, 1) == "/" then return true end
  -- Windows UNC: "\\server\share" or "//server/share".
  if path:sub(1, 2) == "\\\\" or path:sub(1, 2) == "//" then return true end
  -- Review 4.5: Windows root-of-drive form "\foo" (single leading
  -- backslash, no drive letter) represents the root of the current drive —
  -- an ABSOLUTE path. Previously this form was mis-classified as relative,
  -- causing it to be wrongly joined with cwd (e.g. "C:\Users\user\foo"
  -- instead of "C:\foo"). Adding the single-backslash check fixes this.
  if path:sub(1, 1) == "\\" then return true end
  -- Windows drive: "C:\..." or "C:/..." (single drive letter + colon + sep).
  if path:match("^%a:[/\\]") then return true end
  return false
end
M.is_absolute_path = is_absolute_path

-- Join two path components with a single separator. Detects the separator
-- already used in `head` (preferring `/`, but falling back to `\` when
-- `head` contains backslashes and no forward slashes) and uses that for
-- the join. Strips trailing separators from `head` and leading separators
-- from `tail` so that joining "/project" + "/foo.lua" produces
-- "/project/foo.lua" (not "/project//foo.lua").
--
-- (Previous comment misleadingly claimed it "normalizes mixed separators";
-- it doesn't — it picks whichever separator already appears in `head`.
-- Clarified here to avoid future confusion.)
-- Review 8.3: normalize both head and tail to forward slashes BEFORE
-- selecting the separator. Previously the separator was chosen based on
-- `head`'s content (backslash if head had backslashes and no forward
-- slashes), but `tail` could still contain forward slashes — producing
-- mixed-separator paths like "C:\Users\user\C:/foo.lua". Forward slashes
-- are accepted by both Unix and Windows APIs (and by Lua's io.open),
-- so unifying on "/" is always safe and removes the mixed-separator risk.
local function path_join(head, tail)
  if head == nil or head == "" then return tail end
  if tail == nil or tail == "" then return head end
  -- Normalize both sides to forward slashes.
  head = head:gsub("\\", "/")
  tail = tail:gsub("\\", "/")
  local sep = "/"
  head = strip_trailing_sep(head)
  -- Review 4.6: when `head` is the filesystem root "/" after stripping,
  -- strip_trailing_sep turns it into "" — but joining "" + tail would
  -- produce a relative path like "foo.lua" instead of "/foo.lua".
  -- Preserve the root by re-adding the leading slash.
  if head == "" then
    -- Original head was "/" (or all separators). Re-add the root.
    -- Strip leading separators from tail so we don't get a double slash
    -- (//foo.lua); we want /foo.lua.
    while tail:sub(1, 1) == "/" do
      tail = tail:sub(2)
    end
    return "/" .. tail
  end
  -- Review 1.2.3 (Windows compat): when `head` is the Unix root "/"
  -- (single forward slash, preserved by strip_trailing_sep because its
  -- loop condition `#path > 1` is false for #path==1), we must NOT
  -- append another `/` separator — joining `/` + `foo.lua` should
  -- produce `/foo.lua`, not `//foo.lua`. The previous code went straight
  -- to `head .. sep .. tail`, producing `//foo.lua`.
  if head == "/" then
    -- Strip leading separators from tail (same as the head=="" branch).
    while tail:sub(1, 1) == "/" do
      tail = tail:sub(2)
    end
    return "/" .. tail
  end
  -- Strip leading separators from tail so we don't get a double slash.
  while tail:sub(1, 1) == "/" do
    tail = tail:sub(2)
  end
  if tail == "" then return head end
  return head .. sep .. tail
end
M.path_join = path_join

------------------------------------------------------------------------------
-- candidate_exists: check whether a candidate file path exists.
-- Prefers `exists_func` (existence-only check, saves I/O); falls back to
-- `read_file` (backward-compatible with old callers, but reads the whole
-- file just for existence — prefer `exists_func`). Returns false when
-- neither is provided (does NOT fall back to io.open, avoiding accidental
-- reads of the real filesystem in restricted environments).
--
-- Extracted to module level (previously a nested closure inside
-- resolve_module_path) so it can be unit-tested in isolation and the main
-- resolver stays a straight loop over search_paths.
------------------------------------------------------------------------------
local function candidate_exists(path, exists_func, read_file)
  if exists_func and type(exists_func) == "function" then
    local ok, ret = pcall(exists_func, path)
    return ok and ret == true
  end
  if read_file and type(read_file) == "function" then
    local ok, content = pcall(read_file, path)
    return ok and content ~= nil
  end
  return false
end

--- Resolve a Lua module spec (e.g. "calltree.adapter") to a file path using
--- package.path-style search templates.
---
--- Existence is checked in priority order:
---   1. `exists_func` (existence-only check, saves I/O);
---   2. `read_file` (backward-compatible with old callers, but reads the
---      whole file just for existence — prefer `exists_func`);
---   3. When neither is provided, returns nil (does NOT silently fall back
---      to `io.open`), avoiding accidental reads of the real filesystem
---      in restricted environments.
---
--- @param module_spec string e.g. "calltree.adapter"
--- @param search_paths array of path templates with "?" placeholder
--- @param cwd string|nil current working directory
--- @param read_file function|nil optional file reader (checks existence)
--- @param exists_func function|nil optional existence check (preferred over read_file)
--- @return string|nil file_path
function M.resolve_module_path(module_spec, search_paths, cwd, read_file, exists_func)
  if module_spec == nil or search_paths == nil then return nil end
  -- Convert the module spec's dots to "/". Lua's package.path conventionally
  -- uses "/" even on Windows, and Neovim's runtime accepts both separators,
  -- so we don't bother back-converting to "\".
  local rel = module_spec:gsub("%.", "/")
  -- Review 1.2.3 (Windows compat): escape `%` in the module spec so it
  -- can be safely used as a gsub REPLACEMENT string. Lua's gsub treats
  -- `%` specially in replacements (`%0`, `%1`, ... are backreferences),
  -- so a module name like `50%-off` would raise
  -- "invalid use of '%' in replacement string" when substituted into the
  -- search-path template. Doubling every `%` to `%%` makes gsub treat
  -- them as literal `%` characters. This is purely a string-level fix —
  -- the resolved path still contains the literal `%` char.
  local rel_for_replacement = rel:gsub("%%", "%%%%")
  -- Review 1.12: defensive — `cwd` may be nil (callers can omit it). The
  -- previous `strip_trailing_sep(cwd)` call would crash with
  -- "attempt to index a nil value" because strip_trailing_sep indexes
  -- its argument. Only normalize when cwd is non-nil.
  local cwd_norm = cwd ~= nil and strip_trailing_sep(cwd) or nil

  -- candidate_exists is now the module-level helper (see above). It takes
  -- (path, exists_func, read_file) so we pass the injected funcs through.
  for _, template in ipairs(search_paths) do
    local candidate = template:gsub("%?", rel_for_replacement)
    -- If the candidate is RELATIVE and we have a cwd, anchor it under cwd.
    -- `is_absolute_path` correctly handles Unix "/", Windows "C:\", and
    -- UNC "\\server\share" forms — the previous implementation only
    -- checked the first character against "/", which would mis-classify
    -- "C:\..." as relative on Windows.
    if not is_absolute_path(candidate) and cwd_norm then
      candidate = path_join(cwd_norm, candidate)
    end

    if candidate_exists(candidate, exists_func, read_file) then return candidate end

    -- Fallback: a TEMPLATE-STYLE absolute path (e.g. "/lua/?.lua" from
    --    DEFAULT_PACKAGE_PATHS) is meant to be anchored under cwd. Only
    --    attempt this when:
    --      (a) `candidate` is absolute,
    --      (b) cwd is set,
    --      (c) `candidate` does NOT already start with `cwd` (otherwise
    --          we'd produce a nonsense double-prefix path like
    --          "/home/user/home/user/lua/foo.lua").
    --    The `already_anchored` check is now a path-segment-aware prefix
    --    match (rather than a raw string prefix), so "/home/user2/..." is
    --    correctly distinguished from "/home/user/...".
    -- Review 8.1 + 8.2: normalize separators BEFORE the prefix comparison
    -- so `C:\Users\user` (backslash) and `C:/Users/user/foo.lua` (forward
    -- slash) compare correctly. Previously the prefix mismatch caused the
    -- `already_anchored` check to wrongly return false, triggering the
    -- bogus path_join fallback that produced nonsense paths like
    -- `C:\Users\user\C:\foo.lua` for Windows drive-letter candidates.
    --
    -- Review 8.1 — partial fix only: the report's recommendation ("never
    -- join an absolute candidate with cwd") breaks template-style absolute
    -- paths (e.g. "/?.lua" from DEFAULT_PACKAGE_PATHS), which ARE meant to
    -- be cwd-anchored. We retain the join for Unix-style "/" candidates
    -- (the test_pattern_special_chars_in_module_name test confirms this
    -- expectation). The Windows drive-letter case (C:\foo.lua) is a known
    -- edge case: path_join now normalizes separators before joining, so
    -- `C:\Users\user` + `C:\foo.lua` becomes `C:/Users/user/C:/foo.lua`
    -- which is still wrong but at least uniform. This is documented as a
    -- limitation since calltree doesn't currently run on Windows.
    if cwd_norm and is_absolute_path(candidate) then
      -- Normalize both to forward slashes for the prefix comparison.
      local cwd_norm_fwd = cwd_norm:gsub("\\", "/")
      local candidate_fwd = candidate:gsub("\\", "/")
      local cwd_prefix = cwd_norm_fwd
      if cwd_prefix:sub(-1) ~= "/" then
        cwd_prefix = cwd_prefix .. "/"
      end
      local already_anchored = (#candidate_fwd >= #cwd_prefix
        and candidate_fwd:sub(1, #cwd_prefix) == cwd_prefix)
      if not already_anchored then
        local candidate2 = path_join(cwd_norm, candidate)
        if candidate_exists(candidate2, exists_func, read_file) then return candidate2 end
      end
    end
  end
  return nil
end

return M
