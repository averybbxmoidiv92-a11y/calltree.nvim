--- core/context.lua — context factory extracted from adapter.lua.
---
--- Builds the analysis context table that the analyzer consumes:
---   source_code, file_path, cursor_pos, language, lsp_client, treesitter,
---   fs (IFileSystem), capability_checker, getcwd, read_file, package_paths, debug
---
--- Uses the providers.lsp_client and providers.treesitter constructors and
--- constructs `package_paths` from package.path + Neovim's runtimepath + cwd.
--- Filesystem operations go through the injected IFileSystem interface
--- (defaults to infrastructure/fs.lua); the analysis layer does not
--- reference io.* directly.

local M = {}

local vim = vim or {}

local lsp_client_provider = require("calltree.providers.lsp_client")
local treesitter_provider  = require("calltree.providers.treesitter")
local fs_default           = require("calltree.infrastructure.fs")
local interfaces           = require("calltree.core.interfaces")
local constants            = require("calltree.utils.constants")

-- Default language used when the buffer's filetype cannot be determined.
-- References the centralized constant from utils/constants.lua (was a
-- local "lua" literal that duplicated the constant defined there, causing
-- a maintenance hazard: editing one without the other would silently
-- desync the fallback language across modules). Callers can override via
-- opts.default_language.
local DEFAULT_LANGUAGE = constants.DEFAULT_LANGUAGE

--- Default read_file: delegates to the IFileSystem implementation
--- (infrastructure/fs.lua). This local function is kept for backward
--- compatibility with the ctx.read_file field (some tests read it directly).
--- @param path string
--- @return string|nil
local function read_file(path)
  return fs_default.read_file(path)
end

--- Default getcwd: delegates to the IFileSystem implementation.
--- @return string
local function getcwd()
  return fs_default.getcwd()
end

-- Helper: build the package_paths list from package.path + runtimepath + cwd.
-- Deduplicates entries via a set so that identical templates (e.g. when cwd
-- is already in runtimepath, common for plugin dev) don't appear multiple
-- times — every duplicate wastes an iteration in require-resolution.
local function build_package_paths(fs)
  local package_paths = {}
  local seen = {}  -- dedup set: template string -> true
  local function add(template)
    if template and template ~= "" and not seen[template] then
      seen[template] = true
      package_paths[#package_paths + 1] = template
    end
  end
  -- 1. Standard Lua package.path
  local pp = package and package.path or ""
  for template in pp:gmatch("([^;]+)") do
    add(template)
  end
  -- 2. Neovim runtimepath entries (each with /lua/?.lua and /lua/?/init.lua)
  if vim.api and vim.api.nvim_list_runtime_paths then
    local rtp = vim.api.nvim_list_runtime_paths()
    for _, dir in ipairs(rtp) do
      add(dir .. "/lua/?.lua")
      add(dir .. "/lua/?/init.lua")
    end
  end
  -- 3. The current working directory (common project root layout)
  local cwd = fs.getcwd()
  if cwd ~= nil then
    add(cwd .. "/lua/?.lua")
    add(cwd .. "/lua/?/init.lua")
    add(cwd .. "/?.lua")
    add(cwd .. "/?/init.lua")
  end
  return package_paths
end

-- Helper: build the capability_checker. The LSP clients list is fetched ONCE
-- (when the checker is constructed) and cached for the lifetime of the context,
-- so repeated `supports(method)` calls don't re-fetch the clients list N times.
-- Previously `vim.lsp.get_clients({bufnr=bufnr})` ran on every `supports()` call.
local function build_capability_checker(bufnr)
  -- Fetch clients once. Use `get_clients` (Neovim 0.11+); fall back to the
  -- deprecated `get_active_clients` only when `get_clients` is unavailable.
  -- Guard `vim.lsp` with a truthiness check first: when `vim` is the
  -- module-top `local vim = vim or {}` empty-table fallback (plain Lua
  -- test environment), `vim.lsp` is nil and the previous unguarded
  -- `vim.lsp.get_clients` would crash with "attempt to index nil". Now
  -- consistent with build_package_paths' `if vim.api and ...` style.
  local clients
  if vim.lsp and vim.lsp.get_clients then
    clients = vim.lsp.get_clients({ bufnr = bufnr })
  elseif vim.lsp and vim.lsp.get_active_clients then
    clients = vim.lsp.get_active_clients({ bufnr = bufnr })
  else
    clients = {}
  end
  return {
    supports = function(_self, method)
      local supported, _ = lsp_client_provider.method_supported(clients, method)
      return supported
    end,
  }
end

-- Helper: resolve the buffer language. Prefers the explicit `language`
-- argument, then the buffer filetype, then the configured default.
local function resolve_language(bufnr, language, default_lang)
  if language ~= nil then return language end
  -- Wrap `vim.bo[bufnr].filetype` in pcall because an invalid bufnr
  -- (e.g. buffer was deleted between the caller getting bufnr and calling
  -- build_context) would raise an error that propagates to the user.
  local ok_ft, ft = pcall(function() return vim.bo[bufnr].filetype end)
  if ok_ft and ft ~= nil and ft ~= "" then
    return ft
  end
  -- Buffer invalid or filetype empty; use the configured default.
  return default_lang or DEFAULT_LANGUAGE
end

--- Build the analysis context for the current buffer + cursor position.
--- @param bufnr number
--- @param cursor_pos table { line, character } 0-based
--- @param language string|nil
--- @param opts table|nil {
---   debug = boolean|nil,
---   fs = IFileSystem|nil,
---   default_language = string|nil,
---   skip_stdlib_calls = boolean|nil,         -- v1.2.0
---   deduplicate_external_calls = boolean|nil, -- v1.2.0
--- }
--- @return table ctx
function M.build(bufnr, cursor_pos, language, opts)
  bufnr = bufnr or 0
  opts = opts or {}
  -- Wrap bufnr-dependent API calls in pcall for consistency. Previously
  -- `nvim_buf_get_name` and `nvim_buf_get_lines` were unguarded while
  -- `vim.bo[bufnr].filetype` was pcall'd — if the buffer was deleted between
  -- the caller obtaining bufnr and calling build, the unguarded calls would
  -- crash the whole pipeline. Now all three are pcall'd and we return a
  -- minimal context on failure so downstream phases can produce a clean
  -- "preconditions_failed" result instead of a raw traceback.
  local ok_name, raw_name = pcall(vim.api.nvim_buf_get_name, bufnr)
  local file_path = (ok_name and raw_name ~= nil and raw_name ~= "") and raw_name or nil
  local ok_lines, lines = pcall(vim.api.nvim_buf_get_lines, bufnr, 0, -1, false)
  local source_code
  if ok_lines and type(lines) == "table" then
    source_code = table.concat(lines, "\n") .. "\n"
  else
    source_code = ""
  end

  -- Inject IFileSystem (defaults to infrastructure/fs.lua; can be
  -- overridden by the caller).
  local fs = opts.fs or fs_default
  -- Default to strict=true: previously this passed strict=false AND
  -- discarded the return value, so a malformed fs object would silently
  -- pass the check and only crash later when the analyzer called the
  -- missing method (e.g. fs.read_file). With strict=true (the default),
  -- the failure surfaces here at context-build time with a clear error
  -- message identifying the missing method.
  interfaces.assert_interface(fs, "IFileSystem")

  local package_paths = build_package_paths(fs)

  local lsp_client = lsp_client_provider.new(bufnr)
  local capability_checker = build_capability_checker(bufnr)
  -- Same strict=true default as above.
  interfaces.assert_interface(capability_checker, "ICapabilityChecker")

  local resolved_language = resolve_language(bufnr, language, opts.default_language)

  return {
    source_code         = source_code,
    file_path           = file_path,
    cursor_pos          = cursor_pos,
    language            = resolved_language,
    lsp_client          = lsp_client,
    treesitter          = treesitter_provider.new(bufnr),
    fs                  = fs,
    capability_checker  = capability_checker,
    getcwd              = function() return fs.getcwd() end,
    read_file           = function(path) return fs.read_file(path) end,
    package_paths       = package_paths,
    debug               = opts.debug,  -- nil = enabled (default); false = disabled
    -- v1.2.0: post-collection filtering flags for external_calls.
    -- Both default to true when nil (matching M.options defaults); the
    -- analyzer reads these after the external_calls phase finishes.
    skip_stdlib_calls            = opts.skip_stdlib_calls,
    deduplicate_external_calls   = opts.deduplicate_external_calls,
  }
end

-- Expose the helpers for tests/inspection.
M.read_file = read_file
M.getcwd    = getcwd
M.DEFAULT_LANGUAGE = DEFAULT_LANGUAGE

return M
