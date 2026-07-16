-- tests/javascript_nvim_init.lua
--
-- Minimal nvim init for headless testing of calltree.nvim against a
-- JavaScript project with typescript-language-server attached.
--
-- Sets up:
--   1. runtimepath to include the calltree.nvim plugin
--   2. vim.lsp.start() to attach typescript-language-server for *.js buffers
--   3. require("calltree").setup() so the plugin is ready
--
-- Self-contained: paths are computed relative to this file so the test
-- can be relocated. Override the typescript-language-server binary
-- location via the CALLTREE_TSSERVER_BIN env var (default:
-- typescript-language-server on PATH).

-- Compute paths relative to THIS file.
local this_file = debug.getinfo(1, "S").source
if this_file:sub(1, 1) == "@" then this_file = this_file:sub(2) end
local SCRIPTS_DIR = this_file:match("(.*/)") or "./"

-- RESOURCE = calltree.nvim plugin root. Walk up looking for
-- lua/calltree/init.lua.
local RESOURCE = os.getenv("CALLTREE_PLUGIN_DIR")
if not RESOURCE or RESOURCE == "" then
  local cur = SCRIPTS_DIR
  while cur ~= nil and cur ~= "/" do
    local f = io.open(cur .. "lua/calltree/init.lua", "r")
    if f then
      f:close()
      RESOURCE = cur:gsub("/$", "")
      break
    end
    local parent = cur:match("(.*/)[^/]+/")
    if parent == nil or parent == cur then break end
    cur = parent
  end
end
if not RESOURCE or RESOURCE == "" then
  RESOURCE = vim.fs.normalize(SCRIPTS_DIR .. "/..")
end

-- typescript-language-server binary: prefer env var, then PATH lookup.
local TSS_BIN = os.getenv("CALLTREE_TSSERVER_BIN")
if not TSS_BIN or TSS_BIN == "" then
  if vim and vim.fn and vim.fn.executable then
    if vim.fn.executable("typescript-language-server") == 1 then
      TSS_BIN = "typescript-language-server"
    end
  end
end
if not TSS_BIN or TSS_BIN == "" then
  TSS_BIN = "typescript-language-server"
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

-- 3. Configure typescript-language-server.
local function start_tsserver(bufnr)
  bufnr = bufnr or 0
  -- Reuse an existing client if one is already running.
  local all = vim.lsp.get_clients and vim.lsp.get_clients()
    or vim.lsp.get_active_clients()
  for _, c in ipairs(all) do
    if c.name == "tsserver" then
      pcall(vim.lsp.buf_attach_client, bufnr, c.id)
      return c.id
    end
  end
  -- root_dir: walk up from buffer dir looking for package.json or jsconfig.json.
  local root_dir = vim.fn.getcwd()
  local buf_name = vim.api.nvim_buf_get_name(bufnr)
  if buf_name ~= nil and buf_name ~= "" then
    local start_dir = vim.fs.dirname(buf_name)
    local ok_find, found = pcall(vim.fs.find,
      { "package.json", "jsconfig.json", "tsconfig.json", ".git" },
      { upward = true, path = start_dir })
    if ok_find and found and found[1] then
      root_dir = vim.fs.dirname(found[1])
    end
  end
  local client_id = vim.lsp.start({
    name = "tsserver",
    cmd = { TSS_BIN, "--stdio" },
    root_dir = root_dir,
    filetypes = { "javascript", "typescript" },
  }, { bufnr = bufnr })
  return client_id
end

-- 4. Auto-attach for *.js / *.ts files.
vim.api.nvim_create_autocmd("FileType", {
  pattern = { "javascript", "typescript" },
  callback = function(args) start_tsserver(args.buf) end,
})

-- 5. Expose start_tsserver for tests that want to force-attach a buffer.
_G.start_tsserver = start_tsserver

-- 6. Register calltree with filtering disabled so integration tests can
--    assert on the raw collected entries (callers / external_calls).
require("calltree").setup({
  skip_stdlib_calls = false,
  deduplicate_external_calls = false,
  user_commands = false,
})
