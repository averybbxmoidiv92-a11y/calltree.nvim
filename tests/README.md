# calltree.nvim — Test Suite Guide

This directory contains **all** automated tests for `calltree.nvim`.

There are four complementary layers:

| Layer | What it exercises | Needs Neovim? | Needs real LSP? | How to run |
|-------|-------------------|---------------|-----------------|------------|
| **1. Pure-Lua unit tests** | Analyzer logic with mock LSP / Treesitter | No | No | `lua5.4 tests/test_runner.lua` or `make test` |
| **2. Headless integration (no LSP)** | Plugin load, adapter, real Treesitter, commands | Yes | No | `nvim --headless -u NORC -c "luafile tests/runner_headless.lua"` |
| **3. Headless real-LSP (Lua)** | End-to-end against **lua-language-server** | Yes | lua_ls | `nvim --headless -u NORC -c "luafile tests/runner_headless_real_lsp.lua"` |
| **4. Language real-LSP** | End-to-end against **clangd** / **rust-analyzer** / **typescript-language-server** + real parsers | Yes | clangd / rust-analyzer / tsserver | See sections below |

Run everything with one command from the plugin root:

```bash
bash tests/run_all_tests.sh
# or
make test-all
```

Expected green run (assertion counts may grow slightly over time):

```
[1/7] Pure-Lua unit tests                   → 162 passed
[2/7] Neovim headless integration (no LSP)  → 105 passed
[3/7] Neovim headless REAL-LSP (lua_ls)     →  59 passed
[4/7] C real-LSP scenarios (clangd)         →  10 scenarios passed
[5/7] C stress tests (clangd)               →   3 scenarios passed
[6/7] Rust end-to-end (rust-analyzer)       →  76 assertions passed
[7/7] JavaScript e2e (typescript-ls)        →  29 assertions passed
ALL TESTS PASSED
```

Total: **444+ assertions / scenarios**, all must pass.

---

## Directory layout

```
tests/
├── README.md                      # This file
├── run_all_tests.sh               # Full matrix entry (7 suites)
├── test_runner.lua                # Pure-Lua unit entry: lua5.4 tests/test_runner.lua
├── runner_headless.lua            # Suite 2 entry
├── runner_headless_real_lsp.lua   # Suite 3 entry
├── assert.lua                     # Tiny assertion helpers (pure-Lua suite)
├── mocks.lua                      # Mock LSP client + Treesitter
├── scenario.lua                   # Fluent scenario builder
├── tree_builder.lua               # DSL for mock treesitter trees
├── windows_compat_helper.lua      # Shared helpers for the Windows-compat suite (NEW in 1.2.3)
├── test_*.lua                     # Pure-Lua unit modules
├── test_windows_compat_path.lua        # 34 tests — path.lua Windows compat (NEW)
├── test_windows_compat_fs.lua          # 20 tests — fs.lua Windows compat (NEW)
├── test_windows_compat_module_finder.lua# 28 tests — module_finder.lua Windows compat (NEW)
├── test_windows_compat_init.lua        # 10 tests — init.lua write_json_to_file (NEW)
├── javascript_spec.lua            # JavaScript unit tests (11 scenarios)
├── test_domain_types.lua          # domain/types.lua immutability tests (15 scenarios)
├── headless_integration.lua       # Suite 2 body
├── headless_real_lsp.lua          # Suite 3 body
├── javascript_nvim_init.lua       # Minimal nvim init for JS (attaches tsserver)
├── run_javascript_tests.lua       # JavaScript e2e entry (6 scenarios, 29 assertions)
├── c/                             # C language real-LSP tests
│   ├── README.md
│   ├── run_c_tests.lua            # 10 clangd scenarios
│   ├── run_stress_tests.lua       # 3 stress scenarios
│   ├── scenarios/s01_…s10_…/      # Per-scenario sources + compile_commands.json
│   └── stress/                    # Nested / multifile / control-flow fixtures
├── rust/                          # Rust language real-LSP tests
│   ├── run_rust_tests.lua         # 10 rust-analyzer e2e scenarios
│   └── rust_nvim_init.lua         # Minimal nvim init (attaches rust-analyzer)
├── javascript_project/            # JS integration test fixture (ES6 module)
│   ├── index.js                   # Main module — imports from utils.js
│   ├── utils.js                   # Helpers: add (arrow), greet (fn), Calculator (class)
│   ├── package.json               # npm manifest (declares typescript devDep)
│   └── jsconfig.json              # TS server project config
└── fixtures/
    └── rust_test/                 # Tiny Cargo project used by the Rust suite
```

---

## 1. Pure-Lua unit tests

**Method:** plain Lua 5.4 process, **no** Neovim, **no** language servers.  
All LSP responses and Treesitter trees are hand-built mocks (`mocks.lua`, `tree_builder.lua`).

```bash
# from plugin root
lua5.4 tests/test_runner.lua
# or
make test
# or
make test-unit
```

`tests/test_runner.lua` loads every `tests/test_*.lua` module and runs each exported
`test_*` function via `pcall`. Failures print expected/actual and exit non-zero.

### Covered modules (high level)

| File | Focus |
|------|-------|
| `test_preconditions.lua` | Missing LSP methods, error trees, empty symbols |
| `test_cursor_position.lua` | Cursor not on a function-definition name |
| `test_callers.lua` | Inbound callers, recursion, global scope, decl-vs-def |
| `test_external_calls.lua` | Cross-function calls, stdlib, unresolved, nested locals |
| `test_coordinates.lua` | 0-based internal → 1-based output conversion |
| `test_edge_cases.lua` / `test_edge_cases_advanced.lua` | Empty files, unicode, timeouts, URI encoding, … |
| `test_debug_field.lua` / `test_debug_option.lua` / `test_setup_debug_option.lua` | `debug` field & `setup({debug=…})` propagation |
| `test_c.lua` | 10 C-language mock scenarios |
| `test_python.lua` | 10 Python-language mock scenarios |
| `test_multilanguage.lua` | C / Python / Rust / Go / C# adapter smoke cases |
| others | Adapter arg order, module import resolution, wrapped nodes, … |

---

## 2. Headless integration (no LSP)

**Method:** `nvim --headless` with **real** Treesitter parsers, **no** language server attached.  
Verifies that the plugin loads, commands register, context builds, and
preconditions fail cleanly when LSP is absent.

```bash
nvim --headless -u NORC -c "luafile tests/runner_headless.lua"
# or
make test-headless
```

Requires Neovim **0.10+** with a working `lua` Treesitter parser
(bundled with Neovim on most distros).

---

## 3. Headless real-LSP (Lua / lua_ls)

**Method:** `nvim --headless` + **real lua-language-server**.  
Creates temporary mini-projects under `/tmp`, attaches `lua_ls`, and asserts
callers / external_calls / JSON / debug options against live responses.

```bash
export CALLTREE_LSP_BIN=/path/to/lua-language-server   # if not on PATH
nvim --headless -u NORC -c "luafile tests/runner_headless_real_lsp.lua"
# or
make test-lsp
```

Init wiring lives in `scripts/nvim_lsp_init.lua` (runtimepath, package.path,
`vim.lsp.start` for lua_ls, `calltree.setup()`).

> **Low-memory hosts:** each test stops all LSP clients and wipes buffers in
> cleanup so `lua-language-server` processes do not accumulate (OOM).

---

## 4. C real-LSP (clangd + tree-sitter-c)

**Method:** real `.c` fixtures, real `compile_commands.json`, real **clangd**,
real tree-sitter-c. Catches integration bugs mocks cannot reproduce
(e.g. clangd returning header declarations, `#else` branch walking).

```bash
export CALLTREE_CLANGD_BIN=clangd   # optional override
nvim --headless -u NORC -c "luafile tests/c/run_c_tests.lua"
nvim --headless -u NORC -c "luafile tests/c/run_stress_tests.lua"
# or
make test-c
```

Details and per-scenario expectations: [`tests/c/README.md`](c/README.md).

**Requirements**

- Neovim 0.10+ (built-in C parser)
- clangd 14+
- `gcc`/`clang` available for the compilation database commands

---

## 5. Rust end-to-end (rust-analyzer + tree-sitter-rust)

**Method:** opens files from `tests/fixtures/rust_test`, attaches
**rust-analyzer**, places the cursor via `documentSymbol`, runs
`calltree.analyze_at_cursor()`, and asserts callers / external_calls /
stdlib flags / graceful syntax-error recovery.

```bash
export CALLTREE_RUST_ANALYZER_BIN=rust-analyzer   # optional
export CALLTREE_RUST_PROJECT=/abs/path/to/crate   # optional override
# Ensure rust std sources are visible to rust-analyzer (install via
# `rustup component add rust-src`; the sources live under
# $(rustc --print sysroot)/lib/rustlib/src/rust/library).
nvim --headless -u NORC -c "luafile tests/rust/run_rust_tests.lua"
# or
make test-rust
```

**Requirements**

- Neovim 0.10+ with a **rust** Treesitter parser installed  
  (`:TSInstall rust` via nvim-treesitter, or ship a `parser/rust.so`)
- `rust-analyzer`, `rustc`, `cargo`
- `rust-src` (or equivalent) so rust-analyzer can load the standard library

---

## 6. JavaScript end-to-end (typescript-language-server + tree-sitter-javascript)

**Method:** opens files from `tests/javascript_project/`, attaches
**typescript-language-server** (tsserver), places the cursor on
function/arrow-function/method names via text scan, runs
`calltree.analyze_at_cursor()`, and asserts callers / external_calls /
JSON structure / graceful import handling.

The test suite uses a **shared LSP session** (both `index.js` and
`utils.js` are opened and warmed up before tests run) for speed and
reliable cross-file reference resolution.

```bash
export CALLTREE_TSSERVER_BIN=typescript-language-server   # optional
# Install typescript in the test project (required by tsserver):
cd tests/javascript_project && npm install && cd ../..
nvim --headless -u NORC -c "luafile tests/run_javascript_tests.lua"
```

**Requirements**

- Neovim 0.10+ with a **javascript** Treesitter parser installed
  (`:TSInstall javascript` via nvim-treesitter, or manually compile
  tree-sitter-javascript v0.21.x and place the `.so` in Neovim's
  parser directory — Neovim 0.10 supports ABI 13–14)
- `typescript-language-server` (install via `npm install -g
  typescript-language-server typescript`)
- `typescript` installed in `tests/javascript_project/node_modules`
  (the `typescript-language-server` requires a local TypeScript install
  to function)

**What the tests cover**

| Test | Scenario |
|------|----------|
| 1 | Arrow function (`const add = (a,b) => ...`) cross-file caller detection |
| 2 | Function declaration (`function greet() {}`) cross-file caller detection |
| 3 | Class method (`class App { run() {} }`) current_function detection |
| 4 | Arrow function external_calls (calls imported `add` → resolved to utils.js) |
| 5 | JSON output structure (contains current_function / callers / external_calls / debug) |
| 6 | ES6 import statement doesn't crash analysis |

**Unit tests** (`javascript_spec.lua`, 11 tests) exercise the same JS
language features using mock treesitter trees (no real LSP / Neovim
required), covering: arrow function / function declaration / class
method name extraction, call expression / member call collection,
callers analysis, nested function scope, CommonJS require, ES6 import,
function_expression, and cross-file caller scenarios.

---

## One-shot full matrix

```bash
# Auto-detects binaries on PATH; skips suites whose LSP is missing.
bash tests/run_all_tests.sh

# Explicit binaries / selective skips:
CALLTREE_LUA_BIN=lua5.4 \
CALLTREE_NVIM_BIN=nvim \
CALLTREE_LSP_BIN=lua-language-server \
CALLTREE_CLANGD_BIN=clangd \
CALLTREE_RUST_ANALYZER_BIN=rust-analyzer \
CALLTREE_TSSERVER_BIN=typescript-language-server \
  bash tests/run_all_tests.sh

CALLTREE_SKIP_C=1 CALLTREE_SKIP_RUST=1 CALLTREE_SKIP_JAVASCRIPT=1 \
  bash tests/run_all_tests.sh   # Lua-only
```

Makefile targets:

```bash
make test            # unit only
make test-unit
make test-headless
make test-lsp
make test-c
make test-rust
make test-javascript
make test-all        # == bash tests/run_all_tests.sh
```

---

## Testing methods & techniques used

1. **Mock-based pure-Lua unit tests**  
   Dependency injection of fake `lsp_client` / `treesitter` / `read_file` /
   `getcwd` into the analyzer context. Fast, deterministic, no network or
   language servers.

2. **Fluent scenario builders** (`scenario.lua` + `tree_builder.lua`)  
   Build mock document symbols, references, definitions, and Treesitter node
   trees with a small DSL so each case reads like a spec.

3. **Headless Neovim integration**  
   `nvim --headless -u NORC` loads only this plugin (no user config). Uses
   real Treesitter parsers shipped with Neovim / nvim-treesitter.

4. **Real-LSP end-to-end**  
   Spawns `lua-language-server`, `clangd`, or `rust-analyzer` via
   `vim.lsp.start`, waits for `textDocument/documentSymbol` readiness, then
   drives `calltree.analyze_at_cursor()` / JSON / user commands.

5. **Per-scenario compilation databases (C)**  
   Each C fixture has its own `compile_commands.json` so clangd does not
   index sibling scenarios and leak cross-file references.

6. **Stress / multifile / control-flow fixtures (C)**  
   Nested calls, multi-TU callers, and `if`/`for` branches exercise walker
   and reference-resolution edge cases.

7. **Cursor placement via LSP symbols (Rust)**  
   Cursor is placed with `selectionRange` from `documentSymbol` (not hardcoded
   line numbers), so tests survive formatting drift.

8. **Process isolation / cleanup**  
   Between real-LSP cases, clients are force-stopped and buffers wiped to
   avoid multi-GB OOM on small CI hosts.

9. **Graceful degradation checks**  
   Suites assert precondition failures (no LSP, syntax errors) still return a
   structured result with a useful `debug.completion_reason`.

10. **Public API / complexity helpers** (optional extras under `scripts/`)  
    - `scripts/verify_api_compat.lua` — public API surface  
    - `scripts/measure_complexity.lua` — McCabe-style report  
    - `scripts/verify_lsp.lua` — lua_ls smoke connectivity

---

## Prerequisites cheat-sheet

| Tool | Used by | Notes |
|------|---------|-------|
| **Lua 5.4** | Unit tests | `lua5.4` or `CALLTREE_LUA_BIN` |
| **Neovim 0.10+** | All headless suites | Treesitter + `vim.lsp.start` |
| **Treesitter parsers** | lua, c (bundled); python, rust, javascript (install via nvim-treesitter) | |
| **lua-language-server** | Suite 3 | `CALLTREE_LSP_BIN` |
| **clangd** | Suites 4–5 | `CALLTREE_CLANGD_BIN` |
| **rust-analyzer** + **rustc/cargo** + **rust-src** | Suite 6 | `CALLTREE_RUST_ANALYZER_BIN` |
| **typescript-language-server** + **typescript** | Suite 7 (JS e2e) | `CALLTREE_TSSERVER_BIN`; run `npm install` in `tests/javascript_project/` |
| **pyright** / **pylsp** | Optional for interactive Python use (not required by CI suites) | |

---

## Adding a new test

### Pure-Lua unit test

1. Create `tests/test_<topic>.lua` that returns a module table `M`.
2. Export functions named `test_*`.
3. Add the filename to the `test_files` list in `tests/test_runner.lua`.
4. Use `require("assert")`, `require("scenario")`, `require("mocks")` as needed.

### Headless / real-LSP test

1. Add a `function M.test_...()` to `headless_integration.lua` or
   `headless_real_lsp.lua` and register it in that file’s `M.run()` list.
2. Always clean up temp dirs **and** stop LSP clients on the way out.

### C scenario

1. Add `tests/c/scenarios/sNN_name/` with sources + `compile_commands.json`.
2. Register the scenario in `tests/c/run_c_tests.lua`.

### Rust scenario

1. Extend `tests/fixtures/rust_test` if new symbols are needed.
2. Add a `test_NN_...` function in `tests/rust/run_rust_tests.lua` and append
   it to the `tests` table at the bottom.

---

## Troubleshooting

| Symptom | Likely cause | Fix |
|---------|--------------|-----|
| Unit tests: `module 'calltree...' not found` | Wrong cwd | Run from plugin root |
| Headless: `no parser for 'lua'` | Broken Neovim install | Use official Neovim build with bundled parsers |
| Real-LSP Lua: hangs / OOM | Too many lua_ls processes | Use current `headless_real_lsp.lua` cleanup; ensure ≥1.5 GiB free RAM |
| C S10 cross-file fails | Stale / wrong `compile_commands.json` paths | Run `python3 scripts/rewrite_fixture_paths.py` to regenerate paths; wait for clangd index |
| Rust: `can't load standard library from sysroot` | Missing rust-src | Install via `rustup component add rust-src`; sources live under `$(rustc --print sysroot)/lib/rustlib/src/rust/library` |
| Rust: `could not locate function via documentSymbol` | RA not fully ready | Current runner retries symbol lookup; re-run after `cargo check` in the fixture crate |
| JS: `Could not find a valid TypeScript installation` | Missing local typescript | Run `cd tests/javascript_project && npm install` |
| JS: arrow function `current_function` is nil | Old plugin version (pre-1.2.1) | Ensure you're running v1.2.1+ which added arrow-function name extraction |
| Suite skipped in `run_all_tests.sh` | Binary not on PATH | Install tool or set the matching `CALLTREE_*_BIN` env var |

---

## Exit codes

| Command | `0` | non-zero |
|---------|----|----------|
| `tests/test_runner.lua` | all unit tests passed | ≥1 failure / load error |
| `tests/runner_headless*.lua` | all assertions passed | `cquit! 1` |
| `tests/c/run_*.lua` | all scenarios passed | `cq` |
| `tests/rust/run_rust_tests.lua` | all assertions passed | `cquit! 1` |
| `tests/run_all_tests.sh` | every non-skipped suite passed | any suite failed |
