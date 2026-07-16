-- scripts/verify_lsp.lua
-- Quick smoke test: open a lua file, attach lua_ls, wait for it to be ready,
-- then print diagnostic info and exit.

-- Compute paths relative to THIS file so the package is self-contained.
local this_file = debug.getinfo(1, "S").source
if this_file:sub(1, 1) == "@" then this_file = this_file:sub(2) end
local script_dir = this_file:match("(.*/)") or "."
script_dir = script_dir:gsub("/$", "")

-- Source the init (which sets up runtimepath, package.path, lsp, calltree).
vim.cmd("luafile " .. script_dir .. "/nvim_lsp_init.lua")

-- Create a tiny lua project on disk so the LSP has a stable root to index.
local project_dir = "/tmp/calltree_lsp_proj"
vim.fn.mkdir(project_dir, "p")
local path = project_dir .. "/lib.lua"
-- Wrap file writes in pcall so a disk-error or permission-denied
-- doesn't crash the verify script before it can print a useful error.
local f, open_err = io.open(path, "w")
if not f then
  print("[verify_lsp] FAILED: could not open " .. path .. " for writing: " .. tostring(open_err))
  vim.cmd("cquit! 1")
end
local write_ok, write_err = f:write([[local M = {}

function M.greet(name)
  return "hello " .. name
end

function M.use_greet()
  return M.greet("world")
end

return M
]])
f:close()
if not write_ok then
  print("[verify_lsp] FAILED: could not write to " .. path .. ": " .. tostring(write_err))
  vim.cmd("cquit! 1")
end

-- Edit the file from the project root (so root_dir detection works).
vim.cmd("cd " .. project_dir)
vim.cmd("edit " .. path)
vim.bo.filetype = "lua"

-- Force-attach LSP (FileType autocmd may not fire reliably in headless mode).
_G.start_lua_lsp(0)

-- Wait for the client to be ready (poll for up to 15 seconds).
local function wait_for_client_ready(timeout_ms)
  timeout_ms = timeout_ms or 15000
  local start = vim.loop.hrtime()
  while (vim.loop.hrtime() - start) / 1e6 < timeout_ms do
    local clients = vim.lsp.get_clients and vim.lsp.get_clients({ bufnr = 0 })
      or vim.lsp.get_active_clients({ bufnr = 0 })
    if #clients > 0 then
      local c = clients[1]
      if c.server_capabilities and (c.server_capabilities.documentSymbolProvider
          or c.server_capabilities.definitionProvider) then
        return true, c
      end
    end
    vim.wait(50)
  end
  return false, nil
end

local ok, client = wait_for_client_ready(15000)
if not ok then
  print("[verify_lsp] FAILED: no LSP client became ready within 15s")
  local clients = vim.lsp.get_clients and vim.lsp.get_clients({ bufnr = 0 })
    or vim.lsp.get_active_clients({ bufnr = 0 })
  print(string.format("[verify_lsp] client_count=%d", #clients))
  for _, c in ipairs(clients) do
    print(string.format("  client id=%d name=%s", c.id, c.name))
  end
  vim.cmd("cquit! 1")
end

print(string.format("[verify_lsp] OK: client id=%d name=%s attached",
  client.id, client.name))

-- Wait for the LSP server to finish workspace indexing before sending
-- requests. lua_ls emits a `$/progress` notification as it indexes; we
-- can't easily inspect that without more wiring, but waiting a few seconds
-- and polling documentSymbol is a simple heuristic.
local function wait_for_symbols(timeout_ms)
  timeout_ms = timeout_ms or 30000
  local uri = vim.uri_from_bufnr(0)
  local start = vim.loop.hrtime()
  while (vim.loop.hrtime() - start) / 1e6 < timeout_ms do
    local ok_req, result = pcall(vim.lsp.buf_request_sync, 0,
      "textDocument/documentSymbol", { textDocument = { uri = uri } }, 3000)
    if ok_req and result then
      -- Sort client_ids numerically so the "first" result is
      -- deterministic across runs (pairs iteration order is undefined).
      local ids = {}
      for id in pairs(result) do table.insert(ids, id) end
      table.sort(ids, function(a, b)
        local na, nb = tonumber(a), tonumber(b)
        if na and nb then return na < nb end
        return tostring(a) < tostring(b)
      end)
      for _, id in ipairs(ids) do
        local r = result[id]
        if r.result and type(r.result) == "table" and #r.result > 0 then
          return r.result
        end
      end
    end
    vim.wait(200)
  end
  return nil
end

local symbols = wait_for_symbols(30000)
if not symbols then
  print("[verify_lsp] FAILED: documentSymbol returned 0 symbols even after 30s")
  vim.cmd("cquit! 1")
end
print(string.format("[verify_lsp] OK: %d document symbols returned", #symbols))
for _, s in ipairs(symbols) do
  print(string.format("  symbol name=%s kind=%d range=%s",
    s.name, s.kind, vim.inspect(s.range)))
end

vim.cmd("q!")

