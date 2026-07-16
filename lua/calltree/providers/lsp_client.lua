--- providers/lsp_client.lua — LSP client constructor (extracted from adapter.lua).
---
--- Bridges Neovim's `vim.lsp` API to the interface expected by call_analyzer:
---   { definition, declaration, references, document_symbols, _diagnostics }
---
--- This is the ONLY module (alongside providers/treesitter.lua) that touches
--- the `vim.*` global for LSP access.

local utils     = require("calltree.utils")
local fifo_cache = require("calltree.utils.fifo_cache")
local M = {}

local vim = vim or {}

--------------------------------------------------------------------------------
-- Diagnostics (collected during LSP calls, for debugging)
--------------------------------------------------------------------------------

--- Diagnostics collected during LSP calls, for debugging.
---
--- **Design note (was a code-review finding):** this used to be a single
--- Per-bufnr diagnostics accumulator cache. Keyed by bufnr so that
--- concurrent analyses on different buffers don't overwrite each other's
--- diagnostic snapshots. `M.get_diagnostics(bufnr)` retrieves the
--- snapshot for a specific buffer; calling without bufnr returns the
--- most-recently-written entry (backward compat with the old API).
---
--- Previously this was a single module-level mutable table that every
--- `M.new(bufnr)` call would reset, making the module unsafe for
--- concurrent analyses on different buffers. The fix keys by bufnr so
--- each buffer's diagnostics persist until that buffer's client_obj is
--- garbage-collected (entries are cleaned up when a new client_obj for
--- the same bufnr replaces them, or explicitly via M.clear_diagnostics).
---
--- **Cache eviction:** to prevent unbounded memory growth in long
--- sessions, the cache is capped at MAX_DIAG_CACHE_ENTRIES. When the
--- limit is exceeded, the oldest entries (by insertion order) are
--- evicted. This is a simple FIFO eviction (not true LRU, but
--- sufficient for the typical usage pattern where recent buffers are
--- more likely to be re-analyzed).
---
--- Item 2 (1.2.4 refactor): the hand-rolled `lsp_diagnostics_by_bufnr` map
--- + `lsp_diagnostics_order` list + `_evict_diag_cache` function were
--- replaced by a single `fifo_cache` instance. The hand-rolled
--- implementation duplicated the exact FIFO eviction logic that
--- `fifo_cache` already provides (map + order list + table.remove(1)
--- eviction). Consolidating onto `fifo_cache` removes ~30 lines of
--- duplicated logic and guarantees the eviction strategy stays in sync
--- with the other caches in the codebase (file_parser, file_reader shim).
local MAX_DIAG_CACHE_ENTRIES = 64
local lsp_diagnostics_cache = fifo_cache.new(MAX_DIAG_CACHE_ENTRIES)
local most_recent_bufnr = nil        -- for backward-compat get_diagnostics()

--- Map of LSP method -> server_capabilities field name.
--- Used to check whether the attached LSP server supports each method before
--- making the request. If the server doesn't support a method, we skip the
--- request entirely (returning nil) instead of waiting for a timeout.
--
-- Method-name keys are sourced from the centralized utils.LSP_METHODS table
-- (was 6 inline "textDocument/..." string literals). This keeps the keys
-- in sync with the request strings used by the closure methods below
-- (definition / declaration / references / document_symbols) and the
-- debug-log strings used by callers.lua / external_calls.lua /
-- preconditions.lua, eliminating the chance of a typo like
-- "textDocument/documentSymbols" (note the trailing 's') passing
-- silently in one place and failing in another.
local LSP_METHODS = utils.LSP_METHODS
local METHOD_CAPABILITY_MAP = {
  [LSP_METHODS.definition]      = "definitionProvider",
  [LSP_METHODS.declaration]     = "declarationProvider",
  [LSP_METHODS.references]      = "referencesProvider",
  [LSP_METHODS.document_symbol] = "documentSymbolProvider",
  [LSP_METHODS.type_definition] = "typeDefinitionProvider",
  [LSP_METHODS.implementation]  = "implementationProvider",
}

--- Default LSP sync timeout (milliseconds). lua_ls / clangd / gopls typically
--- respond within 200ms; 1000ms leaves generous headroom for cold caches and
--- slow disks. Exposed as a module-level constant so callers can override
--- via `M.DEFAULT_LSP_TIMEOUT_MS = ...` if needed.
-- Reference the centralized constant from utils/constants.lua (was a
-- local literal 1000 that duplicated the constant and could drift).
M.DEFAULT_LSP_TIMEOUT_MS = utils.DEFAULT_LSP_TIMEOUT_MS or 1000

--- Check whether any attached LSP client supports the given method.
--- @param clients table list of LSP client objects
--- @param method string e.g. "textDocument/definition"
--- @return boolean supported, string|nil reason
local function method_supported(clients, method)
  local cap_field = METHOD_CAPABILITY_MAP[method]
  if cap_field == nil then
    -- Unknown method — assume supported (let the server reject it).
    return true, nil
  end
  for _, client in ipairs(clients or {}) do
    local caps = client.server_capabilities
    if caps and caps[cap_field] ~= nil then
      -- caps[cap_field] can be a boolean OR a table (e.g. for hoverProvider
      -- some servers return { workDoneProgress = true }). Truthy = supported.
      if caps[cap_field] == true or type(caps[cap_field]) == "table" then
        local cid = client.id ~= nil and tostring(client.id) or "<unknown>"
        return true, ("supported by " .. (client.name or ("client_" .. cid)))
      end
    end
  end
  return false, "no client supports " .. method .. " (capability: " .. cap_field .. ")"
end

--- Run an LSP request synchronously using Neovim's built-in
--- `vim.lsp.buf_request_sync`, which correctly handles event-loop processing.
--- Before making the request, checks server_capabilities to skip unsupported
--- methods immediately (avoids waiting for a timeout when the server doesn't
--- support declaration/typeDefinition etc.).
---
--- method: e.g. "textDocument/definition"
--- params: table with textDocument + position
--- diag_accumulator: array table to append diagnostics to (per-instance)
--- timeout_ms: optional override for the sync timeout
--- Returns: result (list of locations or symbols), or nil on error/empty/unsupported.

-- Query: build the diagnostic entry skeleton.
local function _build_diag_entry(method, params, clients)
  local client_count = clients and #clients or 0
  local entry = {
    method = method,
    params = params,
    client_count = client_count,
    client_names = {},
    timed_out = false,
    errors = {},
    result_count = 0,
    skipped_unsupported = false,
  }
  for _, c in ipairs(clients or {}) do
    local cid = c.id ~= nil and tostring(c.id) or "<unknown>"
    table.insert(entry.client_names, c.name or ("client_" .. cid))
  end
  return entry
end

-- Sentinel error string used to signal "buf_request_sync not available"
-- so the caller can fall back to the manual polling path. Centralized as
-- a module-level constant (was an inline string duplicated between
-- _send_request_via_buf_sync and lsp_request_sync, creating a hidden
-- coupling where renaming the string in one place would break the other).
local BUF_SYNC_UNAVAILABLE = "buf_request_sync not available"

-- Command: send the request via vim.lsp.buf_request_sync (Neovim 0.8+ path).
-- Returns results, err. err non-nil means pcall failed.
local function _send_request_via_buf_sync(bufnr, method, params, timeout_ms)
  if not vim.lsp.buf_request_sync then return nil, BUF_SYNC_UNAVAILABLE end
  local ok, results = pcall(vim.lsp.buf_request_sync, bufnr, method, params, timeout_ms)
  if not ok then return nil, "buf_request_sync error: " .. tostring(results) end
  return results, nil
end

-- Command: fallback path (Neovim <0.8), manual request + wait polling.
-- Side effect: populates diag_entry.timed_out / errors.
local function _send_request_via_fallback(clients, bufnr, method, params, timeout_ms, diag_entry)
  local results = {}
  for _, client in ipairs(clients) do
    local result, err, done = nil, nil, false
    client.request(method, params, function(e, r)
      err, result = e, r
      done = true
    end, bufnr)
    local waited = 0
    while not done and waited < timeout_ms do
      vim.wait(10)
      waited = waited + 10
    end
    if not done then
      diag_entry.timed_out = true
    elseif err then
      diag_entry.errors[#diag_entry.errors + 1] = tostring(err)
    elseif result then
      results[client.id] = { result = result }
    end
  end
  return results
end

-- Query: check whether an LSP result is "non-empty". An empty table `{}`
-- is truthy in Lua, so a naive `if res.result then` would treat a 0-result
-- response as "non-empty" and stop, causing client B's real results to be
-- ignored when client A returned an empty array. This helper correctly
-- distinguishes:
--   - nil → empty
--   - non-table → non-empty (anomalous but treat as data)
--   - array table → non-empty only if #result > 0
--   - single Location ({uri=...}) → non-empty (has the uri key)
--   - other object table → non-empty if it has at least one key
local function _result_is_non_empty(result)
  if result == nil then return false end
  if type(result) ~= "table" then return true end
  -- Single Location object (has `uri` key).
  if result.uri ~= nil then return true end
  -- Array: check #result. Note: #result is 0 for empty arrays and for
  -- non-array tables with no integer keys, so we also check next() for
  -- the object-table case.
  if #result > 0 then return true end
  return next(result) ~= nil
end

-- Query: collect the first non-empty result from results, recording
-- client errors into diag_entry. client_ids are sorted ascending to
-- ensure deterministic ordering (Lua `pairs` iteration order is
-- undefined, so "first" would otherwise be arbitrary).
local function _collect_first_result(results, diag_entry)
  if results == nil then return nil end
  -- Collect client_ids and sort them to guarantee deterministic order.
  local ids = {}
  for client_id in pairs(results) do
    table.insert(ids, client_id)
  end
  table.sort(ids, function(a, b)
    -- Use numeric comparison when both ids are numeric (the common case
    -- for vim.lsp client ids). Falls back to string comparison for
    -- non-numeric ids. The previous `tostring(a) < tostring(b)` sort
    -- was lexicographic, which sorts "10" before "2" — leading to
    -- non-deterministic "first result" selection in setups with 10+
    -- LSP clients.
    local na, nb = tonumber(a), tonumber(b)
    if na and nb then return na < nb end
    return tostring(a) < tostring(b)
  end)
  local first_result = nil
  for _, client_id in ipairs(ids) do
    local res = results[client_id]
    if res and _result_is_non_empty(res.result) then
      first_result = res.result
      break
    elseif res and res.error then
      diag_entry.errors[#diag_entry.errors + 1] =
        "client " .. tostring(client_id) .. " error: " .. vim.inspect(res.error)
    end
  end
  return first_result
end

-- Query: count the result items, populating diag_entry.result_count.
local function _count_result(first_result, diag_entry)
  if first_result == nil then return end
  if type(first_result) == "table" and first_result.uri then
    diag_entry.result_count = 1
  elseif type(first_result) == "table" then
    diag_entry.result_count = #first_result
  else
    -- Non-table non-nil: record the anomaly.
    diag_entry.errors[#diag_entry.errors + 1] =
      "unexpected LSP result type: " .. type(first_result)
    diag_entry.result_count = 0
  end
end

--- Orchestrator: synchronous LSP request. Calls the query/command
--- functions above and aggregates. Returns result (first non-empty) or nil.
local function lsp_request_sync(bufnr, method, params, diag_accumulator, timeout_ms)
  timeout_ms = timeout_ms or M.DEFAULT_LSP_TIMEOUT_MS
  diag_accumulator = diag_accumulator or {}

  -- 1. Collect attached clients + build diagnostic entry.
  -- Use `vim.lsp.get_clients` (Neovim 0.11+); fall back to the deprecated
  -- `vim.lsp.get_active_clients` only when `get_clients` is unavailable.
  -- This avoids deprecation warnings on modern Neovim while keeping
  -- backward compatibility with older builds.
  local clients
  if vim.lsp.get_clients then
    clients = vim.lsp.get_clients({ bufnr = bufnr })
  elseif vim.lsp.get_active_clients then
    clients = vim.lsp.get_active_clients({ bufnr = bufnr })
  else
    clients = {}
  end
  local diag_entry = _build_diag_entry(method, params, clients)

  -- 2. No client → record and return.
  if diag_entry.client_count == 0 then
    diag_entry.errors[#diag_entry.errors + 1] = "no LSP clients attached to buffer"
    table.insert(diag_accumulator, diag_entry)
    return nil
  end

  -- 3. Capability check: skip if unsupported.
  local supported, reason = method_supported(clients, method)
  if not supported then
    diag_entry.skipped_unsupported = true
    diag_entry.errors[#diag_entry.errors + 1] = "skipped: " .. (reason or "not supported")
    table.insert(diag_accumulator, diag_entry)
    return nil
  end

  -- 4. Send the request (prefer buf_request_sync, fall back to manual polling).
  local results, err = _send_request_via_buf_sync(bufnr, method, params, timeout_ms)
  if err == BUF_SYNC_UNAVAILABLE then
    results = _send_request_via_fallback(clients, bufnr, method, params, timeout_ms, diag_entry)
  elseif err ~= nil then
    diag_entry.errors[#diag_entry.errors + 1] = err
    table.insert(diag_accumulator, diag_entry)
    return nil
  end

  if results == nil then
    table.insert(diag_accumulator, diag_entry)
    return nil
  end

  -- 5. Collect the first non-empty result + count.
  local first_result = _collect_first_result(results, diag_entry)
  _count_result(first_result, diag_entry)

  table.insert(diag_accumulator, diag_entry)
  return first_result
end

-- Convert a vim.lsp location (which may be a Location or LocationLink) to our
-- canonical { uri, range, tags } form.
local function normalize_location(loc)
  if loc == nil then return nil end
  if loc.uri then
    return {
      uri = loc.uri,
      range = loc.range,
      tags = loc.tags,
    }
  end
  if loc.targetUri then
    -- LocationLink
    return {
      uri = loc.targetUri,
      range = loc.targetSelectionRange or loc.targetRange,
      tags = loc.tags,
    }
  end
  return nil
end

local function normalize_location_list(list)
  if list == nil then return {} end
  -- Review 1.10: handle `vim.NIL` (which represents JSON `null`). LSP
  -- servers can return `null` for empty results (e.g. an empty
  -- `textDocument/definition` response). `vim.NIL` is a userdata, NOT a
  -- table, so the `list.uri` access below would crash with
  -- "attempt to index userdata" before reaching `ipairs`. Bail out
  -- cleanly when the result is `vim.NIL` or any non-table value.
  if vim and vim.NIL and list == vim.NIL then return {} end
  if type(list) ~= "table" then return {} end
  -- LSP may return a single Location or an array; normalize to array.
  if list.uri or list.targetUri then
    list = { list }
  end
  local out = {}
  for _, loc in ipairs(list) do
    local n = normalize_location(loc)
    if n then table.insert(out, n) end
  end
  return out
end

--- Construct an LSP client object for the given buffer.
--- @param bufnr number
--- @return table { definition, declaration, references, document_symbols, _diagnostics }
function M.new(bufnr)
  -- **Per-instance diagnostics accumulator** (was module-level mutable state).
  -- Each `M.new(bufnr)` call now gets its own fresh `diag_acc` table, so
  -- concurrent analyses on different buffers no longer clobber each other's
  -- diagnostics. The accumulator is also cached in the per-bufnr map
  -- (`lsp_diagnostics_by_bufnr`) so `M.get_diagnostics(bufnr)` can retrieve
  -- a specific buffer's snapshot without race conditions.
  local diag_acc = {}
  -- Item 2 (1.2.4 refactor): use fifo_cache:set instead of the hand-rolled
  -- map+order+evict pattern. fifo_cache handles the eviction internally
  -- (oldest entry popped when over MAX_DIAG_CACHE_ENTRIES), so we don't
  -- need to call _evict_diag_cache separately.
  fifo_cache.set(lsp_diagnostics_cache, bufnr, diag_acc)
  most_recent_bufnr = bufnr  -- for backward-compat M.get_diagnostics()
  -- Resolve the buffer URI. `vim.uri_from_bufnr` has existed since Neovim
  -- 0.5 — but to be defensive on older builds (or in test harnesses that
  -- inject a stub `vim` global), fall back to a manual file:// URI built
  -- from `nvim_buf_get_name`. The fallback produces the same canonical
  -- form for on-disk files and an empty "file://" string for unnamed
  -- buffers, mirroring `vim.uri_from_bufnr`'s documented behavior.
  local uri
  if vim.uri_from_bufnr then
    uri = vim.uri_from_bufnr(bufnr)
  elseif vim.api and vim.api.nvim_buf_get_name then
    local name = vim.api.nvim_buf_get_name(bufnr) or ""
    uri = "file://" .. name
  else
    uri = "file://"
  end
  local client_obj = {
    -- IMPORTANT: the analyzer calls these as `lsp:definition(uri, position)`,
    -- so the method signature is (self, uri, position). The `uri` argument is
    -- redundant here (we already captured it in the closure), but we MUST
    -- consume it so `position` receives the actual {line, character} table.
    -- Previously the signature was `function(_, position)` which meant
    -- `position` received the uri STRING — causing lua_ls to crash with
    -- "attempt to compare number with nil" and return 0 results.
    definition = function(_self, _consumed_uri, position)
      local r = lsp_request_sync(bufnr, LSP_METHODS.definition, {
        textDocument = { uri = uri },
        position = position,
      }, diag_acc)
      return normalize_location_list(r)
    end,
    declaration = function(_self, _consumed_uri, position)
      local r = lsp_request_sync(bufnr, LSP_METHODS.declaration, {
        textDocument = { uri = uri },
        position = position,
      }, diag_acc)
      return normalize_location_list(r)
    end,
    references = function(_self, _consumed_uri, position, includeDecl)
      local r = lsp_request_sync(bufnr, LSP_METHODS.references, {
        textDocument = { uri = uri },
        position = position,
        context = { includeDeclaration = includeDecl },
      }, diag_acc)
      return normalize_location_list(r)
    end,
    document_symbols = function(_self, _consumed_uri)
      local r = lsp_request_sync(bufnr, LSP_METHODS.document_symbol, {
        textDocument = { uri = uri },
      }, diag_acc)
      if r == nil then return {} end
      -- DocumentSymbol and DocumentSymbol[] share the same shape; normalize.
      local out = {}
      for _, sym in ipairs(r) do
        table.insert(out, {
          name = sym.name,
          kind = sym.kind,
          range = sym.range or (sym.location and sym.location.range),
          selectionRange = sym.selectionRange,
          children = sym.children,
          tags = sym.tags,
        })
      end
      return out
    end,
    -- Expose diagnostics so the analyzer can include them in the debug field.
    -- Returns THIS instance's accumulator (not the module-level snapshot),
    -- so callers that hold a client_obj reference see exactly that client's
    -- diagnostics even after another `M.new(bufnr)` is called.
    _diagnostics = function() return diag_acc end,
  }
  -- Interface contract self-check: ensure the returned object satisfies ILspClient.
  -- Silent failure in strict=false mode (avoid raising in production).
  local interfaces = require("calltree.core.interfaces")
  interfaces.assert_interface(client_obj, "ILspClient", false)
  return client_obj
end

--- Get the accumulated LSP diagnostics from the most-recently-constructed
--- client object. Returns a shallow snapshot copy so callers cannot
--- accidentally mutate the live accumulator. For per-instance access, prefer
--- `client_obj:_diagnostics()` (returns the live table for that specific
--- client) — this module-level function is kept only for backward
--- compatibility with `adapter.get_lsp_diagnostics()`.
--- @param bufnr number|nil optional buffer number; when omitted, returns
---               the most-recently-created instance's diagnostics (backward
---               compat with the old single-buffer API).
--- @return table
function M.get_diagnostics(bufnr)
  local raw
  if bufnr ~= nil then
    -- Item 2 (1.2.4 refactor): use fifo_cache:get instead of the raw map
    -- lookup. fifo_cache:get returns nil for missing keys, so the `or {}`
    -- fallback preserves the previous behavior for unknown bufnrs.
    raw = fifo_cache.get(lsp_diagnostics_cache, bufnr) or {}
  else
    -- Backward-compat: no bufnr → return most-recent instance's diagnostics.
    raw = (most_recent_bufnr ~= nil
           and fifo_cache.get(lsp_diagnostics_cache, most_recent_bufnr)) or {}
  end
  local snapshot = {}
  for i, entry in ipairs(raw) do
    -- Deep-copy each entry so callers cannot mutate nested fields
    -- (entry.errors, entry.params, etc.) of the live accumulator.
    -- Previously this was a shallow copy: `snapshot[i] = entry` shared
    -- the inner tables by reference, so a caller doing
    -- `snapshot[1].errors[1] = "x"` would mutate the original.
    if vim and vim.deepcopy then
      snapshot[i] = vim.deepcopy(entry)
    else
      -- Pure-Lua fallback: shallow copy + best-effort deep copy of
      -- known nested fields (errors, params).
      local copy = {}
      for k, v in pairs(entry) do copy[k] = v end
      if type(copy.errors) == "table" then
        local errs = {}
        for j, e in ipairs(copy.errors) do errs[j] = e end
        copy.errors = errs
      end
      snapshot[i] = copy
    end
  end
  return snapshot
end

--- Clear the diagnostics snapshot for a specific buffer (or all buffers
--- when bufnr is nil). Useful for test teardown and when a buffer is
--- deleted to prevent the per-bufnr cache from growing unboundedly.
--- @param bufnr number|nil
function M.clear_diagnostics(bufnr)
  -- Item 2 (1.2.4 refactor): use fifo_cache:remove / fifo_cache:clear
  -- instead of the hand-rolled map+order cleanup. The previous code
  -- manually nil'd the map entry and walked the order list to find and
  -- remove the bufnr — exactly what fifo_cache.remove does internally.
  if bufnr ~= nil then
    fifo_cache.remove(lsp_diagnostics_cache, bufnr)
    if most_recent_bufnr == bufnr then most_recent_bufnr = nil end
  else
    fifo_cache.clear(lsp_diagnostics_cache)
    most_recent_bufnr = nil
  end
end

--------------------------------------------------------------------------------
-- Item 6 & 17 (1.2.4 refactor): safe_request — centralized LSP pcall wrapper.
--
-- Both callers.lua and external_calls.lua wrapped every `lsp:definition` /
-- `lsp:declaration` / `lsp:references` call in the same 10-line pcall +
-- error-log + default-empty-result + dbg:lsp_call pattern. The pattern was
-- duplicated 4+ times across the two modules, risking drift if the error-
-- handling or logging format ever changed.
--
-- This helper centralizes the pattern. The caller passes a `call_fn`
-- callback that performs the actual LSP method invocation (so the helper
-- doesn't need to know the per-method signature differences — definition
-- takes (uri, position), references takes (uri, position, includeDecl),
-- document_symbols takes (uri)). The helper:
--   1. pcall-wraps the call_fn.
--   2. On success: logs via dbg:lsp_call with the result, returns the
--      result (or {} when the server returned nil).
--   3. On failure: logs the error via dbg:error AND dbg:lsp_call (with
--      nil result + the error string), returns {} (empty list, so the
--      caller's `#result == 0` checks still work).
--
-- @param method_name string the LSP method name (e.g. "textDocument/definition") for dbg:lsp_call
-- @param params table the params to log in dbg:lsp_call (textDocument + position, etc.)
-- @param call_fn function() -> result  the LSP method invocation (e.g. function() return lsp:definition(uri, pos) end)
-- @param dbg table the debug collector (for :error and :lsp_call)
-- @param error_label string a label for dbg:error (e.g. "callers.lsp.definition")
-- @return table the result list (empty table on failure or nil result)
--------------------------------------------------------------------------------
function M.safe_request(method_name, params, call_fn, dbg, error_label)
  local ok, result = pcall(call_fn)
  if not ok then
    if dbg and dbg.error then
      dbg:error(error_label, tostring(result))
    end
    if dbg and dbg.lsp_call then
      dbg:lsp_call(method_name, params, nil, tostring(result))
    end
    return {}
  end
  result = result or {}
  if dbg and dbg.lsp_call then
    dbg:lsp_call(method_name, params, result, nil)
  end
  return result
end

--- Expose the capability map for tests/inspection.
M.METHOD_CAPABILITY_MAP = METHOD_CAPABILITY_MAP
M.method_supported = method_supported

return M
