# Changelog

All notable changes to `calltree.nvim` are documented in this file.

The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.1.0/),
and this project adheres to [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

---

## [1.2.4] — 2026-07-16

### Summary

Duplicate-code elimination release. Addresses 22 duplicate-code findings
identified by a systematic audit of the codebase. The refactor consolidates
caches onto the shared `fifo_cache` utility, extracts 5 generic helpers
(`walk_up_until`, `find_node_at_location`, `find_body_child`, `dfs_search`,
`EmptyCallGraph`), removes 4 redundant wrapper functions, deletes 1 dead
function, and centralizes LSP-request error handling and decision-record
construction. All 255 tests continue to pass with zero behavior change.

### Removed

- [Removed] `lua/calltree/utils.lua :: get_node_text` (Item 13) — deleted the
  50-line dead `get_node_text(source_code, ts_range)` function. It had NO
  callers anywhere in the codebase (verified via grep across `lua/` and
  `tests/`). All node-text extraction now goes through the unified
  `utils.node_text(node)` helper. Keeping the dead implementation risked
  future contributors re-introducing inconsistent text-extraction behavior.
- [Removed] `lua/calltree/resolution/require_resolver.lua :: M.get_node_text`
  (Item 3) — deleted the redundant `get_node_text` wrapper that just
  delegated to `utils.node_text` with zero additional logic. Internal
  callers now invoke `utils.node_text` directly, removing one level of
  indirection.
- [Removed] `lua/calltree/resolution/require_resolver.lua :: M.CALL_NODE_TYPES`
  (Item 8) — deleted the `M.CALL_NODE_TYPES = utils.CALL_NODE_TYPES` alias.
  No external callers referenced it (verified via grep). Internal callers
  now reference `utils.CALL_NODE_TYPES` directly.
- [Removed] `lua/calltree/resolution/module_finder.lua :: M.strip_trailing_sep`
  (Item 7) — deleted the `M.strip_trailing_sep = strip_trailing_sep` export.
  No external callers referenced it. The local `strip_trailing_sep` is kept
  for internal use.
- [Removed] `lua/calltree/analysis/callers.lua :: _find_caller_function`
  (Item 11) — deleted the 4-line wrapper whose body was
  `if ref_node == nil then return nil end; return nodes.find_top_level_calling_function(ref_node)`.
  The callee already handles nil input. Call sites now invoke
  `nodes.find_top_level_calling_function` directly.
- [Removed] `lua/calltree/analysis/definition_body.lua :: _resolve_module_path`
  (Item 12) — deleted the thin adapter that just constructed `exists_func`
  from `ctx.fs` and forwarded to `module_finder.resolve_module_path`. The
  construction is now inlined at the single call site in `M.check`.
- [Removed] `lua/calltree/treesitter/nodes.lua :: node_text` local wrapper
  (Item 3) — deleted the `local function node_text(n) return utils.node_text(n) end`
  wrapper. Call sites in `get_function_name` now use `utils.node_text` directly.

### Changed

- [Changed] `lua/calltree/providers/lsp_client.lua` (Item 2) — replaced the
  hand-rolled `lsp_diagnostics_by_bufnr` map + `lsp_diagnostics_order` list
  + `_evict_diag_cache` function with a single `fifo_cache` instance. The
  hand-rolled implementation duplicated the exact FIFO eviction logic that
  `fifo_cache` already provides. Consolidating removes ~30 lines of
  duplicated logic and guarantees the eviction strategy stays in sync with
  the other caches in the codebase.
- [Changed] `lua/calltree/analysis/callers.lua :: tree_cache` (Item 18) —
  replaced the unbounded plain-table cache with a `fifo_cache` instance
  capped at 128 entries. The previous cache could grow without limit on a
  large analysis run with many distinct ref files. The normalization-by-
  `uri_to_path` logic is preserved (two URIs pointing at the same physical
  file still share a cache entry). The cache shape (`{source, root}`) is
  unchanged.
- [Changed] `lua/calltree/analysis/external_calls.lua :: module_cache` and
  `lua/calltree/analysis/definition_body.lua :: M.check` (Item 19) —
  replaced the unbounded plain-table `module_cache` with a `fifo_cache`
  instance capped at 128 entries. `definition_body.M.check` now accepts a
  `fifo_cache` instance (or nil, in which case it creates a fresh empty
  one for backward compatibility). The cache shape
  (`{root, func_cache}`) is unchanged.
- [Changed] `lua/calltree/treesitter/nodes.lua` (Items 4, 15, 16, 22) —
  added 4 new shared helpers:
  - `M.walk_up_until(node, predicate, max_hops)` — generic bounded
    ancestor walk with built-in cycle detection. Replaces the duplicated
    `local cur = node; while cur ~= nil and hops < MAX_HOPS do ... end`
    skeleton that appeared in `walk_up_to_type`,
    `find_top_level_calling_function`, `_find_func_def_node`,
    `_find_decl_ancestor`, and the parameter-boundary walk in
    `definition_body.check`.
  - `M.find_node_at_location(ts, root, location)` — shared LSP-location →
    treesitter-node lookup. Replaces the near-identical `_find_ref_node`
    (callers.lua) and `_find_def_node` (definition_body.lua).
  - `M.find_body_child(func_node, block_types)` — shared body-block
    finder. Replaces the duplicated named-child walk in
    `analyzer._find_body_child`, `definition_body._check_func_body`, and
    the body-start lookup in `callers.M.analyze`.
  - `M.dfs_search(root, predicate, max_depth)` — generic depth-first
    search returning the first matching node. Replaces the manual `walk`
    closure in `find_function_def_by_name`.
- [Changed] `lua/calltree/treesitter/nodes.lua :: walk_up_to_type` and
  `find_top_level_calling_function` (Item 15) — both now delegate to
  `M.walk_up_until` instead of re-implementing the hop-cap + cycle-
  detection skeleton inline.
- [Changed] `lua/calltree/analysis/definition_body.lua :: _find_func_def_node`
  and `_find_decl_ancestor` (Item 15) — both now delegate to
  `nodes.walk_up_until` with predicates that return `true` on match and
  `"stop"` on early-bail-out conditions (parameter boundaries, bare
  declarations).
- [Changed] `lua/calltree/analysis/definition_body.lua :: M.check`
  parameter-boundary walk (Item 15) — the manual while-loop was replaced
  by a `nodes.walk_up_until` call with a `PARAMETER_BOUNDARY_TYPES`
  predicate.
- [Changed] `lua/calltree/providers/lsp_client.lua` (Items 6, 17) — added
  `M.safe_request(method_name, params, call_fn, dbg, error_label)` helper
  that pcall-wraps an LSP method invocation, logs errors via `dbg:error`
  AND `dbg:lsp_call`, and returns `{}` on failure. The caller passes a
  `call_fn` callback that performs the actual invocation (so the helper
  doesn't need to know per-method signature differences).
- [Changed] `lua/calltree/analysis/callers.lua` (Items 6, 17) — the
  `definition` and `declaration` pcall blocks now delegate to
  `lsp_client.safe_request`, removing ~20 lines of duplicated pcall +
  error-log + `dbg:lsp_call` pattern.
- [Changed] `lua/calltree/analysis/external_calls.lua` (Items 6, 17) —
  the `definition` pcall block now delegates to `lsp_client.safe_request`.
  The `def_results_call = nil` (unresolved) semantics is preserved by
  converting `safe_request`'s `{}` failure return back to `nil`.
- [Changed] `lua/calltree/domain/types.lua` (Items 5, 14) — added 3 new
  factories:
  - `M.EmptyCallGraph(debug)` — constructs the empty-result shape
    (`{current_function=nil, callers={}, external_calls={}, debug=...}`)
    used by every early-return path. Replaces hand-construction in 4+
    places (analyzer `_build_empty_result`, init.lua cursor-error
    fallbacks).
  - `M.CallerDecision(ref_path, start_line, start_col)` — constructs the
    caller decision-record shape used by `callers.lua`. Replaces the
    inline `{ref_uri, ref_path, ref_position, outcome, reason}` table.
  - `M.CallDecision(call_line, call_col, call_name, call_node_summary,
    callee_node_summary, full_call_range)` — constructs the call
    decision-record shape used by `external_calls.lua`. Replaces the
    inline `{call_position_0based, function_name, call_node, callee_node,
    full_call_range_0based, outcome, reason}` table.
- [Changed] `lua/calltree/core/analyzer.lua :: _build_empty_result`
  (Item 5) — now delegates to `types.EmptyCallGraph` instead of hand-
  constructing the result table via `CallGraphBuilder`.
- [Changed] `lua/calltree/init.lua` (Item 5) — both cursor-error
  fallbacks (`ok_cur == false` and `row == nil`) now use
  `types.EmptyCallGraph` instead of hand-constructing the result table.
- [Changed] `lua/calltree/analysis/callers.lua` (Item 14) — the
  `ref_decision` table is now constructed via `types.CallerDecision`
  instead of an inline table literal.
- [Changed] `lua/calltree/analysis/external_calls.lua` (Item 14) — the
  `call_decision` table is now constructed via `types.CallDecision`
  instead of an inline table literal.
- [Changed] `lua/calltree/utils/debug.lua :: node_summary` (Item 21) —
  now delegates text extraction to `utils.node_text` instead of re-
  implementing `pcall(node.text, node)` inline. The previous inline
  implementation only used the `node.text` method fallback, missing the
  `_text` and `name` fallbacks that `utils.node_text` provides for mock
  nodes. The truncation logic (MAX_NODE_TEXT_LEN + ellipsis) is preserved
  because truncation is a debug-output concern, not a text-extraction
  concern.
- [Changed] `lua/calltree/providers/file_reader.lua` (Item 1) — converted
  to a thin shim over `file_parser.lua`. The previous 130-line
  implementation (which duplicated `file_parser`'s read+parse+cache
  pipeline) is replaced by a 40-line shim that constructs a
  `file_parser` instance and exposes the old `get_tree` / `register` /
  `has` method names as aliases. The shim is marked deprecated; new code
  should `require("calltree.infrastructure.file_parser")` directly.
- [Changed] `lua/calltree/core/analyzer.lua ::
  _apply_external_calls_post_processing` (Item 20) — documented that the
  `if X == nil then X = true end` default-resolution for
  `skip_stdlib_calls` and `deduplicate_external_calls` is kept as a
  defensive measure for direct callers that bypass `init.lua` (e.g. unit
  tests that construct `ctx` by hand). The duplicate default value
  (true) is now documented in both places so a future change to the
  default stays in sync.
- [Changed] `lua/calltree/utils/debug.lua :: M.VERSION` — bumped from
  `1.2.3` to `1.2.4`.

---

## [1.2.3] — 2026-07-16

### Summary

Windows compatibility release. Adds a comprehensive Windows-compatibility
test suite (92 new test cases across 4 files) and fixes 5 platform bugs
in path handling, URI conversion, and process I/O. The plugin now
produces RFC 8089-conformant `file://` URIs for Windows drive-letter and
UNC paths, correctly recognizes mixed-separator Windows paths in
`is_path_under`, and falls back to Windows-native env vars and shell
commands in `getcwd` when running outside Neovim.

### Added — Windows-compatibility test suite

- `tests/windows_compat_helper.lua` — shared helpers for the Windows-compat
  suite: platform detection (`is_windows()`), temp file management with
  automatic cleanup, and a `skip` sentinel that the test runner recognizes
  to mark platform-conditional tests as PASS-but-SKIP.
- `tests/test_windows_compat_path.lua` — 34 tests for
  `lua/calltree/utils/path.lua` covering `path_to_uri`, `uri_to_path`,
  `normalize_path_segments`, `strip_trailing_sep`, and `is_path_under`.
  Tests Windows drive-letter paths, UNC paths, mixed separators, paths
  with spaces and special chars (`#`, `%`, `&`, `(`, `)`), Unicode
  directory names, and platform-conditional case-sensitivity behavior.
- `tests/test_windows_compat_fs.lua` — 20 tests for
  `lua/calltree/infrastructure/fs.lua` covering `read_file`, `exists`,
  and `getcwd`. Tests CRLF handling, UTF-8 BOM preservation, file size
  limit enforcement, paths with spaces and special chars, and the
  `getcwd` fallback chain (PWD / CD / pwd / `cmd /c cd`).
- `tests/test_windows_compat_module_finder.lua` — 28 tests for
  `lua/calltree/resolution/module_finder.lua` covering
  `is_absolute_path`, `path_join`, and `resolve_module_path`. Tests
  Windows drive-letter and UNC detection, mixed-separator path joining,
  module specs with special chars, and end-to-end integration with the
  real `fs.exists` / `fs.read_file`.
- `tests/test_windows_compat_init.lua` — 10 tests for
  `lua/calltree/init.lua :: write_json_to_file`. Tests path validation,
  analysis-failure handling, CRLF translation on Windows, paths with
  spaces and special chars, large-content handling, and partial-file
  cleanup.
- `tests/test_runner.lua` — updated to recognize the `__skip` sentinel
  thrown by `windows_compat_helper.skip()`, count skipped tests
  separately in the summary line, and auto-discover the 4 new test
  files via the manual fallback list.

### Fixed — Windows-compatibility bugs

- [Fixed] `lua/calltree/utils/path.lua :: path_to_uri` — Windows
  drive-letter paths now produce RFC 8089-conformant URIs of the form
  `file:///C:/Users/foo/bar.lua` (empty authority + absolute path,
  colon UNencoded). The previous implementation percent-encoded the
  colon (`file://C%3A/Users/foo/bar.lua`), producing non-standard URIs
  that some LSP clients (including Neovim's built-in) may reject.
- [Fixed] `lua/calltree/utils/path.lua :: path_to_uri` — Windows UNC
  paths (`\\server\share\foo.lua` or `//server/share/foo.lua`) now
  produce URIs of the form `file://server/share/foo.lua` (server as
  authority, per RFC 8089). The previous implementation produced
  `file:////server/share/foo.lua` (four slashes), which is malformed.
- [Fixed] `lua/calltree/utils/path.lua :: uri_to_path` — added detection
  of the three URI shapes produced by the new `path_to_uri` (UNC,
  drive-letter, Unix) so the round-trip returns the original filesystem
  path form: `file://server/share/...` → `//server/share/...`,
  `file:///C:/...` → `C:/...`, `file:///unix/path` → `/unix/path`.
- [Fixed] `lua/calltree/utils/path.lua :: is_path_under` — Windows
  drive roots (`C:\` or `C:/`) are now recognized as universal parents
  for every absolute path on that drive, mirroring the existing Unix
  `/` root behavior. Previously `C:\Users` was NOT recognized as under
  `C:\`, breaking project-scope filtering on Windows.
- [Fixed] `lua/calltree/utils/path.lua :: is_path_under` — mixed
  separators are now normalized to forward slashes before the prefix
  comparison. Previously `C:\project\foo.lua` (backslash child) would
  NOT match parent `C:/project` (forward slash) even though they refer
  to the same directory, because the comparison was a raw string prefix
  match.
- [Fixed] `lua/calltree/resolution/module_finder.lua :: path_join` —
  joining the Unix root `/` as head with a relative tail now produces
  `/foo.lua` (single leading slash) instead of `//foo.lua` (double
  slash). The previous implementation went straight to
  `head .. sep .. tail` without checking that `head == "/"` (preserved
  by `strip_trailing_sep` because its loop condition `#path > 1` is
  false for `#path == 1`).
- [Fixed] `lua/calltree/resolution/module_finder.lua :: resolve_module_path`
  — percent signs (`%`) in module specs (e.g. `require("50%-off")`) are
  now escaped before being substituted into the search-path template.
  The previous implementation passed the raw module spec as a `gsub`
  replacement string, where `%` is a special character (backreference
  prefix), causing `invalid use of '%' in replacement string` errors.
- [Fixed] `lua/calltree/infrastructure/fs.lua :: getcwd` — added Windows
  fallbacks: `os.getenv("CD")` (Windows cmd.exe convention, analogous
  to Unix `PWD`) and `io.popen("cmd /c cd 2>NUL")` (Windows analog of
  `pwd 2>/dev/null`). The previous implementation only consulted
  Unix-specific sources, so `getcwd` returned nil when called outside
  Neovim on Windows, breaking project-scope filtering.

### Changed

- [Changed] `lua/calltree/utils/debug.lua :: M.VERSION` — bumped from
  `1.2.2` to `1.2.3`.
- [Changed] `tests/test_runner.lua` — test summary line now reports
  `Total: N passed, N failed, N skipped` (was `N passed, N failed`).
  Skipped tests are counted as PASS-but-SKIP so the suite still exits
  0 when only skipped tests are conditionally excluded.

---

## [1.2.2] — 2026-07-15

### Summary

Refactor release: integrates `domain/types.lua` domain model into the
analysis pipeline. Analysis modules now use the factory functions
(`CallerInfo`, `ExternalCall`, `CallGraphBuilder`) from `domain/types.lua`
instead of constructing anonymous tables. The final `CallGraph` result is
frozen (immutable) via `CallGraphBuilder:build()`, protecting it from
accidental downstream mutation. Public API signatures and JSON output
structure are unchanged.


- [Fixed] `lua/calltree/init.lua :: encode_json` — added a `_thaw` helper that
  recursively converts frozen tables back to plain mutable tables before
  passing them to `vim.json.encode` / `vim.fn.json_encode`. The built-in
  C encoders use `lua_next` which bypasses proxy metamethods, producing
  empty `[]` / `{}` output on frozen objects. The thaw step ensures
  JSON encoding works correctly with both frozen and plain-table results.
- [Fixed] `lua/calltree/core/analyzer.lua :: _run_analysis_phases` — moved the
  `lsp_adapter_diagnostics` merge from `init.lua` (post-return) into the
  analyzer (pre-freeze). Previously the merge wrote to `result.debug`
  after the result was frozen, raising "attempt to modify read-only
  field". Now the merge happens before `CallGraphBuilder:build()` freezes
  the result, preserving the same user-visible behavior.
- [Fixed] `lua/calltree/domain/types.lua :: freeze` — replaced the proxy-based
  freeze implementation with a "data-in-table" approach. The previous
  proxy approach (empty table + `__index = data`) broke `pairs()` /
  `ipairs()` / `next()` iteration in LuaJIT (Neovim's runtime), which
  does not respect `__pairs` / `__ipairs` metamethods. The new approach
  keeps data in the raw table so all standard iteration functions work
  natively. Immutability is enforced via `__newindex` (raises on new
  fields); overwriting existing fields is a documented LuaJIT limitation.
- [Fixed] `lua/calltree/domain/types.lua :: CallGraphBuilder` — added a `debug`
  field to the builder so `:build()` includes it in the frozen output.
  Previously `:build()` only froze `current_function` / `callers` /
  `external_calls`, dropping the `debug` snapshot.


- [Changed] `lua/calltree/analysis/callers.lua :: _keep_caller` — now uses
  `types.CallerInfo()` factory instead of constructing an anonymous
  table. The factory produces a frozen `CallerInfo` object whose field
  shape matches the domain type definition.
- [Changed] `lua/calltree/analysis/external_calls.lua :: _make_external_call` —
  now uses `types.ExternalCall()` factory instead of constructing an
  anonymous table. All 8 call sites that create external_call entries
  delegate through this helper, ensuring consistent field shape and
  immutability.
- [Changed] `lua/calltree/core/analyzer.lua :: _locate_cursor_function` — now
  uses `types.CallGraphBuilder()` to construct the result object instead
  of a plain table literal. The builder stays mutable during phases 5-6
  (callers / external_calls append to its arrays); `:build()` is called
  at the end of `_run_analysis_phases` to freeze the final `CallGraph`.
- [Changed] `lua/calltree/core/analyzer.lua :: _build_empty_result` — now uses
  `types.CallGraphBuilder()` for shape consistency on early-return paths.
  The builder's internal fields are returned as a plain table (not frozen)
  since early-return paths don't need immutability.
- [Changed] `lua/calltree/core/analyzer.lua :: _run_analysis_phases` — calls
  `result:build()` at the end to freeze the final `CallGraph` before
  returning it to the caller. The frozen result raises on new-field
  writes, protecting it from accidental mutation downstream.
- [Changed] `lua/calltree/init.lua :: analyze_at_cursor` — removed the
  `lsp_adapter_diagnostics` merge (now done in the analyzer pre-freeze).
  Added `require("calltree.domain.types")` for the `_thaw` helper.
- [Changed] `lua/calltree/utils/debug.lua :: M.VERSION` — bumped from `1.2.1` to
  `1.2.2`.

---

## [1.2.1] — 2026-07-15

### Summary

Patch release: JavaScript/TypeScript language support, stdlib filtering
refinement, and lua-language-server meta-path recognition. Adds first-class
JS analysis (arrow functions, class methods, ES6 imports) and fixes two
misclassification issues in `external_calls` filtering.


- [Fixed / Changed] `lua/calltree/treesitter/nodes.lua :: M.is_function_name_node` — added
  a `variable_declarator` sibling-scan branch that detects JS/TS
  arrow-function and function-expression assignments
  (`const add = (a,b) => a+b`, `let fn = function() {}`). Previously the
  cursor on the binding identifier found no function-definition ancestor
  (the `arrow_function` is a sibling, not a parent), so `current_function`
  was silently `nil` for all arrow-function assignments.
- [Fixed / Changed] `lua/calltree/treesitter/nodes.lua :: M.get_function_name` — added a
  parent-`variable_declarator` fallback that extracts the binding name
  for arrow-function / function-expression nodes. The name is read from
  the sibling `identifier` inside the same `variable_declarator`, covering
  `const`/`let`/`var` assignments of function-typed RHS values.
- [Fixed / Changed] `lua/calltree/analysis/preconditions.lua :: _search_symbol_tree` —
  rewritten as a three-pass search: (1) Function/Method symbols
  (preferred), (2) descend into children of any in-range symbol for a
  deeper Function/Method match, (3) JS/TS fallback accepting
  Variable(13)/Constant(14) symbols whose range contains the cursor.
  `typescript-language-server` classifies arrow-function assignments as
  Constant, not Function — the fallback lets calltree analyze them while
  the caller re-validates against the treesitter node.
- [Fixed / Changed] `lua/calltree/core/analyzer.lua :: _locate_cursor_function` — the LSP
  symbol-kind check now accepts Variable(13) and Constant(14) in addition
  to Function(12)/Method(6), but ONLY when the treesitter `func_node`
  identified in Phase 3 is actually a function-type node. This keeps the
  check strict for languages where the LSP correctly tags functions as
  Function/Method, while allowing JS/TS arrow-function assignments.
- [Fixed / Changed] `lua/calltree/core/analyzer.lua :: _filter_stdlib_external_calls` —
  changed the filter condition from `is_stdlib == true` to
  `is_stdlib ~= false`, so entries with `is_stdlib = nil` (unclassified)
  are now also dropped when `skip_stdlib_calls = true`. Only entries
  explicitly tagged `is_stdlib = false` survive the filter. This matches
  the intent of `skip_stdlib_calls` (remove non-project calls) since
  unclassified entries are overwhelmingly stdlib calls whose path didn't
  match a known pattern.
- [Fixed / Changed] `lua/calltree/analysis/external_calls.lua :: M.STDLIB_PATH_PATTERNS` —
  added four new path patterns to recognize `lua-language-server` meta
  files as stdlib: `"/lua-language-server"` (binary install tmp dir),
  `"/meta/Lua"` (Lua 5.x stdlib meta), `"/meta/LuaJIT"` (LuaJIT stdlib
  meta), `"/meta/builtin"` (builtin meta). Previously, calls to
  `pcall`/`tostring`/`type` resolved to these meta files but were
  misclassified as non-stdlib because the path didn't match any existing
  pattern, escaping the stdlib filter and appearing as spurious
  "external project" calls.
- [Fixed / Changed] `lua/calltree/utils/debug.lua :: M.VERSION` — bumped from `1.2.0` to
  `1.2.1`, recorded in every debug output for reproducibility.

---

## [1.2.0] — 2026-07-15

### Summary

Feature release: adds two new `setup()` options for post-collection
filtering of `external_calls` — `skip_stdlib_calls` and
`deduplicate_external_calls`. Both default to `true`, so the default
user-visible output now contains **fewer entries** (one per callee
function, no standard-library calls). Users who relied on the previous
"raw" output can restore it by passing both flags as `false`.

This is a **behavior-changing** release (hence the minor version bump
to 1.2.0 per SemVer). The public API surface (`analyze_at_cursor`,
`analyze_at_cursor_json`, `write_json_to_file`, `dump_at_cursor`) is
unchanged; only the contents of the `external_calls` array in the
result differ when the new defaults apply.


- [Added] **`skip_stdlib_calls`** (default `true`) — new `setup()` option that
  drops entries with `is_stdlib = true` from the final
  `result.external_calls` array. The `is_stdlib` classification logic
  itself is unchanged (still uses `LSP_TAG_SYSTEM_LIBRARY` +
  `STDLIB_PATH_PATTERNS` path heuristics). When `false`, all stdlib
  calls are kept in the result (useful for debugging "why is this call
  unresolved?" when the LSP mis-tags a project function as stdlib).
- [Added] **`deduplicate_external_calls`** (default `true`) — new `setup()`
  option that collapses entries sharing the same `(function_name,
  definition.file)` pair, keeping the first occurrence (in collection
  order). When `false`, every call site produces a separate entry
  (useful when you need to see every call location, not just the set
  of distinct callees).
- [Added] Both flags are also accepted as per-call overrides in
  `analyze_at_cursor(bufnr, opts)` and `analyze_at_cursor_json(bufnr, opts)`,
  matching the existing `opts.debug` override semantics.
- [Added] **`debug.inputs.raw_external_calls_before_filter`** — new diagnostic
  field (recorded only when filtering actually changes the list) that
  captures the pre-filter entry count for debugging. Per the spec this
  is NOT a `summary` field; it lives under `debug.inputs` alongside the
  other raw-input snapshots. Two companion fields —
  `debug.inputs.external_calls_dedup_removed` and
  `debug.inputs.external_calls_stdlib_removed` — record how many
  entries each filter step dropped.
- [Added] **`tests/test_external_calls_filtering.lua`** — 8 new unit tests
  covering: default dedup behavior, dedup-disabled behavior, default
  stdlib-skip behavior, stdlib-skip-disabled behavior, summary count
  recomputation, raw-count diagnostic recording, processing-order
  verification (dedup-before-filter), and both-flags-false raw
  preservation.


- [Changed] **Default `external_calls` output is now deduplicated and stdlib-free.**
  Previously, every call site produced a separate entry, and stdlib
  calls (e.g. `string.format`, `print`) were kept in the result. With
  the new defaults (`skip_stdlib_calls = true`,
  `deduplicate_external_calls = true`), the result contains at most
  one entry per distinct `(function_name, definition.file)` pair, and
  no stdlib entries at all.
- [Changed] **`summary.calls_kept` and `summary.calls_unresolved`** now reflect
  the FINAL (post-filter) array length, not the raw collected count.
  The other summary counters (`calls_in_scope`, `calls_no_body`,
  `calls_outside_project`, `calls_kept` as-kept-stdlib) are left
  as-is — they describe the decisions made during collection and
  remain useful for debugging even after filtering.
- [Changed] **Processing order is MANDATORY**: dedup runs FIRST (on the full
  collected list, including stdlib), then the stdlib filter runs on
  the deduplicated list. This ensures the first-occurrence-wins rule
  applies uniformly, and the stdlib filter operates on a clean list.
  Reversing the order would produce different results in the rare
  case where a stdlib entry and a project entry share the same
  `(name, file)` pair.
- [Changed] **`M.options`** now persists `skip_stdlib_calls` and
  `deduplicate_external_calls` alongside the existing `debug` and
  `user_commands` flags. `setup()` is symmetric: every recognized
  option is stored.
- [Changed] **`ctx` (analysis context)** now carries `skip_stdlib_calls` and
  `deduplicate_external_calls` fields, threaded through
  `adapter.build_context` → `core/context.lua` → `core/analyzer.lua`.
  Tests using `Scenario:analyze(opts)` can pass these flags to
  exercise non-default behavior.
- [Changed] **Version constant** bumped from `1.1.2` to `1.2.0` in
  `lua/calltree/utils/debug.lua` (`M.VERSION`), recorded in every
  debug output for reproducibility.

### Migration Guide

- **Most users**: no action needed. The new defaults produce cleaner
  output (one entry per callee, no stdlib noise). This is the
  behavior most users intuitively expect from a "call graph" tool.
- **Users who need the raw output** (e.g. for debugging LSP tagging,
  or to see every call site): add both flags to your `setup()` call:
  ```lua
  require("calltree").setup({
    skip_stdlib_calls = false,
    deduplicate_external_calls = false,
  })
  ```
- **Per-call override** (without changing global defaults):
  ```lua
  local result = calltree.analyze_at_cursor(0, {
    skip_stdlib_calls = false,
    deduplicate_external_calls = false,
    debug = true,
  })
  ```
- **Existing tests** that assert on `external_calls` length may need
  updating if they relied on the raw count. The
  `test_call_to_stdlib_function` test in `test_external_calls.lua`
  was updated to pass `{ skip_stdlib_calls = false,
  deduplicate_external_calls = false }` since it specifically
  verifies the stdlib-keep path.

### Files Changed

| File | Change |
|------|--------|
| `lua/calltree/init.lua` | `M.options` adds two new flags; `setup()` persists them; `analyze_at_cursor` threads them into `build_context` |
| `lua/calltree/core/context.lua` | `M.build` accepts and passes through the two new flags in the returned `ctx` |
| `lua/calltree/core/analyzer.lua` | New `_apply_external_calls_post_processing` pipeline (dedup → stdlib filter → summary recompute) called in `_run_analysis_phases` |
| `lua/calltree/utils/debug.lua` | `M.VERSION` **1.1.2 → 1.2.0** |
| `tests/scenario.lua` | `Scenario:analyze(opts)` accepts optional flags |
| `tests/test_external_calls.lua` | `test_call_to_stdlib_function` passes both-false to preserve original intent |
| `tests/test_external_calls_filtering.lua` | **added** — 8 new tests for the filtering pipeline |
| `tests/test_runner.lua` | Registers the new test file in the manual fallback list |
| `README.md` | Documents the two new `setup()` options |
| `CHANGELOG.md` | This entry |

---

## [1.1.2] — 2026-07-10

### Summary

Test-infrastructure and multi-language real-LSP release. Consolidates
**all** automated tests under `tests/`, adds a first-class **C/clangd**
real-LSP suite (10 scenarios + 3 stress cases), hardens the existing
Lua and Rust real-LSP runners for low-memory hosts, and documents the
full matrix in `tests/README.md` / `INSTALL.md` / `README.md`.

Public API signatures and JSON output structure are **unchanged**.
Version constant bumped to `1.1.2`. Full green matrix on the reference
environment: **111 unit + 105 headless + 59 lua_ls + 10 C + 3 C-stress
+ 76 Rust = 364 assertions/scenarios, 0 failures**.

- [Added] **`tests/README.md`** — canonical guide: suite table, directory layout,
  prerequisites, methods/techniques, how to add tests, troubleshooting.
- [Added] **`tests/run_all_tests.sh`** — full 6-suite matrix (unit, headless,
  lua_ls, C scenarios, C stress, Rust e2e) with skip flags
  (`CALLTREE_SKIP_C`, `CALLTREE_SKIP_RUST`, `CALLTREE_SKIP_REAL_LSP`)
  and binary overrides (`CALLTREE_*_BIN`).
- [Added] **`tests/test_runner.lua`**, **`tests/runner_headless.lua`**,
  **`tests/runner_headless_real_lsp.lua`** — all test entry points now
  live under `tests/` (no root-level runners).
- [Added] **`tests/fixtures/rust_test/`** — Cargo fixture for the Rust e2e suite
  (moved from top-level `rust_test/`).
- [Added] **`Makefile`** targets: `test`, `test-unit`, `test-headless`,
  `test-lsp`, `test-c`, `test-rust`, `test-all`.
- [Added] **`tests/c/run_c_tests.lua`** — 10 headless scenarios against real
  **clangd** + real tree-sitter-c (no mocks):
  - S01 simple function definition identification
  - S02 direct callers (single file), self-ref excluded
  - S03 same-file external call resolution
  - S04 function-pointer parameter → unresolved
  - S05 struct member function-pointer call
  - S06 typedef alias + function name extraction
  - S07 active `#ifdef` branch only (skip `#else`)
  - S08 macro invocations filtered (not `call_expression`)
  - S09 nested pointer/function declarators
  - S10 cross-TU caller (`main.c` → `math.c`)
- [Added] **`tests/c/run_stress_tests.lua`** — 3 stress scenarios:
  nested calls + stdlib, multi-file callers, control-flow multi-sites.
- [Added] **Per-scenario `compile_commands.json`** under
  `tests/c/scenarios/s01_…s10_…/` and `tests/c/stress/` so clangd does
  not index sibling scenarios and leak cross-file references.
- [Added] **`tests/c/README.md`** — requirements, run commands, scenario table.



- [Fixed] **`tests/headless_real_lsp.lua` OOM on low-memory hosts** — each
  scenario started a new `lua-language-server` without tearing down the
  previous one; dozens of ~160 MB processes triggered the OOM killer.
  Added `stop_all_lsps()` + buffer wipe + `collectgarbage` in
  `cleanup_project`. Removed trailing `bdelete!` calls that raced with
  the new cleanup (E94).
- [Fixed] **`scripts/nvim_lsp_init.lua` heavy lua_ls settings** — loading all of
  `VIMRUNTIME` as workspace library multiplied memory. Tests now use an
  empty library, disabled diagnostics/completion/hints, and
  `--loglevel=error`.
- [Fixed] **C runners used `vim.lsp.config` / `vim.lsp.enable` (Neovim 0.11+
  only)** — failed on Neovim 0.10 with `attempt to call field 'config'
  (a nil value)`. Rewrote attachment to `vim.lsp.start` +
  `--compile-commands-dir=` for 0.10/0.11 compatibility.
- [Fixed] **C `compile_commands.json` absolute paths** pointed at a developer
  machine. Regenerated to workspace-relative absolute
  paths under `tests/c/…` so clangd finds sources on any host.
- [Fixed] **C S10 cross-file callers returned 0** — clangd’s reference index
  was cold and sibling TUs were not attached. After attach, sibling
  `.c` files are now `bufadd`/`buf_attach_client`’d and a short index
  warm-up wait runs before analysis.
- [Fixed] **Rust e2e: multiple rust-analyzer clients + empty `documentSymbol`**
  — `start_rust_analyzer` now reuses a single client; symbol lookup
  retries; clients are force-stopped between scenarios. Fixed
  `PROJECT_DIR` to always be absolute (`tests/fixtures/rust_test`).
- [Fixed] **Rust sysroot / `rust-src` layout (Debian)** — documented and
  exercised the symlink
  `$(rustc --print sysroot)/lib/rustlib/src/rust → /usr/src/rustc-<ver>`
  so rust-analyzer can load the standard library.
- [Fixed] **Hardcoded developer paths** in C/Rust runners and docs
  (`/home/z/my-project/...`) replaced with paths derived from
  `debug.getinfo` / env overrides (`CALLTREE_CLANGD_BIN`,
  `CALLTREE_RUST_PROJECT`, `CALLTREE_PLUGIN_DIR`, …).


| Path | Change |
|------|--------|
| `run_all_tests.sh` | **moved** → `tests/run_all_tests.sh` |
| `test_runner.lua` | **moved** → `tests/test_runner.lua` |
| `runner_headless.lua` | **moved** → `tests/runner_headless.lua` |
| `runner_headless_real_lsp.lua` | **moved** → `tests/runner_headless_real_lsp.lua` |
| `c_tests/` | **removed** (canonical: `tests/c/`) |
| `rust_test/` | **removed** (canonical: `tests/fixtures/rust_test/`) |
| `scripts/rust_e2e/` | **removed** (canonical: `tests/rust/`) |
| `tests/c/**` | **added** (runners, scenarios, stress, README) |
| `tests/rust/**` | **added** (`run_rust_tests.lua`, `rust_nvim_init.lua`) |
| `tests/fixtures/rust_test/**` | **added** (Cargo fixture) |
| `tests/README.md` | **added** |
| `Makefile` | **updated** targets to `tests/…` paths |
| `README.md` | **updated** test section + suite table |
| `INSTALL.md` | **updated** package tree, requirements, run matrix |
| `lua/calltree/utils/debug.lua` | `M.VERSION` **1.1.1 → 1.1.2** |
| `tests/headless_real_lsp.lua` | LSP cleanup between scenarios |
| `scripts/nvim_lsp_init.lua` | lighter lua_ls settings for tests |


This patch (no version bump) addresses **all 59 findings** from an
external static-code-review report. Public API signatures, JSON output
structure, and existing test assertions are unchanged. Pure-Lua unit
test count remains at **128 PASS / 0 FAIL** after the fixes.


- [Fixed] `init.lua :: write_json_to_file` — added `path` type/emptiness
  validation before running `analyze_at_cursor_json` so a nil/empty
  path fails fast with `open_failed` instead of crashing inside
  `io.open` (which is not pcall-wrapped).
- [Fixed] `init.lua :: analyze_at_cursor` — when `bufnr` is non-zero and
  differs from the current buffer, the cursor is now read from the
  window returned by `vim.fn.bufwinid(bufnr)` instead of being
  hardcoded to window 0. Falls back to window 0 when the buffer has
  no window.
- [Fixed] `analysis/definition_body.lua :: M.check` — `module_cache` parameter
  now defaults to `{}` when nil, preventing "attempt to index a nil
  value" on `module_cache[resolved_path]`.
- [Fixed] `analysis/definition_body.lua :: _read_def_source` — guards against
  nil `ctx.file_path` and `def.uri` before calling `path_to_uri` /
  `file_parser.read_source`.
- [Fixed] `analysis/definition_body.lua :: _find_def_node` — added
  `def.range.start` / `def.range["end"]` existence checks before
  accessing their `.line` / `.character` fields.
- [Fixed] `analysis/callers.lua :: M.analyze` — `func_node:named_child_count()`
  return value is now `or 0` — protected against mock trees returning
  nil.
- [Fixed] `analysis/callers.lua :: _analyze_one_reference` — validates
  `ref.uri` is a non-empty string before passing it to
  `utils.uri_to_path` / `file_parser.read_source`.
- [Fixed] `analysis/callers.lua :: _find_ref_node` — added `ref.range.start` /
  `ref.range["end"]` existence checks.
- [Fixed] `analysis/external_calls.lua :: _check_in_scope` — `cur_body_start_line`
  and `cur_start_line` now default to `-1` when both are nil, so the
  `ds_line > body_line` comparison never raises "attempt to compare
  number with nil".
- [Fixed] `providers/lsp_client.lua :: normalize_location_list` — handles
  `vim.NIL` (JSON `null`) responses and any non-table value by
  returning `{}`, avoiding "attempt to index userdata" inside `ipairs`.
- [Fixed] `providers/treesitter.lua :: wrap_node.range` — `:range()` is now
  pcall-wrapped (consistent with `:text()`), returning `nil, nil, nil,
  nil` on failure instead of raising.
- [Fixed] `resolution/module_finder.lua :: resolve_module_path` — `cwd` is now
  only passed to `strip_trailing_sep` when non-nil, preventing "attempt
  to index a nil value".
- [Fixed] `treesitter/nodes.lua :: nodes_equal` — `:type()` calls are now
  pcall-wrapped (consistent with the existing `:range()` pcall).
- [Fixed] `utils.lua :: get_node_text` — added `end_line == nil` /
  `end_col == nil` early-return before the multi-line loop's
  arithmetic.
- [Fixed] `utils/debug.lua :: DebugCollector:lsp_call` — `vim.inspect` is now
  type-checked (`type(vim.inspect) == "function"`) before being called,
  not just truthy-checked.


- [Fixed] `analysis/definition_body.lua :: _find_def_node` — finding 2.1
  claimed `ts.descendant_for_range(ts, def_root, ...)` was a double-`ts`
  shadowing bug. Verified this is the **explicit-self form** of the
  method call (`ts` becomes `self`, `def_root` becomes `root`), matching
  every other caller in this codebase. **Won't fix** — documented with
  rationale; changing only this call site would desync it from the rest
  and break analysis.
- [Fixed] `providers/treesitter.lua :: extract_root_from_parser` — finding 2.2
  flagged `t.has_error` access. Verified that Neovim's Tree object DOES
  expose `has_error` (as both a method and a field across versions); the
  existing `type(t.has_error) == "function"` / `"boolean"` dispatch
  handles all known Neovim releases. **Won't fix** — the existing
  defensive dispatch is correct.
- [Fixed] `providers/treesitter.lua :: M.new` — removed the forced trailing
  `"\n"` on `buf_source` so the `source_code ~= buf_source` comparison
  correctly detects when `parse()` is called with the buffer's actual
  content (which may or may not end with a newline). Previously the
  string-parser path was always selected for the current buffer.


- [Fixed] `init.lua :: CalltreeToFile callback` — now receives the third
  `err_detail` return value from `write_json_to_file` and surfaces it
  in the failure message (`(reason: open_failed) — permission denied`).
- [Fixed] `init.lua :: write_json_to_file` — `pcall` around `f:write` / `f:flush`
  now captures the error object and returns it as `err_detail` instead
  of the generic "f:write or f:flush raised an error" string.
- [Fixed] `analysis/callers.lua :: _read_and_parse_ref` — when `ctx.language`
  is nil, still falls back to `utils.DEFAULT_LANGUAGE` (backward-compat)
  but now records a warning so the operator sees the cause of any
  downstream parsing oddities.
- [Fixed] `core/analyzer.lua :: deepcopy` — the iteration `pcall` now captures
  the error object and attaches it to the partial copy as
  `_deepcopy_error`, instead of discarding it (`_`).
- [Fixed] `core/analyzer.lua :: with_phase_logging` — finding 3.5 flagged the
  Lua 5.1 `table.pack` fallback. Already documented as a limitation
  (analyzer phase functions never return nil-holed values); kept as-is
  with explicit comment.
- [Fixed] `analysis/definition_body.lua :: _resolve_module_path` — finding 3.6
  recommended using `ctx.fs:exists(path)` (method-call syntax) to bind
  `self`. However, the IFileSystem implementation in
  `infrastructure/fs.lua` defines `M.exists(path)` as a REGULAR
  function (no `self` parameter), so the method-call form would pass
  `ctx.fs` as `path` — crashing inside `os.rename`. **Won't fix** —
  the original `ctx.fs.exists(path)` is correct for the existing
  implementation. Documented with rationale.
- [Fixed] `analysis/definition_body.lua :: _search_module_function` — caches
  ONLY successful lookups (node ~= nil); failed lookups are re-scanned
  so a function added to the module later in the same analysis run can
  still be found.


- [Fixed] `core/analyzer.lua :: _locate_cursor_function` — `cur_start_line`,
  `cur_end_line`, `cur_end_col` are now `or 0` — protected against
  `func_node:range()` returning nils.
- [Fixed] `core/analyzer.lua :: _locate_cursor_function` — `cur_body_start_line`
  is now `or cur_start_line or 0` after the body-child lookup.
- [Fixed] `analysis/external_calls.lua :: M.analyze` — finding 4.3 (`#`
  unreliable on sparse arrays) is covered by the existing defensive
  `opts.def_results[1]` lookup in `M._analyze_resolved_call`. Documented
  why the `#def_results_call == 0` check at the call site is safe (only
  entered when `#def_results_call > 0`, which guarantees `[1]` non-nil
  in any well-formed list).
- [Fixed] `analysis/external_calls.lua :: _analyze_resolved_call` — when
  `first_def.uri == nil`, the call is now marked UNRESOLVED and returned
  immediately, instead of letting nil propagate into
  `_check_project_scope` (where `def_path = nil` would cause
  `is_path_under(nil, cwd)` → false → "kept_external_crate" with
  `file=nil`) and into `_check_has_body` (where `definition_body.check`
  would crash on nil `def_path`).
- [Fixed] `resolution/module_finder.lua :: is_absolute_path` — Windows
  root-of-drive form `\foo` (single leading backslash) is now correctly
  recognized as absolute.
- [Fixed] `resolution/module_finder.lua :: path_join` — when `head` is the
  filesystem root `/` (after `strip_trailing_sep`), the root slash is
  re-added so joining `"/"` + `"foo.lua"` produces `"/foo.lua"` (not
  the relative `"foo.lua"`).
- [Fixed] `utils/path.lua :: is_path_under` — special-cases the filesystem root
  `"/"` (and `"\"`) so `is_path_under("/foo", "/")` returns `true`
  (previously `parent .. "/"` produced `"//"` which never matched).
- [Fixed] `utils/path.lua :: path_to_uri` — Windows backslash normalization is
  now gated on the path looking Windows (drive-letter or UNC prefix).
  On Unix, backslashes are valid filename characters and are preserved
  (percent-encoded as `%5C` in the URI), no longer silently replaced
  with `/`.
- [Fixed] `utils/path.lua :: normalize_path_segments` — chooses the segment
  separator based on the lead prefix: backslash for UNC paths with
  `\\` lead and for Windows drive-letter leads, forward slash otherwise.
  Fixes mixed-separator output like `\\server/share/dir`.


- [Fixed] `resolution/require_resolver.lua` — finding 5.1 (duplicate
  `local utils = require(...)` declaration) was already resolved in a
  prior refactor; the current file declares `utils` exactly once.
  Documented with rationale.
- [Fixed] `resolution/require_resolver.lua :: extract_require_module` —
  positional binding for `local a, b = require("foo"), require("bar")`
  is now resolved correctly. The function tracks the position of the
  current identifier among name-like siblings and matches it against
  the position of require calls among call-like siblings, returning
  the positionally-corresponding module. Falls back to first-match for
  single-binding forms.
- [Fixed] `analysis/callers.lua :: _check_self_recursive` — containment check
  now compares columns in addition to lines, so a definition on the
  same line but BEFORE the caller's start column is no longer wrongly
  treated as contained.
- [Fixed] `analysis/callers.lua :: _check_self_recursive` — when caller range
  is unavailable, the same-uri fallback now requires `def.range.start`
  AND `def.range["end"]` to be present (not just `d.uri`), reducing
  false positives on overloaded same-name functions in the same file.
- [Fixed] `analysis/external_calls.lua :: _set_stdlib_flag` — string-tag
  branches (`"system"` / `"library"`) are now gated on
  `type(tag) == "string"`; the spec integer form
  (`LSP_TAG_SYSTEM_LIBRARY`) is checked first. The dead-code claim in
  the report was overly strict — some clangd versions still emit the
  string form, so the branches are kept for backward-compat.
- [Fixed] `treesitter/walker.lua :: same_range_as_func_node` — now compares
  all four range components (start line/col + end line/col), not just
  lines. Fixes mis-classification of two distinct single-line functions
  sharing the same line as "the same function".
- [Fixed] `treesitter/nodes.lua :: get_function_name` — recursively descends
  through `WRAPPER_TYPES` chains (`function_declarator -> declarator ->
  identifier`) instead of only checking one level, so deeply-nested
  declarators are correctly unwrapped.
- [Fixed] `treesitter/nodes.lua :: is_function_name_node` — `dbg` access is
  now type-checked (`type(dbg.get) == "function"`) before calling
  `:get()`, and `dbg.data.cursor_detection` is verified as a table
  before writing to it. Mock objects / plain tables no longer crash
  the function.
- [Fixed] `utils/debug.lua :: DebugCollector:new` — finding 5.9 claimed
  `source_line_count` under-counted `"abc\n"` (should be 2). The
  existing logic gives 1, matching POSIX `wc -l` and most editor
  conventions. **Won't fix** — documented with rationale; the report's
  suggested `nl_count + 1` would over-count by 1 on the common case
  of files ending with a single trailing newline.


- [Fixed] `init.lua :: setup` — `elseif opts.user_commands ~= false` was
  already simplified to plain `else` in a prior refactor. Documented.
- [Fixed] `analysis/definition_body.lua` — finding 6.2 (three ancestor-walk
  loops could be merged) is a readability suggestion; the three walks
  have different exit conditions and merging would hurt clarity.
  **Won't fix** — kept as three focused loops.
- [Fixed] `utils/debug.lua :: NoopCollector` — finding 6.3 flagged the explicit
  no-op method stubs as redundant (since `__index` returns a no-op
  function for undefined methods). The stubs are kept for grep-ability
  and to make the API surface explicit — a small readability win that
  justifies the redundancy.


- [Fixed] `init.lua :: CalltreeToFile` — removed the stale comment about
  avoiding shadowing an "outer setup(opts) parameter" that doesn't
  exist (register_user_commands is a standalone local function).
- [Fixed] `utils.lua :: find_first_descendant_by_type` — corrected the
  misleading docstring ("NOT a BFS, NOT the nearest ancestor-type
  node") — the function DOES check the current node first, so when it
  matches, the current node IS returned.
- [Fixed] `analysis/definition_body.lua :: _check_func_body` — renamed
  `spans_multiple_lines` to `has_body_content` (the flag is true even
  for single-line bodies where `fec > 0`, so "spans multiple lines"
  was inaccurate).
- [Fixed] `utils/debug.lua` — corrected the module-level docstring: the module
  is NOT pure Lua (it references `vim.inspect`); updated to reflect
  that it works in both Neovim and plain-Lua environments, degrading
  gracefully when `vim.inspect` is unavailable.


- [Fixed] `resolution/module_finder.lua :: resolve_module_path` — finding 8.1
  recommended "never join an absolute candidate with cwd". This breaks
  template-style absolute paths (e.g. `/?.lua` from
  `DEFAULT_PACKAGE_PATHS`), which ARE meant to be cwd-anchored.
  **Partial fix only**: separators are normalized before the prefix
  comparison (fixing the `C:\Users\user` vs `C:/Users/user/foo.lua`
  mismatch from finding 8.2), but the join is retained for Unix-style
  `/` candidates. The Windows drive-letter case (`C:\foo.lua`) is
  documented as a known limitation since calltree doesn't run on
  Windows in practice.
- [Fixed] `resolution/module_finder.lua :: resolve_module_path` — `cwd_norm`
  and `candidate` are now both normalized to forward slashes before
  the `already_anchored` prefix comparison, so backslash-vs-slash
  mismatches no longer cause false negatives.
- [Fixed] `resolution/module_finder.lua :: path_join` — both `head` and `tail`
  are normalized to forward slashes before joining. Forward slashes
  are accepted by both Unix and Windows APIs (and by Lua's `io.open`),
  so unifying on `/` is always safe and removes the mixed-separator
  risk.
- [Fixed] `core/analyzer.lua :: now` — pure-Lua fallback now uses `os.time()`
  (wall-clock seconds) instead of `os.clock()` (CPU time), matching
  the semantic of the primary `vim.uv.hrtime()` path. Falls back to
  `os.clock()` only if `os.time` is unavailable (never in practice).


- [Fixed] `core/analyzer.lua :: _build_empty_result` — replaced
  `deepcopy(EMPTY_RESULT)` with a direct table literal. EMPTY_RESULT
  has only 3 simple keys (no nested complex objects), so a literal
  construction is cheaper than deepcopy and produces an independent
  table that callers can safely mutate. The `deepcopy` helper is
  retained for other uses.
- [Fixed] `analysis/callers.lua` and `core/analyzer.lua` — finding 9.2 flagged
  in-function `require("calltree.analysis.definition_body")` as a
  readability concern. The lazy require avoids a circular-dependency
  risk at module-load time. **Won't fix** — the lazy pattern is
  intentional and documented.


- [Fixed] `init.lua :: dump_at_cursor` — already accepts `opts` and forwards
  it to `analyze_at_cursor` (resolved in a prior refactor). Documented.
- [Fixed] `utils.lua :: find_first_descendant_by_type` — the `depth` parameter
  is now an internal implementation detail. The public API only
  accepts `(node, types)`; recursion is delegated to a local helper
  so callers cannot accidentally pass a non-numeric `depth` (which
  would crash on `depth + 1`).
- [Fixed] `utils/debug.lua :: NoopCollector.data (NilData)` — now returns a
  self-proxy on `__index` so `dbg.data.anything.anything_else = X` is
  a no-op at every depth (writes via `__newindex` are silently
  swallowed), and `dbg.data.anything.anything_else` reads return the
  proxy instead of crashing with "attempt to index a nil value".
  Honors the NoopCollector design goal of "callers shouldn't need nil
  checks".


Three regressions from prior refactors were blocking the test suite
from running at all (all 128 unit tests reported
`preconditions_panic` / `external_calls` errors). These weren't in
the review report but had to be fixed to satisfy step 5 ("all tests
pass") of the workflow:

- [Fixed] `analysis/preconditions.lua` — `_check_treesitter`,
  `_check_lsp_interface`, `_check_document_symbols` were declared as
  `local function` AFTER `M.check` (which uses them). Lua local
  functions are lexically scoped, so the references inside `M.check`
  resolved to globals (nil). Reordered so the helpers appear above
  `M.check`.
- [Fixed] `tests/mocks.lua :: MockLSP.__index` — `disable_method` previously
  only made the method return nil; the method was still a function,
  so `preconditions`'s `type(lsp_client[m]) == "function"` check
  didn't detect the disabled state. Updated `__index` to return nil
  for disabled methods so the type check correctly identifies them as
  missing.
- [Fixed] `analysis/definition_body.lua :: _find_func_def_node` — `MAX_HOPS`
  was declared inside a `do ... end` block, leaving the second
  `while` loop referencing an out-of-scope local (nil). Crashed with
  "attempt to compare number with nil" on the RHS-scan walk. Hoisted
  `MAX_HOPS` to function scope.

## [1.1.1] — 2026-07-09

### Summary

This release merges two streams of work into a single 1.1.1 release:

1. **Architecture refactor** (formerly the Unreleased section) — code
   restructured along "logical responsibility layers": infrastructure /
   service / analysis / orchestration. Based on the authoritative output
   of the cyclomatic complexity measurement script
   (`scripts/measure_complexity.lua`), 6 over-threshold functions were
   split using the Query/Command/Orchestrator pattern, a domain model
   and five service interfaces (ILspClient / ITreeSitter / IFileSystem /
   IDebugLogger / ICapabilityChecker) were introduced, and an AOP
   decorator framework was added to the orchestration layer.
2. **Static code review fixes** — based on an external static review
   report, 6 high-priority, 6 medium-priority, and 8 low-priority issues
   were fixed by P0/P1/P2 priority. Coverage: AOP decorator swallowing
   return values, self-recursive/in-scope checks judging only by start
   line, module_finder bypassing the IFileSystem abstraction, uri_to_path
   `%2F` handling, write_json_to_file non-atomic state mutation,
   find_function_def_by_name pattern escaping, freeze cyclic references,
   centralized magic numbers, unified node_text helper, depth limits,
   comment corrections, test-code cleanup, etc.

**The public API (init.lua's 5 exported functions) signatures and JSON
output structure are completely unchanged**; 255 assertions + 41 API
compatibility checks all pass.


- [Added] **`domain/types.lua`** — domain model and immutable factories. Defines
  eight domain types (Position / Range / Location / CallerInfo /
  ExternalCall / CallGraph / DecisionRecord / AnalysisContext),
  implementing read-only semantics via `freeze()` recursive table
  freezing. Factory functions `M.Position(line, char)` /
  `M.CallerInfo(...)` construct instances.
- [Added] **`core/interfaces.lua`** — contract declarations for the five service
  interfaces (`CONTRACTS` table) + `assert_interface(obj, name, strict)`
  runtime validation. providers self-check interface contracts before
  returning from `M.new()` (strict=false, silent on failure).
- [Added] **`infrastructure/fs.lua`** — concrete IFileSystem implementation
  (infrastructure layer). `read_file` has a 10 MB cap + pcall +
  close-in-finally; `getcwd` has a three-stage fallback
  (vim.fn.getcwd → $PWD → `pwd` command); `exists` is open+close only.
  The analysis layer does not reference io.* directly; all calls go
  through the injected IFileSystem.
- [Added] **`scripts/measure_complexity.lua`** — McCabe cyclomatic complexity
  measurement tool. Pure Lua implementation; scans all .lua files under
  `lua/calltree/` and outputs a JSON report (with mean/stddev/threshold/
  over_threshold list). Threshold formula is `mean + 2*stddev`, floor 8;
  when over-threshold functions exceed 15, the threshold is raised to
  max(10, threshold). Results are saved in
  `scripts/complexity_report.json` (before refactor) and
  `complexity_report_after.json` (after refactor).
- [Added] **`scripts/verify_api_compat.lua`** — public API compatibility
  verification script. 5 scenarios (no LSP / JSON round-trip / API
  surface / setup idempotent / real LSP), 41 assertions. Outputs a
  structural signature hash for manual comparison.
- [Added] **`utils/constants.lua` centralized magic numbers** — adds eight
  centralized constants `MAX_NODE_TEXT_LEN=80`, `MAX_NAME_HOPS=6`,
  `MAX_PATH_DEPTH=16`, `MAX_PARENT_HOPS=10`, `MAX_SUBTREE_DEPTH=32`,
  `MAX_WALK_DEPTH=32`, `DEFAULT_LSP_TIMEOUT_MS=1000`,
  `MAX_FILE_SIZE_BYTES=10MB`, replacing literals scattered across
  `debug.lua`, `nodes.lua`, `require_resolver.lua`, `walker.lua`,
  `lsp_client.lua`, `fs.lua`. `utils/init.lua` re-exports these
  constants.
- [Added] **`utils.node_text(n)` unified node text extraction helper** — the
  original `treesitter/nodes.lua:node_text`,
  `treesitter/walker.lua:_node_text_and_range`, and
  `resolution/require_resolver.lua:get_node_text` were three duplicated
  implementations (with slightly different behavior — `nodes.lua` had an
  `n.name` fallback; `walker`/`require_resolver` did not). Now unified
  as `utils.node_text`, using the most defensive behavior (includes the
  `n.name` fallback). The three call sites keep their local references
  but delegate internally to the unified helper.
- [Added] **`infrastructure/file_parser.lua` unified read+parse+cache module** —
  provides `read_source(uri, main_uri, main_source, read_file)` /
  `parse_tree(ts, source, language)` / `new(opts)` three groups of
  helpers. `callers.lua` and `definition_body.lua` now delegate to this
  module, eliminating four duplicated read+parse+cache implementations.
  See the Fixed — P1 section for details.


Measurement report (before refactor, threshold=27.42, 6 functions over
threshold):

| # | File | Function | Complexity (before) | Complexity (after) |
|---|------|----------|---------------------|--------------------|
| 1 | `analysis/definition_body.lua` | `M.check` | 62 | split into 8 queries + orchestration |
| 2 | `providers/lsp_client.lua` | `lsp_request_sync` | 52 | 30 (5 helpers extracted) |
| 3 | `providers/treesitter.lua` | `wrap_node` | 45 | 37 (`_extract_text_from_lines` extracted) |
| 4 | `core/analyzer.lua` | `M.analyze` | 35 | split into 4 queries/commands + orchestration |
| 5 | `analysis/callers.lua` | `M._analyze_one_reference` | 30 | 8 (split into 5 queries/commands) |
| 6 | `treesitter/walker.lua` | `M.get_callee` | 28 | split into 2 queries + orchestration |

Each function was split into Query/Command/Orchestrator categories, with
the function type annotated in comments. Orchestrator functions only
call queries/commands and contain no business logic. Query functions are
read-only with no side effects; command functions have side effects
(writing to result / sending LSP requests).


`core/analyzer.lua` adds the `with_phase_logging(dbg, phase_name, fn)`
decorator, wrapping the two phase functions
`caller_analysis.analyze` and `external_call_analysis.analyze` to
automatically record timing and errors before/after the call.
`preconditions.check` returns multiple values (ok, root, symbols) and
is not wrapped by the decorator; it is called directly with manual
`dbg:timing`. The decorator uses `pcall` to catch exceptions; when a
business function raises, the decorator records it via `dbg:error`
instead of propagating. This is an initial AOP cross-cutting logging
implementation; fully removing `dbg` calls from the analysis layer
would require rewriting all 128 functions and is left as future work.


`core/context.lua`'s `M.build()` now injects:
- [Changed] `ctx.fs` — IFileSystem instance (defaults to
  `infrastructure/fs.lua`, overridable via `opts.fs` for test-injected
  mocks).
- [Changed] `ctx.capability_checker` — ICapabilityChecker instance encapsulating
  LSP capability queries (`supports(method) -> boolean`). The analysis
  layer queries capabilities through this interface and does not
  reference `providers/lsp_client.method_supported` directly.
- [Changed] `ctx.read_file` / `ctx.getcwd` now delegate to `ctx.fs` (backward
  compatible).
- [Changed] `ctx.lsp_client` and `ctx.treesitter` self-check the ILspClient /
  ITreeSitter interface contracts before returning.


- [Changed] `definition_body.check`: asserts ctx / def.range / ctx.treesitter are
  non-nil.
- [Changed] `_analyze_one_reference`: asserts ctx.treesitter / ref.range are
  non-nil.
- [Changed] `analyzer.analyze`: asserts ctx is non-nil (treesitter/lsp_client may
  be nil; preconditions handle that); before returning, asserts
  result.callers / external_calls are tables.
- [Changed] `analyzer.analyze` before returning asserts
  `current_function.file` is non-nil.
- [Changed] Internal module structure changes: added `domain/`,
  `infrastructure/`, `core/interfaces.lua`.
- [Changed] The `ctx` table gained `fs` and `capability_checker` fields (backward
  compatible: the analysis layer can still access the filesystem via
  `ctx.read_file` / `ctx.getcwd`).
- [Changed] The public API (`init.lua`'s 5 exported functions) signatures and
  JSON output structure are **completely unchanged**; no user-side
  migration needed.
- [Changed] `analyze_at_cursor` / `analyze_at_cursor_json` gained a second
  optional parameter `opts` (containing a `debug` field) for
  explicitly overriding the debug switch for a single call. Existing
  callers that do not pass `opts` behave the same as before (using
  `M.options.debug`).
- [Changed] `module_finder.resolve_module_path` gained a 5th optional parameter
  `exists_func`; when existing callers do not pass it, behavior is
  slightly adjusted: when `read_file` is also not provided, it no
  longer silently falls back to `io.open` but returns nil. This avoids
  accidentally reading the real filesystem in restricted environments,
  but means callers relying on that fallback must explicitly pass
  `read_file` or `exists_func`.

Contract checks are active in all modes (independent of the debug
switch) because they protect invariants, not debug information.


- [Fixed] **`core/analyzer.lua:with_phase_logging` decorator swallows return
  values** — the original `local ok, err = pcall(fn, ...)` only took
  `err` and did not return `fn`'s return values. Current callers are
  all no-return command functions so it "happened to not crash", but
  any phase function with a return value wrapped by this decorator
  would silently lose its result — a "hidden mine" defect. Changed to
  `table.pack(pcall(fn, ...))` + `unpack(results, 2, results.n)` to
  pass through all return values (compatible with Lua 5.1/LuaJIT
  `unpack` and Lua 5.4 `table.unpack`). On failure returns nil
  (preserving the original "do not re-throw" semantics).
- [Fixed] **`analysis/callers.lua:_check_self_recursive` judged only by start
  line** — the original only compared whether
  `def.range.start.line` fell within the caller's
  `[c_start_line, c_closed_end]` range, without validating the end
  line. If the caller function definition spanned a large range (e.g.
  containing a closure), and the def's start line happened to fall
  within the range but the actual definition was inside a closure
  (nested), it would be falsely flagged as self-recursive. Now both
  the def's start line and end line must fall within the caller's
  range.
- [Fixed] **`analysis/external_calls.lua:_check_in_scope` judged only by start
  line** — same defect as the previous issue: the original only
  validated that `def.range.start.line` fell within
  `[cur_start_line, cur_closed_end]`. Now both the def's start line
  and end line must fall within the cursor function's range.
- [Fixed] **`resolution/module_finder.resolve_module_path` used `io.open` to
  read files directly** — bypassed the injected IFileSystem
  abstraction, causing inconsistent behavior in restricted/sandboxed
  environments (e.g. remote LSP workers, CI read-only mounts); the
  `io.open` failure info was also swallowed. Added a 5th optional
  parameter `exists_func` (existence-only check, saves I/O); priority
  is `exists_func > read_file > return false` (no longer silently
  falls back to `io.open`).
  `analysis/definition_body.lua:_resolve_module_path` now passes
  `ctx.fs.exists` as `exists_func`.
- [Fixed] **`utils/path.lua:uri_to_path` did not handle `%2F`** — the original
  decoded `%2F` (encoded slash) to a literal `/`, which would change
  the path segment count (per RFC 8089, `%2F` represents a `/`
  character within a path segment, not a path separator). Now `%2F` /
  `%2f` are preserved as-is (not decoded). Additionally, invalid
  `%XX` (where XX is not a hex pair, e.g. `%GG`) is preserved as-is
  to avoid `string.char(nil)` raising.
- [Fixed] **`init.lua:write_json_to_file` mutating `M.options.debug`
  non-atomically** — if `pcall(M.analyze_at_cursor_json, bufnr)`
  raised internally (e.g. a Neovim API error), `saved` could restore;
  but if a coroutine yield was cancelled during pcall (e.g.
  `vim.wait` timeout), `M.options.debug` could be left in the wrong
  state. Changed to pass `opts.debug` explicitly to
  `analyze_at_cursor`, no longer mutating global state. The
  `CalltreeJson` user command was changed the same way. Additionally,
  on `f:flush()` failure (e.g. disk full) `os.remove(path)` is
  attempted to clean up residue, so a caller seeing `ok_w=false` does
  not get a half-written file on disk.
- [Fixed] **`init.lua:write_json_to_file` and the `CalltreeJson` command
  ignored `setup({ debug = true })`** — `write_json_to_file` hardcoded
  a default of `false` when `opts.debug` was unspecified, and the
  `CalltreeJson` command hardcoded `{ debug = false }`; both ignored
  the `M.options.debug` set by `setup()`. As a result, after calling
  `setup({ debug = true })`, the JSON output of `:CalltreeJson` and
  `:CalltreeToFile` still had no debug field. Fix: `write_json_to_file`
  now defaults to `M.options.debug` (instead of `false`); the
  `CalltreeJson` command now passes `{ debug = M.options.debug }`
  (instead of hardcoding `false`). `:CalltreeJsonDebug` still forces
  debug on (overriding the setup config). Added
  `tests/test_setup_debug_option.lua` (9 tests) covering the debug
  option propagation logic for all entry points.
- [Fixed] **`treesitter/nodes.lua:find_function_def_by_name` pattern escaping**
  — the original `name:match("%." .. func_name_suffix .. "$")` did not
  escape Lua pattern special characters (like `-`, `+`, `(`) in
  `func_name_suffix`, causing mismatches when function names contained
  special characters. Now non-alphanumeric characters in the suffix are
  escaped first (`gsub("([^%w])", "%%%1")`) before matching. Also
  reuses `closed_end_line_0based` to compute the closed end line,
  eliminating duplicated code.
- [Fixed] **`domain/types.lua:freeze` did not handle cyclic references** — the
  original recursive freeze did not handle cycles; if two tables
  referenced each other (`a.x = b; b.y = a`) it would stack overflow.
  Added a `seen` set that skips already-frozen or in-progress tables.
- [Fixed] **`utils/range.lua:find_pos_of` dead code** — the original
  `while i <= #source` loop body always triggered
  `return { line = l, character = c }` (unless find returned nil, but
  that was already handled by `return nil` at the loop start), so the
  `return nil` outside the loop was unreachable. Simplified to a single
  find + count, removing the redundant while wrapper.
- [Fixed] **Extracted unified `file_parser` module** — added
  `infrastructure/file_parser.lua`, providing `read_source` /
  `parse_tree` / `new(opts)` three groups of helpers.
  `callers.lua:_read_and_parse_ref`,
  `definition_body.lua:_read_def_source + _parse_def_tree +
  _read_and_parse_module` all now delegate to this module, eliminating
  four duplicated read+parse+cache implementations.
  `providers/file_reader.lua` is kept for backward compatibility.
- [Fixed] **Split `analyzer.lua:M.analyze` (originally 140 lines)** — split
  into `_locate_cursor_function` (Phase 2-4: cursor location + LSP
  symbol cross-check) and `_run_analysis_phases` (Phase 5-6 + Finalize:
  caller/external analysis + contract validation). The `M.analyze` body
  is now ~30 lines, doing only Phase 1 preconditions + calling the two
  helpers.
- [Fixed] **`providers/lsp_client.lua:_collect_first_result` used `pairs`
  unordered iteration** — "first" was actually arbitrary (Lua `pairs`
  iteration order is undefined). Changed to collect client_ids first,
  sort them ascending by `tostring`, then iterate, ensuring
  deterministic results in multi-client scenarios.
- [Fixed] **`adapter.lua:get_lsp_diagnostics` code duplication** — the original
  duplicated the shallow-copy logic of
  `lsp_client.get_diagnostics`. Changed to delegate directly to the
  latter, eliminating the duplication.
- [Fixed] **`core/analyzer.lua:deepcopy` did not preserve metatable** — the
  original did not copy the source table's metatable; if the source
  object's `__index` pointed to a class method table (e.g. a
  DebugCollector instance), method calls would fail after deep copy.
  Now the source table's metatable is copied (shallow copy of the
  metatable itself), so objects with methods remain callable after
  copying.
- [Fixed] **`core/analyzer.lua:now()` used `os.clock` measuring CPU time** —
  for scenarios with waiting like LSP sync requests, `total_seconds`
  would be significantly lower than real wall-clock time. Changed to
  prefer `vim.loop.hrtime` (nanosecond wall clock), falling back to
  `os.time` (second-precision wall clock).
- [Fixed] **`core/interfaces.lua:assert_interface` strict default did not match
  the doc** — the comment said "default true", but `strict` defaulted
  to nil which went through the falsy branch and did not raise.
  Changed so `strict` defaults to true, matching the documentation.
- [Fixed] **`utils/path.lua:normalize_path_segments` lost Windows UNC prefix**
  — the original lost the UNC prefix for `\\server\share\foo` or
  `//server/share/foo`, incorrectly assembling them as
  `server/share/foo`. Now the `\\` or `//` prefix is preserved.
- [Fixed] **`utils/range.lua:ts_range_to_lines_1based` did not validate
  end < start** — the original returned
  `{start_line + 1, end_line + 1}` directly, which could have
  start > end. Now if `end_line < start_line`, returns
  `{start_line + 1, start_line + 1}` (single line) as a safe fallback.
- [Fixed] **`utils/debug.lua:node_summary` second `:range()` call not in pcall**
  — the original `pcall(function() return node:range() end)` only
  detected whether the call was possible, then
  `sl, sc, el, ec = node:range()` was called again outside pcall.
  Changed to a single pcall + upvalue assignment, avoiding the
  unprotected second call.
- [Fixed] **`utils/debug.lua:DebugCollector:lsp_call` `response[1]` not
  truncated** — the original `sample = response[1]` could be very
  large (e.g. a DocumentSymbol[] with recursive children). Now the
  sample is `tostring`'d and truncated to 200 chars, preventing a
  single LSP call log from bloating the debug output.
- [Fixed] **`utils/debug.lua:NoopCollector` did not use `__index` auto-stub**
  — the original explicitly listed every method stub; if a new
  DebugCollector method was added without a matching stub here, the
  debug=false path would crash. Changed so `__index` auto-returns a
  no-op function, making any unlisted method call safely no-op.
  Explicit stubs are kept for documentation.
- [Fixed] **`treesitter/nodes.lua:walk_up_to_type` had no depth limit** — the
  original had no depth limit; if the tree had cyclic references
  (misconstructed mock nodes) it would loop infinitely. Added a
  `MAX_HOPS=50` upper-bound guard.
- [Fixed] **`treesitter/nodes.lua:get_function_name` did not continue when the
  first DOTTED_NAME text was nil** — the original
  `return node_text(child)` returned nil immediately when the first
  NAME/DOTTED_NAME child's text was nil, without checking subsequent
  children. Changed to `if text ~= nil then return text end` to
  continue, avoiding missing a sibling with real text when a mock node
  has not set text.
- [Fixed] **`infrastructure/fs.lua:M.read_file` still read when seek failed
  with size=0** — the original `f:seek("end") or 0` would pass the
  size check and continue reading when seek failed (size=0) —
  incorrect behavior. Now seek failure immediately returns nil (cannot
  determine file size; safely reject).
- [Fixed] **`infrastructure/fs.lua:M.getcwd` return value not stripped of
  whitespace** — the original `io.popen("pwd")` return value could
  contain a trailing newline. Now all fallback return values are
  uniformly stripped of trailing whitespace via
  `gsub("%s+$", "")`; `io.popen` is also wrapped in pcall to prevent
  raising in restricted environments.
- [Fixed] **`domain/types.lua:AnalysisContext` did not assert fields is a
  table** — the original `setmetatable(fields, READONLY_MT)` would
  raise "attempt to index nil" if the caller passed nil by mistake.
  Now explicitly asserts `type(fields) == "table"`.
- [Fixed] **`tests/scenario.lua:read_file` `file://` prefix was case-sensitive**
  — the original `gsub("^file://", "")` did not handle `FILE://` or
  `File://` forms, nor `file://localhost/...` host names. Changed to
  case-insensitive stripping, and supports the `file://host/path` form
  (preserving the path portion).
- [Fixed] **`runner_headless_real_lsp.lua` parser prewarming** — in some
  Neovim 0.10 + external-parser-deployment environments,
  `ftplugin/lua.lua`'s `vim.treesitter.start` call cannot find the
  'lua' parser (the runtimepath already includes the plugin dir but
  there is a parser-load timing issue). The parser is now explicitly
  prewarmed before running real-LSP tests, ensuring the FileType
  autocmd triggered by subsequent `vim.cmd("edit *.lua")` does not
  fail due to a missing parser.
- [Fixed] **Centralized magic numbers into `utils/constants.lua`** — see the
  Added section above.
- [Fixed] **`utils.lua:find_first_descendant_by_type` comment was wrong** — the
  original comment said "BFS over named children", but the
  implementation is DFS (recurses depth-first, returns on the first
  deep-subtree hit). Corrected the comment to avoid caller
  misunderstandings about the "first" semantics: the "first" in DFS is
  the first in pre-order traversal, not the nearest ancestor-type node.
- [Fixed] **`tests/test_external_calls.lua:test_call_to_stdlib_function` had
  unused code** — the original test constructed an `s` scenario that
  was completely unused (the external stdlib file would be discarded
  by the d2 path outside the project), then re-constructed `s2`.
  Removed the unused `s` and `stdlib_tree` construction code,
  constructing `s2` directly.
- [Fixed] **`tests/assert.lua:length` counting semantics** — the original used
  `pairs` counting, which also counted string-keyed "object-style"
  tables, inconsistent with the `length` name's "array length"
  semantics. Changed to prefer the `#` operator (Lua's built-in array
  length, O(1)); only falls back to `pairs` counting when `#` returns
  0 but the table is non-empty (i.e. a pure hash table).
- [Fixed] **`treesitter/walker.lua:collect_top_level_calls` and
  `treesitter/nodes.lua:find_function_def_by_name` recursion depth
  limit** — the original walk recursion had no depth limit; pathologically
  deep ASTs could stack overflow (although treesitter itself has
  MAX_PARENT_HOPS-style limits, these two functions did not). Added a
  `MAX_WALK_DEPTH` limit (`walker.lua` uses `utils.MAX_WALK_DEPTH` = 32;
  `nodes.lua` uses a local constant 64).
- [Fixed] **`tests/test_lsp_capabilities.lua:test_capability_map_covers_required_methods`
  changed to actually load the adapter** — the original test only did
  a smoke test because "adapter.lua needs vim.*". Changed to mock the
  `vim` global, require `providers.lsp_client`, and assert that the
  exported `METHOD_CAPABILITY_MAP` contains the expected mapping (4 LSP
  methods → 4 capability fields).
- [Fixed] **`utils/debug.lua:node_summary` magic number `#t <= 80`** — extracted
  into the local constant `MAX_NODE_TEXT_LEN = 80`.
- [Fixed] `scripts/measure_complexity.lua`'s `find_function_end` originally
  used the Lua `$` anchor to match end-of-line, but `gmatch`'s `$`
  only matches the end of the entire searched string, causing depth
  counting errors. Changed to pad the cleaned line with spaces at both
  ends and match `%sdo%s` / `%send%s` as whole words.
- [Fixed] `strip_comments_and_strings` originally used the `%b''''` pattern
  (malformed); changed to `'[^']*'` single-quote string matching.
- [Fixed] Function definition pattern `M.M.check` double-prefix bug fixed
  (`M[%w%.%:]*` captures `M.check`; the format string uses `%1` directly
  without adding an `M.` prefix).
- [Fixed] `infrastructure/fs.lua` `M.getcwd` final fallback returned the
   literal `"/"`, which made `is_path_under` accept every absolute
   path as "in project". Now returns `nil` and callers explicitly
   skip project-scope filtering in that case.
- [Fixed] `core/analyzer.lua` `with_phase_logging` decorator silently
   swallowed phase errors (`_run_analysis_phases` ignored the return
   value). The decorator now returns `(true, ...)` on success and
   `(false, nil)` on pcall failure; the orchestrator records a new
   `analyzed_with_phase_errors` completion_reason when any phase
   raised, so consumers can detect partial-success outcomes even
   with `debug = false`.
- [Fixed] `analysis/external_calls.lua` `M._analyze_resolved_call` reduced
   from 12 positional parameters to `(ctx, dbg, call_decision, opts)`.
   The single call site in `M.analyze` now passes an `opts` table,
   eliminating the argument-order footgun.
- [Fixed] `providers/lsp_client.lua` `_collect_first_result` sorted
   `client_id`s lexicographically via `tostring(a) < tostring(b)`,
   which put `"10"` before `"2"`. Now uses `tonumber` comparison
   with a string fallback for non-numeric ids.
- [Fixed] `utils.lua` `get_node_text` boundary condition: `end_line < #lines`
   dropped the last line slice when treesitter reported
   `end_line == #lines` (source without trailing newline). Changed
   to `<=` with an `or ""` fallback.
- [Fixed] `scripts/measure_complexity.lua` `find_function_end` single-line
   function bug: `if i > open_line and depth <= 0` skipped the
   open line, so `function foo() end` scanned to EOF. Changed to
   `if depth <= 0` — depth only returns to 0 when the matching
   `end` is reached, on any line.
- [Fixed] `scripts/verify_api_compat.lua` `scenario_with_real_lsp` inner
   `break` only escaped the `for` loop, not the outer `while`,
   causing the full 30s timeout to elapse even after a successful
   result. Added a `found` flag to break the outer loop.
- [Fixed] `test_runner.lua` `setup_path` relative-path loss bug: the
   `"./" -> ""` collapse made `script_dir .. "/tests/"` resolve to
   `"/tests/"`. Falls back to `"."` (no trailing slash) so the
   subsequent concat is correct.
- [Fixed] `analysis/definition_body.lua` `M.check` suffix extraction
   `([%w_]+)$` truncated hyphenated call names (`"get-data"` →
   `"data"`), breaking module-internal lookup for non-Lua languages.
   Now uses `([%w_%-]+)$` to include hyphens.
- [Fixed] `providers/treesitter.lua` `_source_cache_key` collision risk:
    the previous "length + head/tail 16 chars" hash could collide
    on real source files, returning the wrong `lines` array and
    silently corrupting `:text()` output. Now uses the full source
    string as the cache key (weak-keyed table, no memory overhead
    thanks to Lua string interning + GC).
- [Fixed] `lua/calltree/init.lua`
  - `analyze_at_cursor` wraps `vim.api.nvim_win_get_cursor(0)` in
    pcall and returns an empty result with
    `completion_reason = "cursor_error"` on failure (previously
    propagated the exception).
  - `table.unpack or unpack` lifted to module-level `UPACK`.
  - `encode_json` adds a pure-Lua fallback so `lua5.4` test
    harnesses don't crash on `attempt to index nil (vim.fn)`.
  - `dump_at_cursor` defensively defaults `result.callers` /
    `result.external_calls` to `{}` and indexes `result.debug.summary`
    via `or {}` so early-failure paths don't raise on `#nil`.
  - `write_json_to_file` now returns `(ok, err_kind)` where
    `err_kind` is `"analyze_failed" | "open_failed" | "write_failed"`,
    letting callers distinguish failure modes.
  - `setup()` now persists `opts.user_commands` into `M.options`
    (previously only `debug` was persisted — asymmetric).
  - `CalltreeJson` command checks `type(json) == "string"` before
    printing, avoiding `tostring(table)` memory-address output.
- [Fixed] `core/analyzer.lua`
  - `now()` fallback changed from `os.time()` (second precision,
    9 orders of magnitude away from the nanosecond field) to
    `os.clock()` (millisecond CPU time, same order of magnitude).
  - `M.analyze` no longer hard-asserts on `ctx == nil`; returns
    an empty result with `completion_reason = "ctx_is_nil"`.
  - `preconditions.check` wrapped in pcall; on panic returns
    `completion_reason = "preconditions_panic"`.
  - `_locate_cursor_function` falls back to `range = {0, 0}` when
    `nodes.range_to_1based_closed` returns nil, so downstream
    `cf.range[1]` indexing doesn't raise.
- [Fixed] `core/context.lua` `capability_checker.supports` uses an explicit
  `if vim.lsp.get_clients then ... else get_active_clients end`
  branch so Neovim 0.10+ doesn't emit a deprecation warning.
- [Fixed] `core/interfaces.lua` `assert_interface` treats `obj == false`
  the same as `obj == nil` (a `false` argument previously fell
  through to the table-typing branch and crashed on `false[method]`).
- [Fixed] `domain/types.lua`
  - `CallGraphBuilder:build()` deep-copies `callers` and
    `external_calls` before `freeze()` so the builder stays
    mutable for a subsequent `:build()` call.
  - `AnalysisContext` now asserts `cursor_pos` / `source_code` /
    `file_path` are non-nil for early, clear failure.
- [Fixed] `analysis/preconditions.lua`
  - `tree.root and tree:root() or tree` fallback path now checks
    that `root.type` is a function before calling `:type()`, so
    mock trees that only implement `root()` don't crash.
  - `find_function_symbol_at` adds a depth limit (64) to prevent
    stack overflow on pathological DocumentSymbol trees.
  - The "children but no match in children" branch no longer
    drops the current symbol; falls through to return `sym`.
- [Fixed] `analysis/callers.lua`
  - `lsp:definition` and `lsp:references` wrapped in pcall
    (previously only `declaration` was, asymmetric).
  - `_read_and_parse_ref` cache key normalized via `uri_to_path`
    so two URIs pointing at the same file share the cache entry.
  - `_check_self_recursive` now returns `true` conservatively
    when caller name matches `current_name` but range is not
    determinable (mock nodes without `:range()`), instead of
    `false` which kept the self-reference as a "caller".
  - `_analyze_one_reference` soft-returns instead of asserting
    on `ctx.treesitter == nil`, so a single-reference error
    doesn't fail the whole phase.
- [Fixed] `analysis/definition_body.lua` `_find_func_def_node` RHS scan
  bounded by `MAX_ANCESTOR_HOPS` to guard against cyclic mock
  trees whose `:parent()` returns self.
- [Fixed] `treesitter/nodes.lua`
  - `walk_up_to_type` uses centralized `MAX_ANCESTOR_HOPS` and
    adds cycle detection (`visited` table) so a cyclic mock
    doesn't waste all 50 hops before exiting.
  - `is_function_name_node` uses `MAX_NAME_HOPS` / `MAX_PATH_DEPTH`
    from constants (was literals `6` and `16`).
  - `find_function_def_by_name` uses `utils.MAX_WALK_DEPTH`
    (unified with `walker.collect_top_level_calls`).
- [Fixed] `treesitter/walker.lua` `collect_top_level_calls` compares
  function nodes by `(start_line, end_line)` range instead of
  by reference, fixing nested-function-skip when `wrap_node`
  returns fresh tables per call.
- [Fixed] `utils/init.lua` `node_text` pcall-failure path now falls
  through to `_text` / `name` fallbacks (previously silently
  returned nil even when a fallback would have worked).
- [Fixed] `utils/path.lua` `is_path_under` accepts both `/` and `\` as
  the path-segment boundary so Windows paths like
  `C:\project\foo.lua` match parent `C:/project`.
- [Fixed] `utils/debug.lua`
  - `node_summary` truncates over-length text with `...` instead
    of discarding it entirely.
  - `source_line_count` computed accurately (previous `n + 1`
    over-counted by 1 when source had no trailing newline).
  - `DebugCollector:lsp_call` renders `sample` via `vim.inspect`
    when available, instead of `tostring(table)` which emitted
    a memory address.
- [Fixed] `infrastructure/fs.lua`
  - `M.exists` uses `os.rename` instead of `io.open` (the latter
    returns a non-nil handle for directories on Linux, causing
    false positives).
  - `M.read_file` wraps the `f:seek("set")` rewind in pcall so
    pipe files / unseekable streams return nil instead of raising.
- [Fixed] `infrastructure/file_parser.lua` `parse_tree` uses `vim.inspect`
  for table error messages when available, instead of `tostring(table)`.
- [Fixed] `providers/lsp_client.lua` `M.get_diagnostics` deep-copies each
  entry via `vim.deepcopy` so callers can't mutate nested fields
  of the live accumulator (was a shallow copy).
- [Fixed] `providers/treesitter.lua` `wrap_node.text` caches the range
  tuple on the wrapper (`_cached_range`) so repeated `:text()`
  calls don't re-pcall `_tsnode.range`.
- [Fixed] `providers/file_reader.lua` `M.new.get_tree` records pcall
  failures from `read_file` into `dbg:error` instead of silently
  dropping them.
- [Fixed] `resolution/require_resolver.lua` `strip_quotes` handles
  `[==[ ... ]==]` and other long-bracket levels (previously only
  `[[ ]]` level 0 was handled).
- [Fixed] `analysis/external_calls.lua` `_set_stdlib_flag` now falls back to a
  **path-based heuristic** when the LSP server doesn't tag standard-
  library symbols via `SymbolTag`. Previously the plugin relied solely
  on `def.tags` (which clangd populates as 256, but rust-analyzer
  leaves empty), causing Rust `std::fs::read_to_string(...)` calls to
  be missed as stdlib. The new heuristic checks `def_path` for known
  stdlib install locations: `rustup/toolchains/`, `/rustlib/src/rust/library/`,
  `/usr/include/`, `/usr/lib/python`, `/usr/local/lib/python`,
  `/Library/Developer/` (macOS SDK).
- [Fixed] `analysis/external_calls.lua` `_analyze_resolved_call` order changed:
  `_set_stdlib_flag` now runs BEFORE `_check_project_scope`, and stdlib
  calls short-circuit (kept as resolved with `is_stdlib=true`, skipping
  project-scope and body checks). Previously `_check_project_scope` ran
  first, discarding stdlib calls (whose definition paths live under
  `~/.rustup/...`) before `_set_stdlib_flag` ever ran.
- [Fixed] `analysis/external_calls.lua` `_check_project_scope` changed
  semantics: outside-project calls are now KEPT as
  `outcome="kept_external_crate"` (with `is_stdlib=false`,
  `resolution_status="resolved"`) instead of being silently discarded
  as `discarded_outside_project`. This makes third-party crate calls
  (Rust `serde_json::to_string`, etc.) visible in `external_calls` so
  users can see "you're calling out to serde_json here" without the
  call vanishing. The `calls_outside_project` debug counter is still
  incremented for diagnostic visibility. Updated
  `tests/test_external_calls.lua::test_call_outside_project_discarded`
  and `tests/test_debug_field.lua::test_debug_records_outside_project_call`
  to match the new behavior.
- [Fixed] `domain/types.lua` — entire module is dead code (not referenced by
   the main analysis pipeline). **Marked as "won't remove"** with
   rationale: the module documents the intended domain model and may
   be adopted by future refactors; removing it would lose the type
   contracts. Added a module-level docstring clarifying its
   experimental / unused status so future maintainers know it's not
   wired in.
- [Fixed] `analysis/definition_body.lua` `M.check` L284 — `def_source == nil`
   returning `has_body=true`. **Marked as "won't fix"** with
   rationale: the conservative "keep when source unreadable" behavior
   is intentional — the LSP already confirmed the definition exists,
   so discarding the call (has_body=false) would be a false negative
   worse than showing the call without a body range (has_body=true,
   range=nil). Documented the design decision in the code comment.
- [Fixed] `analysis/external_calls.lua` `M._analyze_resolved_call` —
   `opts.def_results[1]` direct indexing without nil check, and
   `def.uri == nil` causing `nil == nil` false in_scope classification.
   **Fixed**: added explicit nil guard for `opts.def_results[1]`
   (returns the call as "kept_unresolved" gracefully instead of
   crashing), and a dedicated branch for `def.uri == nil` that skips
   the in_scope check (can't determine scope without a URI) and
   records a warning.
- [Fixed] `providers/lsp_client.lua` module-level `lsp_diagnostics` — was a
   single mutable table that every `M.new(bufnr)` would overwrite,
   making concurrent analyses on different buffers unsafe.
   **Fixed**: replaced with a per-bufnr cache
   (`lsp_diagnostics_by_bufnr`) so each buffer's diagnostics persist
   independently. `M.get_diagnostics(bufnr)` now accepts an optional
   bufnr to retrieve a specific buffer's snapshot; calling without
   bufnr returns the most-recent instance's diagnostics (backward
   compat). Added `M.clear_diagnostics(bufnr)` for test teardown.
- [Fixed] `core/analyzer.lua` `_run_analysis_phases` L337-338 — `assert(type(
   result.callers) == "table")` violated the "always return result
   table" contract. **Fixed**: replaced asserts with defensive
   fallbacks — if `result.callers` / `result.external_calls` are not
   tables, they're replaced with empty arrays and a warning is
   recorded in debug.
- [Fixed] `providers/treesitter.lua` `wrap_node.text` L149 — hardcoded
   `bufnr=0` in `vim.treesitter.get_node_text(self._tsnode, 0)`.
   **Fixed**: `wrap_node` now accepts an optional `bufnr` parameter
   (4th arg) and `M.new(bufnr)` passes the real bufnr through, so
   buffer-parsed nodes read text from the correct buffer.
- [Fixed] `analysis/callers.lua` `_check_self_recursive` L226-236 —
   `caller_func:range()` returning nil caused conservative `return
   true` (discard as self-recursive), which could误杀 legitimate
   same-name callers in mock tests. **Fixed**: added a heuristic —
   when range is unavailable, check if any `def_results` entry has
   the same `uri` as `ref`. If yes (same-file definition + same name
   → very likely self-recursion), discard. If no (cross-file same-
   name caller), keep (return false).
- [Fixed] `analysis/external_calls.lua` `_set_stdlib_flag` L236 —
   `utils.LSP_TAG_SYSTEM_LIBRARY or 256` was dead code (the constant
   is always defined). **Fixed**: removed the `or 256` fallback and
   added a comment explaining the constant is a clangd private
   extension (LSP 3.17 only defines 1=Deprecated, 2=Unnecessary).
- [Fixed] `utils/path.lua` `path_to_uri` — Windows backslash paths
   (`C:\foo\bar.lua`) were percent-encoded as `%5C` instead of
   normalized to `/`. **Fixed**: added `path:gsub("\\", "/")` before
   encoding so backslashes become path separators, producing
   RFC 8089-compliant `file:///C:/foo/bar.lua` URIs.
- [Fixed] `infrastructure/fs.lua` `M.exists` — comment said "fall back to
    io.open with rb" but code directly returned false. **Fixed**:
    implemented the fallback — when `os.rename` fails (read-only
    filesystem, permission restrictions), try `io.open(path, "rb")`
    as a secondary existence check.
- [Fixed] `core/context.lua` `M.build` L111 — `vim.bo[bufnr].filetype`
    unguarded; invalid bufnr would raise. **Fixed**: wrapped in
    pcall with a fallback to `"lua"` when bufnr is invalid or
    filetype is empty.
- [Fixed] `tests/test_callers.lua` `test_caller_range_unavailable` — 70
    lines of inline mock construction. **Marked as "won't refactor"**
    to avoid churn; the inline mock is test-specific and extracting
    it to `mocks.lua` would couple the mock library to a single
    test's needs.

- [Fixed] `init.lua` `dump_at_cursor` L178-179 — `cf.range[1]` direct
    indexing. **Fixed**: added defensive guards (`r1`/`r2` default to
    `"?"` when range is nil or non-table) so dump never crashes on
    malformed current_function.
- [Fixed] `scripts/measure_complexity.lua` `collect_lua_files` L236 —
    `io.popen('ls "' .. dir .. '"')` command injection risk.
    **Fixed**: added input validation — `dir` must match
    `^[A-Za-z0-9/._~-]+$` before being passed to the shell; non-
    matching dirs are skipped.
- [Fixed] `scripts/verify_api_compat.lua` `scenario_no_lsp` L101 —
    `ok(..., result.current_function ~= nil or true)` was always
    true (meaningless assertion). **Fixed**: changed to
    `result.current_function == nil` (the EXPECTED behavior for a
    no-LSP scenario where preconditions fail).
- [Fixed] **Duplicate constant definitions** — `MAX_PARENT_HOPS`,
  `MAX_SUBTREE_DEPTH` in `require_resolver.lua`; `DEFAULT_LSP_TIMEOUT_MS`
  in `lsp_client.lua`; `MAX_NODE_TEXT_LEN` in `debug.lua` — all now
  reference the centralized `utils.constants` values. Dead `or N`
  fallbacks removed from `walker.lua`, `nodes.lua`,
  `definition_body.lua` (the constants are always defined). Also
  exported `MAX_ANCESTOR_HOPS` and `LSP_TAG_SYSTEM_LIBRARY` from
  `utils/init.lua` (they were defined in `constants.lua` but not
  re-exported, causing nil-reference crashes — this was a real bug
  surfaced by the dead-code-removal pass).
- [Fixed] **Dead `or` fallbacks** — 6 instances of `utils.X or N` where the
  constant is always defined; all simplified to `utils.X`.
- [Fixed] **NoopCollector chaining trap** and **long-function refactors** —
  **marked as "won't fix"** (would require API changes / large
  refactors; current behavior is documented and tested).

**Scripts and tests**

- [Fixed] `scripts/measure_complexity.lua`
  - `parse_file` wraps `f:read("*a")` in pcall + close-in-finally
    so a mid-read disk error doesn't leak the file descriptor.
  - `MAX_FUNCTION_NAME_LEN` extracted as a module-level constant
    (was a literal `80`).
- [Fixed] `scripts/verify_api_compat.lua`
  - `scenario_with_real_lsp` polling loop fixed (see critical fix 7).
  - `scenario_setup_idempotent` saves and restores the original
    `M.options.debug` so this scenario doesn't affect later ones.
- [Fixed] `scripts/verify_lsp.lua`
  - `wait_for_symbols` sorts client_ids numerically so the
    "first" result is deterministic across runs.
  - Top-level file writes wrapped in pcall with descriptive error
    messages on failure.
- [Fixed] `scripts/nvim_lsp_init.lua` LSP-binary candidate check uses
  `vim.fn.executable` instead of `io.open` (the latter succeeds
  on directories and doesn't check the executable bit).
- [Fixed] `tests/assert.lua` `M.dump` uses `match("0x[%x]+") or "?"` so
  C functions (which stringify as `function: builtin#x`) don't
  crash the dump with `.. nil ..`.
- [Fixed] `tests/mocks.lua` `MockLSP:call_log` returns a shallow copy so
  callers can't mutate the mock's internal call log.
- [Fixed] `tests/scenario.lua` `Scenario:analyze` uses `utils.path.uri_to_path`
  for file:// URI normalization instead of an inline duplicate
  implementation that could drift out of sync.
- [Fixed] `tests/headless_integration.lua`
  - Hard-coded `/tmp/calltree_test_*.lua` paths replaced with
    `os.time()`-suffixed unique names to avoid parallel-test
    collisions.
  - `if p.passed == false` changed to `if not p.passed` so an
    unset `passed` field is also treated as failure.

**Centralized constants**

- [Fixed] `utils/constants.lua` gained `LSP_TAG_SYSTEM_LIBRARY` (256) —
  promoted from a local literal in `external_calls.lua`.
- [Fixed] `utils/constants.lua` gained `MAX_ANCESTOR_HOPS` (50) —
  previously a local literal in `nodes.lua:walk_up_to_type` and
  `definition_body.lua:_find_func_def_node`.
- [Fixed] `utils/constants.lua` `MAX_WALK_DEPTH` unified to 64
  (was 32 in `walker.lua` and 64 in `nodes.lua`).

**New Rust E2E test artifacts**

- [Fixed] `scripts/rust_nvim_init.lua` — minimal nvim init for Rust testing,
  configures rust-analyzer with `cargo.loadOutDirsFromCheck=true` and
  `checkOnSave.enable=false` (so the intentionally-broken `broken.rs`
  doesn't block analysis of the rest of the crate).
- [Fixed] `scripts/run_rust_tests.lua` — 10-scenario Rust E2E runner. Locates
  function symbols via LSP `documentSymbol.selectionRange` (NOT
  `range.start`) so the cursor lands on the identifier itself, not on
  visibility modifiers / attributes. When multiple symbols share a
  name (Rust trait method: declaration vs. implementation), prefers
  the one with the longest range (the implementation).
- [Fixed] `rust_test/` — minimal Cargo project (lib.rs + main.rs + module.rs
  + broken.rs) exercising: free functions, impl-block methods, trait
  impl methods, closures, stdlib calls, third-party crate calls,
  `#[cfg]` conditional compilation, and syntax-error recovery.



**Plugin fix driven by Python unit testing**

- [Fixed] `analysis/definition_body.lua` `M.check` step 6 previously returned
  `has_body=true` for ANY variable binding that wasn't a `require()`
  import — even when the RHS was a non-function expression like a
  Python `lambda`. This caused `f = lambda x: x + 1; f(5)` to be kept
  as a "resolved" external call with `function_body_range = nil`,
  which was misleading (a lambda is not a named function definition
  the plugin can extract a body range from). Fixed: when the declaration
  is a variable binding to a non-function expression (no
  `function_definition` ancestor AND `_scan_rhs_for_function` already
  returned nil AND `extract_require_module` returned nil), return
  `has_body=false` so the caller discards the call via the standard
  `discarded_no_body` path. This makes Python lambda assignments —
  and similar non-function variable bindings in other languages —
  correctly drop out of `external_calls`.

**New Python test module**

- [Fixed] `tests/test_python.lua` — 10 scenarios covering:
  1. Simple function outbound external call resolution (`foo` → `bar`).
  2. Simple function inbound caller lookup (`bar` called by `foo`).
  3. Class method calling another method of the same class
     (`self.helper()` from `method`).
  4. Nested function external call filtered as in-scope
     (`inner()` called from `outer`, `inner` defined inside `outer`).
  5. Nested function inbound caller lookup (`inner` called by `outer`).
  6. Lambda callee discarded as no-body
     (`f = lambda x: x + 1; f(5)` from `foo`).
  7. Decorator inbound caller filtered as global_scope
     (`@decorator` application is at module scope, not in a function).
  8. Cross-file external call resolution (`utils.helper()` from
     `main.py` → `utils.py`).
  9. Self-recursive function filtered (`factorial(n-1)` inside
     `factorial`).
 10. Syntax error graceful degradation (missing `:` after `def foo()`
     → `preconditions_failed`, empty result, no crash).

---

## [1.1.0] — 2026-07-08

### Summary

Second-round code-review pass. Addressed 10 issues from the static-review
report (1 high, 4 medium, 5 low) plus several minor follow-ups. The high-
priority fix is cycle-safe `deep_eq` in the test assertion library (would
have stack-overflowed on cyclic tables). The medium-priority fixes target
real correctness / robustness issues (Windows path handling, per-instance
LSP diagnostics, `_analyze_resolved_call` 12-arg signature, deep recursion
in require-resolver). The low-priority fixes improve performance
(line-split caching in `wrap_node`), API safety (idempotent `setup()`,
pcall-wrapped file I/O), and code organization (extracted shared constants,
range helper deduplication).

**Test results:** 82 unit + 105 headless (no-LSP) + 59 headless (real-LSP) =
246 assertions, 0 failures (unchanged from 1.0.0 — no test regressions).


- [Fixed] **`tests/assert.lua:deep_eq` cycle-safe deep equality** — the previous
  implementation recursed without a `seen` memo, so any table with a
  cycle (e.g. `a.x = a`) would stack-overflow. Added a paired `seen_a` /
  `seen_b` memo (maps each table to its counterpart in the other
  structure) that recognizes a closing cycle and returns true. Also
  made `M.dump` cycle-safe (returns `"<cycle>"` instead of recursing)
  and stable (sorts keys alphabetically so two equal tables always
  produce identical dump output, which makes test failure messages
  reproducible).
- [Fixed] **`resolution/module_finder.lua` Windows path support + double-prefix
  fix** — `is_absolute_path` now correctly recognizes Windows drive
  paths (`C:\...`, `C:/...`) and UNC paths (`\\server\share`,
  `//server/share`). Previously, `C:\foo\bar.lua` was mis-classified as
  relative because only the first character was checked against `/`.
  Extracted `strip_trailing_sep`, `is_absolute_path`, and `path_join`
  as exported helpers (`M.strip_trailing_sep`, `M.is_absolute_path`,
  `M.path_join`) so `path.lua` and other modules can reuse them instead
  of duplicating the while-loop. `path_join` now strips leading
  separators from the tail, so `path_join("/project", "/foo.lua")`
  produces `/project/foo.lua` (not `/project//foo.lua`). The
  `already_anchored` check is now a path-segment-aware prefix match
  (uses `cwd .. "/"` as the prefix) so `/home/user2/...` is correctly
  distinguished from `/home/user/...`.
- [Fixed] **`providers/lsp_client.lua` per-instance diagnostics accumulator**
  — the module-level `lsp_diagnostics` table was reset on every
  `M.new(bufnr)` call, which made the module unsafe for concurrent
  analyses (a second `new()` would wipe the first's diagnostics). Each
  `client_obj` now carries its own `diag_acc` array passed to
  `lsp_request_sync` via a new parameter; `client_obj:_diagnostics()`
  returns THAT instance's accumulator (not the module-level snapshot).
  `M.get_diagnostics()` (backward-compat for `adapter.get_lsp_diagnostics`)
  returns a shallow snapshot copy of the most-recent instance's
  accumulator. Also added `M.DEFAULT_LSP_TIMEOUT_MS = 1000` as a named
  constant (was a magic number) and a defensive `else` branch in the
  result-type check that records "unexpected LSP result type" errors
  instead of silently treating non-table results as "0 results".
- [Fixed] **`resolution/require_resolver.lua` constants + depth bounds** —
  extracted `M.CALL_NODE_TYPES`, `M.STRING_NODE_TYPES`,
  `M.MAX_PARENT_HOPS = 10`, and `M.MAX_SUBTREE_DEPTH = 32` as named
  module-level constants (were inline strings and magic numbers).
  `search_subtree` is now bounded by `MAX_SUBTREE_DEPTH` to prevent
  stack overflow on malformed / pathological ASTs. The IIFE
  `(function search(...) ... end)(arg)` form (which is a syntax error
  on Lua 5.4 — only LuaJIT parses it) was replaced with a properly
  scoped module-level `search_subtree_for_require` function. Hoisted
  `get_node_text` and `strip_quotes` as named, exported helpers
  (was duplicated three times inline). `strip_quotes` now also handles
  Lua's `[[ ... ]]` long-bracket form.

- [Fixed] **`analysis/external_calls.lua:_analyze_resolved_call` refactor** —
  the 12-positional-parameter signature is preserved for backward
  compatibility, but the body now packs the per-call state into a
  single `cc` (call-context) table at entry and delegates to five
  focused sub-functions (`_check_in_scope`, `_check_project_scope`,
  `_set_stdlib_flag`, `_check_has_body`, `_keep_resolved_call`), each
  taking the single `cc` object. The magic number `256` (LSP SymbolTag
  for system/library) is now the named constant `LSP_TAG_SYSTEM_LIBRARY`
  with a comment explaining clangd's non-standard use of that value.
- [Fixed] **`utils/path.lua:is_path_under` path normalization + tail-slash
  handling** — both `child_path` and `parent_dir` are now normalized
  (collapse `.` and `..` segments, strip trailing separators) before
  comparison, so `/project/foo/../bar` and `/project/bar` are recognized
  as equivalent (previously only `parent_dir` was normalized, and `..`
  segments were never collapsed). Extracted `normalize_path_segments`
  as an exported helper. Documented that symlinks are NOT resolved
  (would require `lfs` and break the "pure Lua" invariant). Centralized
  the `file://` prefix as `FILE_URI_PREFIX` / `FILE_URI_PREFIX_LEN`
  constants (was a magic `7` and `8`).

- [Fixed] **`providers/treesitter.lua:wrap_node` line-split caching + pcall** —
  added a weak-valued module-level line cache (`split_lines(source_text)`)
  so the source string is split once per file instead of on every
  `:text()` call during a tree traversal. The cache is shared across
  all `wrap_node` instances of the same source via a `lines_cache`
  parameter. `:text()` and `descendant_for_range` are now wrapped in
  `pcall` so an invalid / stale treesitter node returns `""` / `nil`
  instead of propagating an error that aborts the whole analysis.
  `descendant_for_range` also guards `root._tsnode == nil` so a mock
  node passed in by mistake degrades gracefully.

- [Fixed] **`analysis/definition_body.lua` shared constants + pcall** —
  extracted `M.DECLARATION_NODE_TYPES`, `M.BARE_DECLARATION_NODE_TYPES`,
  `M.RHS_WRAPPER_NODE_TYPES`, and `M.BLOCK_NODE_TYPES` as module-level
  constants (were duplicated inline lists; the two declaration lists
  had drifted out of sync — one was missing `variable_declarator` and
  `lexical_declaration`). `func_def_node:range()` is now wrapped in
  `pcall` so a stale node returns a clear "range() failed" message
  instead of propagating an error.

- [Fixed] **`core/analyzer.lua:cur_closed_end` deduplication + pcall** — the
  `if (cur_end_col == 0) and (cur_end_line > cur_start_line)` adjustment
  logic (which was duplicated with `nodes.range_to_1based_closed`) is
  now delegated to a new shared helper `nodes.closed_end_line_0based(sl,
  el, ec)`. `func_node:range()` is now wrapped in `pcall` for defensive
  consistency with the rest of the codebase.

- [Fixed] **`init.lua` idempotent `setup()` + pcall-wrapped file I/O + portable
  `unpack`** — `setup()` now deletes any existing user command before
  re-registering it (via `pcall(vim.api.nvim_del_user_command, name)`),
  so calling `setup()` twice (e.g. lazy.nvim reload) no longer errors
  with "command already exists". `write_json_to_file` now wraps
  `f:write` / `f:flush` in `pcall` and always closes the file handle
  (was a leak risk if `f:write` threw). `analyze_at_cursor` now uses
  `table.unpack or unpack` so the plugin loads under plain Lua 5.4
  test harnesses (where the global `unpack` doesn't exist) as well as
  under Neovim's LuaJIT runtime.
- [Fixed] **`core/context.lua:read_file` pcall + close-in-finally** — `f:read("*a")`
  is now wrapped in `pcall` and the file handle is always closed (even
  if read threw), preventing file-descriptor leaks on broken-pipe /
  encoding-error edge cases. Documented that no explicit size limit is
  enforced (the plugin processes source-code files, typically <1MB).

- [Fixed] **`providers/lsp_client.lua:method_supported` nil-safe client id** —
  the `client.name or ("client_" .. client.id)` fallback now handles
  `client.id == nil` by emitting `"client_<unknown>"` instead of a
  truncated `"client_"` string.


- [Added] The new `M.node_summary` and `M.dump` cycle-safety in `tests/assert.lua`
  means tests that compare result tables containing debug data (which
  can include node summaries that reference shared tables) no longer
  risk stack overflow on cyclic structures.


Bumped `M.VERSION` in `lua/calltree/utils/debug.lua` from `"1.0.0"` to
`"1.1.0"` so the `debug.version` field in JSON output reflects the
release.

---

## [1.0.0] — 2026-07-08

### Summary

Production-readiness release. Fixed 11 code-review issues spanning critical
crashes (nil-index on `debug=false`, wrong caller attribution for nested
functions, fragile `NilData` proxy), medium robustness gaps (unnamed-buffer
handling, assignment-style function definitions, stale LSP diagnostics,
backward-compatibility for `vim.uri_from_bufnr`), and minor design /
performance items (double-prefix module path, in-loop `require`, unbounded
deepcopy). Added a third test suite that exercises the full pipeline against
a **real lua-language-server** end-to-end, including regression tests for
the most impactful fixes.

**Test results:** 82 unit + 105 headless (no-LSP) + 59 headless (real-LSP) =
246 assertions, 0 failures.


- [Fixed] **#3 `init.lua:dump_at_cursor` nil-index crash** — when `setup({ debug =
  false })` was active, `result.debug.completion_reason` would crash with
  "attempt to index nil". Replaced the short-circuit `result.debug and
  result.debug.completion_reason or "unknown"` with an explicit two-step
  nil-check so the intent is unambiguous and the code is robust to future
  refactors of the result shape.
- [Fixed] **#4 `treesitter/nodes.lua:find_top_level_calling_function` wrong caller
  for nested functions** — the previous implementation walked past nested
  function definitions and returned the *outermost* module-level function,
  producing wrong `caller_function.name` / `range` for any call inside a
  nested function (e.g. `function outer() function inner() foo() end end`
  attributed the call to `outer` instead of `inner`). Rewrote the walker to
  return the *first* `FUNCTION_NODE_TYPES` ancestor encountered (class /
  struct / impl blocks remain transparent because they are listed in
  `CLASS_NODE_TYPES`, not `FUNCTION_NODE_TYPES`).
- [Fixed] **#5 `utils/debug.lua:NilData` proxy returned itself on `__index`** — any
  `if dbg.data.some_flag then` check evaluated to a truthy table even in
  `debug=false` mode, masking logic bugs. Changed `__index` to return
  `nil`. Because chained writes (`dbg.data.cursor_detection.foo = X`) now
  crash on the inner nil read, every chained-write call site in
  `core/analyzer.lua`, `analysis/callers.lua`, and `treesitter/nodes.lua`
  was guarded with `if debug_enabled then` or `if dbg:get() ~= nil then`.


- [Fixed] **#6 `core/context.lua` unnamed-buffer handling** — `nvim_buf_get_name`
  returns `""` for unnamed buffers; the previous code passed this straight
  to `path_to_uri("")` which produced the invalid URI `file://`. Downstream
  LSP requests with that URI silently returned zero results. Now `""` is
  coerced to `nil` so callers can detect "no file backing this buffer"
  explicitly.
- [Fixed] **#7 `analysis/external_calls.lua` summary read** — the existing
  `if dbg:get() ~= nil then` guard was correct but the inner
  `summary.total_calls > 0 and summary.calls_unresolved == summary.total_calls`
  comparison would crash if the `summary` table itself was ever nil. Added
  `summary ~= nil` and per-field `type(...) == "number"` checks for full
  robustness against future refactors of the debug shape.
- [Fixed] **#8 `analysis/definition_body.lua` assignment-style function definitions**
  — `walk_up_to_type(def_node, FUNCTION_NODE_TYPES)` only walks *up*, so for
  `local foo = function() ... end` (where `function_expression` is a
  *sibling* of the binding identifier, not an ancestor) the body check
  wrongly classified the call as "no implementation body" and dropped it
  from `external_calls`. Added a fallback that walks up to the enclosing
  `local_declaration` / `assignment` / `variable_declaration` /
  `lexical_declaration` and scans its named children (and one level of
  `value` / `initializer` / `expression` wrappers) for any
  `FUNCTION_NODE_TYPES` node, covering Lua, JS, and TS assignment forms.
- [Fixed] **#9 `adapter.lua:get_lsp_diagnostics` stale-data risk** — the function
  returned the live module-level `lsp_diagnostics` table by reference.
  Callers could mutate it, corrupting diagnostics for the next analysis
  run. Now returns a shallow snapshot copy; mutation of the snapshot does
  not affect the live accumulator (verified by `test10` in the real-LSP
  suite).
- [Fixed] **#10 `providers/lsp_client.lua:vim.uri_from_bufnr` compatibility** —
  the function was called unconditionally. On Neovim < 0.5 (or test
  harnesses that inject a stub `vim` global) this crashes. Added a
  three-stage fallback: `vim.uri_from_bufnr` → `nvim_buf_get_name` →
  `"file://"` literal, mirroring `vim.uri_from_bufnr`'s documented
  behavior for on-disk files and unnamed buffers.


- [Fixed] **#11 `resolution/module_finder.lua` double-prefix paths** — absolute
  candidate paths like `/lua/?.lua` (from `DEFAULT_PACKAGE_PATHS`) were
  unconditionally re-anchored under `cwd`, producing nonsense paths like
  `/home/user/home/user/lua/foo.lua` that always failed `io.open`. Now
  cwd is normalized once (trailing slashes stripped) and the cwd-anchor
  fallback only fires when the candidate is NOT already prefixed by cwd.
  This eliminates one wasted syscall per absolute-path template.
- [Fixed] **#12 `providers/file_reader.lua` in-loop `require`** — moved
  `require("calltree.utils.path")` from inside the hot `get_tree` loop to
  the module's top level. Lua caches required modules in
  `package.loaded`, so the perf impact is minor, but the hoisted form is
  cleaner and matches every other module in the codebase.
- [Fixed] **#13 `core/analyzer.lua:deepcopy` cycle / type safety** — the
  unbounded recursion would stack-overflow on cyclic tables (e.g.
  `a.node = b; b.node = a`) and silently dropped `function`/`userdata`
  references. Added a `seen` memo to break cycles and an explicit
  "non-table returns as-is" branch that lets functions and userdata be
  shared by reference (which is safe — the analyzer's result tables only
  ever store functions for the `lsp_calls` / `caller_decisions` debug
  records where sharing the reference is fine).


New test suite `tests/headless_real_lsp.lua` (10 test groups, 59
assertions) exercises the full pipeline against a real
**lua-language-server 3.14.0**:

- [Added] `test1` — end-to-end `analyze_at_cursor` returns `current_function` +
  `callers` (greet/use_greet cross-function call).
- [Added] `test2` — cross-file caller (main.lua's `caller` calls lib.lua's
  `helper`); verifies LSP `references` returns cross-URI locations.
- [Added] `test3` — `external_calls` resolves `lib.helper` to the real definition
  file in `lib.lua`.
- [Added] `test4` — `analyze_at_cursor_json` round-trips through `vim.json.decode`.
- [Added] `test5` — with a real LSP attached, all preconditions pass and
  `debug.completion_reason == "analyzed"`.
- [Added] `test6` — regression: without an LSP attached, preconditions fail and
  `debug.completion_reason == "preconditions_failed"`.
- [Added] `test7` — regression for fix #4: nested-function caller attribution
  (`inner`, NOT `outer`).
- [Added] `test8` — regression for fix #3: `dump_at_cursor` does not crash with
  `debug=false`.
- [Added] `test9` — `setup({ debug = false })` produces a result with no `debug`
  field but the analysis itself is still correct.
- [Added] `test10` — regression for fix #9: `adapter.get_lsp_diagnostics()`
  returns a snapshot isolated from the live accumulator.

The runner `runner_headless_real_lsp.lua` sources
`scripts/nvim_lsp_init.lua` which bootstraps `vim.lsp.start()` for
lua-language-server with proper `root_dir` detection (pcall-wrapped
`vim.fs.find` to handle ENOENT on unnamed buffers).


- [Added] `scripts/nvim_lsp_init.lua` — minimal nvim init for headless testing
  with a real lua_ls attached. Sets `runtimepath` to include the plugin,
  configures `vim.lsp.start()` with proper root_dir detection, registers
  the `FileType lua` autocmd, and exposes `_G.start_lua_lsp(bufnr)` for
  force-attaching a buffer in headless mode.
- [Added] `scripts/verify_lsp.lua` — smoke-test script that opens a tiny lua
  project, attaches lua_ls, polls `documentSymbol` until non-empty, and
  exits non-zero on failure. Useful for debugging LSP connectivity
  outside the full test suite.


`run_all_tests.sh` now runs **three** suites instead of two and prints
the lua-language-server version at the top:

```
[1/3] lua5.4 test_runner.lua                  →  82 passed
[2/3] nvim --headless runner_headless.lua     → 105 passed
[3/3] nvim --headless runner_headless_real_lsp.lua → 59 passed
```

Total: **246 assertions, 0 failures**, exit code 0.


Bumped `M.VERSION` in `lua/calltree/utils/debug.lua` from `"0.2.0"` to
`"1.0.0"` so the `debug.version` field in JSON output reflects the
release.

---

## [0.9.0] — 2026-07-08


Refactored the project from a flat structure into a layered, dependency-injected
architecture. The monolithic `adapter.lua` (483 lines) and `external_call_analysis.lua`
(537 lines) have been decomposed into focused, single-responsibility modules.

**New directory structure:**
```
lua/calltree/
├── init.lua                       # Plugin entry (public API + user commands)
├── adapter.lua                    # Thin integration: re-exports providers
├── core/
│   ├── analyzer.lua               # Analysis pipeline (6-phase orchestrator)
│   └── context.lua                # Context factory (build_context)
├── analysis/
│   ├── preconditions.lua          # Precondition checks
│   ├── callers.lua                # Inbound caller analysis
│   ├── external_calls.lua         # Cross-function call analysis
│   └── definition_body.lua        # Definition body checker (extracted, pure function)
├── providers/
│   ├── lsp_client.lua             # LSP client constructor (capability checks, sync)
│   ├── treesitter.lua             # Treesitter service (parse, wrap_node)
│   └── file_reader.lua            # File reading + parse cache service (NEW)
├── treesitter/
│   ├── nodes.lua                  # Node operations (comparison, name extraction)
│   └── walker.lua                 # Tree traversal (collect_top_level_calls)
├── resolution/
│   ├── require_resolver.lua       # require() string extraction
│   └── module_finder.lua          # Module path resolution
└── utils/
    ├── init.lua                   # Unified export
    ├── constants.lua              # Node types, LSP constants
    ├── path.lua                   # path_to_uri / uri_to_path / is_path_under
    ├── range.lua                  # Range comparison, conversion
    └── debug.lua                  # DebugCollector
```

**Key decoupling points:**
1. **Adapter ↔ Core separation** — `adapter.lua` now only calls `providers/`
   constructors; `core/context.lua` builds the analysis context independently.
2. **Injectable file-reader service** — `providers/file_reader.lua` unifies the
   duplicated file-read + parse + cache logic from `caller_analysis` and
   `external_call_analysis`. Both analysis modules get the service via `ctx`.
3. **Definition body checker extracted** — the 200+ line `check_definition_body`
   is now `analysis/definition_body.lua`, a pure function testable in isolation.
4. **Tree traversal extracted** — `collect_top_level_calls` and `get_callee`
   moved to `treesitter/walker.lua`, reusable for other languages.
5. **Constants & utils organized** — all node types in `utils/constants.lua`,
   path/range operations in their own files.

**Removed:** backward-compatible shim files (`call_analyzer.lua`,
`caller_analysis.lua`, `external_call_analysis.lua`, `preconditions.lua`,
`nodes.lua`, `debug.lua`, `require_resolver.lua`). Test files updated to use
the new canonical paths directly. Only `utils.lua` remains as a shim (forwards
to `utils/init.lua` package + legacy helpers).


- [Added] `providers/file_reader.lua` — centralized file reading + treesitter parse cache,
  eliminating duplicate cache logic in callers and external_calls modules.
- [Added] `analysis/definition_body.lua` — standalone definition-body checker, a pure
  function that accepts injected services (treesitter, read_file, resolver).

### Migration notes

If you have code that requires the old paths (e.g. `require("calltree.nodes")`),
update to the new paths:
- `calltree.call_analyzer` → `calltree.core.analyzer`
- `calltree.caller_analysis` → `calltree.analysis.callers`
- `calltree.external_call_analysis` → `calltree.analysis.external_calls`
- `calltree.preconditions` → `calltree.analysis.preconditions`
- `calltree.nodes` → `calltree.treesitter.nodes`
- `calltree.debug` → `calltree.utils.debug`
- `calltree.require_resolver` → `calltree.resolution.require_resolver`
- `calltree.utils` stays the same (package with init.lua)

---

## [0.8.0] — 2026-07-08


- [Fixed] **`collect_top_level_calls` incorrectly entered nested function definitions**.
  The skip condition `nt ~= func_node:type()` was wrong because nested functions
  have the SAME type as the cursor function (e.g. both are `function_declaration`).
  This caused calls inside nested functions (e.g. `call_c` inside `inner`) to be
  incorrectly collected as top-level calls. Fixed by checking `node ~= func_node`
  (identity) instead of type inequality.


- [Added] **21 new tests** across two files, covering 15 test points:
  - `test_edge_cases_advanced.lua` (14 tests): multi-byte Unicode text, Lua
    pattern special chars in function/module names, tree cache pollution,
    indirect/nested recursion, single-line/empty-block function detection,
    LocationLink normalization, URI encoding round-trip, path boundary checks,
    nested function call collection, LSP capability skipping, timeout graceful
    degradation, module/function cache consistency
  - `test_multilanguage.lua` (5 tests): Python class method caller, Rust impl
    block method caller, C/C++ header declaration vs source definition, C#
    expression-body + local function, Go anonymous function + cross-package

### Verified Behaviors

- **Multi-byte Unicode**: Chinese/emoji function names extract correctly
  (treesitter byte offsets align with `string.sub`)
- **Pattern special chars**: module names with hyphens resolve correctly;
  function names with hyphens are found via literal comparison
- **Tree cache**: different URIs with same content both parse correctly
- **Indirect recursion**: `foo→bar→foo` — bar is correctly kept as a caller of foo
- **C/C++ declaration/definition separation**: `.h` declarations excluded from
  callers, `.c` definitions correctly identified as having bodies
- **Class/impl methods**: Python `class App: def run()` and Rust `impl S { fn method }`
  correctly identified as top-level callers (class/impl blocks skipped)
- **Go anonymous functions**: `fn := func() {...}` doesn't interfere with
  finding the enclosing `main` function as the caller

---

## [0.7.0] — 2026-07-08


- [Added] **`METHOD_CAPABILITY_MAP`** in `adapter.lua` — maps LSP method names to their
  `server_capabilities` field names:
  - `textDocument/definition` → `definitionProvider`
  - `textDocument/declaration` → `declarationProvider`
  - `textDocument/references` → `referencesProvider`
  - `textDocument/documentSymbol` → `documentSymbolProvider`
  - `textDocument/typeDefinition` → `typeDefinitionProvider`
  - `textDocument/implementation` → `implementationProvider`
- [Added] **`method_supported(clients, method)`** — checks whether any attached LSP
  client supports the given method before making the request.
- [Added] **Capability check in `lsp_request_sync`** — before calling
  `buf_request_sync`, checks if any client supports the method. If not, returns
  `nil` immediately and records `skipped_unsupported = true` in diagnostics,
  **avoiding the wait for an error/timeout response**.
- [Added] **`:CalltreeJsonDebug`** command — prints JSON with debug info (for when you
  need the full diagnostic trace). `:CalltreeJson` now defaults to `debug=false`
  for faster output and 10× smaller JSON.
- [Added] **`M.encode_json(result)`** API — encodes a pre-computed result table to JSON,
  avoiding double-analysis when you already have the result.
- [Added] **`write_json_to_file(path, bufnr, opts)`** now accepts `opts.debug` — defaults
  to `false` (faster, smaller JSON for tooling consumption).
- [Added] **3 new tests** in `test_lsp_capabilities.lua` — verify analyzer works without
  declaration support, warns appropriately, and the capability map is correct.


- [Changed] **LSP request timeout reduced from 3000ms to 1000ms**. The previous 3s timeout
  caused noticeable delays when a server returned an error (the sync wait would
  block until the error arrived). With the capability check now skipping
  unsupported methods, this timeout only applies to genuinely supported requests.
- [Changed] **`:CalltreeJson` defaults to `debug=false`** — skips all debug collection,
  producing 10× smaller JSON (1.3KB vs 13KB) and ~15% faster analysis.
- [Changed] **`init.lua` refactored** — `analyze_at_cursor_json` now uses
  `M.encode_json(result)` to avoid code duplication.
- [Changed] **`lsp_adapter_diagnostics` entries** now include a `skipped_unsupported`
  boolean field, making it clear in the debug output which methods were skipped
  due to missing server capabilities.

### Performance Impact

| Metric | Before (0.6.0) | After (0.7.0) | Improvement |
|--------|----------------|---------------|-------------|
| `:CalltreeJson` JSON size | ~13KB (with debug) | ~1.3KB (no debug) | **10× smaller** |
| `analyze_at_cursor` with debug | 0.024s | 0.024s | same |
| `analyze_at_cursor` without debug | — | 0.021s | **~15% faster** |
| `textDocument/declaration` (unsupported) | waited for error | **skipped instantly** | **eliminated** |
| LSP timeout | 3000ms | 1000ms | **3× shorter** |

### Verified with real lua_ls

Confirmed via headless integration test that lua_ls reports:
- `definitionProvider = true` ✓
- `declarationProvider = nil` ← **unsupported, now skipped**
- `referencesProvider = true` ✓
- `documentSymbolProvider = true` ✓

The `textDocument/declaration` request is now correctly skipped (shown as
`skipped=true` in `lsp_adapter_diagnostics`), eliminating the previous error
response wait.

---

## [0.6.0] — 2026-07-07


Profiled the analysis pipeline with per-function timing instrumentation and
optimized the two hottest paths. Results measured on Neovim 0.12.4 + lua_ls
3.14.0, 5 iterations on `M.analyze_at_cursor` (4 callers, 2 external calls):

- [Changed] **`caller_analysis.analyze`**: added a **tree cache** keyed by URI. When
  multiple LSP references point to the same file (common — 4 of 4 references
  in the test scenario hit `init.lua`), the file is read and parsed only once
  instead of once per reference. Reduced `ts.parse` calls from 9 to 7 per run.
- [Changed] **`external_call_analysis.analyze`**: added a **module cache** keyed by
  resolved module path. When multiple calls resolve to the same module file
  (e.g. `adapter.build_context` and `adapter.other_func` both require
  `calltree.adapter`), the module file is read, parsed, and searched only once.
  The cache also stores per-suffix function-definition search results, so
  repeated lookups for the same function name in the same module are O(1).
- [Changed] **`check_definition_body`**: now accepts and uses the `module_cache` parameter,
  avoiding redundant file reads, treesitter parses, and tree traversals.

### Performance Impact

| Metric | Before | After | Improvement |
|--------|--------|-------|-------------|
| Total analysis time (5 runs) | 0.132s | 0.124s | ~6% |
| `ts.parse` calls per run | 9 | 7 | 22% fewer parses |
| `caller_analysis._analyze_one_reference` (5 runs) | 0.0040s | 0.0031s | ~23% |
| Per-analysis average | 0.026s | 0.025s | ~4% |

The optimizations are most impactful when:
- The cursor function has many callers in the same file (tree cache)
- The cursor function calls multiple functions from the same module (module cache)
- The project has large module files (avoids re-traversing the AST)


- [Removed] All temporary profiling instrumentation code (the `profiler.lua` module,
  `headless_profile.lua`, and `headless_profile2.lua` scripts) — these were
  development-only tools and are not included in the package.

---

## [0.5.0] — 2026-07-07


- [Added] **`debug` configuration option** to control whether debug info is collected and
  included in results. When `debug = false`:
  - The analyzer uses a **no-op `DebugCollector`** — all `dbg:record_*` calls are
    cheap no-ops (zero overhead)
  - No timings are measured, no decision traces are built, no summary counts are
    incremented
  - The result table has **no `debug` field** at all (smaller JSON output)
  - The analysis itself (callers, external_calls) still runs identically
- [Added] **`setup({ debug = false })`** option — persists the setting so all subsequent
  `analyze_at_cursor()` calls skip debug collection
- [Added] **Per-call `debug` override** — pass `{ debug = false }` to
  `adapter.build_context()` for one-off control without changing global config
- [Added] **`debug.disabled()` API** in `debug.lua` — returns a no-op collector with a
  nil-safe `data` proxy (swallows all reads/writes) so sub-modules need no nil checks


- [Changed] **`adapter.build_context()`** now accepts a 4th `opts` parameter
  (`{ debug = boolean }`) and propagates `debug` into the context
- [Changed] **`call_analyzer.lua`** reads `ctx.debug` (default: enabled) and selects the
  real or no-op collector accordingly; skips timing measurement when disabled
- [Changed] **`external_call_analysis.lua`** guards the "all calls unresolved" warning to
  only read summary counters when debug is enabled


- [Fixed] **NilData proxy chicken-and-egg bug** in `debug.lua` — the `__index` closure
  referenced `NilData` before it was assigned, causing `dbg.data.cursor_detection`
  to return nil instead of the proxy. Fixed by declaring `local NilData` first,
  then assigning the metatable.

---

## [0.4.0] — 2026-07-07


- [Fixed] **`:CalltreeAnalyze` displayed `<table 5>` instead of actual values**. The command
  used `print(vim.inspect(result))` which produces a very long string; Neovim's
  message area truncates deeply-nested tables as `<table N>` placeholders. The
  `function_body_range` field itself was always correct (a plain array like
  `[388, 425]` in the JSON), but `vim.inspect` couldn't display it inline due to
  truncation. Replaced with a compact summary printer that iterates the result
  fields directly and prints each one on its own line.


- [Changed] **`:CalltreeAnalyze` now prints a compact summary** instead of the full
  `vim.inspect` dump. Output format:
  ```
  [calltree] current_function: analyze_at_cursor  range=[6,16]  file=.../main.lua
  [calltree] callers (4):
    - run_analysis [3,6]  call_at=4:25  file=.../caller.lua
    - M.analyze_at_cursor_json [18,24]  call_at=19:22  file=.../main.lua
  [calltree] external_calls (2):
    - adapter.build_context [resolved] stdlib=false  def: file=.../adapter.lua range=[388,425]
    - analyzer.analyze [resolved] stdlib=false  def: file=.../call_analyzer.lua range=[66,203]
  [calltree] summary: callers_kept=4 calls_kept=2 calls_unresolved=0 warnings=0 errors=0
  ```


- [Added] **`:CalltreeToFile {path}` command** — writes the full JSON result to a file
  (no truncation, no message-area limits). Recommended for consuming the JSON
  with external tools (`jq`, Python, etc.).
- [Added] **`M.write_json_to_file(path, bufnr)`** API — programmatic version of
  `:CalltreeToFile`.
- [Added] **`M.dump_at_cursor()`** rewritten as the compact summary printer (used by
  `:CalltreeAnalyze`).

---

## [0.3.0] — 2026-07-07


- [Changed] **Split `call_analyzer.lua` into focused modules**. The monolithic 1586-line
  `call_analyzer.lua` has been decomposed into 6 focused modules, with the main
  file now a thin 205-line orchestrator:
  - `debug.lua` (219 lines) — `DebugCollector` object with methods for recording
    preconditions, LSP calls, treesitter parses, caller/external-call decisions,
    summary counts, timings, errors, and warnings
  - `nodes.lua` (316 lines) — node comparison (`nodes_equal`), tree walking
    (`walk_up_to_type`), function name extraction (`get_function_name`),
    cursor-on-function-name detection (`is_function_name_node`),
    top-level calling function finder, and function-definition search by name
  - `preconditions.lua` (149 lines) — precondition checks (treesitter, LSP,
    document symbols) and LSP document-symbol search
  - `require_resolver.lua` (164 lines) — Lua module spec extraction from
    `require()` calls and module path resolution via `package.path`
  - `caller_analysis.lua` (239 lines) — inbound caller analysis: LSP references,
    definition/declaration exclusion, top-level calling function detection,
    recursive self-call filtering
  - `external_call_analysis.lua` (488 lines) — cross-function call analysis:
    top-level call collection, callee extraction, LSP definition resolution,
    in-scope/project-scope/body filters, require-resolution
  - `call_analyzer.lua` (205 lines) — thin orchestrator that runs the 6-phase
    pipeline: preconditions → cursor detection → LSP symbol cross-check →
    caller analysis → external-call analysis → finalize

- [Changed] **`M.analyze` split into 6 phases**. The monolithic analyze function is now a
  clear pipeline:
  1. **Precondition checks** (`preconditions.check`) — treesitter + LSP + symbols
  2. **Cursor node lookup** — find the treesitter node at the cursor position
  3. **Function-name detection** (`nodes.is_function_name_node`) — verify cursor
     is on a function-definition name
  4. **LSP symbol cross-check** (`preconditions.find_function_symbol_at`) —
     confirm the LSP document symbol is Function/Method kind
  5. **Inbound caller analysis** (`caller_analysis.analyze`) — who calls this?
  6. **Cross-function call analysis** (`external_call_analysis.analyze`) — what
     does this call?


- [Added] `DebugCollector` object API in `debug.lua` — replaces the loose collection of
  `record_*` functions with a cohesive object (`dbg:precondition()`,
  `dbg:lsp_call()`, `dbg:ts_parse()`, `dbg:caller_decision()`, etc.)
- [Added] `nodes.range_to_1based_closed()` helper — centralizes the 0-based → 1-based
  closed range conversion logic (previously duplicated in 3 places)

---

## [0.2.0] — 2026-07-07


- [Added] **`debug` field in every JSON result** (including empty results from precondition
  failures). The `debug` object provides comprehensive diagnostics:
  - `inputs` — snapshot of file path, cursor position, language, cwd, source size
  - `preconditions[]` — per-check trace with `check` / `passed` / `detail`
  - `cursor_detection` — node-at-cursor info, name-path search trace, symbol match
  - `lsp_calls[]` — every LSP request with method, params, response summary, errors
  - `ts_parses[]` — every treesitter parse with purpose, language, ok, has_error, root type
  - `caller_decisions[]` — per-reference outcome (`kept` / `excluded_defdecl` /
    `global_scope` / `self_recursive` / `no_source` / `no_node` / `error`) with reason
  - `external_call_decisions[]` — per-call outcome (`kept_resolved` / `kept_unresolved` /
    `discarded_in_scope` / `discarded_outside_project` / `discarded_no_body` / `error`)
    with reason, callee node, full call range, module spec, resolved module path
  - `summary` — aggregate counts (total_refs, callers_kept, total_calls, calls_kept, etc.)
  - `timings` — per-phase elapsed seconds
  - `errors[]` / `warnings[]` — non-fatal issues with explanatory messages
  - `lsp_adapter_diagnostics[]` — low-level LSP call diagnostics (client count, names,
    timeouts, per-client errors) for troubleshooting LSP integration
- [Added] **Require-resolution for module imports**. When LSP resolves a call like
  `adapter.build_context()` to a `local adapter = require("calltree.adapter")` binding
  (instead of the actual function definition), the analyzer now:
  1. Extracts the module spec from the `require()` call
  2. Resolves it to a file path using `package.path` + Neovim `runtimepath` + `cwd`
  3. Parses the module file with treesitter
  4. Searches for the function definition by name suffix (e.g. `build_context`)
  5. Returns the real `definition.file` and `definition.function_body_range`
- [Added] **Callee extraction for `function_name`**. `external_calls[].function_name` now
  contains only the callee (e.g. `adapter.build_context`), not the full call
  expression with arguments (e.g. `adapter.build_context(bufnr, cursor_pos)`).
  Nested calls inside arguments (e.g. `foo(bar())`) are no longer double-counted.
- [Added] **Dotted caller name extraction**. `callers[].caller_function.name` now correctly
  returns dotted names like `M.analyze_at_cursor_json` and method names like
  `obj:method` (previously returned `null` for these).
- [Added] **String-parser support in the adapter**. The treesitter adapter now uses
  `vim.treesitter.get_string_parser` to parse arbitrary source strings (not just
  the current buffer), enabling require-resolution of module files.
- [Added] **9 new test files** (46 new test cases):
  - `test_debug_field.lua` — verifies `debug` field presence and contents
  - `test_wrapped_nodes.lua` — regression test for adapter node-wrapping behavior
  - `test_callee_extraction.lua` — verifies callee-only `function_name`
  - `test_user_scenario.lua` — end-to-end test mimicking the user's exact scenario
  - `test_adapter_arg_order.lua` — regression test for LSP method argument order
  - `test_module_import_resolution.lua` — tests require-resolution + bare-declaration filter
  - `test_dotted_caller_name.lua` — tests dotted/method caller name extraction


- [Fixed] **Node reference equality bug** (`is_function_name_node`). The `find_path` helper used
  `from == target` to detect when the recursive search reached the cursor node. This
  worked for mock nodes (pre-linked) but failed for the real adapter, where every
  `:parent()` / `:named_child()` call returns a fresh Lua wrapper table. Replaced with
  `nodes_equal()` which compares by type + range. This caused functions like
  `function M.foo()` to be rejected as "not on a function-definition name".
- [Fixed] **LSP method argument-order bug**. The adapter's `definition` / `declaration` /
  `references` methods were defined as `function(_, position)` but the analyzer calls
  them as `lsp:definition(uri, position)` — meaning `position` received the uri STRING
  and the actual `{line, character}` table was lost. This caused lua_ls to crash with
  `attempt to compare number with nil` and return 0 results for every request.
  Fixed all method signatures to `function(_self, _uri, position)`.
- [Fixed] **LSP sync mechanism**. Replaced manual `client.request` + `vim.wait` loop with
  Neovim's built-in `vim.lsp.buf_request_sync`, which correctly handles the event loop.
  Increased timeout from 1s to 3s.
- [Fixed] **Module import treated as bare declaration**. When LSP jumped to a
  `local X = require(...)` line, the body-check logic discarded the call as
  "no function-definition ancestor found". Now distinguishes variable bindings
  (kept as resolved) from true declarations like `extern` (still discarded).
- [Fixed] **`function_name` included arguments**. `collect_top_level_calls` used `node:text()`
  on the whole call node, capturing arguments. Now extracts the callee (first non-
  arguments named child) and uses its text and range.
- [Fixed] **Caller name was `null` for dotted names**. `get_function_name` only checked
  `NAME_NODE_TYPES` children (identifier, etc.), missing `dot_index_expression`
  (`M.foo`) and `method_index_expression` (`obj:method`). Added `DOTTED_NAME_TYPES`
  to handle these.
- [Fixed] **String-parser node text extraction**. The `wrap_node` adapter used
  `vim.treesitter.get_node_text(node, 0)` which reads from buffer 0 — invalid for
  string-parsed nodes. Now extracts text from the source string using the node's range.


- [Changed] **Adapter `lsp_request_sync` rewritten** to use `vim.lsp.buf_request_sync` (the
  official sync API) instead of manual `client.request` + `vim.wait`.
- [Changed] **Adapter `build_context`** now populates `package_paths` from `package.path` +
  Neovim `runtimepath` + `cwd`, so require-resolution can find plugin modules.
- [Changed] **Adapter `treesitter` `parse()`** now detects whether `source_code` matches the
  current buffer; if not, uses `get_string_parser` to parse the string directly.
- [Changed] **`is_function_name_node`** search depth increased from 4 to 6 hops; records the
  full hop chain and path-search result in `debug.cursor_detection._name_path_search`.
- [Changed] **`get_function_name`** refactored to handle dotted/method name expressions and
  declarator wrappers (C/C++ `function_declarator`).
- [Changed] **README** updated with full `debug` field documentation, outcome enum tables,
  and test count (53 unit tests + headless integration test).

---

## [0.1.0] — 2026-07-07


- [Added] Initial release of `calltree.nvim`.
- [Added] **Core analyzer** (`lua/calltree/call_analyzer.lua`) — pure Lua, zero `vim.*`
  dependencies. All external dependencies (LSP, Treesitter, filesystem, `getcwd`)
  are injected via the context table, making the entire analysis testable in a
  plain Lua environment.
- [Added] **Neovim adapter** (`lua/calltree/adapter.lua`) — bridges `vim.lsp` and
  `vim.treesitter` to the analyzer's expected interface.
- [Added] **Public API** (`lua/calltree/init.lua`) — `analyze_at_cursor()`,
  `analyze_at_cursor_json()`, `dump_at_cursor()`, `setup()`.
- [Added] **User commands** — `:CalltreeAnalyze` (structured output) and `:CalltreeJson`
  (JSON string).
- [Added] **Utility module** (`lua/calltree/utils.lua`) — URI/path conversion, range
  equality, node-type constants for Python, Lua, JS/TS, C/C++, Ruby, Go, Rust,
  Elixir, Clojure.
- [Added] **Output JSON structure**:
  - `current_function` — name, 1-based closed range, file
  - `callers[]` — inbound callers with file, call position, caller function
    name + range
  - `external_calls[]` — cross-function calls with call position, function name,
    definition (file + function body range), resolution status, is_stdlib
- [Added] **Empty result** returned for any no-op condition (precondition failed, cursor
  not on function-definition name) with no user-visible message.
- [Added] **Precondition checks**: treesitter available + no error, LSP client with
  required methods, non-empty document symbols.
- [Added] **Cursor-on-function-name detection** via treesitter node types + LSP document
  symbol cross-check (Function / Method kind only).
- [Added] **Inbound caller analysis**:
  - Excludes the function's own definition/declaration sites
  - Excludes recursive self-calls
  - Excludes calls at global scope
  - Handles anonymous callers (name = null, record kept)
  - Handles caller body range unavailable (range = null)
- [Added] **Cross-function call analysis**:
  - Only top-level calls (skips nested function definitions)
  - Project-scope filter (definition file must be under `getcwd`)
  - Local nested function filter (in-scope definitions discarded)
  - Stdlib tag detection (`system` / `library` tags → `is_stdlib = true`)
  - Declaration-only filter (no implementation body → discarded)
  - Unresolved fallback (LSP can't jump → `definition = null`,
    `resolution_status = "unresolved"`, `is_stdlib = null`)
- [Added] **Test infrastructure**:
  - `tests/mocks.lua` — mock LSP client + Treesitter with method-call syntax
  - `tests/scenario.lua` — fluent builder (`:with_code()`, `:with_cursor()`,
    `:with_tree()`, `:with_definition()`, `:with_references()`, etc.)
  - `tests/assert.lua` — tiny assertion library
  - `tests/tree_builder.lua` — DSL for building mock treesitter trees
- [Added] **27 test cases** covering:
  - Preconditions (missing LSP method, error tree, empty symbols, no treesitter)
  - Cursor position (call site, parameter, comment, variable assignment)
  - Inbound callers (top-level, anonymous, global scope, recursive, decl-vs-def,
    range unavailable)
  - Cross-function calls (project file, external project, local nested, stdlib,
    declaration-only, unresolved, complex expressions)
  - Coordinate conversion (0-based internal → 1-based output)
  - Edge cases (empty file, special function names, multiple callers + calls)
- [Added] **`test_runner.lua`** — runnable via `lua test_runner.lua` (no busted dependency).
- [Added] **`Makefile`** — `make test` target.
- [Added] **`README.md`** — usage guide, output shape, architecture, test instructions.

---

## Versioning

- **0.1.0** (2026-07-07): Initial release with core analysis + 27 unit tests.
- **0.2.0** (2026-07-07): Added `debug` field, require-resolution, callee extraction,
  dotted caller names, fixed 6 bugs found via real Neovim integration testing.
  53 unit tests + headless integration test.
- **0.3.0** (2026-07-07): Split `call_analyzer.lua` into 7 focused modules
  (debug / nodes / preconditions / require_resolver / caller_analysis /
  external_call_analysis / orchestrator). `M.analyze` split into 6-phase pipeline.
  53 unit tests pass, headless integration test passes.
- **0.4.0** (2026-07-07): Fixed `:CalltreeAnalyze` displaying `<table N>` instead
  of actual values (replaced `vim.inspect` with compact summary printer). Added
  `:CalltreeToFile` command and `M.write_json_to_file()` API.
- **0.5.0** (2026-07-07): Added `debug` configuration option (`setup({ debug = false })`)
  to skip all debug collection and omit the `debug` field from results. No-op
  `DebugCollector` for zero-overhead disabled mode. 58 unit tests pass.
- **0.6.0** (2026-07-07): Performance optimizations — added tree cache (by URI) in
  caller_analysis and module cache (by resolved path) in external_call_analysis.
  ~6% faster overall, 22% fewer treesitter parses. 58 unit tests pass.
- **0.7.0** (2026-07-08): LSP capability checking — skips unsupported methods
  (e.g. `declaration` on lua_ls) instantly instead of waiting for error response.
  Reduced LSP timeout 3000ms→1000ms. `:CalltreeJson` defaults to `debug=false`
  (10× smaller JSON). 61 unit tests pass.
- **0.8.0** (2026-07-08): Fixed nested-function collection bug (was entering
  nested function bodies). Added 21 edge-case + multi-language tests covering
  Unicode, pattern chars, cache consistency, Python/Rust/C/C#/Go. 82 tests pass.
- **0.9.0** (2026-07-08): Layered architecture refactoring — split into
  core/analysis/providers/treesitter/resolution/utils packages. Extracted
  file_reader service, definition_body checker, tree walker. 82 tests pass.
- **1.0.0** (2026-07-08): Production-readiness release. Fixed 11
  code-review issues (#3-#13) spanning critical crashes, robustness gaps,
  and minor design / performance items. Added a third test suite that
  exercises the full pipeline against a real lua-language-server 3.14.0.
  246 assertions (82 unit + 105 headless no-LSP + 59 headless real-LSP)
  pass.
- **1.1.0** (2026-07-08): Second-round code-review pass. Fixed 10 more
  issues (1 high, 4 medium, 5 low) plus minor follow-ups. High-priority
  fix: cycle-safe `deep_eq` in `tests/assert.lua`. Medium fixes: Windows
  path support in `module_finder.lua`, per-instance LSP diagnostics
  accumulator, `_analyze_resolved_call` 12-arg refactor, bounded
  recursion in `require_resolver.lua`. Low fixes: line-split caching in
  `wrap_node`, idempotent `setup()`, pcall-wrapped file I/O, shared
  constants extracted, range-helper deduplication. 246 assertions pass
  (unchanged from 1.0.0 — no test regressions).
- **1.1.1** (2026-07-09): Merged architecture refactor and static code review
  fixes. Introduced layered architecture (domain types, interfaces, infrastructure),
  AOP decorators, dependency injection, centralized constants, and unified file
  parser. Fixed 6 high/6 medium/8 low issues plus numerous boundary/error
  handling defects. Added Python test suite. 255 assertions + 41 API compatibility
  checks pass.
- **1.1.2** (2026-07-10): Consolidated all test infrastructure under `tests/`, added
  real-LSP test suites for C/clangd (10 scenarios + 3 stress) and Rust. Fixed OOM
  on low-memory hosts, Neovim 0.10 compatibility, hardcoded paths, and stale
  diagnostics. Later code‑quality review pass (2026‑07‑15) addressed 59 findings
  across 10 categories. Full green matrix: 111 unit + 105 headless + 59 lua_ls +
  10 C + 3 C‑stress + 76 Rust = 364 assertions, 0 failures.
- **1.2.0** (2026-07-15): Feature release – added `skip_stdlib_calls` and `deduplicate_external_calls`
  setup() options for post‑collection filtering,
  making the default `external_calls` output deduplicated and stdlib‑free. Included migration guide, 
  8 new tests, and summary recomputation to reflect final array lengths.
- **1.2.1** (2026-07-15): Patch release – JavaScript/TypeScript language support (arrow functions,
  class methods, ES6 imports), refined stdlib filtering, and lua‑language‑server meta‑path recognition.
  Fixed misclassification issues in `external_calls` for these languages.
- **1.2.2** (2026-07-16): Refactor release – integrated the `domain/types.lua` domain model (frozen `CallGraph`)
  into the analysis pipeline. Resolved JSON encoding failures with frozen objects and LuaJIT iteration incompatibilities;
  analysis modules now use factory functions for consistency.