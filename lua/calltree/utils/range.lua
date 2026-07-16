--- range.lua — LSP range/location comparison and conversion utilities.
--- Pure Lua, no Neovim dependencies.

local M = {}

--- Compare two LSP ranges for exact equality.
--- @param a table|nil
--- @param b table|nil
--- @return boolean
function M.range_equal(a, b)
  if a == nil and b == nil then return true end
  if a == nil or b == nil then return false end
  local as, ae = a.start, a["end"]
  local bs, be = b.start, b["end"]
  if as == nil or ae == nil or bs == nil or be == nil then return false end
  return as.line == bs.line and as.character == bs.character
     and ae.line == be.line and ae.character == be.character
end

--- Compare two LSP locations (uri + range) for equality.
function M.location_equal(a, b)
  if a == nil and b == nil then return true end
  if a == nil or b == nil then return false end
  if a.uri ~= b.uri then return false end
  return M.range_equal(a.range, b.range)
end

--- Check whether `loc` is in a list of locations (by uri+range equality).
function M.location_in_list(loc, list)
  if not list or not loc then return false end
  for _, item in ipairs(list) do
    if M.location_equal(loc, item) then return true end
  end
  return false
end

--- Convert a 0-based Treesitter range to a 1-based closed [start_line, end_line] pair.
--- @param ts_range table|nil { start_line, start_col, end_line, end_col }
--- @return table|nil [start_line, end_line] 1-based, closed
function M.ts_range_to_lines_1based(ts_range)
  if ts_range == nil then return nil end
  local start_line, _, end_line, _ = ts_range[1], ts_range[2], ts_range[3], ts_range[4]
  if start_line == nil or end_line == nil then return nil end
  -- Guard against invalid input where end_line < start_line: fall back to
  -- a single-line range {start_line + 1, start_line + 1} so the returned
  -- pair never has start > end.
  if end_line < start_line then
    return { start_line + 1, start_line + 1 }
  end
  local end_col = ts_range[4] or 0
  local closed_end = end_line
  if end_col == 0 and end_line > start_line then
    closed_end = end_line - 1
  end
  return { start_line + 1, closed_end + 1 }
end

--- Convert a 0-based {line, character} position to 1-based.
-- Defensive: returns nil when `pos` is nil OR when pos.line is nil
-- (a partial position table from a malformed LSP response would
-- otherwise crash with "attempt to perform arithmetic on a nil value").
function M.pos_to_1based(pos)
  if pos == nil or pos.line == nil then return nil end
  return { line = pos.line + 1, character = (pos.character or 0) + 1 }
end

--- Check whether an LSP location list contains a location for `uri` whose range
--- encloses (or equals) the given 0-based position.
-- Defensive: returns nil when `pos` is nil (a caller that forgot to pass
-- a cursor position shouldn't crash here).
function M.find_enclosing_location(list, uri, pos)
  if not list or not pos then return nil end
  for _, loc in ipairs(list) do
    if loc.uri == uri then
      local r = loc.range
      if r and r.start and r["end"] then
        local s, e = r.start, r["end"]
        if (pos.line > s.line or (pos.line == s.line and pos.character >= s.character))
           and (pos.line < e.line or (pos.line == e.line and pos.character <= e.character)) then
          return loc
        end
      end
    end
  end
  return nil
end

--- Check whether a position (0-based) is inside a Treesitter range.
-- Defensive: returns false when `pos` is nil (previously crashed with
-- "attempt to index a nil value" on `pos.line`).
function M.pos_in_ts_range(ts_range, pos)
  if ts_range == nil or pos == nil then return false end
  local sl, sc, el, ec = ts_range[1], ts_range[2], ts_range[3], ts_range[4]
  if pos.line < sl or pos.line > el then return false end
  if pos.line == sl and pos.character < sc then return false end
  if pos.line == el and pos.character >= ec then return false end
  return true
end

--- Find the position of a substring within a source string (0-based).
--- A single find + line/column count; the return always fires once find
--- succeeds (nil is returned when find finds nothing).
function M.find_pos_of(source, needle)
  if source == nil or needle == nil then return nil end
  local start_idx = source:find(needle, 1, true)
  if start_idx == nil then return nil end
  local l, c = 0, 0
  for j = 1, start_idx - 1 do
    local ch = source:sub(j, j)
    if ch == "\n" then l = l + 1; c = 0
    else c = c + 1 end
  end
  return { line = l, character = c }
end

return M
