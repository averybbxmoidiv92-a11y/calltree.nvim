--- adapter.lua — thin integration layer for calltree.nvim.
---
--- This module re-exports the provider constructors and the context factory
--- for backward compatibility. All Neovim-specific code lives in the
--- `providers/` modules; this file simply routes calls through to them.
---
--- Public surface (kept stable):
---   adapter.build_context(bufnr, cursor_pos, language, opts) -> ctx table
---   adapter.read_file(path) -> string|nil
---   adapter.getcwd() -> string
---   adapter.get_lsp_diagnostics() -> table
---
--- Provider modules are also exposed for callers that want them directly:
---   adapter.lsp_client   -> providers.lsp_client (module with .new(bufnr))
---   adapter.treesitter   -> providers.treesitter (module with .new(bufnr))

local M = {}

local lsp_client_provider = require("calltree.providers.lsp_client")
local treesitter_provider  = require("calltree.providers.treesitter")
local context              = require("calltree.core.context")

-- Expose the provider modules for inspection/direct construction.
M.lsp_client = lsp_client_provider
M.treesitter = treesitter_provider

-- Re-export the context builder (the primary entry point used by init.lua).
M.build_context = context.build

--- Read a file's contents as a string (returns nil if the file can't be opened).
--- @param path string
--- @return string|nil
M.read_file = context.read_file

--- Get the current working directory.
--- @return string
M.getcwd = context.getcwd

--- Backward-compatible alias for providers.lsp_client.get_diagnostics().
--- Delegates directly to the latter to avoid duplicating the shallow-copy
--- logic. Semantics unchanged (returns a snapshot of the most recent LSP
--- session's diagnostics).
--- @return table
M.get_lsp_diagnostics = function()
  return lsp_client_provider.get_diagnostics()
end

return M
