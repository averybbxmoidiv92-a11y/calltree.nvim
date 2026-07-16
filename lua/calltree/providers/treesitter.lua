--- providers/treesitter.lua — treesitter service constructor (extracted from adapter.lua).
---
--- Wraps Neovim's `vim.treesitter` API to expose:
---   { parse(source_code, language), descendant_for_range(root, sl, sc, el, ec) }
---
--- This is one of the two modules that touches the `vim.*` global (the other
--- being providers/lsp_client.lua).

local M = {}

local vim = vim or {}

-- Pull in the shared safe_range helper (pcall-wrapped node:range()) so we
-- don't re-implement the same defensive pattern inline. Previously the
-- `pcall(self._tsnode.range, self._tsnode)` idiom was duplicated twice in
-- this file (the :range() method on the wrapper, and the cached range
-- extraction inside :text()). Delegating to utils.safe_range keeps the
-- defensive behavior identical across the codebase.
local utils = require("calltree.utils")

-- Per-source-text line cache. Keyed by the source string itself (Lua
-- interns short strings automatically; long strings are NOT interned but
-- the cache uses weak keys AND weak values so neither the source nor the
-- lines array is retained after the caller drops its reference). Using
-- the full source string as the key eliminates collision risk that the
-- previous "length + head/tail 16 chars" hash suffered — collisions
-- returned the wrong lines array and silently corrupted `:text()`
-- output. The intern + weak-key combo means there is no memory overhead
-- compared to the previous hash approach.
--
-- The cache is set up lazily on first use.
local _line_cache = nil
local function _get_line_cache()
  if _line_cache == nil then
    _line_cache = setmetatable({}, { __mode = "kv" })  -- weak keys + weak values
  end
  return _line_cache
end

-- Split a source string into lines (1-indexed). Cached per source string.
-- The cache key is the source string itself — Lua interns short strings
-- (< 40 chars) automatically, and weak table keys ensure long strings
-- can be GC'd once the caller releases its reference.
local function split_lines(source_text)
  if source_text == nil then return {} end
  local cache = _get_line_cache()
  local cached = cache[source_text]
  if cached ~= nil then return cached end
  local lines = {}
  local pos = 1
  while pos <= #source_text do
    local nl = source_text:find("\n", pos, true)
    if nl == nil then
      table.insert(lines, source_text:sub(pos))
      break
    end
    table.insert(lines, source_text:sub(pos, nl - 1))
    pos = nl + 1
  end
  cache[source_text] = lines
  return lines
end
M._split_lines = split_lines  -- exported for tests

--================================================================================
-- Query: extract text from a source string by treesitter range.
-- _extract_text_from_lines is extracted to reduce the cyclomatic complexity
-- of wrap_node.text.
--================================================================================

-- Query: extract text from a pre-split lines array within the [sl,sc]-[el,ec]
-- range. sl/el are 0-based line numbers; sc/ec are 0-based byte offsets
-- (ec on the last line is exclusive).
local function _extract_text_from_lines(lines, sl, sc, el, ec)
  if sl + 1 > #lines then return "" end
  if sl == el then
    -- Single line: slice directly.
    local line = lines[sl + 1] or ""
    return line:sub(sc + 1, ec)
  end
  -- Multiple lines: first line from sc to end, middle lines in full, last
  -- line from start to ec.
  local parts = { (lines[sl + 1] or ""):sub(sc + 1) }
  for l = sl + 2, el do
    table.insert(parts, lines[l] or "")
  end
  if el + 1 <= #lines then
    table.insert(parts, (lines[el + 1] or ""):sub(1, ec))
  end
  return table.concat(parts, "\n")
end
M._extract_text_from_lines = _extract_text_from_lines

-- Wrap a vim.treesitter node so it quacks like our mock Node.
-- `source_text` is the original source string the node was parsed from
-- (used for :text() extraction, since string-parsed nodes have no buffer).
-- `lines_cache` is an optional pre-split lines array for the source_text
-- (used internally to share the cache across all wrappers of the same source).
-- `bufnr` is the buffer number for buffer-parsed nodes (passed to
-- vim.treesitter.get_node_text); defaults to 0 for backward compat but
-- should be the actual bufnr from M.new(bufnr) to avoid reading text
-- from the wrong buffer.
local function wrap_node(tsnode, source_text, lines_cache, bufnr)
  if tsnode == nil then return nil end
  -- Compute has_error eagerly as a boolean (the analyzer reads it as a field).
  local has_err = false
  if type(tsnode.has_error) == "function" then
    has_err = tsnode:has_error()
  elseif type(tsnode.has_error) == "boolean" then
    has_err = tsnode.has_error
  end
  return {
    _tsnode = tsnode,
    _source_text = source_text,
    has_error = has_err,
    type = function(self) return self._tsnode:type() end,
    parent = function(self)
      local p = self._tsnode:parent()
      if p == nil then return nil end
      -- Pass bufnr so buffer-parsed nodes use the correct buffer for :text().
      -- Previously bufnr was dropped here, causing :text() to fall back to
      -- bufnr=0 (current buffer) instead of the buffer the tree was parsed from.
      return wrap_node(p, self._source_text, lines_cache, bufnr)
    end,
    range = function(self)
      -- Review 1.11: pcall-protect _tsnode:range() so an invalid
      -- treesitter node (e.g. after a buffer modification invalidated
      -- the tree) returns nil instead of raising. Consistent with the
      -- pcall already used in :text() above.
      -- Delegates to the shared utils.safe_range helper so the defensive
      -- pattern (type-check + pcall + nil-on-failure) is identical to
      -- every other call site across the codebase.
      return utils.safe_range(self._tsnode)
    end,
    named_child_count = function(self)
      return self._tsnode:named_child_count()
    end,
    named_child = function(self, i)
      local c = self._tsnode:named_child(i)
      if c == nil then return nil end
      -- Pass bufnr (same fix as :parent() above).
      return wrap_node(c, self._source_text, lines_cache, bufnr)
    end,
    text = function(self)
      -- For buffer-parsed nodes, use vim.treesitter.get_node_text.
      -- For string-parsed nodes, extract from the source string using the range.
      -- pcall guards against nodes that have become invalid (e.g. after a
      -- buffer modification invalidated the tree) — the previous code would
      -- propagate the error and abort the whole analysis.
      --
      -- Optimization: cache the range tuple on the wrapper so repeated
      -- :text() calls on the same wrapper don't re-pcall _tsnode.range.
      -- (split_lines is already cached, but pcall(range) ran every time.)
      if self._cached_range == nil then
        -- Delegate to utils.safe_range so the pcall + type-check pattern
        -- is shared with the wrapper's own :range() method above (was an
        -- inline `pcall(self._tsnode.range, self._tsnode)` that could
        -- drift out of sync with the :range() implementation).
        local sl, sc, el, ec = utils.safe_range(self._tsnode)
        if sl == nil then
          self._cached_range = false  -- sentinel: range unavailable
        else
          self._cached_range = { sl, sc, el, ec }
        end
      end
      if self._cached_range == false then return "" end
      local sl, sc, el, ec = self._cached_range[1], self._cached_range[2],
                              self._cached_range[3], self._cached_range[4]
      if self._source_text then
        -- Delegate to _extract_text_from_lines (query) to reduce this
        -- function's complexity.
        local lines = lines_cache or split_lines(self._source_text)
        return _extract_text_from_lines(lines, sl, sc, el, ec)
      else
        -- Buffer-parsed node: use vim.treesitter.get_node_text with the
        -- CORRECT bufnr (previously hardcoded to 0, which would read from
        -- the current buffer even when M.new(bufnr) was called for a
        -- different buffer — a real bug in multi-buffer setups).
        if vim.treesitter and vim.treesitter.get_node_text then
          local ok_t, t = pcall(vim.treesitter.get_node_text, self._tsnode, bufnr or 0)
          if ok_t then return t or "" end
        end
        return ""
      end
    end,
  }
end
M.wrap_node = wrap_node

------------------------------------------------------------------------------
-- extract_root_from_parser: shared helper that runs parser:parse() and
-- extracts the root node + has_error flag. Extracted because the buffer-
-- parse and string-parse branches of M.new's parse() function did the
-- exact same 8-line dance (parse → check trees → root → has_error).
-- Centralizing here keeps both branches identical and makes the helper
-- independently testable.
-- @return table|nil root, boolean has_error
------------------------------------------------------------------------------
local function extract_root_from_parser(parser)
  if parser == nil then return nil, false end
  local trees = parser:parse()
  if not trees or #trees == 0 then return nil, false end
  local t = trees[1]
  local root = t:root()
  if root == nil then return nil, false end
  local has_error = false
  if type(t.has_error) == "function" then
    has_error = t:has_error()
  elseif type(t.has_error) == "boolean" then
    has_error = t.has_error
  end
  return root, has_error
end

--- Construct a treesitter service for the given buffer.
--- @param bufnr number
--- @return table { parse, descendant_for_range }
function M.new(bufnr)
  -- Cache the buffer's source code so we can detect when parse() is called
  -- with a DIFFERENT source string (i.e. parsing another file's content).
  -- Wrap nvim_buf_get_lines in pcall so a detached / unloaded / invalid
  -- buffer doesn't crash M.new (which has no way to surface the error to
  -- the caller). On failure we fall back to an empty source so the
  -- downstream precondition check fails cleanly with "empty source" rather
  -- than a raw Neovim traceback.
  local buf_lines_tbl = {}
  local ok_lines, lines_res = pcall(vim.api.nvim_buf_get_lines, bufnr, 0, -1, false)
  if ok_lines and type(lines_res) == "table" then
    buf_lines_tbl = lines_res
  end
  local buf_source = table.concat(buf_lines_tbl, "\n")
  -- Review 2.3: do NOT force a trailing "\n". The previous
  -- `.. "\n"` made `buf_source` ALWAYS end with a newline, so
  -- `source_code ~= buf_source` was true whenever the caller passed
  -- the buffer's actual content (which may or may not end with a
  -- newline) — causing the string-parser path to be selected even
  -- for the current buffer. We now compare against the buffer's
  -- actual content; if the buffer has no trailing newline we still
  -- detect the match correctly.
  -- Pre-split the buffer's source for the line cache so subsequent
  -- `:text()` calls on buffer-parsed nodes don't re-split on every call.
  local buf_lines = split_lines(buf_source)
  local svc = {
    parse = function(self, source_code, language)
      -- If source_code matches the current buffer, use the buffer parser.
      -- Otherwise, use a string parser to parse the given source.
      local using_string_parser = (source_code ~= buf_source)
      local source_text = using_string_parser and source_code or nil
      -- Pick the lines cache: for buffer parses, use the pre-split buf_lines;
      -- for string parses, split_lines() will hit the module-level cache.
      local lines = using_string_parser and split_lines(source_code) or buf_lines
      if not using_string_parser then
        local ok, parser = pcall(vim.treesitter.get_parser, bufnr, language)
        if not ok or parser == nil then return nil end
        local root, has_error = extract_root_from_parser(parser)
        if root == nil then return nil end
        return {
          -- Pass bufnr to wrap_node so :text() can use the correct buffer
          -- for buffer-parsed nodes (was hardcoded to 0, a real bug when
          -- M.new(bufnr) was called with bufnr != 0).
          root = function() return wrap_node(root, source_text, lines, bufnr) end,
          has_error = has_error,
        }
      else
        -- Parse an arbitrary source string (not the buffer).
        local ok, parser
        if vim.treesitter.get_string_parser then
          ok, parser = pcall(vim.treesitter.get_string_parser, source_code, language)
        end
        if not ok or parser == nil then return nil end
        local root, has_error = extract_root_from_parser(parser)
        if root == nil then return nil end
        return {
          -- String-parsed nodes use source_text for :text() extraction,
          -- but pass bufnr anyway for consistency (it's only used as a
          -- fallback when source_text is nil, which doesn't apply here).
          root = function() return wrap_node(root, source_text, lines, bufnr) end,
          has_error = has_error,
        }
      end
    end,
    descendant_for_range = function(self, root, sl, sc, el, ec)
      if root == nil then return nil end
      -- Defensive: if `root` is a mock node (no `_tsnode`), it has its own
      -- `descendant_for_range` method and shouldn't reach this code path.
      -- But we guard anyway so a mock tree passed in by mistake degrades
      -- gracefully instead of crashing with "attempt to index nil".
      if root._tsnode == nil then return nil end
      local ok, tsnode = pcall(root._tsnode.named_descendant_for_range,
        root._tsnode, sl, sc, el, ec)
      if not ok or tsnode == nil then return nil end
      -- Pass bufnr (stored on the root wrapper's closure) so descendant
      -- nodes also use the correct buffer for :text().
      return wrap_node(tsnode, root._source_text, nil, bufnr)
    end,
  }
  -- Interface contract self-check: the returned service object should
  -- satisfy ITreeSitter.
  local interfaces = require("calltree.core.interfaces")
  interfaces.assert_interface(svc, "ITreeSitter", false)
  return svc  -- (the table literal above is the return value; this is documentation)
end

return M
