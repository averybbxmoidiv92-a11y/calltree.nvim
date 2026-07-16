-- scripts/nvim_lsp_init.lua
--
-- Minimal nvim init for headless integration testing of calltree.nvim
-- with a REAL lua-language-server attached.
--
-- Sets up:
--   1. runtimepath to include the calltree.nvim plugin (this directory's parent)
--   2. vim.lsp.start() to attach lua-language-server for *.lua buffers
--   3. calls require("calltree").setup() so user commands are registered
--
-- Self-contained: paths are computed relative to this file so the package
-- can be relocated. Override the lua-language-server binary location via
-- the CALLTREE_LSP_BIN env var (default: <repo_root>/lsp/bin/lua-language-server).
--
-- This file is sourced via `nvim --headless -u NORC -c "luafile ..."`.

-- Compute paths relative to THIS file so the package is self-contained.
local this_file = debug.getinfo(1, "S").source
if this_file:sub(1, 1) == "@" then this_file = this_file:sub(2) end
-- this_file = .../resource/scripts/nvim_lsp_init.lua
local SCRIPTS_DIR = this_file:match("(.*/)")
local RESOURCE = SCRIPTS_DIR and (SCRIPTS_DIR:sub(1, -2):match("(.*/)") .. "") or "."
if RESOURCE:sub(-1) == "/" then RESOURCE = RESOURCE:sub(1, -2) end
-- Strip the trailing "scripts/" — we want the resource root.
RESOURCE = RESOURCE:gsub("/scripts$", "")

-- LSP binary: prefer the env var, then look for a sibling ../lsp/bin/ dir
-- (development layout), then fall back to PATH lookup.
local LSP_BIN = os.getenv("CALLTREE_LSP_BIN")
if not LSP_BIN or LSP_BIN == "" then
  local candidate = RESOURCE .. "/../lsp/bin/lua-language-server"
  -- Use vim.fn.executable instead of io.open: io.open succeeds for
  -- directories (false positive) and does NOT check the executable bit.
  -- vim.fn.executable returns 1 only when the path is a regular file
  -- with the executable permission bit set.
  if vim and vim.fn and vim.fn.executable then
    if vim.fn.executable(candidate) == 1 then
      LSP_BIN = candidate
    end
  else
    -- Fallback for environments without vim.fn (shouldn't happen in nvim
    -- headless, but defensive): use io.open and accept the false-positive
    -- risk on directories.
    local f = io.open(candidate, "r")
    if f then f:close(); LSP_BIN = candidate end
  end
end
if not LSP_BIN or LSP_BIN == "" then
  LSP_BIN = "lua-language-server"  -- rely on PATH
end

-- 1. Make calltree.nvim discoverable on the runtimepath.
vim.opt.runtimepath:prepend(RESOURCE)

-- 2. Set package.path so require("calltree.xxx") works.
package.path = RESOURCE .. "/?.lua;"
              .. RESOURCE .. "/?/init.lua;"
              .. RESOURCE .. "/lua/?.lua;"
              .. RESOURCE .. "/lua/?/init.lua;"
              .. RESOURCE .. "/tests/?.lua;"
              .. package.path

-- 3. Configure lua-language-server.
--    Use vim.lsp.start (Neovim 0.8+) which is the recommended API.
local function start_lua_lsp(bufnr)
  bufnr = bufnr or 0
  -- Don't double-attach.
  local existing = vim.lsp.get_clients and vim.lsp.get_clients({ bufnr = bufnr })
    or vim.lsp.get_active_clients({ bufnr = bufnr })
  for _, c in ipairs(existing) do
    if c.name == "lua_ls" then return c.id end
  end
  -- Compute root_dir: walk upward from the buffer's directory looking for
  -- common project markers. vim.fs.find raises ENOENT if the buffer has no
  -- on-disk path (e.g. a scratch buffer), so we wrap it in pcall and fall
  -- back to the current working directory.
  local root_dir = vim.fn.getcwd()
  local buf_name = vim.api.nvim_buf_get_name(bufnr)
  if buf_name ~= nil and buf_name ~= "" then
    local start_dir = vim.fs.dirname(buf_name)
    local ok_find, found = pcall(vim.fs.find,
      { ".luarc.json", ".luarc.jsonc", ".git", "Makefile", "stylua.toml" },
      { upward = true, path = start_dir })
    if ok_find and found and found[1] then
      root_dir = vim.fs.dirname(found[1])
    end
  end
  local client_id = vim.lsp.start({
    name = "lua_ls",
    cmd = { LSP_BIN, "--loglevel=error" },
    root_dir = root_dir,
    single_file_support = true,
    settings = {
      Lua = {
        runtime = { version = "LuaJIT" },
        diagnostics = { globals = { "vim" }, enable = false },
        workspace = {
          -- Keep the library empty for tests: loading all of VIMRUNTIME
          -- multiplies memory usage and is unnecessary for these fixtures.
          library = {},
          checkThirdParty = false,
          maxPreload = 100,
          preloadFileSize = 50,
        },
        telemetry = { enable = false },
        completion = { enable = false },
        hint = { enable = false },
      },
    },
  }, { bufnr = bufnr })
  return client_id
end

-- 4. Auto-attach for *.lua files.
vim.api.nvim_create_autocmd("FileType", {
  pattern = "lua",
  callback = function(args) start_lua_lsp(args.buf) end,
})

-- 5. Expose start_lua_lsp for tests that want to force-attach a buffer.
_G.start_lua_lsp = start_lua_lsp

-- 6. Register calltree user commands.
require("calltree").setup()
