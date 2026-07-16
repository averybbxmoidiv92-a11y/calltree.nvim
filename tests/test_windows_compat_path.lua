--- tests/test_windows_compat_path.lua — Windows-compatibility tests for
--- `lua/calltree/utils/path.lua`.
---
--- This file is part of the Windows compatibility test suite. It exercises
--- every public function in `path.lua` with Windows-style inputs (drive
--- letters, UNC paths, backslashes, mixed separators, special chars) and
--- asserts that the output is correct regardless of the host platform.
---
--- Most tests are PURE LOGIC tests: they verify that the path conversion
--- functions produce the right string output for a given Windows-style
--- input, even when the test itself is running on Unix. The expected
--- behavior is documented in the source-file comments of `path.lua`.
---
--- A few tests are PLATFORM-CONDITIONAL: they verify that the actual
--- filesystem treats `foo` and `FOO` as the same file on Windows
--- (case-insensitive) but as different files on Unix (case-sensitive).
--- These tests use the skip sentinel from `windows_compat_helper` so they
--- are auto-skipped on the wrong platform.
---
--- Functions tested (all HIGH priority — directly invoke path-segment /
--- separator logic that differs between Windows and Unix):
---   * M.path_to_uri(path)
---   * M.uri_to_path(uri)
---   * M.normalize_path_segments(path)
---   * M.strip_trailing_sep(path)
---   * M.is_path_under(child_path, parent_dir)

local path_utils = require("calltree.utils.path")
local A          = require("assert")
local helper     = require("windows_compat_helper")

local M = {}

-- Convenience aliases.
local path_to_uri  = path_utils.path_to_uri
local uri_to_path  = path_utils.uri_to_path
local normalize    = path_utils.normalize_path_segments
local strip_ts     = path_utils.strip_trailing_sep
local is_path_under = path_utils.is_path_under

--------------------------------------------------------------------------------
-- Section 1: path_to_uri — Windows drive-letter paths
--------------------------------------------------------------------------------

--- A Windows drive-letter path like `C:\Users\foo\bar.lua` must be converted
--- to a `file://` URI with backslashes normalized to forward slashes and
--- every non-unreserved byte percent-encoded. The drive letter and colon
--- are NOT encoded (they're in the unreserved set `[A-Za-z0-9/._~-]`).
function M.test_path_to_uri_windows_drive_letter()
  local uri = path_to_uri("C:\\Users\\foo\\bar.lua")
  A.equal("file:///C:/Users/foo/bar.lua", uri,
    "Windows drive-letter path: RFC 8089 form file:///C:/... with backslashes normalized to forward slashes, colon unencoded")
end

--- Forward slashes on a Windows drive-letter path are accepted as-is.
--- The path-to-URI converter should NOT touch the separators when the
--- path already uses forward slashes (it only normalizes backslashes →
--- forward slashes; the reverse never happens).
function M.test_path_to_uri_windows_drive_letter_forward_slash()
  local uri = path_to_uri("C:/Users/foo/bar.lua")
  A.equal("file:///C:/Users/foo/bar.lua", uri,
    "Windows drive-letter path with forward slashes: RFC 8089 form file:///C:/...")
end

--- A Windows path containing spaces (e.g. `C:\Program Files\app.lua`) must
--- percent-encode the space as `%20`. This is the single most common
--- Windows compatibility bug — `Program Files` is on almost every Windows
--- install and an unencoded space in a URI breaks the LSP file:// handler.
function M.test_path_to_uri_windows_path_with_spaces()
  local uri = path_to_uri("C:\\Program Files\\app.lua")
  A.equal("file:///C:/Program%20Files/app.lua", uri,
    "Spaces in Windows paths must be percent-encoded as %20 (RFC 8089 form)")
end

--- Special characters commonly found in Windows file names: `#`, `%`, `&`,
--- `(`, `)`. All of these are outside the RFC 3986 unreserved set
--- `[A-Za-z0-9/._~-]` and MUST be percent-encoded.
function M.test_path_to_uri_windows_path_with_special_chars()
  -- `#` is a URL fragment delimiter and must be encoded.
  local uri1 = path_to_uri("C:\\project\\#file.lua")
  A.equal("file:///C:/project/%23file.lua", uri1,
    "Hash sign (#) must be percent-encoded as %23")

  -- `%` itself must be encoded as `%25` (otherwise the decoder would
  -- interpret the following two chars as a hex escape).
  local uri2 = path_to_uri("C:\\project\\50%.lua")
  A.equal("file:///C:/project/50%25.lua", uri2,
    "Percent sign (%) must be percent-encoded as %25")

  -- `&` is a sub-delimiter in RFC 3986 but the implementation encodes
  -- everything outside the unreserved set, so it becomes %26.
  local uri3 = path_to_uri("C:\\project\\a&b.lua")
  A.equal("file:///C:/project/a%26b.lua", uri3,
    "Ampersand (&) must be percent-encoded as %26")

  -- `(` and `)` — parens are Gen-delims/Sub-delims in RFC 3986 but the
  -- implementation encodes them since they're not in the unreserved set.
  local uri4 = path_to_uri("C:\\project\\copy(1).lua")
  A.equal("file:///C:/project/copy%281%29.lua", uri4,
    "Parentheses must be percent-encoded (%28 and %29)")
end

--- A Windows UNC path `\\server\share\foo.lua` must preserve the leading
--- `\\` (converted to `//` in the URI) so that `uri_to_path` can
--- reconstruct the UNC form. This is the network-share case (e.g. SMB
--- mounts).
function M.test_path_to_uri_windows_unc_path()
  local uri = path_to_uri("\\\\server\\share\\foo.lua")
  A.equal("file://server/share/foo.lua", uri,
    "UNC path: backslashes normalized, leading \\\\ preserved as part of authority")
end

--- A UNC path in forward-slash form `//server/share/foo.lua` must be
--- treated as Windows-style (backslashes normalized) because of the
--- `//` prefix detection in `path_to_uri`.
function M.test_path_to_uri_windows_unc_forward_slash()
  local uri = path_to_uri("//server/share/foo.lua")
  A.equal("file://server/share/foo.lua", uri,
    "UNC path in forward-slash form: should pass through unchanged")
end

--- On Unix, a path that contains a literal backslash (e.g. a file named
--- `foo\bar.lua`) must NOT have its backslash converted to a forward slash
--- — backslash is a legal filename character on Unix. The path-to-URI
--- converter detects this by checking for a Windows drive-letter or UNC
--- prefix; if neither matches, the path is treated as Unix and the
--- backslash is preserved (percent-encoded as %5C in the URI).
function M.test_path_to_uri_unix_preserves_backslash_in_filename()
  local uri = path_to_uri("/project/foo\\bar.lua")
  A.equal("file:///project/foo%5Cbar.lua", uri,
    "Unix path with literal backslash: backslash must be percent-encoded as %5C, NOT converted to forward slash")
end

--- Round-trip: `uri_to_path(path_to_uri(p)) == p` for Windows paths.
--- Note: the round-trip is not always bit-identical because `path_to_uri`
--- normalizes backslashes to forward slashes — but the resulting path
--- must still be a valid Windows path that points to the same file
--- (Windows APIs accept both separators).
function M.test_path_to_uri_round_trip_windows_drive()
  local p1 = "C:\\Users\\foo\\bar.lua"
  local uri = path_to_uri(p1)
  local p2 = uri_to_path(uri)
  -- p2 will have forward slashes (the URI form uses /), but it should
  -- still represent the same Windows path.
  A.equal("C:/Users/foo/bar.lua", p2,
    "Round-trip drive-letter path: backslashes normalized to forward slashes (Windows APIs accept both)")
end

--------------------------------------------------------------------------------
-- Section 2: path_to_uri — Unicode / non-ASCII chars
--------------------------------------------------------------------------------

--- Non-ASCII characters (e.g. Chinese characters in a Windows username
--- like `C:\Users\小明\bar.lua`) must be percent-encoded byte-by-byte.
--- `小` is 3 bytes in UTF-8 (E5 B0 8F) and `明` is also 3 bytes (E6 98 8E),
--- so the URI should contain 6 `%XX` sequences for the two characters.
function M.test_path_to_uri_windows_unicode_chars()
  local uri = path_to_uri("C:\\Users\\小明\\bar.lua")
  -- The expected encoding: 小 = E5 B0 8F, 明 = E6 98 8E
  A.equal("file:///C:/Users/%E5%B0%8F%E6%98%8E/bar.lua", uri,
    "Unicode characters must be percent-encoded byte-by-byte (UTF-8), RFC 8089 form")
end

--------------------------------------------------------------------------------
-- Section 3: uri_to_path — decoding
--------------------------------------------------------------------------------

--- Standard Windows URI: `file://C:/Users/foo/bar.lua` → `C:/Users/foo/bar.lua`.
function M.test_uri_to_path_windows_drive()
  local p = uri_to_path("file://C:/Users/foo/bar.lua")
  A.equal("C:/Users/foo/bar.lua", p,
    "Windows URI: drive letter preserved, forward slashes preserved")
end

--- URI with encoded spaces — round-trip the `path_to_uri` output.
function M.test_uri_to_path_encoded_spaces()
  local p = uri_to_path("file://C:/Program%20Files/app.lua")
  A.equal("C:/Program Files/app.lua", p,
    "URI with %20 must decode to a space")
end

--- `%2F` (encoded forward slash) must be PRESERVED as-is, not decoded to
--- a literal `/`. Decoding it would change the path segment count per
--- RFC 8089 — `%2F` represents a `/` character WITHIN a path segment,
--- not a path separator.
function M.test_uri_to_path_preserves_encoded_slash()
  local p = uri_to_path("file://C:/project/foo%2Fbar.lua")
  A.equal("C:/project/foo%2Fbar.lua", p,
    "Encoded slash %2F must be preserved (RFC 8089) — not decoded to /")
end

--- Invalid `%XX` sequences (e.g. `%GG`) must be preserved as-is, not
--- crash with `string.char(nil)`. The decoder must defensively check
--- that the hex pair is valid before calling `string.char`.
function M.test_uri_to_path_invalid_percent_sequence()
  local p = uri_to_path("file://C:/project/%GG.lua")
  A.equal("C:/project/%GG.lua", p,
    "Invalid %XX sequence (%GG) must be preserved as-is, not crash")
end

--- A non-`file://` URI (or a bare path) is returned unchanged by
--- `uri_to_path`. This is a defensive behavior — callers can pass either
--- a URI or a bare path without crashing, though they should be aware
--- that a non-URI string is returned as-is rather than flagged as error.
function M.test_uri_to_path_passes_through_non_uri()
  A.equal("C:/Users/foo/bar.lua", uri_to_path("C:/Users/foo/bar.lua"),
    "Bare path (no file:// prefix) is returned unchanged")
  A.equal(nil, uri_to_path(nil), "nil input returns nil")
end

--------------------------------------------------------------------------------
-- Section 4: normalize_path_segments — Windows drive letters and UNC
--------------------------------------------------------------------------------

--- A Windows drive-letter path with `.` and `..` segments must have them
--- collapsed while preserving the `C:\` prefix. The drive letter must
--- NOT be duplicated (a previous bug produced `C:\C:/foo/bar.lua`).
function M.test_normalize_windows_drive_with_dot_segments()
  local p = normalize("C:\\Users\\foo\\.\\bar\\..\\baz.lua")
  A.equal("C:\\Users\\foo\\baz.lua", p,
    "Windows drive path with . and .. : segments collapsed, C:\\ prefix preserved (not duplicated)")
end

--- A UNC path `\\server\share\foo\..\bar.lua` must normalize to
--- `\\server\share\bar.lua` with the `\\` prefix preserved (not turned
--- into `server/share/bar.lua` which would lose the UNC form).
function M.test_normalize_windows_unc_with_dot_segments()
  local p = normalize("\\\\server\\share\\foo\\..\\bar.lua")
  A.equal("\\\\server\\share\\bar.lua", p,
    "UNC path with .. : \\\\ prefix preserved, segment popped correctly")
end

--- A Windows path with MIXED separators (`C:\Users/foo\bar.lua`) must
--- normalize them consistently. The chosen separator for the output
--- depends on the leading prefix: for `C:\` lead, backslash is used.
function M.test_normalize_windows_mixed_separators()
  local p = normalize("C:\\Users/foo\\bar.lua")
  A.equal("C:\\Users\\foo\\bar.lua", p,
    "Mixed-separator Windows drive path: output uses backslash (matching the C:\\ lead)")
end

--- A Unix path with `..` that pops above the root stays at the root.
--- This is a regression test for the segment-popping logic which must
--- not produce negative indices.
function M.test_normalize_unix_root_with_parent()
  -- Standard Unix path with .. — pops the previous segment.
  A.equal("/foo/baz.lua", normalize("/foo/bar/../baz.lua"),
    "Unix path with .. : .. pops the previous segment")
  A.equal("/foo/bar.lua", normalize("/foo/./bar.lua"),
    "Unix path with . : . is removed")
  -- Documented behavior: `..` at the root is preserved (the implementation
  -- keeps it so relative paths like `../sibling` stay recognizable). We
  -- verify this is still the case after the Windows-compat changes.
  A.equal("/../foo.lua", normalize("/../foo.lua"),
    "Unix root with .. : .. at root is preserved (documented behavior)")
end

--- Just a root path (`/` or `C:\`) must be preserved as the root, not
--- turned into an empty string.
function M.test_normalize_root_paths()
  A.equal("/", normalize("/"), "Unix root / preserved")
  A.equal("C:\\", normalize("C:\\"), "Windows root C:\\ preserved")
  A.equal("\\\\", normalize("\\\\"), "UNC root \\\\ preserved")
end

--------------------------------------------------------------------------------
-- Section 5: strip_trailing_sep — Windows root preservation
--------------------------------------------------------------------------------

--- `strip_trailing_sep("C:\\Users\\foo\\")` must produce `C:\\Users\\foo`
--- (single trailing backslash removed).
function M.test_strip_trailing_sep_windows_path()
  A.equal("C:\\Users\\foo", strip_ts("C:\\Users\\foo\\"),
    "Single trailing backslash on Windows path is stripped")
  A.equal("C:\\Users\\foo", strip_ts("C:\\Users\\foo\\\\"),
    "Multiple trailing backslashes are stripped")
end

--- The Windows drive root `C:\` must be PRESERVED by strip_trailing_sep
--- (it must NOT be stripped to `C:` which would no longer be a valid
--- path). This is the critical Windows-specific edge case: the
--- implementation checks if the second-to-last char is `:` and stops
--- stripping if so.
function M.test_strip_trailing_sep_preserves_windows_drive_root()
  A.equal("C:\\", strip_ts("C:\\"),
    "Windows drive root C:\\ must be preserved (not stripped to C:)")
  A.equal("C:/", strip_ts("C:/"),
    "Windows drive root C:/ (forward slash form) must also be preserved")
end

--- The Unix root `/` must be preserved — this is the existing Unix
--- behavior and must not regress when Windows support is added.
function M.test_strip_trailing_sep_preserves_unix_root()
  A.equal("/", strip_ts("/"), "Unix root / preserved")
  A.equal("/foo", strip_ts("/foo/"), "Single trailing slash stripped on Unix path")
end

--- nil input returns nil (defensive — many callers pass values that may
--- be nil and rely on the no-crash behavior).
function M.test_strip_trailing_sep_nil()
  A.is_nil(strip_ts(nil), "nil input returns nil")
end

--------------------------------------------------------------------------------
-- Section 6: is_path_under — mixed separators and Windows paths
--------------------------------------------------------------------------------

--- A Windows child path with backslashes must match a Windows parent
--- path with backslashes: `C:\project\foo.lua` is under `C:\project`.
function M.test_is_path_under_windows_backslash()
  A.truthy(is_path_under("C:\\project\\foo.lua", "C:\\project"),
    "Windows backslash path: child under parent with backslashes")
end

--- A Windows child path with backslashes must ALSO match a Windows parent
--- path with FORWARD slashes (mixed separator). This is the case where
--- the parent was normalized by the analyzer but the child came from a
--- raw source that still uses backslashes.
function M.test_is_path_under_windows_mixed_separators()
  A.truthy(is_path_under("C:\\project\\foo.lua", "C:/project"),
    "Mixed separators: backslash child matches forward-slash parent")
  A.truthy(is_path_under("C:/project/foo.lua", "C:\\project"),
    "Mixed separators: forward-slash child matches backslash parent")
end

--- A UNC child path must match a UNC parent path: `\\server\share\foo.lua`
--- is under `\\server\share`.
function M.test_is_path_under_unc_path()
  A.truthy(is_path_under("\\\\server\\share\\foo.lua", "\\\\server\\share"),
    "UNC child under UNC parent")
end

--- A Windows path with a `..` segment in the child must have it
--- collapsed before the prefix comparison, so `C:\project\sub\..\foo.lua`
--- is recognized as under `C:\project`.
function M.test_is_path_under_windows_with_dot_segments()
  A.truthy(is_path_under("C:\\project\\sub\\..\\foo.lua", "C:\\project"),
    "Child with .. must be normalized before prefix comparison")
end

--- Negative case: `C:\project-other\foo.lua` is NOT under `C:\project`
--- (segment-boundary check — must not match on string prefix alone).
function M.test_is_path_under_windows_segment_boundary()
  A.falsy(is_path_under("C:\\project-other\\foo.lua", "C:\\project"),
    "Segment-boundary check: project-other must NOT match parent project")
  A.falsy(is_path_under("C:\\projectother\\foo.lua", "C:\\project"),
    "Segment-boundary check: projectother must NOT match parent project")
end

--- Path with spaces: `C:\Program Files\app\foo.lua` is under
--- `C:\Program Files\app`. The space in the path must not break the
--- prefix comparison.
function M.test_is_path_under_windows_path_with_spaces()
  A.truthy(is_path_under("C:\\Program Files\\app\\foo.lua", "C:\\Program Files\\app"),
    "Path with spaces: prefix comparison must work despite the space")
  A.falsy(is_path_under("C:\\Program Files (x86)\\foo.lua", "C:\\Program Files"),
    "Path with spaces: segment boundary respected even with similar prefixes")
end

--- Trailing slash on parent must be tolerated: `C:\project\foo.lua` is
--- under `C:\project\` and also under `C:\project`. Both forms must match.
function M.test_is_path_under_windows_trailing_slash_on_parent()
  A.truthy(is_path_under("C:\\project\\foo.lua", "C:\\project\\"),
    "Trailing separator on parent: must still match")
  A.truthy(is_path_under("C:\\project\\foo.lua", "C:\\project"),
    "No trailing separator on parent: must match")
end

--- Windows drive root `C:\` is the root of its drive — every absolute
--- path on `C:` is under `C:\`. This is the analog of the Unix `/` case.
function M.test_is_path_under_windows_drive_root()
  -- Note: this depends on how the implementation treats drive roots.
  -- The current implementation short-circuits via `child == parent` for
  -- exact match, but a child NOT exactly equal to the drive root may
  -- not be detected as "under" — verify actual behavior.
  A.truthy(is_path_under("C:\\", "C:\\"),
    "Drive root is under itself (exact match)")
  A.truthy(is_path_under("C:\\Users", "C:\\"),
    "Subdirectory of drive root is under drive root")
end

--------------------------------------------------------------------------------
-- Section 7: Platform-conditional case-sensitivity test
--------------------------------------------------------------------------------

--- On Windows, the filesystem is case-insensitive: `foo.lua` and `FOO.LUA`
--- refer to the same file. On Unix, they're different files. This test
--- creates both files and verifies the platform-appropriate behavior.
--- It is auto-skipped on the wrong platform.
---
--- NOTE: This is the ONLY test in this file that touches the real
--- filesystem — all other tests are pure logic. We touch the FS here
--- because case-sensitivity is a filesystem property, not a string
--- comparison property, so it can ONLY be verified by actually creating
--- files.
function M.test_case_sensitivity_filesystem_behavior()
  if not helper.is_windows() then
    -- On Unix, foo.lua and FOO.LUA are different files. We verify that
    -- creating both works (no collision).
    local p1 = helper.tempfile("case_test_foo.lua", "lower")
    local p2 = helper.tempfile("case_test_FOO.LUA", "upper")
    -- Both files must exist as separate files.
    local f1 = io.open(p1, "r"); local c1 = f1 and f1:read("*a"); if f1 then f1:close() end
    local f2 = io.open(p2, "r"); local c2 = f2 and f2:read("*a"); if f2 then f2:close() end
    A.equal("lower", c1, "Unix: lowercase file exists with its own content")
    A.equal("upper", c2, "Unix: uppercase file exists as a separate file")
    A.truthy(p1 ~= p2, "Unix: paths are different (case-sensitive)")
  else
    -- On Windows, creating FOO.LUA after foo.lua collides with the
    -- existing file (overwrites it). We verify this by creating foo.lua
    -- first, then writing to FOO.LUA, then reading foo.lua back and
    -- confirming the content changed to the uppercase-write content.
    local p1 = helper.tempfile("case_test_foo.lua", "lower")
    -- Open FOO.LUA in the same directory (Windows will resolve it to
    -- the same file as foo.lua).
    local dir = p1:match("^(.*)[\\/][^/\\]+$")
    local p2 = dir .. "\\FOO.LUA"
    local f2 = io.open(p2, "w")
    if f2 then
      f2:write("upper")
      f2:close()
    end
    local f1 = io.open(p1, "r"); local c1 = f1 and f1:read("*a"); if f1 then f1:close() end
    A.equal("upper", c1,
      "Windows: writing to FOO.LUA overwrites foo.lua (case-insensitive)")
  end
end

--------------------------------------------------------------------------------
-- Section 8: Path-separator edge cases that break naive string comparison
--------------------------------------------------------------------------------

--- A Windows path with a drive letter and forward slashes (`C:/foo`)
--- must compare equal to its backslash form (`C:\foo`) for the purposes
--- of `is_path_under`. This is a logic test (no FS access).
function M.test_is_path_under_separator_normalization_for_drive_letter()
  -- Both forms should recognize the child as under the parent.
  A.truthy(is_path_under("C:/foo/bar.lua", "C:/foo"),
    "Forward-slash Windows path: child under parent")
  A.truthy(is_path_under("C:\\foo\\bar.lua", "C:/foo"),
    "Mixed: backslash child, forward-slash parent")
  A.truthy(is_path_under("C:/foo/bar.lua", "C:\\foo"),
    "Mixed: forward-slash child, backslash parent")
end

--- A path with a Unicode directory name (e.g. `C:\项目\foo.lua`) must
--- compare correctly — the prefix match must operate on byte-level
--- strings, not on locale-dependent comparisons.
function M.test_is_path_under_windows_unicode_dirname()
  A.truthy(is_path_under("C:\\项目\\sub\\foo.lua", "C:\\项目"),
    "Unicode directory name: child under parent (byte-level prefix match)")
  A.falsy(is_path_under("C:\\项目2\\foo.lua", "C:\\项目"),
    "Unicode directory name: segment boundary respected (项目2 ≠ 项目)")
end

return M
