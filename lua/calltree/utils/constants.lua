--- constants.lua — shared constants for calltree.nvim.
--- Pure data, no functions. Defines node-type sets and LSP constants.

local M = {}

-- Node types that represent a "function definition" across the languages we support.
M.FUNCTION_NODE_TYPES = {
  ["function_definition"]    = true,
  ["function_declaration"]   = true,
  ["function_item"]          = true,
  ["method_definition"]      = true,
  ["method_declaration"]     = true,
  ["function_specification"] = true,
  ["method_specification"]   = true,
  ["func_literal"]           = true,
  ["function"]               = true,
  ["arrow_function"]         = true,
  ["function_expression"]    = true,
  ["method"]                 = true,
  ["singleton_method"]       = true,
  ["func_declaration"]       = true,
  ["function_clause"]        = true,
  ["def"]                    = true,
  ["defn"]                   = true,
  ["defmacro"]               = true,
  ["fn"]                     = true,
  ["function_signature"]     = true,
  ["function_statement"]     = true,
  ["local_function_declaration"] = true,
  ["local_function"]         = true,
  ["constructor_declaration"] = true,
}

-- Node types that represent inactive preprocessor branches in C/C++.
-- Real tree-sitter-c parses BOTH the active and inactive (#else / #elif)
-- branches into named children. When walking a function body for
-- call expressions, we must skip these inactive-branch containers so
-- that calls inside `#else` / `#elif` blocks are NOT collected — only
-- the active branch's calls should be reported.
--
-- This is C/C++-specific; for other languages these node types do not
-- exist, so including them here is a harmless no-op.
M.PREPROC_INACTIVE_BRANCH_TYPES = {
  ["preproc_else"] = true,  -- C/C++ #else branch
  ["preproc_elif"] = true,  -- C/C++ #elif branch
}

-- Node types that represent a "name" identifier inside a function definition.
M.NAME_NODE_TYPES = {
  ["identifier"]     = true,
  ["property_identifier"] = true,
  ["method_name"]    = true,
  ["type_identifier"] = true,
  ["name"]           = true,
  ["field_identifier"] = true,
  ["meta_method"]    = true,
}

-- Node types that represent a "function call" expression across the
-- languages we support. This is the SUPERSET of every call-like node
-- type used by any module in calltree.nvim.
--
-- Previously this set was duplicated in two places with slightly
-- different members:
--   - resolution/require_resolver.lua  (function_call, call, call_expression)
--   - treesitter/walker.lua            (superset: also method_invocation,
--                                       command_call, method_call_expression)
-- The walker version is a strict superset of the require_resolver one,
-- but the two were functionally independent (one drove require() detection,
-- the other drove top-level call collection). Unifying here lets both
-- modules share the same set, so adding a new language's call node type
-- only needs one edit.
M.CALL_NODE_TYPES = {
  ["function_call"]          = true,  -- Lua
  ["call"]                   = true,  -- Python / generic
  ["call_expression"]        = true,  -- C / JS / Rust / Go
  ["method_invocation"]      = true,  -- Java / JS methods
  ["command_call"]           = true,  -- LaTeX / TeX
  ["method_call_expression"] = true,  -- C++ method calls
}

-- LSP SymbolKind values.
-- Full enum (per LSP 3.17 spec): 1=File, 2=Module, 3=Namespace, 4=Package,
-- 5=Class, 6=Method, 7=Property, 8=Field, 9=Constructor, 10=Enum,
-- 11=Interface, 12=Function, 13=Variable, 14=Constant, ...
-- Only the kinds used by calltree.nvim are listed here.
M.LSP_SYMBOL_FUNCTION = 12
M.LSP_SYMBOL_METHOD = 6
M.LSP_SYMBOL_VARIABLE = 13
M.LSP_SYMBOL_CONSTANT = 14

-- LSP tags (LSP 3.16+).
M.LSP_TAG_DEPRECATED = 1
-- Some servers (notably clangd) overload tag value 256 to mark system/
-- standard-library symbols. Promoted from a local constant in
-- external_calls.lua so it lives alongside the other LSP constants.
M.LSP_TAG_SYSTEM_LIBRARY = 256

-- LSP 3.17 SymbolTag is a numeric enum, but some servers (clangd) emit
-- the private string extensions "system" / "library" as tag values too.
-- Centralizing these strings alongside the numeric tag avoids scattered
-- magic literals in external_calls.lua and makes the source of each
-- value easy to grep.
M.LSP_TAG_STR_SYSTEM  = "system"
M.LSP_TAG_STR_LIBRARY = "library"

-- Default source language when the context does not specify one.
-- Previously hardcoded as the literal "lua" in multiple modules
-- (debug.lua, definition_body.lua, preconditions.lua, file_reader.lua,
-- file_parser.lua) — promoting it to a single constant so all modules
-- agree on the fallback and the value can be changed in one place.
M.DEFAULT_LANGUAGE = "lua"

-- LSP methods that calltree's analysis depends on. Used by
-- preconditions.lua to verify the injected LSP client supports the
-- required interface. Promoted from an inline list literal so tests
-- and other modules can reference the same set.
M.REQUIRED_LSP_METHODS = { "definition", "references", "document_symbols" }

-- LSP method name strings, keyed by the short semantic name used inside
-- calltree.nvim (the injected lsp_client interface exposes
-- `definition` / `declaration` / `references` / `document_symbols`
-- methods, NOT the raw "textDocument/..." strings).
--
-- The raw "textDocument/..." literals were previously scattered as
-- inline string constants across:
--   - analysis/callers.lua       (debug logs for definition / declaration / references)
--   - analysis/external_calls.lua (debug log for definition)
--   - analysis/preconditions.lua  (debug log for documentSymbol)
--   - providers/lsp_client.lua    (METHOD_CAPABILITY_MAP keys + the actual
--                                  lsp_request_sync call sites)
-- Centralizing them here avoids spelling mistakes (e.g. "documentSymbol"
-- vs "documentSymbols") and lets us adjust the wire-format string in a
-- single place should LSP ever rename a method.
M.LSP_METHODS = {
  definition       = "textDocument/definition",
  declaration      = "textDocument/declaration",
  references       = "textDocument/references",
  document_symbol  = "textDocument/documentSymbol",
  type_definition  = "textDocument/typeDefinition",
  implementation   = "textDocument/implementation",
}

------------------------------------------------------------------------------
-- Resolution / decision status enums.
--
-- These string literals are written into:
--   - ExternalCall.resolution_status   (the public, user-visible status of an
--                                       external call: "resolved" | "unresolved")
--   - caller_decision.outcome          (internal debug-only classification of
--                                       each LSP reference: "kept" / "excluded_defdecl" /
--                                       "self_recursive" / "no_source" / ...)
--   - external_call_decision.outcome   (internal debug-only classification of
--                                       each top-level call: "kept_resolved" /
--                                       "kept_unresolved" / "kept_stdlib" /
--                                       "kept_external_crate" / "discarded_*")
--
-- They were previously inlined as string literals throughout callers.lua,
-- external_calls.lua, and core/analyzer.lua. Promoting them to constants
-- here so:
--   1. Adding a new status only needs one edit.
--   2. Tests can reference the same constants when asserting equality,
--      eliminating the chance of a typo passing in one place and failing
--      in another.
--   3. Future enum extensions (e.g. a "skipped" status) are obvious.
------------------------------------------------------------------------------

-- ExternalCall.resolution_status: public field on every ExternalCall entry.
M.RESOLUTION_STATUS_RESOLVED   = "resolved"
M.RESOLUTION_STATUS_UNRESOLVED = "unresolved"

-- caller_decision.outcome: per-reference classification produced by
-- analysis/callers.lua and consumed by the debug collector + tests.
M.CALLER_OUTCOME_EXCLUDED_DEFDECL = "excluded_defdecl"
M.CALLER_OUTCOME_KEPT             = "kept"
M.CALLER_OUTCOME_SELF_RECURSIVE   = "self_recursive"
M.CALLER_OUTCOME_NO_SOURCE        = "no_source"
M.CALLER_OUTCOME_NO_NODE          = "no_node"
M.CALLER_OUTCOME_GLOBAL_SCOPE     = "global_scope"
M.CALLER_OUTCOME_ERROR            = "error"

-- external_call_decision.outcome: per-call classification produced by
-- analysis/external_calls.lua and consumed by the debug collector + tests.
M.CALL_OUTCOME_KEPT_RESOLVED      = "kept_resolved"
M.CALL_OUTCOME_KEPT_UNRESOLVED    = "kept_unresolved"
M.CALL_OUTCOME_KEPT_STDLIB        = "kept_stdlib"
M.CALL_OUTCOME_KEPT_EXTERNAL_CRATE = "kept_external_crate"
M.CALL_OUTCOME_DISCARDED_IN_SCOPE = "discarded_in_scope"
M.CALL_OUTCOME_DISCARDED_NO_BODY  = "discarded_no_body"

------------------------------------------------------------------------------
-- Centralized magic numbers.
-- Modules reference these constants instead of scattered literals, making
-- them easier to adjust and document in one place.
------------------------------------------------------------------------------

-- debug.lua:node_summary node text truncation threshold (prevents long
-- text from bloating the debug output).
M.MAX_NODE_TEXT_LEN = 80

-- nodes.lua:is_function_name_node maximum hops when walking up to find a
-- name node.
M.MAX_NAME_HOPS = 6

-- nodes.lua:is_function_name_node maximum recursion depth inside find_path.
M.MAX_PATH_DEPTH = 16

-- require_resolver.lua maximum hops when walking up to find a call node.
M.MAX_PARENT_HOPS = 10

-- require_resolver.lua maximum subtree search depth (prevents stack
-- overflow on malicious ASTs).
M.MAX_SUBTREE_DEPTH = 32

-- nodes.lua:walk_up_to_type maximum ancestor hops. Larger than
-- MAX_PARENT_HOPS (which is used by require_resolver for shallow
-- parent walks) because real treesitter ASTs can have many nested
-- wrapper nodes between an identifier and its enclosing function.
M.MAX_ANCESTOR_HOPS = 50

-- walker.lua:collect_top_level_calls and nodes.lua:find_function_def_by_name
-- maximum walk recursion depth (prevents stack overflow on deep ASTs).
-- Both modules previously used different values (32 vs 64); unified to
-- 64 so neither hits the limit prematurely on deeply-nested Lua files
-- (e.g. generated/bundled code).
M.MAX_WALK_DEPTH = 64

-- lsp_client.lua default synchronous request timeout (milliseconds).
M.DEFAULT_LSP_TIMEOUT_MS = 1000

-- infrastructure/fs.lua maximum single-file read size in bytes (10 MB,
-- prevents accidentally reading huge binary files).
M.MAX_FILE_SIZE_BYTES = 10 * 1024 * 1024

-- debug.lua lsp_call response sample truncation length (prevents a single
-- large LSP response from bloating the debug output). Was a scattered
-- literal `200` in debug.lua and file_parser.lua.
M.DEBUG_TRUNCATE_LEN = 200

-- mocks.lua Node:dump text truncation length. Was a literal `30`.
M.MOCK_DUMP_TEXT_LEN = 30

-- preconditions.lua find_function_symbol_at maximum nesting depth.
-- Was a local literal `64`.
M.MAX_SYMBOL_DEPTH = 64

return M
