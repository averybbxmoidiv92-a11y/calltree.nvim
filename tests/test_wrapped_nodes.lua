--- tests/test_wrapped_nodes.lua — verify the analyzer works when the
--- treesitter mock wraps each access in a FRESH Lua table (mimicking the
--- real Neovim adapter behavior).
---
--- This is a regression test for a real-world bug: the original
--- `is_function_name_node` used `from == target` to detect when the recursive
--- path search reached the cursor's node. With mock nodes (which pre-link
--- parent/child references) this worked, but with the real adapter — where
--- every `:parent()` / `:named_child(i)` call returns a NEW wrapper table —
--- the reference equality always returned false, so functions like
--- `function M.foo()` were rejected as "not on a function-definition name".
---
--- We construct a mock that mimics the adapter's fresh-wrapper-per-access
--- behavior, then verify the analyzer correctly identifies the cursor on
--- `analyze_at_cursor_json` as a function-definition name.

local Scenario = require("scenario")
local mocks    = require("mocks")
local A        = require("assert")
local utils    = require("calltree.utils")

local M = {}

--------------------------------------------------------------------------------
-- Build a "fresh-wrapper" node: each call to :parent() or :named_child(i)
-- returns a NEW Lua table, just like the real adapter's wrap_node().
-- Equality must therefore be by type+range, not by reference.
--------------------------------------------------------------------------------
local function make_fresh_wrapper(tsnode_table)
  -- tsnode_table is a plain table with: type, range, children (list of similar tables)
  -- We add a parent pointer so :parent() can navigate up.
  local function wrap(t)
    return setmetatable({}, {
      __index = function(_, k)
        if k == "_t" then return t end
        if k == "type" then return function() return t.type end end
        if k == "range" then
          return function()
            return t.range[1], t.range[2], t.range[3], t.range[4]
          end
        end
        if k == "parent" then
          return function() return t.parent and wrap(t.parent) or nil end
        end
        if k == "named_child_count" then
          return function() return #(t.children or {}) end
        end
        if k == "named_child" then
          return function(_, i)
            local c = (t.children or {})[i + 1]
            if c == nil then return nil end
            return wrap(c)
          end
        end
        if k == "text" then
          return function() return t.text or "" end
        end
        if k == "has_error" then return t.has_error or false end
        if k == "descendant_for_range" then
          return function(_, sl, sc, el, ec)
            -- Search the subtree for the smallest node whose range contains
            -- the queried range.
            local function contains(node_range)
              local rsl, rsc, rel, rec =
                node_range[1], node_range[2], node_range[3], node_range[4]
              if sl < rsl or el > rel then return false end
              if sl == rsl and sc < rsc then return false end
              if el == rel and ec > rec then return false end
              return true
            end
            local function search(node)
              if not contains(node.range) then return nil end
              for _, c in ipairs(node.children or {}) do
                local r = search(c)
                if r ~= nil then return r end
              end
              return node
            end
            local found = search(t)
            return found and wrap(found) or nil
          end
        end
        return nil
      end,
    })
  end
  -- Link parents.
  local function link(node, parent)
    node.parent = parent
    for _, c in ipairs(node.children or {}) do
      link(c, node)
    end
  end
  link(tsnode_table, nil)
  return wrap(tsnode_table)
end

--------------------------------------------------------------------------------
-- Test 1: `function M.foo()` — the user's exact scenario.
-- Cursor on `foo` should be detected as a function-definition name.
--------------------------------------------------------------------------------
function M.test_dotted_function_name_with_fresh_wrappers()
  -- Tree structure (Lua):
  --   chunk
  --     function_declaration
  --       function_name_field
  --         identifier "M"
  --         identifier "foo"           <- cursor here
  --       parameters
  --       block
  local tree_table = {
    type = "chunk", range = {0, 0, 1, 3}, children = {
      {
        type = "function_declaration", range = {0, 0, 1, 3}, children = {
          {
            type = "function_name_field", range = {0, 9, 0, 14}, children = {
              { type = "identifier", range = {0, 9, 0, 10}, text = "M" },
              { type = "identifier", range = {0, 11, 0, 14}, text = "foo" },
            },
          },
          { type = "parameters", range = {0, 14, 0, 16}, children = {} },
          { type = "block", range = {1, 0, 1, 3}, children = {} },
        },
      },
    },
  }
  local root_wrapper = make_fresh_wrapper(tree_table)

  -- Verify the wrapper actually returns fresh tables on each access.
  local n1 = root_wrapper:named_child(0)
  local n2 = root_wrapper:named_child(0)
  A.truthy(n1 ~= n2, "wrapper should return fresh tables on each access (mimics adapter)")

  -- Build a custom treesitter mock that returns our fresh-wrapper root.
  local ts_mock = {
    parse = function(self, source, lang)
      return {
        root = function() return root_wrapper end,
        has_error = false,
      }
    end,
    descendant_for_range = function(self, root, sl, sc, el, ec)
      return root:descendant_for_range(sl, sc, el, ec)
    end,
  }

  local analyzer = require("calltree.core.analyzer")
  local lsp = mocks.new_lsp_client()
  local uri = utils.path_to_uri("/project/test.lua")
  lsp:define_symbols(uri, {
    mocks.symbol("M.foo", utils.LSP_SYMBOL_FUNCTION, 0, 9, 1, 3),
  })

  local ctx = {
    source_code = "function M.foo() end\n",
    file_path = "/project/test.lua",
    cursor_pos = { line = 0, character = 11 },  -- on "foo" inside M.foo
    language = "lua",
    lsp_client = lsp,
    treesitter = ts_mock,
    getcwd = function() return "/project" end,
  }

  local result = analyzer.analyze(ctx)
  A.is_not_nil(result.current_function,
    "cursor on 'foo' in 'function M.foo()' should be detected as a function name")
  A.equal("foo", result.current_function.name,
    "current_function.name should be 'foo' (extracted from the identifier node)")
  -- The debug field should record that the path search succeeded.
  A.is_not_nil(result.debug)
  A.is_not_nil(result.debug.cursor_detection._name_path_search,
    "debug should record the name-path search details")
  A.equal(true, result.debug.cursor_detection._name_path_search.path_found,
    "the path search should have found the identifier as a descendant of function_declaration")
end

--------------------------------------------------------------------------------
-- Test 2: regular `function foo()` with fresh wrappers (regression).
--------------------------------------------------------------------------------
function M.test_simple_function_name_with_fresh_wrappers()
  local tree_table = {
    type = "chunk", range = {0, 0, 1, 3}, children = {
      {
        type = "function_declaration", range = {0, 0, 1, 3}, children = {
          { type = "identifier", range = {0, 9, 0, 12}, text = "foo" },
          { type = "parameters", range = {0, 12, 0, 14}, children = {} },
          { type = "block", range = {1, 0, 1, 3}, children = {} },
        },
      },
    },
  }
  local root_wrapper = make_fresh_wrapper(tree_table)
  local ts_mock = {
    parse = function(self, source, lang)
      return { root = function() return root_wrapper end, has_error = false }
    end,
    descendant_for_range = function(self, root, sl, sc, el, ec)
      return root:descendant_for_range(sl, sc, el, ec)
    end,
  }
  local analyzer = require("calltree.core.analyzer")
  local lsp = mocks.new_lsp_client()
  local uri = utils.path_to_uri("/project/test.lua")
  lsp:define_symbols(uri, {
    mocks.symbol("foo", utils.LSP_SYMBOL_FUNCTION, 0, 9, 1, 3),
  })
  local ctx = {
    source_code = "function foo() end\n",
    file_path = "/project/test.lua",
    cursor_pos = { line = 0, character = 9 },
    language = "lua",
    lsp_client = lsp,
    treesitter = ts_mock,
    getcwd = function() return "/project" end,
  }
  local result = analyzer.analyze(ctx)
  A.is_not_nil(result.current_function)
  A.equal("foo", result.current_function.name)
end

--------------------------------------------------------------------------------
-- Test 3: verify the analyzer runs end-to-end with adapter-style wrapped
-- nodes (smoke test that node helpers don't crash on various inputs).
--
-- Renamed from test_nodes_equal_helper (the original name was misleading
-- — this test does NOT directly exercise nodes_equal; it runs a full
-- analyze() with wrapped nodes and asserts the completion_reason). The
-- old name is kept as a backwards-compatible alias below.
--------------------------------------------------------------------------------
function M.test_wrapped_nodes_smoke()
  local analyzer = require("calltree.core.analyzer")
  -- We can't access the local nodes_equal directly, but we can verify it
  -- works end-to-end via the analysis result. This test is a smoke test
  -- that the helper doesn't crash on various inputs.
  local tree_table = {
    type = "chunk", range = {0, 0, 1, 0}, children = {
      {
        type = "function_declaration", range = {0, 0, 0, 18}, children = {
          { type = "identifier", range = {0, 9, 0, 12}, text = "foo" },
          { type = "parameters", range = {0, 12, 0, 14}, children = {} },
          { type = "block", range = {0, 15, 0, 18}, children = {} },
        },
      },
    },
  }
  local root_wrapper = make_fresh_wrapper(tree_table)
  local ts_mock = {
    parse = function(self, source, lang)
      return { root = function() return root_wrapper end, has_error = false }
    end,
    descendant_for_range = function(self, root, sl, sc, el, ec)
      return root:descendant_for_range(sl, sc, el, ec)
    end,
  }
  local lsp = mocks.new_lsp_client()
  local uri = utils.path_to_uri("/project/test.lua")
  lsp:define_symbols(uri, {
    mocks.symbol("foo", utils.LSP_SYMBOL_FUNCTION, 0, 9, 0, 18),
  })
  local ctx = {
    source_code = "function foo() end\n",
    file_path = "/project/test.lua",
    cursor_pos = { line = 0, character = 9 },
    language = "lua",
    lsp_client = lsp,
    treesitter = ts_mock,
    getcwd = function() return "/project" end,
  }
  local result = analyzer.analyze(ctx)
  A.equal("analyzed", result.debug.completion_reason)
end
-- Backwards-compatible alias for the renamed test above.
M.test_nodes_equal_helper = M.test_wrapped_nodes_smoke

return M
