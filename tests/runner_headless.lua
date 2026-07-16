--- tests/runner_headless.lua — loads and runs headless_integration.lua inside nvim.
---
--- Run with (from plugin root):
---   nvim --headless -u NORC -c "luafile tests/runner_headless.lua"
---
--- Sets up package.path so require("calltree.*") works, then runs the tests.

-- This file lives in tests/. Plugin root is the parent directory.
local this_file = debug.getinfo(1, "S").source
if this_file:sub(1, 1) == "@" then this_file = this_file:sub(2) end
local tests_dir = this_file:match("(.*/)") or "./"
tests_dir = tests_dir:gsub("/$", "")
if tests_dir == "" then tests_dir = "." end
local resource_root = tests_dir:match("(.+)/[^/]+$") or (tests_dir .. "/..")
if tests_dir == "." then resource_root = ".." end
resource_root = vim.fs.normalize(resource_root)

package.path = resource_root .. "/?.lua;"
              .. resource_root .. "/?/init.lua;"
              .. resource_root .. "/lua/?.lua;"
              .. resource_root .. "/lua/?/init.lua;"
              .. tests_dir .. "/?.lua;"
              .. package.path

-- Add plugin root to runtimepath so plugin/calltree.lua can be sourced
-- and treesitter queries etc. are found.
vim.opt.runtimepath:prepend(resource_root)

local M = require("headless_integration")
M.run()
