--- infrastructure/file_parser.lua — unified file read + treesitter parse + cache.
---
--- This module consolidates the read+parse+cache logic that was previously
--- duplicated across callers.lua (_read_and_parse_ref), definition_body.lua
--- (_read_def_source + _parse_def_tree, _read_and_parse_module), and
--- providers/file_reader.lua. The duplicated implementations had slightly
--- different behaviors:
---   - callers cached failure results as outcome/reason tables
---   - definition_body did not cache failures
---   - file_reader was a standalone class not integrated into the main
---     analysis path
---
--- This module provides unified read_source / parse_tree / new(opts) helper
--- functions. Call sites keep their own decision-record style but delegate
--- the underlying I/O + parse + cache to this module.
--- Pure Lua, no Neovim dependencies.

local path_utils = require("calltree.utils.path")
local constants   = require("calltree.utils.constants")
local fifo_cache  = require("calltree.utils.fifo_cache")

local M = {}

-- Maximum number of cached file entries. Prevents unbounded memory growth
-- in long sessions that analyze many different files. When the limit is
-- exceeded, the oldest entries (by insertion order) are evicted via the
-- shared fifo_cache utility (replacing the previously hand-rolled
-- cache_set / cache_order pair that was duplicated, slightly differently,
-- in file_reader.lua and lsp_client.lua's _evict_diag_cache).
local MAX_CACHE_ENTRIES = 128

------------------------------------------------------------------------------
-- 1. File reading (unified entry point)
------------------------------------------------------------------------------

--- Read the source code for a given URI.
--- Priority:
---   1. If uri == main_uri, return main_source (avoids re-reading the buffer)
---   2. Otherwise call read_file(path)
--- On failure returns nil + error_message. read_file is wrapped in pcall
--- to prevent exceptions from propagating.
--- @param uri string
--- @param main_uri string|nil  URI of the current buffer (for short-circuit)
--- @param main_source string|nil  source code of the current buffer
--- @param read_file function|nil  function(path) -> source_string
--- @return string|nil source, string|nil error_message
function M.read_source(uri, main_uri, main_source, read_file)
  if uri == nil then return nil, "nil uri" end
  -- Short-circuit: when referencing the main buffer, use its source directly.
  if main_uri ~= nil and uri == main_uri and main_source ~= nil then
    return main_source, nil
  end
  if read_file == nil or type(read_file) ~= "function" then
    return nil, "no read_file function available"
  end
  local path = path_utils.uri_to_path(uri)
  local ok, rs = pcall(read_file, path)
  if not ok then
    return nil, "read_file threw: " .. tostring(rs)
  end
  if rs == nil then
    return nil, "read_file returned nil for " .. path
  end
  return rs, nil
end

------------------------------------------------------------------------------
-- 2. Treesitter parsing (unified entry point)
------------------------------------------------------------------------------

--- Parse source code using the injected treesitter service, returning the
--- root node. ts.parse is wrapped in pcall to prevent parse exceptions
--- from propagating.
--- @param ts table  treesitter service (with parse(source, lang) method)
--- @param source string
--- @param language string|nil  defaults to "lua"
--- @return table|nil root, table|nil tree, string|nil error_message
function M.parse_tree(ts, source, language)
  if ts == nil then return nil, nil, "nil treesitter service" end
  if source == nil then return nil, nil, "nil source" end
  local lang = language or constants.DEFAULT_LANGUAGE
  local ok, tree = pcall(ts.parse, ts, source, lang)
  if not ok or not tree then
    -- tostring(tree) on a nil returns "nil"; on a table returns a memory
    -- address. Provide a more useful message by inspecting the type when
    -- vim.inspect is available. Truncate to DEBUG_TRUNCATE_LEN to bound
    -- the error message size.
    local err_msg
    local max_len = constants.DEBUG_TRUNCATE_LEN or 200
    if vim and vim.inspect and type(tree) == "table" then
      err_msg = "treesitter parse failed: " .. vim.inspect(tree):sub(1, max_len)
    else
      err_msg = "treesitter parse failed: " .. tostring(tree)
    end
    return nil, nil, err_msg
  end
  -- Wrap `tree:root()` in pcall and guard against `tree.root` being a
  -- non-function truthy value (e.g. a mock tree where `root` is a field
  -- rather than a method). Previously `tree.root and tree:root() or tree`
  -- would crash on a mock tree whose `root` field is truthy but not a
  -- function, because `tree:root()` would attempt to call a non-callable.
  local root
  if type(tree.root) == "function" then
    local ok_r, r = pcall(tree.root, tree)
    root = (ok_r and r) or nil
  elseif type(tree.root) == "table" then
    -- Some mocks store the root node directly as a `root` field.
    root = tree.root
  else
    root = tree
  end
  if root == nil then
    return nil, tree, "parse succeeded but root is nil"
  end
  return root, tree, nil
end

------------------------------------------------------------------------------
-- 3. Combined: read + parse + cache (unified entry point)
------------------------------------------------------------------------------

--- Create a cached file_parser instance.
--- Cache key is uri, value is { source, root, ok }.
--- Failure results are also cached (ok=false) to avoid re-reading disk.
--- @param opts table {
---   main_uri = string|nil,
---   main_source = string|nil,
---   main_root = table|nil,    -- already-parsed main buffer root (skips first parse)
---   read_file = function|nil,
---   treesitter = table,
---   language = string|nil,
--- }
--- @return table parser with method :get(uri) -> root, source, err_msg
function M.new(opts)
  opts = opts or {}
  -- Cache value shape: { source, root, ok, err }. The `err` field is
  -- populated on failure so a cached failure response carries the
  -- underlying error message (read failure / parse failure) rather
  -- than just a boolean flag — callers can surface the reason.
  local cache = fifo_cache.new(MAX_CACHE_ENTRIES)

  -- Pre-populate the main buffer.
  if opts.main_uri and opts.main_root then
    cache:set(opts.main_uri, {
      source = opts.main_source,
      root = opts.main_root,
      ok = true,
      err = nil,
    })
  end

  local self = {}

  --- Get the root node + source for a URI (with caching).
  --- @param uri string
  --- @return table|nil root, string|nil source, string|nil err_msg
  function self.get(uri)
    if uri == nil then return nil, nil, "nil uri" end
    if cache:has(uri) then
      local cached = cache:get(uri)
      return cached.root, cached.source, cached.err
    end
    -- Read + parse.
    local source, src_err = M.read_source(uri, opts.main_uri, opts.main_source, opts.read_file)
    if source == nil then
      cache:set(uri, { source = nil, root = nil, ok = false, err = src_err })
      return nil, nil, src_err
    end
    local root, _tree, parse_err = M.parse_tree(opts.treesitter, source, opts.language)
    if root == nil then
      cache:set(uri, { source = source, root = nil, ok = false, err = parse_err })
      return nil, source, parse_err
    end
    cache:set(uri, { source = source, root = root, ok = true, err = nil })
    return root, source, nil
  end

  --- Directly register a pre-parsed tree (for test stubs or main buffer
  --- pre-population).
  --- @param uri string
  --- @param source string
  --- @param root table
  function self.register(uri, source, root)
    cache:set(uri, { source = source, root = root, ok = true, err = nil })
  end

  --- Check whether the cache already has an entry for this URI
  --- (regardless of success or failure).
  --- @param uri string
  --- @return boolean
  function self.has(uri)
    return cache:has(uri)
  end

  return self
end

return M
