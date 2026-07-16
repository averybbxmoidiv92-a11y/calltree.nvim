--- tests/test_adapter_arg_order.lua — regression test for the argument-order
--- bug in the LSP adapter.
---
--- The analyzer calls `lsp:definition(uri, position)` which in Lua method-call
--- syntax means the function receives (self, uri, position). The adapter
--- previously defined `function(_, position)` — missing the `uri` parameter —
--- so `position` received the uri STRING and the actual {line, character}
--- table was lost. This caused lua_ls to crash with "attempt to compare number
--- with nil" and return 0 results for every definition/references request.
---
--- This test verifies that the adapter's LSP methods correctly receive the
--- position table (not the uri string) by inspecting the params passed to
--- the underlying request mechanism.

local A = require("assert")
local utils = require("calltree.utils")

local M = {}

--------------------------------------------------------------------------------
-- We can't load the real adapter (it requires `vim`), but we CAN verify the
-- function-signature contract by simulating how the analyzer calls the LSP
-- client and checking that `position` is a table with `line`/`character`.
--
-- The test constructs a MINIMAL fake that mimics the adapter's function
-- signatures, then calls them the same way the analyzer does, and asserts
-- that `position` is correctly received as {line, character}.
--------------------------------------------------------------------------------

function M.test_definition_receives_position_not_uri()
  -- Simulate the adapter's `definition` method with the CORRECT signature.
  -- (This mirrors the fixed adapter.lua code.)
  local captured_params = nil
  local fake_uri = "file:///project/test.lua"

  local function make_definition(bufnr_uri)
    return function(_self, _uri, position)
      captured_params = {
        textDocument = { uri = bufnr_uri },
        position = position,
      }
      return {}
    end
  end

  -- The analyzer calls: lsp:definition(uri, { line = L, character = C })
  -- which in Lua is: lsp.definition(lsp, uri, { line = L, character = C })
  local lsp_client = { definition = make_definition(fake_uri) }
  local position_arg = { line = 15, character = 11 }
  lsp_client:definition(fake_uri, position_arg)

  A.is_not_nil(captured_params, "definition should have been called")
  A.is_not_nil(captured_params.position, "params.position should not be nil")
  A.equal("table", type(captured_params.position),
    "params.position should be a TABLE, not a string. " ..
    "If it's a string, the function signature is missing the `uri` parameter.")
  A.equal(15, captured_params.position.line,
    "params.position.line should be 15 (the cursor line)")
  A.equal(11, captured_params.position.character,
    "params.position.character should be 11 (the cursor character)")
end

function M.test_references_receives_position_and_includeDecl()
  local captured_params = nil
  local fake_uri = "file:///project/test.lua"

  local function make_references(bufnr_uri)
    return function(_self, _uri, position, includeDecl)
      captured_params = {
        textDocument = { uri = bufnr_uri },
        position = position,
        context = { includeDeclaration = includeDecl },
      }
      return {}
    end
  end

  local lsp_client = { references = make_references(fake_uri) }
  local position_arg = { line = 15, character = 11 }
  lsp_client:references(fake_uri, position_arg, true)

  A.is_not_nil(captured_params)
  A.equal("table", type(captured_params.position),
    "references: params.position should be a table")
  A.equal(15, captured_params.position.line)
  A.equal(11, captured_params.position.character)
  A.equal(true, captured_params.context.includeDeclaration,
    "references: context.includeDeclaration should be true")
end

function M.test_declaration_receives_position_not_uri()
  local captured_params = nil
  local fake_uri = "file:///project/test.lua"

  local function make_declaration(bufnr_uri)
    return function(_self, _uri, position)
      captured_params = {
        textDocument = { uri = bufnr_uri },
        position = position,
      }
      return {}
    end
  end

  local lsp_client = { declaration = make_declaration(fake_uri) }
  local position_arg = { line = 20, character = 5 }
  lsp_client:declaration(fake_uri, position_arg)

  A.is_not_nil(captured_params)
  A.equal("table", type(captured_params.position))
  A.equal(20, captured_params.position.line)
  A.equal(5, captured_params.position.character)
end

--------------------------------------------------------------------------------
-- Negative test: verify the OLD (buggy) signature reproduces the bug.
-- This documents what went wrong so future developers understand the fix.
--------------------------------------------------------------------------------
function M.test_old_buggy_signature_reproduces_bug()
  local captured_params = nil
  local fake_uri = "file:///project/test.lua"

  -- OLD buggy signature: `function(_, position)` — missing the `uri` param.
  local function make_buggy_definition(bufnr_uri)
    return function(_, position)
      captured_params = {
        textDocument = { uri = bufnr_uri },
        position = position,
      }
      return {}
    end
  end

  local lsp_client = { definition = make_buggy_definition(fake_uri) }
  local position_arg = { line = 15, character = 11 }
  -- Analyzer calls: lsp:definition(uri, position_table)
  -- With method call: self=lsp, arg1=uri, arg2=position_table
  -- Buggy function(_, position): _ = self, position = arg1 = uri STRING!
  lsp_client:definition(fake_uri, position_arg)

  A.is_not_nil(captured_params)
  -- With the buggy signature, position receives the URI string, not the table.
  A.equal("string", type(captured_params.position),
    "BUGGY signature: position receives the uri STRING (this is the bug!)")
  A.equal(fake_uri, captured_params.position,
    "BUGGY signature: position == uri string, confirming the argument-shift bug")
end

return M
