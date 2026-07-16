--- core/interfaces.lua — service-layer abstract interface declarations.
---
--- This module declares the five abstract interfaces of the calltree.nvim
--- service layer (pure documentation + runtime shape validation). Concrete
--- implementations under `providers/` should assert they satisfy the
--- interface contract via the `implements` method.
---
--- The interfaces do not enforce a Lua "type system" (Lua has no native
--- interface); instead `assert_interface(obj, "ILspClient")` checks at
--- debug time whether the object exposes the set of methods required by
--- the contract.
---
--- The analysis layer (analysis/) may only depend on these interface
--- types, and must not reference concrete `providers/` implementations
--- directly.

local M = {}

-- Interface contract definitions: each interface lists the method names
-- that must be present.
M.CONTRACTS = {
  ILspClient = {
    "definition",       -- (uri, position) -> Location[]
    "declaration",      -- (uri, position) -> Location[]
    "references",       -- (uri, position, includeDecl) -> Location[]
    "document_symbols", -- (uri) -> DocumentSymbol[]
    "_diagnostics",     -- () -> diagnostic[]
  },
  ITreeSitter = {
    "parse",                -- (source_code, language) -> tree|nil
    "descendant_for_range", -- (root, sl, sc, el, ec) -> node|nil
  },
  IFileSystem = {
    "read_file",  -- (path) -> string|nil
    "exists",     -- (path) -> boolean
    "getcwd",     -- () -> string
  },
  IDebugLogger = {
    "record",  -- (phase, data) -> nil
  },
  ICapabilityChecker = {
    "supports",  -- (method) -> boolean
  },
}

-- Validate that an object satisfies an interface contract. When strict=true
-- the function raises on a missing method; otherwise it silently returns
-- false. strict defaults to true (matching the documentation).
--- @param obj table
--- @param iface_name string
--- @param strict boolean|nil default true; raise on missing method; pass
---                       false explicitly to silently return false
--- @return boolean ok
function M.assert_interface(obj, iface_name, strict)
  -- strict defaults to true (consistent with the doc comment).
  if strict == nil then strict = true end
  -- Only treat `nil` as "not provided"; a caller passing `false` to
  -- explicitly mark "I don't want this service" should still get the
  -- method-presence check (which will correctly report `false[method]`
  -- as non-function). Previously `false` was treated identically to `nil`,
  -- making `assert_interface(false, "IFileSystem")` always error regardless
  -- of `strict` — inconsistent with the `strict` contract.
  if obj == nil then
    if strict then error("assert_interface: obj is nil for " .. iface_name, 2) end
    return false
  end
  -- Guard against non-table `obj` (string, number, boolean, function, etc.).
  -- Previously only `nil` was handled; passing a string would crash on
  -- `obj[method]` with "attempt to index a string value". Now we surface
  -- a clear error (or return false in non-strict mode) instead.
  if type(obj) ~= "table" then
    if strict then
      error(string.format("assert_interface: obj is not a table (got %s) for %s",
        type(obj), iface_name), 2)
    end
    return false
  end
  local contract = M.CONTRACTS[iface_name]
  if contract == nil then
    -- Unknown interface name is a programming error; raise regardless of
    -- `strict` so the developer fixes the typo. Documented here so callers
    -- know this is intentional (the `strict` flag only controls the
    -- method-presence check, not the interface-name validation).
    error("assert_interface: unknown interface " .. iface_name, 2)
  end
  for _, method in ipairs(contract) do
    -- Allow callable tables (objects with a __call metamethod) to satisfy
    -- a method slot. Lua's callable-table idiom is a common way to
    -- implement function-like objects (e.g. some mock frameworks); the
    -- previous `type(obj[method]) ~= "function"` check rejected them,
    -- breaking such mocks. Now we accept either a function OR a table
    -- with a __call metamethod.
    local slot = obj[method]
    local is_callable = type(slot) == "function"
      or (type(slot) == "table" and debug.getmetatable(slot)
          and debug.getmetatable(slot).__call ~= nil)
    if not is_callable then
      if strict then
        error(string.format("assert_interface: %s missing method '%s'", iface_name, method), 2)
      end
      return false
    end
  end
  return true
end

return M
