--- analysis/preconditions.lua — precondition checks for calltree.nvim.
---
--- Verifies the three preconditions required by the spec:
---   1. Treesitter is available, can parse, and the tree has no error.
---   2. LSP client is available and supports the methods we need.
---   3. The LSP returns at least one document symbol for the current file.
---
--- Pure Lua, no Neovim dependencies.

local utils     = require("calltree.utils")
local debug_mod = require("calltree.utils.debug")

local M = {}

------------------------------------------------------------------------------
-- _search_symbol_tree: recursive search of a DocumentSymbol tree for the
-- symbol whose range contains cursor_pos AND whose kind is Function or
-- Method. Prefers the deepest matching symbol (descends into children
-- before returning the current sym).
--
-- Extracted to module level (previously a nested `search` closure inside
-- M.find_function_symbol_at). The nested version couldn't be unit-tested
-- in isolation and was 33 lines deep, hurting readability. The depth
-- limit is now passed explicitly so callers control the cap.
--
-- The long in-range expression was split into `after_start` / `before_end`
-- locals for readability (Lua's `and`/`or` precedence makes the original
-- one-liner technically correct but very hard to follow).
------------------------------------------------------------------------------
-- LSP SymbolKind constants used by the symbol search below.
-- Local aliases keep the comparisons readable; the values themselves
-- are sourced from the centralized utils.constants table so a future
-- SymbolKind edit only needs one change. Previously VARIABLE / CONSTANT
-- were redefined here as local literals (duplicating core/analyzer.lua),
-- while FUNCTION / METHOD already came from utils — the inconsistency
-- was a code-review finding.
local LSP_SYMBOL_FUNCTION = utils.LSP_SYMBOL_FUNCTION
local LSP_SYMBOL_METHOD   = utils.LSP_SYMBOL_METHOD
local LSP_SYMBOL_VARIABLE = utils.LSP_SYMBOL_VARIABLE
local LSP_SYMBOL_CONSTANT = utils.LSP_SYMBOL_CONSTANT

-- _search_symbol_tree: recursive search of a DocumentSymbol tree for the
-- symbol whose range contains cursor_pos AND whose kind is Function or
-- Method. Prefers the deepest matching symbol (descends into children
-- before returning the current sym).
--
-- JS/TS arrow-function fallback: typescript-language-server classifies
-- `const add = (a,b) => a+b` as a Constant (14), not a Function (12).
-- When no Function/Method symbol is found at the cursor, we accept a
-- Variable (13) or Constant (14) symbol as a fallback — the caller
-- (analyzer._locate_cursor_function) re-validates that the treesitter
-- node at the cursor is actually a function-type node before trusting
-- this fallback, so a non-function variable/constant won't slip through.
local function _search_symbol_tree(list, cursor_pos, depth, max_depth)
  if depth > max_depth then return nil end
  -- First pass: look for a Function/Method symbol (preferred).
  for _, sym in ipairs(list) do
    if sym.range and sym.range.start and sym.range["end"] then
      local s, e = sym.range.start, sym.range["end"]
      local after_start = cursor_pos.line > s.line
        or (cursor_pos.line == s.line and cursor_pos.character >= s.character)
      local before_end = cursor_pos.line < e.line
        or (cursor_pos.line == e.line and cursor_pos.character <= e.character)
      local in_range = after_start and before_end
      if in_range and (sym.kind == LSP_SYMBOL_FUNCTION
                      or sym.kind == LSP_SYMBOL_METHOD) then
        if sym.children and #sym.children > 0 then
          local deeper = _search_symbol_tree(sym.children, cursor_pos, depth + 1, max_depth)
          if deeper then return deeper end
        end
        return sym
      end
    end
  end
  -- Second pass: descend into children of any in-range symbol to find
  -- a deeper Function/Method match (covers nested function definitions
  -- inside a class/module symbol that itself isn't Function/Method).
  for _, sym in ipairs(list) do
    if sym.range and sym.range.start and sym.range["end"] then
      local s, e = sym.range.start, sym.range["end"]
      local after_start = cursor_pos.line > s.line
        or (cursor_pos.line == s.line and cursor_pos.character >= s.character)
      local before_end = cursor_pos.line < e.line
        or (cursor_pos.line == e.line and cursor_pos.character <= e.character)
      if (after_start and before_end) and sym.children and #sym.children > 0 then
        local deeper = _search_symbol_tree(sym.children, cursor_pos, depth + 1, max_depth)
        if deeper then return deeper end
      end
    end
  end
  -- Third pass (JS/TS fallback): if no Function/Method was found, accept
  -- a Variable (13) or Constant (14) symbol whose range contains the
  -- cursor. The caller re-validates this against the treesitter node.
  for _, sym in ipairs(list) do
    if sym.range and sym.range.start and sym.range["end"] then
      local s, e = sym.range.start, sym.range["end"]
      local after_start = cursor_pos.line > s.line
        or (cursor_pos.line == s.line and cursor_pos.character >= s.character)
      local before_end = cursor_pos.line < e.line
        or (cursor_pos.line == e.line and cursor_pos.character <= e.character)
      if (after_start and before_end)
         and (sym.kind == LSP_SYMBOL_VARIABLE or sym.kind == LSP_SYMBOL_CONSTANT) then
        return sym
      end
    end
  end
  return nil
end

------------------------------------------------------------------------------
-- Sub-checks, extracted from M.check to keep each focused and testable.
-- Each returns (ok, payload); payload is the treesitter root or symbol
-- list (nil when ok is false). Previously M.check was 112 lines mixing
-- treesitter / LSP interface / document-symbol checks — these helpers
-- reduce it to ~19 lines and let each sub-check be tested independently.
--
-- IMPORTANT: these `local function` declarations MUST appear above
-- M.check. Lua local functions are lexically scoped — a `local function
-- foo()` declared AFTER M.check would NOT be visible inside M.check's
-- body (the reference inside M.check would resolve to the global `foo`,
-- which is nil). A previous refactor introduced this ordering bug,
-- which silently broke every pure-Lua unit test (`preconditions_panic`).
------------------------------------------------------------------------------

-- 1. Treesitter present + interface valid + parse succeeds + root usable.
-- @return boolean ok, table|nil root
local function _check_treesitter(ctx, dbg)
  local treesitter = ctx.treesitter
  local source_code = ctx.source_code
  local language = ctx.language or utils.DEFAULT_LANGUAGE

  -- 1a. Treesitter object present and exposes required methods?
  local ts_ok = true
  if treesitter == nil then
    ts_ok = false
    dbg:precondition("treesitter.present", false, "treesitter is nil")
  else
    if type(treesitter.parse) ~= "function" then
      ts_ok = false
      dbg:precondition("treesitter.parse_method", false, "treesitter.parse is not a function")
    end
    if type(treesitter.descendant_for_range) ~= "function" then
      ts_ok = false
      dbg:precondition("treesitter.descendant_for_range_method", false,
        "treesitter.descendant_for_range is not a function")
    end
    if ts_ok then
      dbg:precondition("treesitter.interface", true)
    end
  end
  if not ts_ok then return false end

  -- 1b. Treesitter can actually parse the source.
  local ok_parse, tree = pcall(treesitter.parse, treesitter, source_code, language)
  if not ok_parse then
    dbg:precondition("treesitter.parse", false, "pcall failed: " .. tostring(tree))
    dbg:error("precondition.treesitter.parse", tree)
    return false
  end
  if tree == nil then
    dbg:precondition("treesitter.parse", false, "parse returned nil")
    return false
  end
  dbg:ts_parse("main_buffer", language, true, tree.has_error, nil)

  if tree.has_error == true then
    dbg:precondition("treesitter.has_error", false, "tree.has_error is true")
    return false
  end

  -- Wrap `tree:root()` in pcall + type guard (consistent with
  -- file_parser.parse_tree and file_reader.get_tree). Simplified the
  -- `tree.root ~= nil and type(...) == "table"` branch — the `~= nil`
  -- check is redundant since `type(x) == "table"` already implies x is
  -- non-nil.
  local root
  if type(tree.root) == "function" then
    local ok_r, r = pcall(tree.root, tree)
    root = (ok_r and r) or nil
  elseif type(tree.root) == "table" then
    root = tree.root
  else
    root = tree
  end
  if root == nil then
    dbg:precondition("treesitter.root", false, "root is nil")
    return false
  end
  -- Unified the two has_error check styles: previously tree-level used
  -- `== true` and root-level used `type() == "boolean" and ...`. Both
  -- now use the simpler `== true` form (Lua treats only true/nil as
  -- booleans in this context; non-boolean values are treated as falsy
  -- which is the desired behavior for a missing has_error field).
  if root.has_error == true then
    dbg:precondition("treesitter.root_has_error", false, "root.has_error is true")
    return false
  end
  -- Defensive: when `tree.root` is a function but returns nil (mock
  -- scenarios, or treesitter parse anomaly), the `or tree` fallback
  -- would assign `root = tree`. The downstream `root:type()` call
  -- requires `type` to be a method on root — many mock trees only
  -- implement `root()` and not `type()`, which would crash here.
  -- Bail out explicitly when root has no `type` method.
  if type(root.type) ~= "function" then
    dbg:precondition("treesitter.root.type_method", false,
      "root has no :type() method (tree.root() returned non-node?)")
    return false
  end
  dbg:precondition("treesitter", true, "root_type=" .. tostring(root:type()))
  return true, root
end

-- 2. LSP available with required methods?
-- @return boolean ok
local function _check_lsp_interface(ctx, dbg)
  local lsp_client = ctx.lsp_client
  if lsp_client == nil then
    dbg:precondition("lsp.present", false, "lsp_client is nil")
    return false
  end
  local lsp_ok = true
  -- Use the centralized constant instead of an inline list literal so
  -- this stays in sync with any future additions to the required set.
  for _, m in ipairs(utils.REQUIRED_LSP_METHODS) do
    if type(lsp_client[m]) ~= "function" then
      lsp_ok = false
      dbg:precondition("lsp." .. m, false, "lsp_client." .. m .. " is not a function")
    end
  end
  if not lsp_ok then return false end
  dbg:precondition("lsp.interface", true)
  return true
end

-- 3. LSP returns at least one document symbol for this file.
-- @return boolean ok, table|nil symbols
local function _check_document_symbols(ctx, dbg)
  local lsp_client = ctx.lsp_client
  local uri = utils.path_to_uri(ctx.file_path)
  local symbols_ok, symbols = pcall(lsp_client.document_symbols, lsp_client, uri)
  dbg:lsp_call(utils.LSP_METHODS.document_symbol, { uri = uri }, symbols,
    (not symbols_ok) and symbols or nil)
  if not symbols_ok then
    dbg:precondition("lsp.document_symbols", false, "pcall failed: " .. tostring(symbols))
    dbg:error("precondition.lsp.document_symbols", symbols)
    return false
  end
  if symbols == nil or #symbols == 0 then
    dbg:precondition("lsp.document_symbols", false, "empty symbol list")
    return false
  end
  dbg:precondition("lsp.document_symbols", true, "symbol_count=" .. #symbols)
  return true, symbols
end

--- Check all preconditions and record each individual check in the debug collector.
--- @param ctx table analysis context
--- @param dbg table debug collector
--- @return boolean ok
--- @return table|nil root (treesitter root node) when ok
--- @return table|nil symbols (LSP document symbols) when ok
function M.check(ctx, dbg)
  local root, symbols = nil, nil
  local ts_ok, ts_root = _check_treesitter(ctx, dbg)
  if not ts_ok then return false end
  root = ts_root

  local lsp_ok = _check_lsp_interface(ctx, dbg)
  if not lsp_ok then return false end

  local sym_ok, sym_list = _check_document_symbols(ctx, dbg)
  if not sym_ok then return false end
  symbols = sym_list

  return true, root, symbols
end

--- Find the document symbol at the cursor position whose kind is Function or Method.
--- @param symbols table list of LSP DocumentSymbol
--- @param cursor_pos table { line, character } 0-based
--- @return table|nil symbol
function M.find_function_symbol_at(symbols, cursor_pos)
  if not symbols then return nil end
  -- No `or 64` fallback: utils.MAX_SYMBOL_DEPTH must be defined by
  -- constants.lua (it is). Removing the fallback surfaces a missing
  -- constant as a hard error rather than silently degrading — same
  -- rationale as the equivalent fix in external_calls.lua.
  local MAX_SYMBOL_DEPTH = utils.MAX_SYMBOL_DEPTH
  return _search_symbol_tree(symbols, cursor_pos, 1, MAX_SYMBOL_DEPTH)
end

return M
