# C Language Tests for calltree.nvim

Location: `tests/c/`.

This directory contains two flavors of C tests:

1. **Mock-based unit tests** (`tests/test_c.lua`, run via `lua tests/test_runner.lua`):
   10 scenarios that use hand-built mock treesitter trees and mock LSP
   responses. These run in pure Lua (no Neovim/clangd required).

2. **Real-LSP integration tests** (`tests/c/run_c_tests.lua`,
   `tests/c/run_stress_tests.lua`): REAL C sources, REAL tree-sitter-c,
   REAL **clangd**. These catch integration issues mocks cannot.

## Requirements

- **Neovim 0.10+** (built-in C tree-sitter parser)
- **clangd 14+** (`CALLTREE_CLANGD_BIN` or `clangd` on `$PATH`)
- A C compiler referenced by each scenario’s `compile_commands.json` (`gcc`)

## Running

```bash
# From plugin root
nvim --headless -u NORC -c "luafile tests/c/run_c_tests.lua"
nvim --headless -u NORC -c "luafile tests/c/run_stress_tests.lua"

# Or via Makefile / full matrix
make test-c
bash tests/run_all_tests.sh
```

## Scenarios

| ID | Directory | What it checks |
|----|-----------|----------------|
| S01 | `scenarios/s01_simple/` | Simple function definition identification |
| S02 | `scenarios/s02_callers/` | Direct callers (single file), self-ref excluded |
| S03 | `scenarios/s03_external/` | Same-file external call resolution |
| S04 | `scenarios/s04_funcptr/` | Function-pointer param → unresolved |
| S05 | `scenarios/s05_struct/` | Struct member function-pointer call |
| S06 | `scenarios/s06_typedef/` | typedef alias + function name extraction |
| S07 | `scenarios/s07_ifdef/` | Active `#ifdef` branch only (skip `#else`) |
| S08 | `scenarios/s08_macro/` | Macro invocations filtered (not call_expression) |
| S09 | `scenarios/s09_complex/` | Nested pointer/function declarators |
| S10 | `scenarios/s10_cross_file/` | Cross-TU caller (`main.c` → `math.c`) |
| ST1 | `stress/stress1_nested.c` | Nested calls + stdlib |
| ST2 | `stress/multifile/` | Multiple cross-file callers |
| ST3 | `stress/stress3_control_flow.c` | if/for + multi call sites |

Each scenario directory has its own `compile_commands.json` so clangd does not
index sibling scenarios and leak references.

## Method notes

- Uses `vim.lsp.start` (Neovim 0.8+) rather than `vim.lsp.config` so the suite
  works on Neovim 0.10 as well as 0.11+.
- Sibling TUs are buffer-loaded and attached so clangd’s reference index is warm
  before cross-file assertions (S10 / multifile stress).
- Clients are force-stopped between scenarios to keep memory bounded.
