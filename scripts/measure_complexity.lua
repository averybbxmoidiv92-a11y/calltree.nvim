--- scripts/measure_complexity.lua
---
--- McCabe cyclomatic complexity measurement tool.
---
--- Usage:
---   lua5.4 scripts/measure_complexity.lua [lua_root_dir] > complexity.json
---
--- By default scans all .lua files under lua_root_dir (default
--- `lua/calltree`), parses each function definition and computes cyclomatic
--- complexity (M = 1 + number of decision points), and outputs a JSON
--- array with each entry containing { file, function_name, complexity,
--- start_line }.
---
--- Decision point counting rules (Lua syntax):
---   if / elseif            -> +1
---   for / while / repeat   -> +1
---   and / or (logical ops) -> +1
---   goto / label           -> 0 (not counted)
---   ? : ternary            -> Lua has no such syntax
---
--- Function definition recognition (no external lpeg dependency; pure Lua
--- pattern matching + line scanning):
---   function M.xxx(...) / function M:xxx(...)
---   function xxx.yyy(...) / function xxx:yyy(...)
---   local function xxx(...)
---   function(...)  -> anonymous function, recorded as "<anonymous>"
---
--- Limitations: pure text scanning, no full AST. Keywords inside string
--- literals may cause false positives, but for this project's code style
--- (keywords rarely appear in strings) the impact is acceptable. Function
--- body boundaries are approximated by the indentation-aligned `end` on a
--- subsequent line.

local M = {}

-- Default scan root directory (../lua/calltree relative to this script).
local function default_root()
  local src = debug.getinfo(1, "S").source
  if src:sub(1, 1) == "@" then src = src:sub(2) end
  local script_dir = src:match("(.*/)") or "./"
  script_dir = script_dir:gsub("/$", "")
  -- script_dir = .../resource/scripts -> root = .../resource
  local root = script_dir:gsub("/scripts$", "")
  return root .. "/lua/calltree"
end

-- Determine whether a line contains a keyword after stripping strings and
-- comments. Simplified: removes -- comments, --[[ ]] block comment markers,
-- and "..." / '...' strings.
local function strip_comments_and_strings(line)
  -- Remove trailing -- comments (does not handle --[[ multi-line comments;
  -- content inside multi-line comments is treated as code, but this project
  -- almost never writes if/for/and/or inside block comments, so the false
  -- positive rate is low).
  local cleaned = line:gsub("%-%-%[%[.*$", "")
                     :gsub("%-%-.*$", "")
  -- Remove double-quoted strings (%b"" is balanced matching and requires
  -- different start/end chars — here " and " are the same, so %b"" does
  -- not work. Use a manual pattern: " [^"]* " replaced with a placeholder.)
  cleaned = cleaned:gsub('"[^"]*"', ' "" ')
  -- Single-quoted strings: '[^']*'
  cleaned = cleaned:gsub("'[^']*'", " '' ")
  -- Long strings [[ ... ]] (single line)
  cleaned = cleaned:gsub("%[%[[^%]]*%]%]", " [[]] ")
  return cleaned
end

-- Scan decision points within a function body (given start/end lines) and
-- return the complexity.
-- lines: full source line array (1-indexed)
-- start_line, end_line: function body line range (inclusive)
local function count_complexity_in_range(lines, start_line, end_line)
  local complexity = 1  -- McCabe baseline
  for i = start_line, end_line do
    local raw = lines[i] or ""
    -- Keywords inside long strings [[ ... ]] are not counted.
    -- Simplified: strip_comments_and_strings already removes single-line
    -- [[ ]]; multi-line [[ ]] is rare and ignored.
    local cleaned = " " .. strip_comments_and_strings(raw) .. " "
    local function count_kw(pat)
      local n = 0
      for _ in cleaned:gmatch(pat) do n = n + 1 end
      return n
    end
    complexity = complexity + count_kw("%sif%s")
    complexity = complexity + count_kw("%selseif%s")
    complexity = complexity + count_kw("%sfor%s")
    complexity = complexity + count_kw("%swhile%s")
    complexity = complexity + count_kw("%srepeat%s")
    -- Logical operators and / or (wrapped in %s to avoid matching
    -- "command" / "border" etc.)
    complexity = complexity + count_kw("%sand%s")
    complexity = complexity + count_kw("%sor%s")
  end
  return complexity
end

-- Find the ending `end` line of a function definition starting at open_line.
-- Uses stack counting: function/do/then/repeat each +1, end each -1.
-- When depth returns to 0, that end line is the function's last line.
-- The `function` keyword on the first line (the definition line) counts
-- +1, so starting from depth=0 the matching end brings depth back to 0.
--
-- Note: Lua's gmatch `$` does not match end-of-single-line (it only
-- matches end-of-the-whole-searched-string), so end-of-line checks must
-- use string.sub or pad the cleaned line with a trailing space and use a
-- %s pattern.
M.find_function_end = function(lines, open_line)
  local depth = 0
  for i = open_line, #lines do
    -- Pad with spaces at both ends to make %f frontier pattern match word
    -- boundaries.
    local cleaned = " " .. strip_comments_and_strings(lines[i] or "") .. " "
    local delta = 0
    -- Block-opening keywords (using %f[%s%p] as left boundary approximating
    -- \b, %f[%s%p] as right boundary). Lua frontier %f[%S] = boundary from
    -- whitespace to non-whitespace; here we use the simpler "non-letter on
    -- both sides" approach. Since cleaned is padded with spaces,
    -- " function " / " do " / " then " / " repeat " whole-word matches
    -- work with %s + word + %s (identifiers never contain such spaces).
    for _ in cleaned:gmatch("%sfunction%s") do delta = delta + 1 end
    for _ in cleaned:gmatch("%sdo%s") do delta = delta + 1 end
    for _ in cleaned:gmatch("%sthen%s") do delta = delta + 1 end
    for _ in cleaned:gmatch("%srepeat%s") do delta = delta + 1 end
    for _ in cleaned:gmatch("%send%s") do delta = delta - 1 end
    depth = depth + delta
    if depth <= 0 then
      -- Bug fix: previously `if i > open_line and depth <= 0` skipped
      -- the first line, which made single-line functions like
      -- `function foo() end` (depth hits 0 on open_line itself) scan
      -- to end-of-file. The `i > open_line` guard was intended to
      -- avoid returning immediately on the open line, but it
      -- inadvertently broke single-line functions. We now return on
      -- ANY line where depth hits 0, which is correct: the function
      -- keyword on open_line adds +1, so depth only returns to 0
      -- when the matching `end` is reached (whether on the same line
      -- or a later line).
      return i
    end
  end
  return #lines
end
local find_function_end = M.find_function_end

-- Constant: max function-name length we keep (avoids dot_index_expression
-- chains and other weird parse artifacts from polluting the report).
local MAX_FUNCTION_NAME_LEN = 80

-- Parse a single file, returning { {name=, complexity=, start_line=,
-- end_line=}, ... }
M.parse_file = function(filepath, root_for_relpath)
  local f = io.open(filepath, "r")
  if not f then return {} end
  -- Wrap file reading in pcall + close-in-finally so a mid-read disk
  -- error (rare but possible on network mounts) doesn't leak the file
  -- descriptor or crash the complexity report.
  local content
  local read_ok, read_err = pcall(function()
    content = f:read("*a")
  end)
  pcall(function() f:close() end)
  if not read_ok then
    -- Could not read content; return empty rather than crash.
    return {}
  end
  if content == nil then return {} end
  local lines = {}
  for line in (content .. "\n"):gmatch("([^\n]*)\n") do
    table.insert(lines, line)
  end
  local results = {}
  -- Function definition patterns
  local patterns = {
    { "^%s*function%s+(M[%w%.%:]*)%s*%(",        "%1" },     -- function M.x / M:x -> "M.x"
    { "^%s*function%s+([%w_%.%:]+)%s*%(",        "%1" },     -- function obj.x / obj:x
    { "^%s*local%s+function%s+([%w_]+)%s*%(",    "%1" },     -- local function x
    { "^%s*function%s+([%w_]+)%s*%(",            "%1" },     -- function x (global)
  }
  for i, line in ipairs(lines) do
    -- Skip comment lines
    local cleaned_head = line:match("^%s*([^%s].*)$") or ""
    if cleaned_head:sub(1, 2) ~= "--" then
      local matched_name = nil
      for _, p in ipairs(patterns) do
        local pat, fmt = p[1], p[2]
        local m = line:match(pat)
        if m then
          -- fmt may contain %1; use gsub to substitute
          matched_name = fmt:gsub("%%1", m)
          break
        end
      end
      -- Also detect assignment-form functions: xxx = function(...)  /
      -- local xxx = function(...)
      if not matched_name then
        local m = line:match("^%s*local%s+([%w_]+)%s*=%s*function%s*%(")
                 or line:match("^%s*([%w_%.%:]+)%s*=%s*function%s*%(")
        if m then matched_name = m end
      end
      if matched_name then
        -- Truncate overly long names using the centralized constant
        -- (was a literal `80` magic number before).
        if #matched_name > MAX_FUNCTION_NAME_LEN then
          matched_name = matched_name:sub(1, MAX_FUNCTION_NAME_LEN)
        end
        local end_line = find_function_end(lines, i)
        local complexity = count_complexity_in_range(lines, i, end_line)
        -- Relative path
        local rel = filepath
        if root_for_relpath and rel:sub(1, #root_for_relpath) == root_for_relpath then
          rel = rel:sub(#root_for_relpath + 1)
          if rel:sub(1, 1) == "/" then rel = rel:sub(2) end
        end
        table.insert(results, {
          file = rel,
          function_name = matched_name,
          complexity = complexity,
          start_line = i,
          end_line = end_line,
        })
      end
    end
  end
  return results
end

-- Recursively collect .lua files
M.collect_lua_files = function(root, acc)
  acc = acc or {}
  -- Use io.popen + find / ls. Reliable on Linux.
  -- Fallback: scan known subdirectories.
  -- Security: previously used `io.popen('ls "' .. dir .. '"')` which is
  -- vulnerable to command injection if `dir` contains shell metacharacters
  -- (e.g. `"; rm -rf /; "`). While `dir` is currently derived from a
  -- fixed `root` + known_subdirs (not user input), we harden it anyway
  -- by validating that `dir` contains only path-safe characters before
  -- passing it to the shell. If validation fails, skip that subdir.
  local known_subdirs = { "", "/core", "/analysis", "/providers", "/treesitter",
                          "/resolution", "/utils" }
  for _, sub in ipairs(known_subdirs) do
    local dir = root .. sub
    -- Reject dirs with shell metacharacters to prevent injection.
    if dir:match("^[A-Za-z0-9/._~-]+$") then
      local p = io.popen('ls "' .. dir .. '" 2>/dev/null')
      if p then
        for fname in p:lines() do
          if fname:sub(-4) == ".lua" then
            table.insert(acc, dir .. "/" .. fname)
          end
        end
        p:close()
      end
    end
  end
  return acc
end

-- Compute statistics
local function stats(values)
  local n = #values
  if n == 0 then return { mean = 0, stddev = 0, threshold = 8 } end
  local sum = 0
  for _, v in ipairs(values) do sum = sum + v end
  local mean = sum / n
  local var_sum = 0
  for _, v in ipairs(values) do var_sum = var_sum + (v - mean) ^ 2 end
  local stddev = math.sqrt(var_sum / n)
  local threshold = mean + 2 * stddev
  if threshold < 8 then threshold = 8 end
  return { mean = mean, stddev = stddev, threshold = threshold }
end

-- JSON encoding (minimal implementation: array + flat object + numbers/
-- strings only)
local function json_escape(s)
  return (s:gsub("\\", "\\\\"):gsub('"', '\\"'):gsub("\n", "\\n"):gsub("\r", "\\r"))
end

local function json_encode_array(arr)
  local parts = {}
  for _, item in ipairs(arr) do
    local s = string.format(
      '{"file":"%s","function_name":"%s","complexity":%d,"start_line":%d,"end_line":%d}',
      json_escape(item.file), json_escape(item.function_name),
      item.complexity, item.start_line, item.end_line)
    table.insert(parts, s)
  end
  return "[" .. table.concat(parts, ",") .. "]"
end

function M.main()
  local root = arg[1] or default_root()
  local files = M.collect_lua_files(root)
  local all = {}
  for _, f in ipairs(files) do
    local items = M.parse_file(f, root)
    for _, it in ipairs(items) do table.insert(all, it) end
  end
  -- Complexity statistics
  local values = {}
  for _, it in ipairs(all) do table.insert(values, it.complexity) end
  local s = stats(values)
  -- First-pass threshold
  local threshold = s.threshold
  -- Find functions over the threshold
  local over = {}
  for _, it in ipairs(all) do
    if it.complexity > threshold then table.insert(over, it) end
  end
  -- If more than 15 are over the threshold, raise it to max(10, new threshold)
  if #over > 15 then
    local new_threshold = math.max(10, s.threshold)
    threshold = new_threshold
    over = {}
    for _, it in ipairs(all) do
      if it.complexity > threshold then table.insert(over, it) end
    end
  end
  -- Sort by complexity descending
  table.sort(over, function(a, b) return a.complexity > b.complexity end)
  -- Output JSON: metadata + function list
  local json = string.format(
    '{"root":"%s","total_functions":%d,"mean":%.4f,"stddev":%.4f,"threshold":%.4f,"over_threshold_count":%d,"over_threshold":%s}',
    json_escape(root), #all, s.mean, s.stddev, threshold, #over, json_encode_array(over))
  print(json)
end

-- Run directly (when loaded via luafile)
if arg and arg[0] and arg[0]:match("measure_complexity") then
  M.main()
end

return M
