# calltree.nvim

A Neovim plugin (requires Neovim 0.10+ with LSP and Treesitter) that analyzes
the function under the cursor and reports:

1. **Inbound callers** — every project function that calls the cursor function
   (excluding recursive self-calls and global-scope calls).
2. **Cross-function calls** — every top-level call expression inside the cursor
   function that resolves to another project-defined function.

The result is returned as a structured JSON object — perfect for tooling that
wants to visualize call graphs, build dependency indexes, or feed data into
external analysis pipelines.

**Supported languages (via LSP + Treesitter):** Lua, C, Python, Rust,
JavaScript/TypeScript, and other languages whose Treesitter grammar
exposes function/call nodes and whose LSP implements `definition` /
`references` / `documentSymbol`.

## Output shape

```json
{
  "current_function": {
    "name": "foo",
    "range": [1, 3],
    "file": "/project/main.lua"
  },
  "callers": [
    {
      "file": "/project/caller.lua",
      "call_position": { "line": 2, "character": 5 },
      "caller_function": {
        "name": "bar",
        "range": [1, 3]
      }
    }
  ],
  "external_calls": [
    {
      "call_position": { "line": 2, "character": 5 },
      "function_name": "helper",
      "definition": {
        "file": "/project/helper.lua",
        "function_body_range": [1, 5]
      },
      "resolution_status": "resolved",
      "is_stdlib": false
    }
  ],
  "debug": { "...": "decision trace, timings, precondition results" }
}
```

When preconditions are not met (no LSP, no Treesitter parser, no document
symbols) or the cursor is not on a function-definition name, the plugin
returns the empty result **with the `debug` field still populated** so callers
can inspect why analysis did not run:

```json
{ "current_function": null, "callers": [], "external_calls": [], "debug": { "completion_reason": "preconditions_failed" } }
```

### `debug.completion_reason` values

| value | meaning |
|-------|---------|
| `"preconditions_failed"` | A precondition check failed (see `debug.preconditions[]`). |
| `"cursor_no_node"` | Treesitter returned no node at the cursor position. |
| `"cursor_not_on_function_name"` | Cursor node is not the name of a function-definition node. |
| `"cursor_no_lsp_symbol"` | No LSP document symbol of kind Function/Method encloses the cursor. |
| `"cursor_symbol_wrong_kind"` | The LSP symbol at the cursor is not a Function or Method. |
| `"analyzed"` | Full analysis completed. |

### `debug.caller_decisions[].outcome` values

| value | meaning |
|-------|---------|
| `"kept"` | Caller recorded in `callers[]`. |
| `"excluded_defdecl"` | Ref matches the cursor function's own definition/declaration site. |
| `"no_source"` | Could not read source for the referencing file. |
| `"no_node"` | Treesitter returned no node at the ref position. |
| `"global_scope"` | Call is at global scope (no enclosing function). |
| `"self_recursive"` | Caller is the cursor function itself (recursive). |
| `"error"` | Parse or other error; see `debug.errors[]`. |

### `debug.external_call_decisions[].outcome` values

| value | meaning |
|-------|---------|
| `"kept_resolved"` | Recorded in `external_calls[]` with a definition. |
| `"kept_unresolved"` | Recorded in `external_calls[]` with `definition=null`. |
| `"discarded_in_scope"` | Definition is inside the cursor function (local nested function). |
| `"discarded_outside_project"` | Definition file is not under `getcwd`. |
| `"discarded_no_body"` | Definition site has no implementation body (e.g. `extern`). |
| `"error"` | Parse or other error; see `debug.errors[]`. |

## Usage

Inside Neovim, after the plugin is on your runtimepath:

```vim
:CalltreeAnalyze   " compact summary (current_function + callers + external_calls)
:CalltreeJson      " print the full JSON string
:CalltreeJsonDebug " full JSON with debug forced on
:CalltreeToFile /tmp/result.json  " write full JSON to a file (recommended)
```

Or programmatically:

```lua
local calltree = require("calltree")
local result = calltree.analyze_at_cursor()       -- table
local json    = calltree.analyze_at_cursor_json() -- string
calltree.write_json_to_file("/tmp/result.json")   -- write to file
```

### Configuration

```lua
require("calltree").setup({
  debug = true,        -- default: true. Set to false to skip all debug
                       -- collection and omit the `debug` field from results
                       -- (faster, smaller output for production use).
  user_commands = true, -- default: true. Set to false to skip registering
                        -- :CalltreeAnalyze / :CalltreeJson / :CalltreeToFile.

  -- v1.2.0: post-collection filtering for external_calls.
  -- Both default to true. Pass false to see the raw collected list.
  skip_stdlib_calls = true,            -- drop is_stdlib=true entries
  deduplicate_external_calls = true,   -- collapse same (name, file) pairs
})
```

When `debug = false`:

- The analyzer uses a no-op collector — all `dbg:record_*` calls are cheap no-ops
- No timings are measured, no decision traces are built
- The result table has **no `debug` field** at all
- The analysis itself (callers, external_calls) still runs identically

#### `external_calls` filtering (v1.2.0)

By default, the `external_calls` array in the result is **deduplicated**
and **stdlib-free**:

- **`skip_stdlib_calls = true`** (default): entries with `is_stdlib = true`
  are dropped from the final output. The `is_stdlib` classification is
  unchanged (LSP `SymbolTag` + `STDLIB_PATH_PATTERNS` path heuristics).
- **`deduplicate_external_calls = true`** (default): entries sharing the
  same `(function_name, definition.file)` pair are collapsed, keeping
  the first occurrence (in collection order).

**Processing order**: dedup runs FIRST (on the full collected list,
including stdlib), then the stdlib filter runs on the deduplicated list.
This ensures the first-occurrence-wins rule applies uniformly.

**Summary counts** (`debug.summary.calls_kept`,
`debug.summary.calls_unresolved`) reflect the FINAL post-filter array
length. The raw pre-filter count is stashed in
`debug.inputs.raw_external_calls_before_filter` (only when filtering
actually changes the list) for diagnostics.

To restore the pre-1.2.0 raw behavior (keep every call site, keep
stdlib calls):

```lua
require("calltree").setup({
  skip_stdlib_calls = false,
  deduplicate_external_calls = false,
})
```

Both flags also accept per-call overrides:

```lua
local result = require("calltree").analyze_at_cursor(0, {
  skip_stdlib_calls = false,
  deduplicate_external_calls = false,
  debug = true,
})
```

You can also override `debug` per-call:

```lua
local result_no_debug = require("calltree").analyze_at_cursor(0, { debug = false })
```

## Architecture

```
lua/calltree/
  init.lua              — public API + setup / user commands
  adapter.lua           — bridges Neovim vim.lsp / vim.treesitter to the core
  core/analyzer.lua     — analysis orchestrator
  core/context.lua      — dependency-injected context factory
  core/interfaces.lua   — service interface contracts
  domain/types.lua      — domain model
  analysis/             — callers, external_calls, preconditions, definition_body
  providers/            — lsp_client, treesitter, file_reader adapters
  treesitter/           — node helpers + walker
  resolution/           — require / module path resolution
  infrastructure/       — fs + file_parser
  utils/                — path, range, debug, constants
tests/                  — all automated tests (see tests/README.md)
```

The analysis core is **decoupled** from Neovim: LSP, Treesitter, filesystem,
and `getcwd` are injected via the context table so the pure-Lua unit suite can
run without an editor.

## Running tests

All tests live under [`tests/`](tests/). Full guide: **[`tests/README.md`](tests/README.md)**.  
Install/tooling notes: **[`INSTALL.md`](INSTALL.md)**.

```bash
# Full matrix (unit + headless + lua_ls + clangd + rust-analyzer)
bash tests/run_all_tests.sh
# or
make test-all

# Fast pure-Lua unit tests only (no Neovim required)
lua5.4 tests/test_runner.lua
# or
make test
```

### Suites at a glance

| Suite | Command | Needs |
|-------|---------|-------|
| Pure-Lua unit (162) | `make test` | Lua 5.4 |
| Headless no-LSP (105) | `make test-headless` | Neovim + lua parser |
| Real lua_ls (59) | `make test-lsp` | + lua-language-server |
| C clangd (10+3) | `make test-c` | + clangd, C parser |
| Rust e2e (76) | `make test-rust` | + rust-analyzer, rust parser |
| JavaScript e2e (29) | `make test-javascript` | + typescript-language-server, js parser |

**444 assertions / scenarios** are expected to pass on a fully provisioned host.

### Methods used

- Mock LSP + mock Treesitter in plain Lua (`tests/mocks.lua`, `tree_builder.lua`)
- Headless Neovim with real Treesitter parsers
- Real language servers: **lua-language-server**, **clangd**, **rust-analyzer**, **typescript-language-server**
- Per-scenario `compile_commands.json` for C isolation
- Cursor placement via LSP `documentSymbol` (Rust) for format-stable tests
- Strict process cleanup between real-LSP cases (low-memory safe)

### Language-focused coverage

- **C** (`tests/test_c.lua` mocks + `tests/c/` real clangd): simple defs, callers,
  external calls, function pointers, struct members, typedefs, `#ifdef`, macros,
  complex declarators, cross-file callers, nested/stress fixtures.
- **Python** (`tests/test_python.lua`): functions, methods, nested, lambdas,
  decorators, imports, recursion, syntax errors.
- **Rust** (`tests/rust/` + `tests/fixtures/rust_test`): cross-file callers,
  impl/trait methods, closures, stdlib flags, third-party crates, `cfg`,
  syntax-error recovery.
- **JavaScript/TypeScript** (`tests/javascript_spec.lua` mocks +
  `tests/javascript_project/` real tsserver): arrow functions, function
  declarations, class methods, ES6 imports, CommonJS require, member call
  expressions, nested function scope, cross-file callers.

## License

MIT
