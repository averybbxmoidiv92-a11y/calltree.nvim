--- tree_builder.lua — concise DSL for building mock treesitter trees.
---
--- Building trees by hand with `Node.new({ ... })` is verbose. This module
--- exposes a builder function `B` that accepts a compact nested-list form:
---
---   local t = TB.build({
---     { type = "program", range = {0,0,5,0}, children = {
---       { type = "function_definition", range = {0,0,2,3}, children = {
---         { type = "identifier", range = {0,4,0,7}, text = "foo" },
---         { type = "block", range = {1,0,2,3}, children = {
---           { type = "call", range = {1,4,1,8}, text = "bar()" },
---         }},
---       }},
---     }},
---   })
---
--- Each entry can have: type, range, text, has_error, children.
--- Returns the root Node (or a Tree wrapping it if `wrap = true`).

local mocks = require("mocks")
local Node = mocks.Node

local M = {}

--- Build a single Node from a spec table.
--- spec = { type=, range=, text=, has_error=, children= }
local function build_one(spec)
  local children = {}
  if spec.children then
    for _, c in ipairs(spec.children) do
      table.insert(children, build_one(c))
    end
  end
  return Node.new({
    type = spec.type or "node",
    range = spec.range or { 0, 0, 0, 0 },
    text = spec.text,
    has_error = spec.has_error or false,
    children = children,
  })
end

M.build = build_one

--- Convenience: build and wrap in a Tree.
function M.tree(spec, has_error)
  local root = build_one(spec)
  return mocks.Tree.new(root, has_error or false)
end

return M
