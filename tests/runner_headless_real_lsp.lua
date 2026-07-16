--- tests/runner_headless_real_lsp.lua — entry point for the real-LSP headless tests.
---
--- Run with (from plugin root):
---   nvim --headless -u NORC -c "luafile tests/runner_headless_real_lsp.lua"
---
--- Sources the LSP init (which sets up runtimepath, package.path, lua_ls,
--- and registers calltree user commands), then runs the tests.

-- This file lives in tests/. Plugin root is the parent directory.
local this_file = debug.getinfo(1, "S").source
if this_file:sub(1, 1) == "@" then this_file = this_file:sub(2) end
local tests_dir = this_file:match("(.*/)") or "./"
tests_dir = tests_dir:gsub("/$", "")
if tests_dir == "" then tests_dir = "." end
local resource_root = tests_dir:match("(.+)/[^/]+$") or (tests_dir .. "/..")
if tests_dir == "." then resource_root = ".." end
resource_root = vim.fs.normalize(resource_root)

-- Source the init script that wires up the LSP and calltree.
vim.cmd("luafile " .. resource_root .. "/scripts/nvim_lsp_init.lua")

-- Prewarm the treesitter parser: in some Neovim 0.10 + external-parser
-- deployments, ftplugin/lua.lua's vim.treesitter.start call cannot find
-- the 'lua' parser. Preloading here ensures subsequent FileType autocmds
-- do not fail due to a missing parser.
if vim.treesitter and vim.treesitter.language then
  pcall(function()
    local tmp_buf = vim.api.nvim_create_buf(false, true)
    vim.api.nvim_buf_set_lines(tmp_buf, 0, -1, false, { "local x = 1" })
    pcall(vim.treesitter.get_parser, tmp_buf, "lua")
    vim.api.nvim_buf_delete(tmp_buf, { force = true })
  end)
end

-- Ensure tests/ is on package.path (nvim_lsp_init already sets plugin paths).
package.path = tests_dir .. "/?.lua;" .. package.path

local M = require("headless_real_lsp")
M.run()
