--- init.lua — public entry point for calltree.nvim.
---
--- Usage:
---   local calltree = require("calltree")
---   calltree.analyze_at_cursor()  -- returns the result table
---   calltree.analyze_at_cursor_json()  -- returns the JSON string

local analyzer = require("calltree.core.analyzer")
local adapter  = require("calltree.adapter")
local types    = require("calltree.domain.types")

local M = {}

-- Default options (can be overridden via setup()).
M.options = {
  debug = true,  -- whether to collect and include debug info in results
  user_commands = true,  -- whether to register :Calltree* user commands
  -- v1.2.0: post-collection filtering for external_calls.
  -- skip_stdlib_calls: when true, drop entries with is_stdlib=true from
  --   the final external_calls array (default true — most users don't
  --   want stdlib noise like string.format / print in their call graph).
  -- deduplicate_external_calls: when true, drop duplicates where two
  --   entries share the same (function_name, definition.file) pair,
  --   keeping the first occurrence (default true — most users want
  --   one entry per callee, not one entry per call site).
  -- Both flags are applied AFTER the external_calls phase finishes
  -- collecting; the order is dedup-then-filter (see analyzer.lua).
  skip_stdlib_calls = true,
  deduplicate_external_calls = true,
}

-- Module-level constant: `unpack` is global in Lua 5.1/LuaJIT (Neovim's
-- runtime) but moved to `table.unpack` in 5.2+. Resolved once at module
-- load time instead of on every analyze_at_cursor call.
local UPACK = table.unpack or unpack

-- Constants centralizing magic strings / numbers used across init.lua.
-- Previously these were scattered literals repeated in multiple print
-- statements and command-registration blocks; grouping them here makes
-- each easy to grep and adjust in one place.
local LOG_PREFIX       = "[calltree] "   -- prefix for all user-facing print() output
local DISPLAY_ANON     = "<anon>"        -- placeholder for anonymous caller names
local DISPLAY_UNKNOWN  = "?"             -- placeholder for missing range coords / line numbers
local DISPLAY_NIL      = "nil"           -- placeholder when a range/caller field is genuinely nil
local LSP_LINE_OFFSET  = 1               -- nvim_win_get_cursor returns 1-based rows; LSP uses 0-based

-- Names of the user commands registered by register_user_commands(). Also
-- used by M.setup() to unregister commands when user_commands is toggled
-- off — previously the list was duplicated in both places, so renaming a
-- command in one spot silently left the other out of sync.
local USER_COMMAND_NAMES = {
  "CalltreeAnalyze", "CalltreeJson", "CalltreeJsonDebug", "CalltreeToFile"
}

-- Helper: resolve the effective debug flag from `opts` (explicit per-call
-- override) falling back to `M.options.debug` (set via setup()). Extracted
-- to eliminate the 3× duplication of this pattern across analyze_at_cursor,
-- write_json_to_file, and analyze_at_cursor_json.
-- @param opts table|nil
-- @return boolean
local function resolve_debug(opts)
  local d = opts and opts.debug
  if d == nil then d = M.options.debug end
  return d
end

--- Run the analysis at the current cursor position.
--- @param bufnr number|nil buffer number (default 0 = current)
--- @param opts table|nil { debug = boolean|nil } — default uses M.options.debug
--- @return table result (the JSON-structured table)
function M.analyze_at_cursor(bufnr, opts)
  bufnr = bufnr or 0
  opts = opts or {}
  -- Review 1.2: when bufnr is non-zero AND doesn't match the current
  -- buffer, use bufwinid to find the window containing that buffer and
  -- read the cursor from THAT window (instead of hardcoding window 0).
  -- When bufnr is 0 (current) or matches the current buffer, the previous
  -- `nvim_win_get_cursor(0)` behavior is preserved.
  local winid = 0
  if bufnr ~= 0 and vim.api.nvim_get_current_buf and bufnr ~= vim.api.nvim_get_current_buf() then
    local w = vim.fn.bufwinid(bufnr)
    -- bufwinid returns -1 when the buffer has no window.
    if w ~= nil and w ~= -1 then
      winid = w
    -- else: fall back to window 0 (best-effort; cursor may not match
    -- the buffer, but at least we don't crash).
    end
  end
  -- Wrap nvim_win_get_cursor in pcall so a missing/invalid window (e.g.
  -- unattached buffer, closed win, headless invocation without a window)
  -- doesn't propagate to the caller. We return an empty result with a
  -- `cursor_error` completion_reason so consumers can introspect the
  -- failure even when debug=false.
  local ok_cur, cur = pcall(vim.api.nvim_win_get_cursor, winid)
  if not ok_cur or cur == nil then
    local debug_opt = resolve_debug(opts)
    -- Distinguish the two failure modes: pcall failed (cur is the error
    -- object) vs. pcall succeeded but returned nil (cur is nil). Previously
    -- both produced the confusing message "failed: nil".
    local err_msg
    if not ok_cur then
      err_msg = "nvim_win_get_cursor raised: " .. tostring(cur)
    else
      err_msg = "nvim_win_get_cursor returned nil (no valid window?)"
    end
    -- Item 5 (1.2.4 refactor): use `types.EmptyCallGraph` instead of
    -- hand-constructing the { current_function, callers, external_calls }
    -- table. The factory centralizes the field list so any future shape
    -- change only needs to be made in one place.
    local debug_snapshot = nil
    if debug_opt then
      debug_snapshot = { completion_reason = "cursor_error",
                         errors = { err_msg },
                         warnings = {}, summary = {}, timings = {} }
    end
    return types.EmptyCallGraph(debug_snapshot)
  end
  local row, col = UPACK(cur)
  -- Defensive: nvim_win_get_cursor is documented to return {row, col}
  -- but some edge cases (e.g. a window with no buffer, or a future API
  -- change) could return a 1-element or 0-element table. Previously a
  -- missing `col` was transparently passed to the analyzer as
  -- `{ character = nil }`, which then crashed deep in the LSP layer.
  -- Guard against that by treating a missing row as a cursor error.
  if row == nil then
    local debug_opt = resolve_debug(opts)
    -- Item 5 (1.2.4 refactor): use `types.EmptyCallGraph` instead of
    -- hand-constructing the result table (same rationale as the
    -- ok_cur==false branch above).
    local debug_snapshot = nil
    if debug_opt then
      debug_snapshot = { completion_reason = "cursor_error",
                         errors = { "nvim_win_get_cursor returned a table without a row" },
                         warnings = {}, summary = {}, timings = {} }
    end
    return types.EmptyCallGraph(debug_snapshot)
  end
  -- nvim_win_get_cursor returns (1-based row, 0-based col).
  local cursor_pos = { line = row - LSP_LINE_OFFSET, character = col }
  local debug_opt = resolve_debug(opts)
  -- v1.2.0: thread the new external_calls post-processing flags from
  -- M.options into the analysis context. Per-call overrides via `opts`
  -- are also supported (matching the `debug` flag's override semantics):
  -- if opts.skip_stdlib_calls / opts.deduplicate_external_calls is
  -- non-nil, it takes precedence over M.options; otherwise we fall back
  -- to the M.options value (which defaults to true).
  local skip_stdlib_opt = opts.skip_stdlib_calls
  if skip_stdlib_opt == nil then skip_stdlib_opt = M.options.skip_stdlib_calls end
  local dedup_opt = opts.deduplicate_external_calls
  if dedup_opt == nil then dedup_opt = M.options.deduplicate_external_calls end
  local ctx = adapter.build_context(bufnr, cursor_pos, nil, {
    debug = debug_opt,
    skip_stdlib_calls = skip_stdlib_opt,
    deduplicate_external_calls = dedup_opt,
  })
  local result = analyzer.analyze(ctx)
  -- LSP adapter diagnostics are now merged inside analyzer._run_analysis_phases
  -- (before the result is frozen via CallGraphBuilder:build()). Previously
  -- this was done here post-return, but the v1.2.2 immutability refactor
  -- froze the result before init.lua could write to result.debug.
  return result
end

--- Same as analyze_at_cursor but returns a JSON string.
--- Uses vim.json if available, falls back to vim.fn.json_encode.
--- @param bufnr number|nil
--- @param opts table|nil { debug = boolean|nil } — forwarded to analyze_at_cursor
--- @return string json
function M.analyze_at_cursor_json(bufnr, opts)
  -- Avoid double-analysis: call the internal analyze once, then encode.
  local result = M.analyze_at_cursor(bufnr, opts)
  return M.encode_json(result)
end

--- Encode a Lua table as a JSON string.
--- Prefers vim.json (Neovim 0.5+), then vim.fn.json_encode (older Neovim),
--- and finally a tiny pure-Lua fallback for environments where neither is
--- available (e.g. plain `lua5.4` test harness). The pure-Lua fallback
--- only handles tables of strings/numbers/booleans/nil and nested tables —
--- sufficient for calltree's flat result schema, but NOT a general JSON
--- encoder.
--- Each branch is wrapped in pcall so that a runtime encoding error (e.g.
--- cyclic table, unsupported value type) falls through to the next branch
--- instead of propagating to the caller.
--- @param result table
--- @return string json
local function _json_escape_string(s)
  s = s:gsub("\\", "\\\\")
       :gsub('"', '\\"')
       :gsub("\n", "\\n")
       :gsub("\r", "\\r")
       :gsub("\t", "\\t")
  return '"' .. s .. '"'
end

-- Cycle-detecting pure-Lua JSON encoder. A `seen` set prevents infinite
-- recursion on self-referential tables (e.g. t.self = t), which would
-- otherwise overflow the Lua stack.
local function _pure_lua_json_encode(v, seen)
  local t = type(v)
  if t == "nil" then return "null"
  elseif t == "boolean" then return v and "true" or "false"
  elseif t == "number" then
    if v ~= v or v == math.huge or v == -math.huge then
      return "null"  -- NaN/Infinity are not valid JSON
    end
    return tostring(v)
  elseif t == "string" then
    return _json_escape_string(v)
  elseif t == "table" then
    -- Cycle detection.
    if seen and seen[v] then return "null" end  -- break cycle
    seen = seen or {}
    seen[v] = true
    -- Distinguish array (positive integer keys 1..n) from object.
    -- Single-pass: collect all key-value pairs, track the max integer key
    -- and whether any non-integer key exists.
    local n = 0
    local is_array = true
    local entries = {}  -- collected (key, value) pairs for the object branch
    for k, val in pairs(v) do
      if type(k) == "number" and k == math.floor(k) and k >= 1 then
        n = math.max(n, k)
      else
        is_array = false
      end
      entries[#entries + 1] = { k = k, val = val }
    end
    -- Verify there are no gaps and the count matches.
    if is_array then
      local count = 0
      for _ in pairs(v) do count = count + 1 end
      if count ~= n then is_array = false end
    end
    if is_array then
      local parts = {}
      for i = 1, n do
        parts[i] = _pure_lua_json_encode(v[i], seen)
      end
      seen[v] = nil  -- allow re-encoding the same table from a different path
      return "[" .. table.concat(parts, ",") .. "]"
    else
      -- Sort keys for deterministic output (non-integer keys only; integer
      -- keys in an object are rare and their order is preserved by pairs()).
      -- This makes snapshot/golden-file tests reproducible across runs.
      table.sort(entries, function(a, b)
        if type(a.k) == type(b.k) then
          return a.k < b.k
        end
        return tostring(a.k) < tostring(b.k)
      end)
      local parts = {}
      for _, e in ipairs(entries) do
        parts[#parts + 1] = _json_escape_string(tostring(e.k)) .. ":" .. _pure_lua_json_encode(e.val, seen)
      end
      seen[v] = nil
      return "{" .. table.concat(parts, ",") .. "}"
    end
  end
  -- functions, userdata, threads: encode as null.
  return "null"
end

-- v1.2.2: Recursively convert a frozen (immutable proxy) table back into
-- a plain mutable table so that vim.json.encode / vim.fn.json_encode can
-- iterate it. Those built-in encoders use raw C-level table iteration
-- (lua_next) which bypasses the proxy's __pairs/__ipairs metamethods,
-- producing empty output ("[]" or "{}") on frozen objects. The pure-Lua
-- fallback encoder (_pure_lua_json_encode) DOES respect metamethods, but
-- we prefer the faster C encoders when available.
-- The thaw is a shallow-to-deep conversion: it walks the table using
-- pairs() (which respects __pairs on proxies) and recurses into sub-tables.
-- A `seen` map handles cyclic references.
local function _thaw(t, seen)
  if type(t) ~= "table" then return t end
  seen = seen or {}
  if seen[t] then return seen[t] end
  local plain = {}
  seen[t] = plain
  for k, v in pairs(t) do
    plain[k] = _thaw(v, seen)
  end
  return plain
end

function M.encode_json(result)
  -- v1.2.2: Thaw the result before encoding. If the result is a frozen
  -- CallGraph (from the v1.2.2 domain-types refactor), vim.json.encode
  -- would produce empty output because it bypasses proxy metamethods.
  -- Thawing converts the proxy tree back to plain tables. If the result
  -- is already a plain table (e.g. from early-return paths or tests),
  -- _thaw is a no-op (returns the same structure).
  -- We thaw ONCE here and pass the plain table to all encoder branches.
  local thawed = _thaw(result)

  -- Each branch is pcall-wrapped so a runtime error in one falls through
  -- to the next, rather than propagating to the caller. Previously only
  -- API availability was checked, so a malformed table would crash even
  -- when a fallback was available.
  if vim and vim.json and vim.json.encode then
    local ok, s = pcall(vim.json.encode, thawed)
    if ok and type(s) == "string" and #s > 2 then return s end
  end
  if vim and vim.fn and vim.fn.json_encode then
    local ok, s = pcall(vim.fn.json_encode, thawed)
    if ok and type(s) == "string" and #s > 2 then return s end
  end
  -- Pure-Lua fallback so headless unit tests / `lua5.4` test harnesses
  -- can call encode_json without crashing on `attempt to index nil (vim.fn)`.
  -- Previously this branch was NOT pcall-wrapped (unlike the comment
  -- above claimed), so a cyclic or unsupported-value table would raise
  -- straight through `write_json_to_file`'s outer pcall as a non-string
  -- json value and surface as a misleading "analyze_failed" error.
  local ok_fallback, s_fallback = pcall(_pure_lua_json_encode, thawed)
  if ok_fallback and type(s_fallback) == "string" then
    return s_fallback
  end
  -- Last-resort: emit a minimal JSON object describing the encoding
  -- failure rather than raising. Callers that read the string back via
  -- vim.json.decode will see the error message here.
  return "{\"encode_json_error\":\"" .. tostring(s_fallback) .. "\"}"
end

-- Helper: format a range table as a compact "[start,end]" string. Used
-- by both _format_caller and _format_external_call (which previously
-- duplicated this logic verbatim). Defensive against nil / non-table
-- ranges so malformed CallerInfo entries don't crash dump_at_cursor.
local function _format_range(r)
  if r and type(r) == "table" then
    return "[" .. tostring(r[1] or DISPLAY_UNKNOWN) .. "," ..
           tostring(r[2] or DISPLAY_UNKNOWN) .. "]"
  end
  return DISPLAY_NIL
end

-- Helper: format a caller entry for dump_at_cursor. Extracted to reduce
-- the three near-identical print loops in dump_at_cursor.
local function _format_caller(c)
  -- Defensive: c.caller_function may be nil on malformed CallerInfo.
  local cf = c.caller_function or {}
  local name = cf.name or DISPLAY_ANON
  local rstr = _format_range(cf.range)
  local cp = c.call_position or {}
  return "  - " .. name .. " " .. rstr .. "  call_at=" ..
    tostring(cp.line or DISPLAY_UNKNOWN) .. ":" .. tostring(cp.character or DISPLAY_UNKNOWN) ..
    "  file=" .. tostring(c.file)
end

-- Helper: format an external call entry for dump_at_cursor.
local function _format_external_call(ec)
  local def = ec.definition
  local def_str
  if def then
    def_str = "file=" .. tostring(def.file) .. " range=" ..
      _format_range(def.function_body_range)
  else
    def_str = DISPLAY_NIL
  end
  return "  - " .. tostring(ec.function_name) .. " [" .. tostring(ec.resolution_status) ..
    "] stdlib=" .. tostring(ec.is_stdlib) .. "  def: " .. def_str
end

--- Print a compact summary of the analysis result (avoids the huge `vim.inspect`
--- output that Neovim truncates with `<table N>` placeholders).
--- @param bufnr number|nil
--- @param opts table|nil { debug = boolean|nil } forwarded to analyze_at_cursor
---   so the caller can temporarily enable debug for a one-off dump
---   regardless of M.options.debug.
function M.dump_at_cursor(bufnr, opts)
  local result = M.analyze_at_cursor(bufnr, opts)
  local cf = result.current_function
  if cf == nil then
    -- Defensive: when setup({ debug = false }) is used, result.debug is nil.
    -- Use an explicit two-step lookup so we never index a nil table.
    local reason = "unknown"
    if result.debug ~= nil and result.debug.completion_reason ~= nil then
      reason = result.debug.completion_reason
    end
    print(LOG_PREFIX .. "No function at cursor. Reason: " .. reason)
    return
  end
  -- Defensive: result.callers / result.external_calls may be nil on some
  -- early-failure paths (e.g. preconditions_failed). Default to empty
  -- tables so `#result.callers` doesn't raise.
  local callers = result.callers or {}
  local external_calls = result.external_calls or {}
  -- Defensive: cf.range might be nil or a non-array table on some
  -- early-failure paths even though analyzer._locate_cursor_function
  -- sets a default {0,0}. Guard the indexing so dump_at_cursor never
  -- crashes on a malformed current_function.
  local r1, r2 = DISPLAY_UNKNOWN, DISPLAY_UNKNOWN
  if cf.range and type(cf.range) == "table" then
    r1 = tostring(cf.range[1] or DISPLAY_UNKNOWN)
    r2 = tostring(cf.range[2] or DISPLAY_UNKNOWN)
  end
  print(LOG_PREFIX .. "current_function: " .. (cf.name or DISPLAY_NIL) ..
    "  range=[" .. r1 .. "," .. r2 .. "]  file=" .. tostring(cf.file))
  print(LOG_PREFIX .. "callers (" .. #callers .. "):")
  for _, c in ipairs(callers) do
    print(_format_caller(c))
  end
  print(LOG_PREFIX .. "external_calls (" .. #external_calls .. "):")
  for _, ec in ipairs(external_calls) do
    print(_format_external_call(ec))
  end
  if result.debug then
    local s = result.debug.summary or {}
    print(LOG_PREFIX .. "summary: callers_kept=" .. (s.callers_kept or 0) ..
      " calls_kept=" .. (s.calls_kept or 0) ..
      " calls_unresolved=" .. (s.calls_unresolved or 0) ..
      " warnings=" .. #(result.debug.warnings or {}) ..
      " errors=" .. #(result.debug.errors or {}))
  end
end

--- Write the full JSON result to a file (for tools that consume the JSON).
--- @param path string output file path
--- @param bufnr number|nil
--- @param opts table|nil { debug = boolean|nil } — default uses M.options.debug
--- @return boolean ok, string|nil err_kind, string|nil err_detail — err_kind is one of:
---   "analyze_failed", "open_failed", "write_failed"; nil on success.
---   err_detail carries the underlying error message for diagnostics.
function M.write_json_to_file(path, bufnr, opts)
  -- Review 1.1: validate `path` BEFORE pcall(analyze_at_cursor_json) so a
  -- nil/empty/non-string path fails fast with a clear error_kind rather
  -- than running the analysis and then crashing inside io.open (which is
  -- NOT pcall-wrapped and would propagate to the caller).
  if type(path) ~= "string" or path == "" then
    return false, "open_failed", "invalid path (nil, non-string, or empty string)"
  end
  opts = opts or {}
  local debug_opt = resolve_debug(opts)
  local ok, json = pcall(M.analyze_at_cursor_json, bufnr, { debug = debug_opt })
  if not ok then
    -- Include the error detail so callers can distinguish an analysis crash
    -- from a JSON-encoding crash (previously the error value was discarded).
    return false, "analyze_failed", tostring(json)
  end
  -- Wrap the file I/O in pcall + close-in-finally so a write failure
  -- (disk full, permission denied mid-write, encoding error in :write)
  -- doesn't leak the file handle.
  local f = io.open(path, "w")
  if not f then return false, "open_failed", "io.open returned nil for " .. tostring(path) end
  -- Review 3.2: capture the pcall error so we can surface the real cause
  -- (disk full, permission denied mid-write, etc.) instead of a generic
  -- "f:write or f:flush raised an error". The error object is included
  -- in the err_detail return value so callers can log/display it.
  local ok_w, write_err = pcall(function()
    f:write(json)
    f:flush()
  end)
  -- Always close, even if write/flush failed.
  pcall(function() f:close() end)
  if not ok_w then
    -- Clean up the partially-written residue file (best-effort). When
    -- debug is on, surface a removal failure rather than silently
    -- swallowing it — previously the os.remove error was discarded,
    -- which made disk-full / permission issues invisible.
    local rm_ok, rm_err = pcall(os.remove, path)
    if not rm_ok and resolve_debug(opts) then
      print(LOG_PREFIX .. "os.remove of partial file failed: " ..
        tostring(path) .. " (" .. tostring(rm_err) .. ")")
    end
    return false, "write_failed", tostring(write_err)
  end
  return true, nil, nil
end

-- Register the :Calltree* user commands. Extracted from setup() to reduce
-- setup()'s line count and make the command-registration logic independently
-- testable. The `safe_del` and `register` closures are created once per
-- call (acceptable since setup() is rarely called in a hot loop).
local function register_user_commands()
  local function safe_del(name)
    pcall(vim.api.nvim_del_user_command, name)
  end
  local function register(name, fn, cmd_opts)
    safe_del(name)
    vim.api.nvim_create_user_command(name, fn, cmd_opts)
  end

  register("CalltreeAnalyze", function()
    M.dump_at_cursor()
  end, { desc = "Run calltree analysis at cursor (compact summary)" })

  -- Shared helper for the two JSON-printing commands. Extracted because
  -- CalltreeJson and CalltreeJsonDebug differed only in the `opts.debug`
  -- value passed to analyze_at_cursor_json — keeping two near-identical
  -- callbacks in sync was error-prone (and was the root cause of the
  -- P0 bug where CalltreeJsonDebug forgot to pass { debug = true }).
  local function _print_json_or_error(opts)
    local ok, json = pcall(M.analyze_at_cursor_json, nil, opts)
    if ok and type(json) == "string" then
      print(json)
    elseif ok then
      print(LOG_PREFIX .. "error: analyze_at_cursor_json returned non-string: " .. type(json))
    else
      print(LOG_PREFIX .. "error: " .. tostring(json))
    end
  end

  register("CalltreeJson", function()
    -- Respects M.options.debug (set via setup()).
    _print_json_or_error({ debug = M.options.debug })
  end, { desc = "Print calltree analysis as JSON (respects setup debug option)" })

  -- CalltreeJsonDebug: ALWAYS run with debug=true regardless of
  -- M.options.debug. Previously this command did NOT pass { debug = true },
  -- so after `setup({ debug = false })` the "Debug" command produced
  -- identical output to CalltreeJson — contradicting the command name
  -- and description ("with debug"). This was the primary P0 bug fixed
  -- in this review pass.
  register("CalltreeJsonDebug", function()
    _print_json_or_error({ debug = true })
  end, { desc = "Print calltree analysis as JSON (with debug)" })

  -- Review 7.1: the previous comment "NOTE: the callback parameter is
  -- `cmd_opts` (not `opts`) to avoid shadowing the outer setup(opts)
  -- parameter" referenced an `outer setup(opts)` that doesn't exist
  -- (register_user_commands is a standalone local function, not nested
  -- inside setup()). The comment was a stale artifact from a previous
  -- refactor. Removed; the parameter name `cmd_opts` is now self-
  -- explanatory as the command callback's argument.
  register("CalltreeToFile", function(cmd_opts)
    -- Review 3.1: receive the err_detail return value so we can surface
    -- the underlying cause (disk full, permission denied, etc.) instead
    -- of just the coarse "open_failed" / "write_failed" kind.
    local ok, err_kind, err_detail = M.write_json_to_file(cmd_opts.args)
    if ok then
      print(LOG_PREFIX .. "Written to " .. cmd_opts.args)
    else
      print(LOG_PREFIX .. "Failed to write to " .. cmd_opts.args
        .. " (reason: " .. tostring(err_kind) .. ")"
        .. (err_detail and (" — " .. tostring(err_detail)) or ""))
    end
  end, { nargs = 1, desc = "Write calltree JSON to a file" })
end

--- Set up the plugin (optional; just exposes user commands).
--- @param opts table|nil {
---   debug = boolean|nil,             -- default true; false disables debug collection
---   user_commands = boolean|nil,     -- default true; false skips registering commands
---   stdlib_path_patterns = table|nil,-- extra Lua patterns merged into
---                                    -- external_calls.STDLIB_PATH_PATTERNS
---   skip_stdlib_calls = boolean|nil, -- default true; false keeps stdlib calls in result
---   deduplicate_external_calls = boolean|nil, -- default true; false keeps duplicate call sites
--- }
function M.setup(opts)
  opts = opts or {}
  -- Persist ALL recognized options (not just `debug`) so setup() is
  -- symmetric — previously only `debug` was persisted while
  -- `user_commands` was read but never stored, leaving M.options
  -- inconsistent across calls.
  if opts.debug ~= nil then
    M.options.debug = opts.debug
  end
  if opts.user_commands ~= nil then
    M.options.user_commands = opts.user_commands
  end
  -- v1.2.0: persist the new external_calls post-processing flags.
  -- Both default to true (see M.options); callers can pass false to
  -- disable filtering / dedup and see the raw collected entries.
  if opts.skip_stdlib_calls ~= nil then
    M.options.skip_stdlib_calls = opts.skip_stdlib_calls
  end
  if opts.deduplicate_external_calls ~= nil then
    M.options.deduplicate_external_calls = opts.deduplicate_external_calls
  end
  -- Externally-configurable stdlib path patterns. The external_calls
  -- module previously documented `STDLIB_PATH_PATTERNS` as
  -- user-overridable, but the only way to override was direct mutation
  -- of the module table — which is fragile when multiple plugins share
  -- the calltree instance. setup() now accepts an extra list and
  -- merges it in (additively, not replace) so users can EXTEND the
  -- default patterns without clobbering them.
  if opts.stdlib_path_patterns and type(opts.stdlib_path_patterns) == "table" then
    local external_calls = require("calltree.analysis.external_calls")
    if type(external_calls.STDLIB_PATH_PATTERNS) == "table" then
      for _, pat in ipairs(opts.stdlib_path_patterns) do
        table.insert(external_calls.STDLIB_PATH_PATTERNS, pat)
      end
    end
  end
  -- Handle user_commands toggling: when user_commands is explicitly false,
  -- unregister any previously-registered commands (so toggling off after a
  -- prior setup() with user_commands=true actually removes them). Previously
  -- `safe_del` was only called inside the non-false branch, so toggling
  -- off was a no-op.
  --
  -- The command-name list is sourced from the USER_COMMAND_NAMES constant
  -- so this stays in sync with register_user_commands() automatically.
  -- The `elseif opts.user_commands ~= false` was simplified to plain
  -- `else` — the `~= false` test was redundant since the prior branch
  -- already covered `== false`.
  if opts.user_commands == false then
    for _, name in ipairs(USER_COMMAND_NAMES) do
      pcall(vim.api.nvim_del_user_command, name)
    end
  else
    register_user_commands()
  end
end

return M
