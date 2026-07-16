#!/bin/bash
# run_all_tests.sh — runs all calltree.nvim test suites.
#
# Suites:
#   1. Pure-Lua unit tests          (mocked LSP / treesitter)
#   2. Neovim headless (no LSP)     (real treesitter, no language server)
#   3. Neovim headless REAL-LSP     (real lua_ls)
#   4. C real-LSP scenarios         (real clangd + tree-sitter-c)
#   5. C stress tests               (real clangd)
#   6. Rust end-to-end              (real rust-analyzer + tree-sitter-rust)
#   7. JavaScript end-to-end        (real typescript-language-server + tree-sitter-javascript)
#
# Exits 0 only if every non-skipped suite passes.
#
# Environment overrides (all optional):
#   CALLTREE_LUA_BIN            — lua5.4 binary (default: lua5.4 / lua on PATH)
#   CALLTREE_NVIM_BIN           — nvim binary  (default: nvim on PATH)
#   CALLTREE_LSP_BIN            — lua-language-server (default: on PATH)
#   CALLTREE_CLANGD_BIN         — clangd (default: clangd on PATH)
#   CALLTREE_RUST_ANALYZER_BIN  — rust-analyzer (default: rust-analyzer on PATH)
#   CALLTREE_TSSERVER_BIN       — typescript-language-server (default: on PATH)
#   CALLTREE_RUST_PROJECT       — path to rust fixture crate
#   CALLTREE_VIMRUNTIME         — nvim runtime path
#   CALLTREE_SKIP_C             — set to 1 to skip C real-LSP suites
#   CALLTREE_SKIP_RUST          — set to 1 to skip Rust e2e suite
#   CALLTREE_SKIP_REAL_LSP      — set to 1 to skip lua_ls real-LSP suite
#   CALLTREE_SKIP_JAVASCRIPT    — set to 1 to skip JavaScript e2e suite

set -u
# This script lives in tests/; plugin root is the parent directory.
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
cd "$SCRIPT_DIR/.."
RESOURCE="$(pwd)"

LUA_BIN="${CALLTREE_LUA_BIN:-}"
if [ -z "$LUA_BIN" ]; then
  if command -v lua5.4 >/dev/null 2>&1; then LUA_BIN=lua5.4
  elif command -v lua >/dev/null 2>&1; then LUA_BIN=lua
  else LUA_BIN=lua5.4
  fi
fi
NVIM_BIN="${CALLTREE_NVIM_BIN:-nvim}"
LSP_BIN="${CALLTREE_LSP_BIN:-lua-language-server}"
CLANGD_BIN="${CALLTREE_CLANGD_BIN:-clangd}"
RA_BIN="${CALLTREE_RUST_ANALYZER_BIN:-rust-analyzer}"
TSS_BIN="${CALLTREE_TSSERVER_BIN:-typescript-language-server}"

if [ -z "${CALLTREE_VIMRUNTIME:-}" ]; then
  nvim_prefix="$(dirname "$(dirname "$NVIM_BIN")" 2>/dev/null)"
  if [ -d "$nvim_prefix/share/nvim/runtime" ]; then
    export VIMRUNTIME="$nvim_prefix/share/nvim/runtime"
  fi
else
  export VIMRUNTIME="$CALLTREE_VIMRUNTIME"
fi

export PATH="${HOME}/.local/bin:${PATH}"
export CALLTREE_LSP_BIN="$LSP_BIN"
export CALLTREE_CLANGD_BIN="$CLANGD_BIN"
export CALLTREE_RUST_ANALYZER_BIN="$RA_BIN"
export CALLTREE_TSSERVER_BIN="$TSS_BIN"

echo "================================================================"
echo "calltree.nvim — full test run"
echo "================================================================"
echo "resource dir : $RESOURCE"
echo "lua  : $($LUA_BIN -v 2>&1)"
echo "nvim : $($NVIM_BIN --version 2>&1 | head -1)"
echo "lua_ls : $($LSP_BIN --version 2>&1 | head -1)"
echo "clangd : $($CLANGD_BIN --version 2>&1 | head -1)"
echo "rust-analyzer : $($RA_BIN --version 2>&1 | head -1)"
echo "tsserver : $($TSS_BIN --version 2>&1 | head -1)"
echo "================================================================"

EXIT_CODE=0
PASS_COUNT=0
FAIL_COUNT=0
SKIP_COUNT=0

run_step() {
  local label="$1"
  shift
  echo ""
  echo ">>> $label"
  echo "----------------------------------------------------------------"
  if "$@"; then
    echo "[OK]   $label"
    PASS_COUNT=$((PASS_COUNT + 1))
    return 0
  else
    local ec=$?
    echo "[FAIL] $label (exit $ec)"
    FAIL_COUNT=$((FAIL_COUNT + 1))
    EXIT_CODE=1
    return $ec
  fi
}

skip_step() {
  local label="$1"
  local reason="$2"
  echo ""
  echo ">>> $label"
  echo "----------------------------------------------------------------"
  echo "[SKIP] $reason"
  SKIP_COUNT=$((SKIP_COUNT + 1))
}

# --- 1. Pure-Lua unit tests ---------------------------------------------
run_step "[1/7] Pure-Lua unit tests" "$LUA_BIN" tests/test_runner.lua || true

# --- 2. Neovim headless integration (no LSP) ----------------------------
run_step "[2/7] Neovim headless integration (no LSP)" \
  "$NVIM_BIN" --headless -u NORC -c "luafile tests/runner_headless.lua" || true

# --- 3. Neovim headless REAL-LSP (lua_ls) -------------------------------
if [ "${CALLTREE_SKIP_REAL_LSP:-0}" = "1" ]; then
  skip_step "[3/7] Neovim headless REAL-LSP (lua_ls)" "CALLTREE_SKIP_REAL_LSP=1"
elif ! command -v "$LSP_BIN" >/dev/null 2>&1 && [ ! -x "$LSP_BIN" ]; then
  skip_step "[3/7] Neovim headless REAL-LSP (lua_ls)" \
    "lua-language-server not found at '$LSP_BIN'"
else
  run_step "[3/7] Neovim headless REAL-LSP (lua_ls)" \
    "$NVIM_BIN" --headless -u NORC -c "luafile tests/runner_headless_real_lsp.lua" || true
fi

# --- 4. C real-LSP scenarios (clangd) -----------------------------------
if [ "${CALLTREE_SKIP_C:-0}" = "1" ]; then
  skip_step "[4/7] C real-LSP scenarios (clangd)" "CALLTREE_SKIP_C=1"
elif ! command -v "$CLANGD_BIN" >/dev/null 2>&1 && [ ! -x "$CLANGD_BIN" ]; then
  skip_step "[4/7] C real-LSP scenarios (clangd)" "clangd not found at '$CLANGD_BIN'"
else
  run_step "[4/7] C real-LSP scenarios (clangd)" \
    "$NVIM_BIN" --headless -u NORC -c "luafile tests/c/run_c_tests.lua" || true
fi

# --- 5. C stress tests --------------------------------------------------
if [ "${CALLTREE_SKIP_C:-0}" = "1" ]; then
  skip_step "[5/7] C stress tests (clangd)" "CALLTREE_SKIP_C=1"
elif ! command -v "$CLANGD_BIN" >/dev/null 2>&1 && [ ! -x "$CLANGD_BIN" ]; then
  skip_step "[5/7] C stress tests (clangd)" "clangd not found at '$CLANGD_BIN'"
else
  run_step "[5/7] C stress tests (clangd)" \
    "$NVIM_BIN" --headless -u NORC -c "luafile tests/c/run_stress_tests.lua" || true
fi

# --- 6. Rust end-to-end (rust-analyzer) ---------------------------------
if [ "${CALLTREE_SKIP_RUST:-0}" = "1" ]; then
  skip_step "[6/7] Rust end-to-end (rust-analyzer)" "CALLTREE_SKIP_RUST=1"
elif ! command -v "$RA_BIN" >/dev/null 2>&1 && [ ! -x "$RA_BIN" ]; then
  skip_step "[6/7] Rust end-to-end (rust-analyzer)" \
    "rust-analyzer not found at '$RA_BIN'"
else
  run_step "[6/7] Rust end-to-end (rust-analyzer)" \
    "$NVIM_BIN" --headless -u NORC -c "luafile tests/rust/run_rust_tests.lua" || true
fi

# --- 7. JavaScript end-to-end (typescript-language-server) -------------
if [ "${CALLTREE_SKIP_JAVASCRIPT:-0}" = "1" ]; then
  skip_step "[7/7] JavaScript end-to-end (typescript-language-server)" "CALLTREE_SKIP_JAVASCRIPT=1"
elif ! command -v "$TSS_BIN" >/dev/null 2>&1 && [ ! -x "$TSS_BIN" ]; then
  skip_step "[7/7] JavaScript end-to-end (typescript-language-server)" \
    "typescript-language-server not found at '$TSS_BIN'"
else
  run_step "[7/7] JavaScript end-to-end (typescript-language-server)" \
    "$NVIM_BIN" --headless -u NORC -c "luafile tests/run_javascript_tests.lua" || true
fi

echo ""
echo "================================================================"
echo "Suites: $PASS_COUNT passed, $FAIL_COUNT failed, $SKIP_COUNT skipped"
if [ $EXIT_CODE -eq 0 ]; then
  echo "ALL TESTS PASSED"
else
  echo "SOME TESTS FAILED"
fi
echo "================================================================"
exit $EXIT_CODE
