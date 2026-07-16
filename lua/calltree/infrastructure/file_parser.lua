--- infrastructure/file_parser.lua — file read, parse, and cache helpers.
---
--- Pure Lua helpers used by analysis code that needs source text and a
--- parsed Treesitter root for files referenced by LSP locations.

local path_utils = require("calltree.utils.path")
local fifo_cache  = require("calltree.utils.fifo_cache")
local tree_parser = require("calltree.infrastructure.tree_parser")

local M = {}

-- Maximum number of cached file entries. Prevents unbounded memory growth
-- in long sessions that analyze many different files.
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
-- 2. Treesitter parsing
------------------------------------------------------------------------------

M.extract_root = tree_parser.extract_root
M.parse_tree = tree_parser.parse_tree

------------------------------------------------------------------------------
-- 3. Combined: read + parse + cache
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
