-- scripts/rust_nvim_init.lua
--
-- Minimal nvim init for headless testing of calltree.nvim against a
-- Rust project with rust-analyzer attached.
--
-- Sets up:
--   1. runtimepath to include the calltree.nvim plugin
--   2. vim.lsp.start() to attach rust-analyzer for *.rs buffers
--   3. require("calltree").setup() so user commands are registered
--
-- Self-contained: paths are computed relative to this file so the
-- test can be relocated.

-- Compute paths relative to THIS file.
local this_file = debug.getinfo(1, "S").source
if this_file:sub(1, 1) == "@" then this_file = this_file:sub(2) end
-- SCRIPTS_DIR = directory of this script
local SCRIPTS_DIR = this_file:match("(.*/)") or "./"
-- RESOURCE = calltree.nvim plugin root. Prefer env var; otherwise derive
-- from SCRIPTS_DIR by walking up to find a directory containing
-- `lua/calltree/init.lua`.
local RESOURCE = os.getenv("CALLTREE_PLUGIN_DIR")
if not RESOURCE or RESOURCE == "" then
  -- Walk up looking for lua/calltree/init.lua
  local cur = SCRIPTS_DIR
  while cur ~= nil and cur ~= "/" do
    local f = io.open(cur .. "lua/calltree/init.lua", "r")
    if f then
      f:close()
      RESOURCE = cur:gsub("/$", "")
      break
    end
    -- Go up one level
    local parent = cur:match("(.*/)[^/]+/")
    if parent == nil or parent == cur then break end
    cur = parent
  end
end
if not RESOURCE or RESOURCE == "" then
  -- Last-resort fallback: assume the standard project layout where
  -- tests/rust/ sits two levels below the plugin root.
  RESOURCE = vim.fs.normalize(SCRIPTS_DIR .. "/../..")
end

-- rust-analyzer binary: prefer the env var, then PATH lookup.
local RA_BIN = os.getenv("CALLTREE_RUST_ANALYZER_BIN")
if not RA_BIN or RA_BIN == "" then
  if vim and vim.fn and vim.fn.executable then
    if vim.fn.executable("rust-analyzer") == 1 then
      RA_BIN = "rust-analyzer"
    end
  end
end
if not RA_BIN or RA_BIN == "" then
  RA_BIN = "rust-analyzer"  -- rely on PATH
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

-- 3. Configure rust-analyzer.
local function start_rust_analyzer(bufnr)
  bufnr = bufnr or 0
  -- Prefer a single rust-analyzer process: reattach if one already exists.
  local all = vim.lsp.get_clients and vim.lsp.get_clients()
    or vim.lsp.get_active_clients()
  for _, c in ipairs(all) do
    if c.name == "rust-analyzer" then
      pcall(vim.lsp.buf_attach_client, bufnr, c.id)
      return c.id
    end
  end
  -- root_dir: walk up from buffer dir looking for Cargo.toml.
  local root_dir = vim.fn.getcwd()
  local buf_name = vim.api.nvim_buf_get_name(bufnr)
  if buf_name ~= nil and buf_name ~= "" then
    local start_dir = vim.fs.dirname(buf_name)
    local ok_find, found = pcall(vim.fs.find,
      { "Cargo.toml", ".git" },
      { upward = true, path = start_dir })
    if ok_find and found and found[1] then
      root_dir = vim.fs.dirname(found[1])
    end
  end
  local client_id = vim.lsp.start({
    name = "rust-analyzer",
    cmd = { RA_BIN },
    root_dir = root_dir,
    workspace_folders = { {
      uri = vim.uri_from_fname(root_dir),
      name = "workspace",
    } },
    settings = {
      ["rust-analyzer"] = {
        checkOnSave = false,
        diagnostics = { enable = false },
        cargo = {
          loadOutDirsFromCheck = false,
          buildScripts = { enable = false },
        },
        procMacro = { enable = false },
        files = { excludeDirs = { "target" } },
      },
    },
  }, { bufnr = bufnr })
  return client_id
end

-- 4. Auto-attach for *.rs files.
vim.api.nvim_create_autocmd("FileType", {
  pattern = "rust",
  callback = function(args) start_rust_analyzer(args.buf) end,
})

-- 5. Expose start_rust_analyzer for tests that want to force-attach a buffer.
_G.start_rust_analyzer = start_rust_analyzer

-- 6. Register calltree user commands.
require("calltree").setup()
