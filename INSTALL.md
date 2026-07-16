# calltree.nvim — Installation & Test Guide

**Version:** 1.2.4 (2026-07-16)

A Neovim plugin (requires Neovim 0.10+ with LSP and Treesitter) that analyzes
the function under the cursor and reports inbound callers and cross-function
calls as a structured JSON object.

## Package Contents

```
calltree.nvim/
├── README.md                       # Plugin documentation.
├── CHANGELOG.md                    # Version history.
├── INSTALL.md                      # This file.
├── Makefile                        # make test / test-all / test-c / test-rust / test-javascript …
├── lua/calltree/                   # Plugin source (architecture consists of layers).
├── tests/                          # All tests and runners live here.
│   ├── README.md                   # Instructions for testing, methods, and prerequisites.
│   ├── run_all_tests.sh            # Matrix: unit + headless + lua/c/rust/js LSP (7 suites)
│   ├── test_runner.lua             # Lua unit test entry point.
│   ├── runner_headless.lua         # nvim headless (no LSP).
│   ├── runner_headless_real_lsp.lua# nvim headless (with lua_ls).
│   ├── assert.lua, mocks.lua, scenario.lua, tree_builder.lua
│   ├── windows_compat_helper.lua   # Shared helpers for the Windows-compat suite (NEW in 1.2.3).
│   ├── test_windows_compat_path.lua        # 34 tests — path.lua Windows compat (NEW).
│   ├── test_windows_compat_fs.lua          # 20 tests — fs.lua Windows compat (NEW).
│   ├── test_windows_compat_module_finder.lua# 28 tests — module_finder.lua Windows compat (NEW).
│   ├── test_windows_compat_init.lua        # 10 tests — init.lua write_json_to_file (NEW).
│   ├── test_*.lua                  # Lua unit test modules (147 assertions).
│   ├── javascript_spec.lua         # JavaScript unit tests (11 scenarios).
│   ├── headless_integration.lua    # 105 assertions (no LSP).
│   ├── headless_real_lsp.lua       # 59 assertions (with lua_ls).
│   ├── javascript_nvim_init.lua    # nvim init for JS (attaches tsserver).
│   ├── run_javascript_tests.lua    # JS e2e entry (29 assertions).
│   ├── c/                          # clangd LSP tests and stress test fixtures.
│   ├── rust/                       # rust-analyzer end-to-end tests.
│   ├── javascript_project/         # JS integration test fixture (ES6 module).
│   └── fixtures/rust_test/         # Cargo fixture for Rust suite.
└── scripts/
    ├── nvim_lsp_init.lua           # nvim init for headless lua_ls tests.
    ├── verify_lsp.lua              # Connectivity test for lua_ls.
    ├── verify_api_compat.lua       # API compatibility verification.
    ├── rewrite_fixture_paths.py    # Rewrites C compile_commands.json paths.
    └── measure_complexity.lua      # Complexity measurement.
```

## What's New in 1.2.4

**Duplicate-code elimination release.** Addresses 22 duplicate-code findings
identified by a systematic audit of the codebase. The refactor consolidates
caches onto the shared `fifo_cache` utility, extracts 5 generic helpers
(`walk_up_until`, `find_node_at_location`, `find_body_child`, `dfs_search`,
`EmptyCallGraph`), removes 4 redundant wrapper functions, deletes 1 dead
function, and centralizes LSP-request error handling and decision-record
construction. All 255 tests continue to pass with zero behavior change.

Highlights:
- All hand-rolled FIFO caches (`lsp_client._evict_diag_cache`,
  `callers.tree_cache`, `external_calls.module_cache`) now use the shared
  `fifo_cache` module, capping memory at 128 entries each and guaranteeing
  the eviction strategy stays in sync across the codebase.
- `treesitter/nodes.lua` gains 4 new shared helpers (`walk_up_until`,
  `find_node_at_location`, `find_body_child`, `dfs_search`) that replace
  the duplicated while-loop and recursion skeletons scattered across
  `callers.lua`, `definition_body.lua`, and `analyzer.lua`.
- `providers/lsp_client.lua` gains a `safe_request` helper that
  centralizes the pcall + error-log + `dbg:lsp_call` pattern previously
  duplicated 4+ times across `callers.lua` and `external_calls.lua`.
- `domain/types.lua` gains `EmptyCallGraph`, `CallerDecision`, and
  `CallDecision` factories that centralize the construction of the
  empty-result and decision-record shapes previously hand-constructed at
  6+ call sites.
- `providers/file_reader.lua` is now a thin deprecated shim over
  `file_parser.lua` (which provides the identical read+parse+cache
  pipeline). The duplicated 130-line implementation is removed.

See `CHANGELOG.md` for the full list of changes.

## What's New in 1.2.3

**Windows compatibility release.** This version adds a comprehensive
Windows-compatibility test suite (92 new test cases across 4 files) and
fixes 5 platform bugs in path handling, URI conversion, and process I/O.
See `CHANGELOG.md` for the full list of changes.

Highlights:
- `path_to_uri` now produces RFC 8089-conformant `file://` URIs for
  Windows drive-letter paths (`file:///C:/Users/foo/bar.lua`) and UNC
  paths (`file://server/share/foo.lua`). Previous versions produced
  non-standard URIs with percent-encoded colons or four slashes.
- `is_path_under` now correctly handles mixed-separator Windows paths
  (`C:\project\foo.lua` matches parent `C:/project`) and recognizes
  Windows drive roots (`C:\`) as universal parents for paths on the
  same drive.
- `fs.getcwd` now falls back to Windows-native env vars (`CD`) and
  shell commands (`cmd /c cd`) when running outside Neovim on Windows.
- `module_finder.resolve_module_path` now correctly handles module
  specs containing `%` characters (e.g. `require("50%-off")`) without
  raising "invalid use of '%' in replacement string".



## Requirements

### Required (always)

- **Lua 5.4** (`lua5.4` / `lua` on PATH, or `CALLTREE_LUA_BIN`)
- **Neovim 0.10+** with Treesitter (`nvim` on PATH, or `CALLTREE_NVIM_BIN`)
  - Built-in parsers: `lua`, `c` (and vim/query/markdown on most packages)
  - Extra parsers for full multi-language work: `python`, `rust`, `javascript`
    (install via [nvim-treesitter](https://github.com/nvim-treesitter/nvim-treesitter)
    e.g. `:TSInstall python rust javascript`, or manually compile the
    tree-sitter grammars and place the `.so` files in Neovim's parser
    directory — Neovim 0.10 supports ABI 13–14, so use grammar v0.21.x)

### Required for real-LSP suites

| Suite | Language server | Env override |
|-------|-----------------|--------------|
| Lua headless real-LSP | **lua-language-server** 3.x | `CALLTREE_LSP_BIN` |
| C scenarios + stress | **clangd** 14+ | `CALLTREE_CLANGD_BIN` |
| Rust e2e | **rust-analyzer** (+ `rustc`/`cargo`/`rust-src`) | `CALLTREE_RUST_ANALYZER_BIN` |
| JavaScript e2e | **typescript-language-server** (+ `typescript` in project) | `CALLTREE_TSSERVER_BIN` |

Missing servers cause `tests/run_all_tests.sh` to **skip** that suite (others still run).

### Optional (interactive / extra languages)

- **Python LSP:** `pyright` or `pylsp` (for editing Python with the plugin)
- **C compiler:** `gcc` or `clang` (referenced by C `compile_commands.json`)

### Optional (local Neovim extract without system install)

- `LD_LIBRARY_PATH` for nvim’s shared libraries if needed
- `CALLTREE_VIMRUNTIME` if runtime is non-standard

## Installing language tooling (quick reference)

```bash
# Debian/Ubuntu-style examples
sudo apt-get install -y lua5.4 neovim clangd rust-analyzer rustc cargo rust-src

# lua-language-server (official release tarball)
# → extract and put bin/lua-language-server on PATH, or set CALLTREE_LSP_BIN

# typescript-language-server (for JavaScript/TypeScript e2e tests)
npm install -g typescript-language-server typescript

# Python LSP (optional)
pip install --user pyright 'python-lsp-server[all]'

# Treesitter parsers not bundled with Neovim
# (nvim-treesitter master branch works with Neovim 0.10)
nvim --headless -c "TSInstallSync python rust javascript" -c "qa"
```

**JavaScript test fixture setup:** the integration test project at
`tests/javascript_project/` requires a local `typescript` install
(the `typescript-language-server` needs it to function). Run:

```bash
cd tests/javascript_project
npm install
```

**Tree-sitter-javascript parser:** Neovim 0.10 does NOT bundle the
JavaScript parser. Install it via `:TSInstall javascript` (requires
nvim-treesitter) or manually compile `tree-sitter-javascript` and place
the `.so` in Neovim's parser directory. The parser must be ABI-compatible
with your Neovim version (Neovim 0.10 supports ABI 13–14; use
tree-sitter-javascript v0.21.x for compatibility).

**rust-src setup:** install the Rust source via rustup so rust-analyzer
can resolve standard-library references:

```bash
rustup component add rust-src
# Sources install under $(rustc --print sysroot)/lib/rustlib/src/rust/library
# rust-analyzer finds them automatically — no symlink needed when using rustup.
```

## Running the Test Suites

```bash
# Full matrix (recommended)
bash tests/run_all_tests.sh
# or
make test-all

# Individual targets
make test            # pure-Lua unit tests only
make test-headless   # nvim headless, no LSP
make test-lsp        # nvim + lua_ls
make test-c          # clangd scenarios + stress
make test-rust       # rust-analyzer e2e
make test-javascript # typescript-language-server e2e
```

With explicit binary locations:

```bash
CALLTREE_LUA_BIN=/usr/bin/lua5.4 \
CALLTREE_NVIM_BIN=/usr/bin/nvim \
CALLTREE_LSP_BIN=/usr/local/bin/lua-language-server \
CALLTREE_CLANGD_BIN=/usr/bin/clangd \
CALLTREE_RUST_ANALYZER_BIN=/usr/bin/rust-analyzer \
CALLTREE_TSSERVER_BIN=/usr/bin/typescript-language-server \
  bash tests/run_all_tests.sh
```

Skip heavy suites when needed:

```bash
CALLTREE_SKIP_C=1 CALLTREE_SKIP_RUST=1 CALLTREE_SKIP_JAVASCRIPT=1 bash tests/run_all_tests.sh
CALLTREE_SKIP_REAL_LSP=1 bash tests/run_all_tests.sh
```

### Expected output (full green run)

```
[1/7] Pure-Lua unit tests                   → 162 passed
[2/7] Neovim headless integration (no LSP)  → 105 passed
[3/7] Neovim headless REAL-LSP (lua_ls)     →  59 passed
[4/7] C real-LSP scenarios (clangd)         →  10 scenarios
[5/7] C stress tests (clangd)               →   3 scenarios
[6/7] Rust end-to-end (rust-analyzer)       →  76 assertions
[7/7] JavaScript end-to-end (typescript-ls) →  29 assertions
ALL TESTS PASSED
```

**Total: 444 assertions / scenarios, 0 failures.**

See [`tests/README.md`](tests/README.md) for methods, layout, and how to add tests.

### Additional verification

```bash
# Public API compatibility (optional)
nvim --headless -u NORC -c "luafile scripts/verify_api_compat.lua"

# Cyclomatic complexity report
lua5.4 scripts/measure_complexity.lua > complexity_report.json
```

## Installing the Plugin (for real Neovim use)

Symlink the package into your Neovim pack path:

```bash
ln -s /path/to/calltree.nvim ~/.local/share/nvim/site/pack/calltree/start/calltree.nvim
```

Then in Neovim, open a source file with an attached LSP (lua_ls / clangd /
rust-analyzer / pyright / …) and run:

```vim
:CalltreeAnalyze   " compact summary printed to messages
:CalltreeJson      " full JSON (respects setup() debug option)
:CalltreeJsonDebug " full JSON (forces debug=true, with full decision trace)
:CalltreeToFile /tmp/result.json   " write JSON to a file
```

Or programmatically:

```lua
local calltree = require("calltree")

calltree.setup({
  debug = true,         -- include debug info in results (default: true)
  user_commands = true, -- register :Calltree* commands (default: true)
})

local result = calltree.analyze_at_cursor()          -- table
local json    = calltree.analyze_at_cursor_json()    -- string
calltree.write_json_to_file("/tmp/result.json")      -- write to file

-- Per-call debug override (takes precedence over setup):
local result_no_debug = calltree.analyze_at_cursor(0, { debug = false })
local json_with_debug = calltree.analyze_at_cursor_json(0, { debug = true })
```

See `README.md` for the full JSON output schema and configuration options.

## What's New in 1.2.2

This release integrates the `domain/types.lua` domain model into the
analysis pipeline. Analysis modules now use factory functions
(`CallerInfo`, `ExternalCall`, `CallGraphBuilder`) instead of anonymous
tables, and the final `CallGraph` result is frozen (immutable). Highlights:

- **Domain-types integration**: `callers.lua :: _keep_caller` uses
  `types.CallerInfo()`, `external_calls.lua :: _make_external_call` uses
  `types.ExternalCall()`, and `analyzer.lua` uses `types.CallGraphBuilder()`
  to construct the result. The final `CallGraph` is frozen via `:build()`.
- **JSON encoding fix**: added a `_thaw` helper in `encode_json` to
  convert frozen tables back to plain tables before passing to
  `vim.json.encode` (which bypasses metamethods in LuaJIT).
- **Freeze implementation**: switched from proxy-based to data-in-table
  approach for LuaJIT compatibility (pairs/ipairs/next work natively).
- **Test matrix**: 444 assertions across 7 suites — 0 failures.

For the complete history, see `CHANGELOG.md`.
