--- providers/file_reader.lua — DEPRECATED, thin shim over `file_parser.lua`.
---
--- Item 1 (1.2.4 refactor): this module previously provided its own
--- `read + parse + cache` pipeline (mirroring `file_parser.lua`) with a
--- `get_tree(uri)` API. It had NO callers anywhere in the codebase
--- (verified via grep across lua/ and tests/), but was kept around as a
--- public API in case external consumers depended on it.
---
--- The duplicated implementation has been removed. This file is now a
--- thin shim that constructs a `file_parser` instance and exposes the
--- old `get_tree` / `register` method names as aliases for `get` /
--- `register`. The behavior is identical; only the implementation moved
--- to the canonical `file_parser` module.
---
--- Deprecated: new code should `require("calltree.infrastructure.file_parser")`
--- directly. This shim will be removed in a future major release.

local file_parser = require("calltree.infrastructure.file_parser")

local M = {}

--- Create a new FileReader instance. Accepts the same opts shape as
--- `file_parser.new` and returns an object whose `get_tree(uri)` method
--- is an alias for `file_parser`'s `get(uri)`. The return signature is
--- `(root, source, error_reason)` — matching the original FileReader API
--- (note: `file_parser.get` returns `(root, source, err_msg)` in the same
--- order, so the alias is direct).
--- @param opts table (see file_parser.new for the full shape)
--- @return table FileReader with :get_tree / :register / :has methods
function M.new(opts)
  local parser = file_parser.new(opts)
  return {
    -- Alias: get_tree(uri) → parser.get(uri). The original FileReader
    -- returned (root, source, error_reason); file_parser.get returns
    -- (root, source, err_msg) — same order, same semantics.
    get_tree = function(_, uri) return parser.get(uri) end,
    -- Alias: register(uri, source, root) → parser.register(uri, source, root).
    register = function(_, uri, source, root) parser.register(uri, source, root) end,
    -- Alias: has(uri) → parser.has(uri).
    has = function(_, uri) return parser.has(uri) end,
  }
end

return M
