--- debug.lua — debug collector for calltree.nvim analysis.
---
--- This module provides a `DebugCollector` object that accumulates diagnostic
--- information throughout the analysis pipeline. The collected data ends up as
--- the `debug` field of the JSON result, giving full visibility into every
--- decision the analyzer made.
---
--- Review 7.4: NOT actually pure Lua — `lsp_call` references the `vim`
--- global (for `vim.inspect`). The previous "Pure Lua, no Neovim dependencies"
--- module-level docstring was inaccurate. Updated to reflect reality: this
--- module works in both Neovim and plain-Lua environments, but degrades
--- gracefully (uses `tostring` fallback) when `vim.inspect` is unavailable.

-- Reference the centralized constants module. constants.lua is pure data
-- (no function dependencies), so requiring it here does NOT create a
-- circular dependency (debug.lua is inside utils/ but constants.lua has
-- no require of any other utils/ submodule).
local constants = require("calltree.utils.constants")
-- Item 21 (1.2.4 refactor): pull in `utils.node_text` so `node_summary`
-- can delegate text extraction to the canonical helper instead of
-- re-implementing `pcall(node.text, node) + truncation` inline. The
-- utils.init module is required lazily inside `node_summary` to avoid a
-- load-time circular dependency (utils/init.lua requires debug.lua's
-- VERSION via constants, but constants has no dep on debug — so a
-- top-level require would actually work; we keep it lazy for clarity
-- and to match the pattern used by fs.lua's constants require).
local _utils_node_text -- forward declaration; resolved lazily

local M = {}

-- Plugin version (recorded in every debug output for reproducibility).
-- Synced with CHANGELOG.md.
M.VERSION = "1.2.4"

------------------------------------------------------------------------------
-- Node summary helper (shared by multiple modules)
------------------------------------------------------------------------------

--- Build a compact serializable summary of a treesitter node.
--- @param node table|nil
--- @return table|nil { type, range, text }
-- node:range() is called once inside a pcall and the four return values
-- are captured via upvalues, so a second unprotected call is not needed.
-- Max text length kept in node_summary. Reference the centralized
-- constant from utils/constants.lua (was a local literal 80 that could
-- drift out of sync if the constant was updated).
local MAX_NODE_TEXT_LEN = constants.MAX_NODE_TEXT_LEN or 80
-- Length of the "..." ellipsis appended to truncated node text. Was a
-- literal `3` in the truncation expression; centralizing here so the
-- `MAX_NODE_TEXT_LEN - 3` arithmetic stays in sync if the ellipsis style
-- ever changes (e.g. to a single-char "…").
local ELLIPSIS_LEN = 3
local function node_summary(node)
  if node == nil then return nil end
  local sl, sc, el, ec
  -- Single pcall captures all 4 return values, avoiding the unprotected
  -- second call issue.
  local ok_r = pcall(function(...)
    sl, sc, el, ec = node:range()
  end)
  if not ok_r then
    sl, sc, el, ec = nil, nil, nil, nil
  end
  -- Item 21 (1.2.4 refactor): delegate text extraction to the canonical
  -- `utils.node_text` helper instead of re-implementing `pcall(node.text,
  -- node)` inline. The previous inline implementation only used the
  -- `node.text` method fallback, missing the `_text` and `name` fallbacks
  -- that `utils.node_text` provides for mock nodes. By delegating, we
  -- guarantee `node_summary` benefits from any future improvement to the
  -- canonical text-extraction logic (e.g. adding a `field` fallback).
  -- The truncation logic (MAX_NODE_TEXT_LEN + ellipsis) is preserved here
  -- because `utils.node_text` is the raw text extractor and should NOT
  -- truncate — truncation is a debug-output concern that belongs in
  -- `node_summary`, not in the general-purpose text extractor.
  if _utils_node_text == nil then
    _utils_node_text = require("calltree.utils").node_text
  end
  local raw_text = _utils_node_text(node)
  local text
  if raw_text then
    -- Truncate rather than discard when text exceeds the limit.
    -- Previously the entire text was dropped (set to nil), which lost
    -- debug information for any node whose text was longer than 80
    -- chars. Truncating with an ellipsis marker keeps a useful prefix
    -- while still bounding the debug output size.
    if #raw_text <= MAX_NODE_TEXT_LEN then
      text = raw_text
    else
      text = raw_text:sub(1, MAX_NODE_TEXT_LEN - ELLIPSIS_LEN) .. ("."):rep(ELLIPSIS_LEN)
    end
  end
  -- pcall node:type() so a mock node without :type() doesn't crash here.
  -- (Real treesitter nodes always have :type(), but mock nodes used in
  -- unit tests occasionally omit it.)
  local node_type
  if type(node.type) == "function" then
    local ok_tt, t = pcall(node.type, node)
    if ok_tt then node_type = t end
  end
  return {
    type  = node_type,
    range = (sl ~= nil) and { sl, sc, el, ec } or nil,
    text  = text,
  }
end
M.node_summary = node_summary

------------------------------------------------------------------------------
-- DebugCollector
------------------------------------------------------------------------------

local DebugCollector = {}
DebugCollector.__index = DebugCollector

--- Create a new debug collector seeded with the analysis context.
--- @param ctx table the analysis context (source_code, file_path, cursor_pos, etc.)
--- @return table collector
function M.new(ctx)
  local self = setmetatable({}, DebugCollector)
  -- Defensive: ctx.cursor_pos may be nil when the analyzer bailed before
  -- computing it (e.g. nvim_win_get_cursor failed). Default to a
  -- {line=0, character=0} sentinel so the inputs snapshot doesn't crash
  -- on `ctx.cursor_pos.line`.
  local cur_pos = ctx.cursor_pos or { line = 0, character = 0 }
  self.data = {
    -- Static inputs snapshot (for reproducibility).
    inputs = {
      file_path = ctx.file_path,
      cursor_pos = { line = cur_pos.line, character = cur_pos.character },
      language = ctx.language or constants.DEFAULT_LANGUAGE,
      cwd = nil,  -- filled lazily when getcwd is first called
    },
    -- Wall-clock-ish phase timings (in seconds, fractional).
    timings = {},
    -- Precondition check trace: each entry { check = string, passed = bool, detail = string|nil }.
    preconditions = {},
    -- Cursor-position detection trace.
    cursor_detection = {
      node_at_cursor = nil,
      is_name_node = nil,
      function_node = nil,
      symbol_match = nil,
      reason = nil,
    },
    -- LSP call trace.
    lsp_calls = {},
    -- Treesitter parse trace.
    ts_parses = {},
    -- Per-caller decision trace.
    caller_decisions = {},
    -- Per-external-call decision trace.
    external_call_decisions = {},
    -- Summary counts.
    summary = {
      total_refs            = 0,
      refs_excluded_defdecl = 0,
      refs_no_source        = 0,
      refs_no_node          = 0,
      refs_global_scope     = 0,
      refs_self_recursive   = 0,
      callers_kept          = 0,
      total_calls           = 0,
      calls_unresolved      = 0,
      calls_in_scope        = 0,
      calls_outside_project = 0,
      calls_no_body         = 0,
      calls_kept            = 0,
    },
    -- Any errors encountered (pcall failures etc).
    errors = {},
    -- Warnings (non-fatal but suspicious).
    warnings = {},
    -- Plugin version.
    version = M.VERSION,
  }
  -- Snapshot source code size (don't store full source to keep JSON small).
  if ctx.source_code then
    -- Count newlines accurately. The previous `for _ in :gmatch("\n") do
    -- n = n + 1 end; n + 1` over-counted by 1 when source_code did NOT
    -- end with a newline (it always added 1 for the trailing partial
    -- line, even when there was none). Fix: count actual `\n` occurrences;
    -- line count = newline count + 1 only when there's a trailing partial
    -- line, otherwise it equals newline count.
    --
    -- Boundary fix: an EMPTY source string should give 0 lines, not 1.
    -- The previous `has_trailing_partial = (#s == 0) or s:sub(-1) ~= "\n"`
    -- returned true for empty string (the `#s == 0` branch), so
    -- source_line_count = 0 + 1 = 1 for an empty source — wrong.
    -- Now: empty string → 0 lines; "abc" (no newline) → 1 line;
    -- "abc\n" → 1 line; "abc\ndef" → 2 lines; "abc\ndef\n" → 2 lines.
    --
    -- Review 5.9: the previous fix was CORRECT for "abc\n" (1 line),
    -- matching the conventional "number of lines = number of newlines + 1
    -- IF there's a trailing partial line, else just number of newlines".
    -- The review report claimed "abc\n" should be 2 lines, but that
    -- contradicts both POSIX `wc -l` (which counts newlines, giving 1)
    -- and most editor conventions. Keeping the existing logic; the report's
    -- suggested fix (`nl_count + 1`) would over-count by 1 on the common
    -- case of files ending with a single trailing newline.
    local _, nl_count = ctx.source_code:gsub("\n", "")
    local has_trailing_partial = #ctx.source_code > 0
      and ctx.source_code:sub(-1) ~= "\n"
    self.data.inputs.source_line_count = nl_count + (has_trailing_partial and 1 or 0)
    self.data.inputs.source_size_bytes = #ctx.source_code
  end
  return self
end

------------------------------------------------------------------------------
-- No-op collector (used when debug=false to skip all recording)
------------------------------------------------------------------------------

--- A no-op debug collector. All methods do nothing; `get()` returns nil.
--- Used when the user sets `debug = false` to avoid any debug-collection
--- overhead. Sub-modules can call methods on this collector without nil checks.
---
--- The __index metatable returns a no-op function for any method not
--- explicitly defined, so adding a new DebugCollector method does not
--- require adding a matching stub here (the debug=false path stays safe).
--- Explicit stubs are kept for documentation and readability.
local NoopCollector = {}
-- __index returns explicitly defined methods first; for undefined methods
-- it returns an automatic no-op function.
NoopCollector.__index = function(_, k)
  if NoopCollector[k] ~= nil then return NoopCollector[k] end
  -- Unknown method: return a no-op function (accepts any args, returns nil).
  return function() end
end

function M.disabled()
  return setmetatable({}, NoopCollector)
end

function NoopCollector:get() return nil end
function NoopCollector:precondition() end
function NoopCollector:lsp_call() end
function NoopCollector:ts_parse() end
function NoopCollector:error() end
function NoopCollector:warning() end
function NoopCollector:caller_decision() end
function NoopCollector:external_call_decision() end
function NoopCollector:incr() end
function NoopCollector:set() end
function NoopCollector:timing() end
function NoopCollector:set_completion_reason() end
function NoopCollector:set_cwd() end

-- The no-op collector has no real `data` field. We expose a "NilData" sentinel
-- table whose purpose is to silently swallow *all* writes (top-level AND
-- chained) and return a proxy for reads so chained access doesn't crash.
--
-- Review 10.3: the previous NilData returned `nil` from `__index`, which
-- meant `dbg.data.some_field` returned nil — and then `dbg.data.some_field.sub`
-- would crash with "attempt to index a nil value". This violated the
-- NoopCollector's design goal of "callers shouldn't need nil checks".
-- The fix: return a self-proxy so `dbg.data.anything.anything_else = X` is
-- a no-op (writes via __newindex are silently swallowed at every depth),
-- and `dbg.data.anything` returns the same NilData proxy (so chained reads
-- also work without crashing). Reads still return a proxy table (truthy),
-- so existing `if dbg.data.flag then` checks may evaluate truthy when the
-- flag was never set — but the only callers checking `dbg.data.X` are
-- already gated by `if dbg:get() ~= nil then`, so this doesn't affect
-- production behavior.
local NilData
NilData = setmetatable({}, {
  __index = function(_, k) return NilData end,
  __newindex = function() end,
})
NoopCollector.data = NilData
-- Review 6.3: the explicit NoopCollector method stubs (get, precondition,
-- lsp_call, etc.) are kept for documentation even though __index returns a
-- no-op function for any undefined method. The review report flagged these
-- as redundant; they're retained for grep-ability and to make the API
-- surface explicit — a small readability win that justifies the redundancy.

--- Get the underlying data table (for direct field access).
function DebugCollector:get() return self.data end

--- Record a precondition check result.
--- @param check string name of the check
--- @param passed boolean
--- @param detail string|nil optional explanation
function DebugCollector:precondition(check, passed, detail)
  table.insert(self.data.preconditions, { check = check, passed = passed, detail = detail })
end

--- Record an LSP call.
--- @param method string e.g. "textDocument/definition"
--- @param request table the request params
--- @param response table|nil the response (locations or symbols)
--- @param err string|nil error message
function DebugCollector:lsp_call(method, request, response, err)
  table.insert(self.data.lsp_calls, {
    method = method,
    request = request,
    response_summary = (function()
      if response == nil then return nil end
      if type(response) ~= "table" then return tostring(response) end
      -- The sample is rendered via vim.inspect (when available) or
      -- tostring, then truncated to 200 chars to prevent a single
      -- large LSP response (e.g. a DocumentSymbol[] with recursive
      -- children) from bloating the debug output. Previously
      -- `tostring(sample)` on a table returned a memory address like
      -- "table: 0x55a...", which was useless for debugging.
      local sample = response[1]
      if sample ~= nil then
        local s
        -- Review 1.15: type-check `vim.inspect` before calling it. The
        -- previous `if vim and vim.inspect then` only checked existence,
        -- not type — if a hostile environment set `vim.inspect = "string"`,
        -- the call would crash with "attempt to call a string value".
        if vim and type(vim.inspect) == "function" then
          s = vim.inspect(sample)
        else
          -- Pure-Lua fallback: shallow stringification.
          s = tostring(sample)
        end
        local max_len = constants.DEBUG_TRUNCATE_LEN or 200
        if #s > max_len then s = s:sub(1, max_len) .. "...(truncated)" end
        sample = s
      end
      return { count = #response, sample = sample }
    end)(),
    error = err,
  })
end

--- Record a treesitter parse.
--- @param purpose string e.g. "main_buffer", "ref_file:...", "def_file:..."
--- @param language string
--- @param ok boolean
--- @param has_error boolean
--- @param root_type string|nil
function DebugCollector:ts_parse(purpose, language, ok, has_error, root_type)
  table.insert(self.data.ts_parses, {
    purpose = purpose,
    language = language,
    ok = ok,
    has_error = has_error,
    root_type = root_type,
  })
end

--- Record a non-fatal error.
--- @param where string location/phase identifier
--- @param err any error value (will be tostring'd)
function DebugCollector:error(where, err)
  table.insert(self.data.errors, { where = where, message = tostring(err) })
end

--- Record a warning (non-fatal but suspicious).
--- @param msg string
function DebugCollector:warning(msg)
  table.insert(self.data.warnings, { message = msg })
end

--- Record a caller decision.
--- @param decision table { ref_uri, ref_position, outcome, reason, ... }
function DebugCollector:caller_decision(decision)
  table.insert(self.data.caller_decisions, decision)
end

--- Record an external-call decision.
--- @param decision table { call_position, function_name, outcome, reason, ... }
function DebugCollector:external_call_decision(decision)
  table.insert(self.data.external_call_decisions, decision)
end

--- Increment a summary counter.
--- @param key string e.g. "callers_kept"
function DebugCollector:incr(key)
  self.data.summary[key] = (self.data.summary[key] or 0) + 1
end

--- Set a summary counter to a specific value.
--- @param key string
--- @param value number
function DebugCollector:set(key, value)
  self.data.summary[key] = value
end

--- Record a timing measurement.
--- @param key string e.g. "preconditions_seconds"
--- @param seconds number
function DebugCollector:timing(key, seconds)
  self.data.timings[key] = seconds
end

--- Set the completion reason.
--- @param reason string e.g. "analyzed", "preconditions_failed"
function DebugCollector:set_completion_reason(reason)
  self.data.completion_reason = reason
end

--- Set the cwd (called lazily when getcwd is invoked).
--- @param cwd string
function DebugCollector:set_cwd(cwd)
  self.data.inputs.cwd = cwd
end

return M
