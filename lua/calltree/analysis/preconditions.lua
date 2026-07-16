--- analysis/preconditions.lua — precondition checks for calltree.nvim.
---
--- Verifies the three preconditions required by the spec:
---   1. Treesitter is available, can parse, and the tree has no error.
---   2. LSP client is available and supports the methods we need.
---   3. The LSP returns at least one document symbol for the current file.
---
--- Pure Lua, no Neovim dependencies.

local utils       = require("calltree.utils")
local tree_parser = require("calltree.infrastructure.tree_parser")

local M = {}

------------------------------------------------------------------------------
-- LSP SymbolKind constants used by document-symbol search.
------------------------------------------------------------------------------
local LSP_SYMBOL_FUNCTION = utils.LSP_SYMBOL_FUNCTION
local LSP_SYMBOL_METHOD   = utils.LSP_SYMBOL_METHOD
local LSP_SYMBOL_VARIABLE = utils.LSP_SYMBOL_VARIABLE
local LSP_SYMBOL_CONSTANT = utils.LSP_SYMBOL_CONSTANT

-- Return true when an LSP range contains a cursor position. The LSP uses
-- zero-based line/character coordinates, matching ctx.cursor_pos.
local function _range_contains_cursor(range, cursor_pos)
  if range == nil or range.start == nil or range["end"] == nil then return false end
  local s, e = range.start, range["end"]
  local after_start = cursor_pos.line > s.line
    or (cursor_pos.line == s.line and cursor_pos.character >= s.character)
  local before_end = cursor_pos.line < e.line
    or (cursor_pos.line == e.line and cursor_pos.character <= e.character)
  return after_start and before_end
end

-- Search a DocumentSymbol tree for the deepest function or method at the
-- cursor. Variable/Constant symbols are accepted as a JS/TS arrow-function
-- fallback; the caller verifies the matching treesitter node is a function.
local function _search_symbol_tree(list, cursor_pos, depth, max_depth)
  if depth > max_depth then return nil end
  -- First pass: look for a Function/Method symbol (preferred).
  for _, sym in ipairs(list) do
    if _range_contains_cursor(sym.range, cursor_pos) then
      if (sym.kind == LSP_SYMBOL_FUNCTION
                      or sym.kind == LSP_SYMBOL_METHOD) then
        if sym.children and #sym.children > 0 then
          local deeper = _search_symbol_tree(sym.children, cursor_pos, depth + 1, max_depth)
          if deeper then return deeper end
        end
        return sym
      end
    end
  end
  -- Descend through in-range non-function symbols to find nested functions.
  for _, sym in ipairs(list) do
    if _range_contains_cursor(sym.range, cursor_pos) and sym.children and #sym.children > 0 then
      local deeper = _search_symbol_tree(sym.children, cursor_pos, depth + 1, max_depth)
      if deeper then return deeper end
    end
  end
  -- JS/TS arrow-function fallback.
  for _, sym in ipairs(list) do
    if _range_contains_cursor(sym.range, cursor_pos)
       and (sym.kind == LSP_SYMBOL_VARIABLE or sym.kind == LSP_SYMBOL_CONSTANT) then
      return sym
    end
  end
  return nil
end

------------------------------------------------------------------------------
-- Sub-checks. Each returns ok plus the payload needed by later phases.
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

  local root = tree_parser.extract_root(tree)
  if root == nil then
    dbg:precondition("treesitter.root", false, "root is nil")
    return false
  end
  if root.has_error == true then
    dbg:precondition("treesitter.root_has_error", false, "root.has_error is true")
    return false
  end
  -- The analyzer expects a treesitter-like node.
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
