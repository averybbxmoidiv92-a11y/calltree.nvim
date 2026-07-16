--- tests/test_lsp_capabilities.lua — verify the adapter checks LSP server
--- capabilities before making requests, skipping unsupported methods.
---
--- This tests the METHOD_CAPABILITY_MAP and method_supported logic indirectly
--- by verifying the adapter's lsp_client methods return empty results for
--- unsupported methods without error.

local A = require("assert")
local utils = require("calltree.utils")

local M = {}

--------------------------------------------------------------------------------
-- Test 1: Verify the capability map covers the required methods.
--------------------------------------------------------------------------------
-- Mocks the `vim` global, requires providers.lsp_client, and asserts that
-- the exported METHOD_CAPABILITY_MAP contains the expected mapping.
function M.test_capability_map_covers_required_methods()
  -- Save and mock the necessary vim.* APIs (lsp_client.lua's top level only
  -- references vim.inspect and vim.lsp; internal functions like
  -- method_supported are not triggered at require time).
  local saved_vim = _G.vim
  if saved_vim == nil then
    _G.vim = {
      inspect = function() return "<mock>" end,
      lsp = { get_clients = function() return {} end, get_active_clients = function() return {} end },
      api = { nvim_get_current_buf = function() return 0 end },
      fn = {},
      schedule = function(f) return f end,
      wait = function() return false end,
    }
  end

  local ok, lsp_client = pcall(require, "calltree.providers.lsp_client")
  -- Restore the vim global (restored even if require fails, to avoid
  -- polluting subsequent tests).
  if saved_vim == nil then _G.vim = nil end

  A.truthy(ok, "should be able to require providers.lsp_client (got: " .. tostring(lsp_client) .. ")")
  if not ok then return end

  A.truthy(type(lsp_client.METHOD_CAPABILITY_MAP) == "table",
    "METHOD_CAPABILITY_MAP should be exported as a table")

  local expected = {
    ["textDocument/definition"]      = "definitionProvider",
    ["textDocument/declaration"]     = "declarationProvider",
    ["textDocument/references"]      = "referencesProvider",
    ["textDocument/documentSymbol"]  = "documentSymbolProvider",
  }
  for method, expected_cap in pairs(expected) do
    A.is_not_nil(lsp_client.METHOD_CAPABILITY_MAP[method],
      "METHOD_CAPABILITY_MAP should contain method " .. method)
    A.equal(expected_cap, lsp_client.METHOD_CAPABILITY_MAP[method],
      "METHOD_CAPABILITY_MAP[" .. method .. "] should map to " .. expected_cap)
  end
end

--------------------------------------------------------------------------------
-- Test 2: Verify the analyzer handles missing declaration gracefully.
-- When the LSP client has no `declaration` method, the analyzer should still
-- work (callers are still found via references, just without declaration
-- exclusion).
--------------------------------------------------------------------------------
function M.test_analyzer_works_without_declaration()
  local Scenario = require("scenario")
  local mocks    = require("mocks")
  local TB       = require("tree_builder")
  local A        = require("assert")

  local tree = TB.tree({
    type = "chunk", range = {0, 0, 5, 0}, children = {
      { type = "function_declaration", range = {0, 0, 2, 3}, children = {
        { type = "identifier", range = {0, 9, 0, 12}, text = "foo" },
        { type = "parameters", range = {0, 12, 0, 14}, children = {} },
        { type = "block", range = {1, 4, 2, 3}, children = {
          { type = "function_call", range = {1, 4, 1, 9}, children = {
            { type = "identifier", range = {1, 4, 1, 7}, text = "bar" },
            { type = "arguments", range = {1, 7, 1, 9}, children = {} },
          }},
        }},
      }},
    },
  })
  local uri = utils.path_to_uri("/project/test.lua")
  local s = Scenario.new()
    :with_code("function foo()\n    bar()\nend\n")
    :with_cursor(0, 9)
    :with_language("lua")
    :with_tree(tree:root())
    :with_file("/project/test.lua")
    :with_cwd("/project")
    :with_symbols(uri, {
      mocks.symbol("foo", utils.LSP_SYMBOL_FUNCTION, 0, 9, 2, 3),
    })
    :with_definition(uri, { line = 0, character = 9 }, {
      mocks.loc(uri, 0, 9, 0, 12),
    })
    :with_references(uri, { line = 0, character = 9 }, {
      mocks.loc(uri, 0, 9, 0, 12),
    }, true)
    :with_definition(uri, { line = 1, character = 4 }, {})

  -- Remove the declaration method from the LSP client (simulating a server
  -- that doesn't support declaration). Use rawset to shadow the metatable method.
  local lsp = s:lsp()
  rawset(lsp, "declaration", false)

  local result = s:analyze()
  A.is_not_nil(result.current_function, "analysis should still work without declaration")
  A.equal("foo", result.current_function.name)
  -- Should have no errors about declaration.
  if result.debug then
    for _, e in ipairs(result.debug.errors) do
      A.falsy(string.find(e.message or "", "declaration") ~= nil,
        "should not error on missing declaration: " .. tostring(e.message))
    end
  end
end

--------------------------------------------------------------------------------
-- Test 3: Verify the analyzer records a warning when declaration is not supported.
--------------------------------------------------------------------------------
function M.test_warning_when_declaration_not_supported()
  local Scenario = require("scenario")
  local mocks    = require("mocks")
  local TB       = require("tree_builder")

  local tree = TB.tree({
    type = "chunk", range = {0, 0, 2, 0}, children = {
      { type = "function_declaration", range = {0, 0, 0, 21}, children = {
        { type = "identifier", range = {0, 9, 0, 12}, text = "foo" },
        { type = "parameters", range = {0, 12, 0, 14}, children = {} },
        { type = "block", range = {0, 16, 0, 21}, children = {} },
      }},
    },
  })
  local uri = utils.path_to_uri("/project/test.lua")
  local s = Scenario.new()
    :with_code("function foo() end\n")
    :with_cursor(0, 9)
    :with_language("lua")
    :with_tree(tree:root())
    :with_file("/project/test.lua")
    :with_cwd("/project")
    :with_symbols(uri, {
      mocks.symbol("foo", utils.LSP_SYMBOL_FUNCTION, 0, 9, 0, 12),
    })
    :with_definition(uri, { line = 0, character = 9 }, {
      mocks.loc(uri, 0, 9, 0, 12),
    })
    :with_references(uri, { line = 0, character = 9 }, {
      mocks.loc(uri, 0, 9, 0, 12),
    }, true)

  -- Remove declaration support by overriding it on the instance with nil.
  -- Setting `lsp.declaration = nil` doesn't work because the metatable's
  -- __index provides MockLSP.declaration. Instead, we set it to a non-function
  -- value on the instance, which shadows the metatable method.
  local lsp = s:lsp()
  rawset(lsp, "declaration", false)  -- false is not a function

  local result = s:analyze()
  A.is_not_nil(result.debug)
  -- Should have a warning about declaration not being supported.
  local found_warning = false
  for _, w in ipairs(result.debug.warnings) do
    if string.find(w.message or "", "declaration") then
      found_warning = true
      break
    end
  end
  A.truthy(found_warning, "should warn about missing declaration support")
end

return M
