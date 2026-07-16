--- utils/init.lua — unified export for calltree utilities.
--- Provides backward-compatible access to all constants, path, and range helpers.
--- Other modules should `require("calltree.utils")` to get everything.

local constants = require("calltree.utils.constants")
local path      = require("calltree.utils.path")
local range     = require("calltree.utils.range")

-- Merge all sub-modules into one table for backward compatibility.
local M = {}

-- Constants
M.FUNCTION_NODE_TYPES  = constants.FUNCTION_NODE_TYPES
M.NAME_NODE_TYPES      = constants.NAME_NODE_TYPES
M.CALL_NODE_TYPES      = constants.CALL_NODE_TYPES
M.LSP_SYMBOL_FUNCTION  = constants.LSP_SYMBOL_FUNCTION
M.LSP_SYMBOL_METHOD    = constants.LSP_SYMBOL_METHOD
M.LSP_SYMBOL_VARIABLE  = constants.LSP_SYMBOL_VARIABLE
M.LSP_SYMBOL_CONSTANT  = constants.LSP_SYMBOL_CONSTANT
M.LSP_TAG_DEPRECATED   = constants.LSP_TAG_DEPRECATED
M.LSP_TAG_SYSTEM_LIBRARY = constants.LSP_TAG_SYSTEM_LIBRARY
M.LSP_TAG_STR_SYSTEM     = constants.LSP_TAG_STR_SYSTEM
M.LSP_TAG_STR_LIBRARY    = constants.LSP_TAG_STR_LIBRARY
M.DEFAULT_LANGUAGE       = constants.DEFAULT_LANGUAGE
M.REQUIRED_LSP_METHODS   = constants.REQUIRED_LSP_METHODS
M.LSP_METHODS            = constants.LSP_METHODS
M.PREPROC_INACTIVE_BRANCH_TYPES = constants.PREPROC_INACTIVE_BRANCH_TYPES

-- Resolution / decision status enums (promoted from inline string literals).
M.RESOLUTION_STATUS_RESOLVED   = constants.RESOLUTION_STATUS_RESOLVED
M.RESOLUTION_STATUS_UNRESOLVED = constants.RESOLUTION_STATUS_UNRESOLVED
M.CALLER_OUTCOME_EXCLUDED_DEFDECL = constants.CALLER_OUTCOME_EXCLUDED_DEFDECL
M.CALLER_OUTCOME_KEPT             = constants.CALLER_OUTCOME_KEPT
M.CALLER_OUTCOME_SELF_RECURSIVE   = constants.CALLER_OUTCOME_SELF_RECURSIVE
M.CALLER_OUTCOME_NO_SOURCE        = constants.CALLER_OUTCOME_NO_SOURCE
M.CALLER_OUTCOME_NO_NODE          = constants.CALLER_OUTCOME_NO_NODE
M.CALLER_OUTCOME_GLOBAL_SCOPE     = constants.CALLER_OUTCOME_GLOBAL_SCOPE
M.CALLER_OUTCOME_ERROR            = constants.CALLER_OUTCOME_ERROR
M.CALL_OUTCOME_KEPT_RESOLVED      = constants.CALL_OUTCOME_KEPT_RESOLVED
M.CALL_OUTCOME_KEPT_UNRESOLVED    = constants.CALL_OUTCOME_KEPT_UNRESOLVED
M.CALL_OUTCOME_KEPT_STDLIB        = constants.CALL_OUTCOME_KEPT_STDLIB
M.CALL_OUTCOME_KEPT_EXTERNAL_CRATE = constants.CALL_OUTCOME_KEPT_EXTERNAL_CRATE
M.CALL_OUTCOME_DISCARDED_IN_SCOPE = constants.CALL_OUTCOME_DISCARDED_IN_SCOPE
M.CALL_OUTCOME_DISCARDED_NO_BODY  = constants.CALL_OUTCOME_DISCARDED_NO_BODY

-- Centralized magic numbers
M.MAX_NODE_TEXT_LEN      = constants.MAX_NODE_TEXT_LEN
M.MAX_NAME_HOPS          = constants.MAX_NAME_HOPS
M.MAX_PATH_DEPTH         = constants.MAX_PATH_DEPTH
M.MAX_PARENT_HOPS        = constants.MAX_PARENT_HOPS
M.MAX_SUBTREE_DEPTH      = constants.MAX_SUBTREE_DEPTH
M.MAX_WALK_DEPTH         = constants.MAX_WALK_DEPTH
M.MAX_ANCESTOR_HOPS      = constants.MAX_ANCESTOR_HOPS
M.DEFAULT_LSP_TIMEOUT_MS = constants.DEFAULT_LSP_TIMEOUT_MS
M.MAX_FILE_SIZE_BYTES    = constants.MAX_FILE_SIZE_BYTES
M.DEBUG_TRUNCATE_LEN     = constants.DEBUG_TRUNCATE_LEN
M.MOCK_DUMP_TEXT_LEN     = constants.MOCK_DUMP_TEXT_LEN
M.MAX_SYMBOL_DEPTH       = constants.MAX_SYMBOL_DEPTH

-- Path utilities
M.path_to_uri  = path.path_to_uri
M.uri_to_path  = path.uri_to_path
M.is_path_under = path.is_path_under

-- Range utilities
M.range_equal            = range.range_equal
M.location_equal         = range.location_equal
M.location_in_list       = range.location_in_list
M.ts_range_to_lines_1based = range.ts_range_to_lines_1based
M.pos_to_1based          = range.pos_to_1based
M.find_enclosing_location = range.find_enclosing_location
M.pos_in_ts_range        = range.pos_in_ts_range
M.find_pos_of            = range.find_pos_of

------------------------------------------------------------------------------
-- Unified node text extraction.
-- Previously duplicated across treesitter/nodes.lua:node_text,
-- treesitter/walker.lua:_node_text_and_range, and
-- resolution/require_resolver.lua:get_node_text, with slightly different
-- behaviors (nodes.lua had an n.name fallback; walker/require_resolver did
-- not). Unified here into one helper, using the most defensive behavior
-- (includes the n.name fallback).
------------------------------------------------------------------------------

--- Extract text from a treesitter-node-like object.
--- Order of preference:
---   1. `node:text()` (real treesitter method, pcall-wrapped)
---   2. `node._text` (mock-node convention)
---   3. `node.name` (some mock nodes use this)
---   4. nil
--- @param n table|nil
--- @return string|nil
local function node_text(n)
  if n == nil then return nil end
  if n.text and type(n.text) == "function" then
    local ok, t = pcall(n.text, n)
    if ok and t ~= nil then
      return t
    end
    -- pcall failed: previously this was silently swallowed. There's no
    -- `dbg` parameter on this helper so we can't record the error in
    -- the debug collector from here, but we at least fall through to
    -- the _text / name fallbacks below so callers don't get a nil
    -- where a fallback would have worked.
  end
  return n._text or n.name or nil
end
M.node_text = node_text

------------------------------------------------------------------------------
-- safe_range: pcall-wrapped `node:range()` returning 4 values (or 4 nils).
-- Previously the `pcall(node.range, node)` pattern was duplicated across
-- callers.lua (4 sites), definition_body.lua, analyzer.lua, walker.lua,
-- and utils.lua. Centralizing it removes the duplication and guarantees
-- every call site applies the same defensive behavior (return nils on
-- error rather than propagating an exception up the analysis pipeline).
-- @param node table|nil
-- @return sl, sc, el, ec  (4 values; all nil if node is nil or range() raises)
------------------------------------------------------------------------------
local function safe_range(node)
  if node == nil then return nil, nil, nil, nil end
  if type(node.range) ~= "function" then return nil, nil, nil, nil end
  local ok, sl, sc, el, ec = pcall(node.range, node)
  if not ok then return nil, nil, nil, nil end
  return sl, sc, el, ec
end
M.safe_range = safe_range

------------------------------------------------------------------------------
-- to_1based: convert 0-based treesitter (line, col) to 1-based (line, col)
-- for LSP-style positions and Neovim API calls. Defensive: returns (nil, nil)
-- if `line` is nil. Centralizes the `line + 1` / `col + 1` arithmetic that
-- was repeated inline in multiple modules.
-- @param line number|nil  0-based line
-- @param col  number|nil  0-based column
-- @return l1, c1  (1-based; or nil, nil if line is nil)
------------------------------------------------------------------------------
local function to_1based(line, col)
  if line == nil then return nil, nil end
  return line + 1, (col or 0) + 1
end
M.to_1based = to_1based

-- Also expose the sub-modules for direct access.
M.constants = constants
M.path = path
M.range = range

return M
