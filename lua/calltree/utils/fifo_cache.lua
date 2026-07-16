--- utils/fifo_cache.lua — shared FIFO-bounded cache utility.
---
--- Encapsulates the map + insertion-order list + eviction pattern
--- duplicated across file_reader, file_parser, and lsp_client.

local M = {}

--- @class FifoCache
--- @field max_entries number
--- @field map table
--- @field order table

function M.new(max_entries)
  if type(max_entries) ~= "number" or max_entries < 1 then
    max_entries = 128
  end
  return { max_entries = max_entries, map = {}, order = {} }
end

function M.get(cache, key)
  return cache.map[key]
end

function M.has(cache, key)
  return cache.map[key] ~= nil
end

function M.set(cache, key, value)
  if cache.map[key] == nil then
    cache.order[#cache.order + 1] = key
    while #cache.order > cache.max_entries do
      local oldest = table.remove(cache.order, 1)
      cache.map[oldest] = nil
    end
  end
  cache.map[key] = value
end

function M.remove(cache, key)
  if cache.map[key] == nil then return end
  cache.map[key] = nil
  for i, k in ipairs(cache.order) do
    if k == key then table.remove(cache.order, i); break end
  end
end

function M.clear(cache)
  cache.map = {}
  cache.order = {}
end

function M.size(cache)
  return #cache.order
end

return M
