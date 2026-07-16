--- tests/headless_helpers.lua — shared helpers for headless Neovim test files.
---
--- Previously the `ok`/`eq` assertion helpers and the path-setup logic were
--- duplicated across headless_integration.lua, headless_real_lsp.lua,
--- runner_headless.lua, and runner_headless_real_lsp.lua. This module
--- centralizes them so there's a single source of truth.
---
--- Usage:
---   local H = require("headless_helpers")
---   H.ok("name", cond, "msg")
---   H.eq("name", actual, expected)

local M = {}

-- Per-file pass/fail counters. Each test file that uses these helpers gets
-- its own counter table (keyed by the file's module identity). We use a
-- simple approach: the file calls M.new_counters() to get a fresh table,
-- then passes it to ok/eq. Alternatively, files can use M.make_ok_eq()
-- to get closures bound to a local counter table.

--- Create a fresh counter table for a test file.
--- @return table { passes = 0, failures = {} }
function M.new_counters()
  return { passes = 0, failures = {} }
end

--- Make ok/eq closures bound to the given counter table.
--- @param counters table (from new_counters)
--- @return function ok, function eq
function M.make_ok_eq(counters)
  local function ok(name, cond, msg)
    if cond then
      counters.passes = counters.passes + 1
      print(string.format("  PASS  %s", name))
    else
      print(string.format("  FAIL  %s -- %s", name, msg or "(no message)"))
      table.insert(counters.failures, { name = name, msg = msg })
    end
  end

  local function eq(name, a, b)
    if a == b then
      ok(name, true)
    else
      ok(name, false, string.format("expected %s, got %s", tostring(b), tostring(a)))
    end
  end

  return ok, eq
end

--- Shared path-setup logic. Previously duplicated in test_runner.lua,
--- runner_headless.lua, and runner_headless_real_lsp.lua. Computes the
--- plugin root from the calling script's location and prepends the
--- necessary entries to package.path.
--- @return string script_dir, string plugin_root
function M.setup_path()
  local source = debug.getinfo(2, "S").source
  local script_dir
  if source:sub(1, 1) == "@" then
    script_dir = source:sub(2):match("(.*/)")
  end
  if script_dir == nil or script_dir == "" then script_dir = "." end
  script_dir = script_dir:gsub("/$", "")
  local plugin_root = script_dir:match("(.+)/[^/]+$") or (script_dir .. "/..")
  if script_dir == "." then plugin_root = ".." end
  -- Deduplicate: don't prepend entries already in package.path.
  local function add_path(p)
    if not package.path:find(p, 1, true) then
      package.path = p .. ";" .. package.path
    end
  end
  add_path(plugin_root .. "/?.lua")
  add_path(plugin_root .. "/?/init.lua")
  add_path(plugin_root .. "/lua/?.lua")
  add_path(plugin_root .. "/lua/?/init.lua")
  add_path(script_dir .. "/?.lua")
  return script_dir, plugin_root
end

return M
