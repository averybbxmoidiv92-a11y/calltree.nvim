--- infrastructure/tree_parser.lua — treesitter parse helpers.
---
--- Keeps parse-result normalization separate from file I/O and cache logic.

local constants = require("calltree.utils.constants")

local M = {}

--- Extract a usable root node from a treesitter parse result or mock tree.
--- @param tree table|nil
--- @return table|nil root
function M.extract_root(tree)
  if tree == nil then return nil end
  if type(tree.root) == "function" then
    local ok, root = pcall(tree.root, tree)
    return (ok and root) or nil
  end
  if type(tree.root) == "table" then
    return tree.root
  end
  return tree
end

local function parse_error_message(tree)
  local max_len = constants.DEBUG_TRUNCATE_LEN or 200
  if vim and vim.inspect and type(tree) == "table" then
    return "treesitter parse failed: " .. vim.inspect(tree):sub(1, max_len)
  end
  return "treesitter parse failed: " .. tostring(tree)
end

--- Parse source code and return its root node.
--- @param ts table treesitter service with parse(source, language)
--- @param source string
--- @param language string|nil
--- @return table|nil root, table|nil tree, string|nil error_message
function M.parse_tree(ts, source, language)
  if ts == nil then return nil, nil, "nil treesitter service" end
  if source == nil then return nil, nil, "nil source" end

  local lang = language or constants.DEFAULT_LANGUAGE
  local ok, tree = pcall(ts.parse, ts, source, lang)
  if not ok or not tree then
    return nil, nil, parse_error_message(tree)
  end

  local root = M.extract_root(tree)
  if root == nil then
    return nil, tree, "parse succeeded but root is nil"
  end
  return root, tree, nil
end

return M
