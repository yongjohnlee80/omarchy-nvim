-- go-test-env: merge a VSCode-style launch.json into nvim-dap-go's debug_test().
--
-- Why this exists
--   VSCode's Go extension resolves `buildFlags`, `env`, and `envFile` from
--   launch.json before sending the request to delve. Under Neovim +
--   nvim-dap + delve's DAP server, `env` is forwarded but `envFile` is
--   silently dropped — it's a VSCode client-side feature. This module
--   parses the file itself, folds it into `env`, and hands the result to
--   nvim-dap-go's `debug_test(custom_config)`.
--
-- Scope: only `type="go", mode="test"` configurations are considered.
-- Non-goals: arbitrary launch.json emulation (preLaunchTask, compound
-- configs, variable substitution beyond `${workspaceFolder}`/`~`/`$VAR`).
--
-- Requires Neovim 0.9+ (vim.json, vim.log.levels, vim.tbl_count).

---@class GoTestEnv.Opts
---@field launch_paths? string[]     Relative paths searched (in order) for launch.json. Default: {".vscode/launch.json", "launch.json"}.
---@field config_name? string        Select a launch config by `name`. Nil → first matching type=go, mode=test entry.
---@field notify_level? integer      Minimum level for notifications (vim.log.levels). Default: INFO.
---@field expand_env_values? boolean Run vim.fn.expand() on inline `env` values too. Default: false (avoids mangling values with $ chars).

---@class GoTestEnv.Result
---@field name? string
---@field type? string
---@field request? string
---@field mode? string
---@field program? string
---@field cwd? string
---@field output? string
---@field args? string[]
---@field buildFlags? string
---@field env? table<string,string>

local M = {}

---@type GoTestEnv.Opts
local defaults = {
  launch_paths = { ".vscode/launch.json", "launch.json" },
  config_name = nil,
  notify_level = vim.log.levels.INFO,
  expand_env_values = false,
}

---@type GoTestEnv.Opts
local opts = vim.deepcopy(defaults)

-- File-level cache of the PARSED launch.json (keyed by path + mtime). Holds
-- the raw table so we can re-filter on every load() without re-reading disk.
-- { path = string|nil, mtime = integer|nil, parsed = table|nil } | nil
local cache = nil

-- Session-level remembered pick, keyed by mode ("test" / "debug"). The first
-- time the user picks from a multi-config launch.json, the choice sticks
-- until M.reload() or M.clear_pick() clears it. Survives edits to the file
-- as long as the same `name` still exists; cleared alongside file cache on
-- reload.
local session_pick = {}

local uv = vim.uv or vim.loop

local function notify(msg, level)
  level = level or vim.log.levels.INFO
  if level < (opts.notify_level or vim.log.levels.INFO) then return end
  vim.schedule(function() vim.notify("[go-test-env] " .. msg, level) end)
end

---@return string
local function global_cwd()
  return uv.cwd() or vim.fn.getcwd(-1, -1)
end

-- Value-level substitution: only `${workspaceFolder}`. Safe for env values
-- that may contain literal `$` (bcrypt hashes, passwords, cron expressions).
---@param v any
---@return any
local function sub_workspace(v)
  if type(v) ~= "string" then return v end
  return (v:gsub("%${workspaceFolder}", global_cwd()))
end

-- Path-level substitution: ${workspaceFolder} + shell ~ / $VAR / <token>.
---@param v any
---@return any
local function sub_path(v)
  if type(v) ~= "string" then return v end
  return vim.fn.expand(sub_workspace(v))
end

-- Parse a .env-style file. Supports:
--   KEY=VAL              unquoted; trailing chars preserved verbatim
--   KEY="VAL" / 'VAL'    surrounding quotes stripped, contents literal
--   export KEY=VAL       leading `export ` stripped
--   # line comments, blank lines skipped
-- Does not: interpret escape sequences, strip mid-line comments, join
-- multi-line values.
---@param path string
---@return table<string,string>|nil, string|nil
local function parse_envfile(path)
  local f = io.open(path, "r")
  if not f then return nil, "cannot open " .. path end
  local out = {}
  for line in f:lines() do
    local s = line:gsub("^%s+", ""):gsub("%s+$", "")
    if s ~= "" and s:sub(1, 1) ~= "#" then
      s = s:gsub("^export%s+", "")
      local key, val = s:match("^([%a_][%w_%-%.]*)%s*=%s*(.*)$")
      if key then
        local q = val:sub(1, 1)
        if (q == '"' or q == "'") and #val >= 2 and val:sub(-1) == q then
          val = val:sub(2, -2)
        end
        out[key] = val
      end
    end
  end
  f:close()
  return out, nil
end

-- Strip // and /* */ comments from a JSON-with-comments string, respecting
-- string boundaries so `postgres://...` inside a value stays intact.
---@param s string
---@return string
local function strip_json_comments(s)
  local out, i, n = {}, 1, #s
  local in_string, escape = false, false
  while i <= n do
    local c = s:sub(i, i)
    if in_string then
      out[#out + 1] = c
      if escape then
        escape = false
      elseif c == "\\" then
        escape = true
      elseif c == '"' then
        in_string = false
      end
      i = i + 1
    elseif c == '"' then
      in_string = true
      out[#out + 1] = c
      i = i + 1
    elseif c == "/" and s:sub(i + 1, i + 1) == "/" then
      local nl = s:find("\n", i + 2, true)
      i = nl or (n + 1)
    elseif c == "/" and s:sub(i + 1, i + 1) == "*" then
      local close = s:find("*/", i + 2, true)
      i = close and (close + 2) or (n + 1)
    else
      out[#out + 1] = c
      i = i + 1
    end
  end
  return table.concat(out)
end

---@param content string
---@return table|nil, string|nil
local function parse_launchjs(content)
  content = strip_json_comments(content)
  content = content:gsub(",(%s*[%]}])", "%1")
  local ok, data = pcall(vim.json.decode, content)
  if not ok then return nil, tostring(data) end
  return data, nil
end

---@param override string?
---@return string?
-- Walk up from the global cwd looking for a launch.json, one level at a
-- time. Stops at project boundary markers so we never slurp an unrelated
-- launch.json from above the project:
--   * `.bare/` dir  -- bare+worktree `.bare`-style container
--   * `.git/`  dir  -- regular repo root OR `bare_dir=".git"` convention
-- Each level checks for launch.json FIRST, then the stop rule, so a
-- `launch.json` sitting next to `.bare/` or `.git/` is still picked up.
-- This is how you share one launch.json across worktrees: park it at the
-- project root (next to the bare) and every worktree picks it up via the
-- walk.
local function resolve_path(override)
  if override and override ~= "" then
    return vim.fn.fnamemodify(override, ":p")
  end

  local launch_paths = opts.launch_paths or defaults.launch_paths
  local cur = global_cwd()
  local seen = {}

  while cur and cur ~= "" and not seen[cur] do
    seen[cur] = true

    for _, rel in ipairs(launch_paths) do
      local p = cur .. "/" .. rel
      if vim.fn.filereadable(p) == 1 then return p end
    end

    if vim.fn.isdirectory(cur .. "/.bare") == 1 then break end
    if vim.fn.isdirectory(cur .. "/.git") == 1 then break end

    local parent = vim.fn.fnamemodify(cur, ":h")
    if parent == cur or parent == "" then break end
    cur = parent
  end

  return nil
end

---@param parsed table
---@param mode string  "test" or "debug"
---@return table[]    all matching configs, in file order
local function filter_configs(parsed, mode)
  if type(parsed) ~= "table" or type(parsed.configurations) ~= "table" then
    return {}
  end
  local out = {}
  for _, c in ipairs(parsed.configurations) do
    if c.type == "go" and c.mode == mode then
      table.insert(out, c)
    end
  end
  return out
end

---@param raw table
---@return GoTestEnv.Result
-- Produce a full dap-ready config from a launch.json entry:
--   * Identity fields (name/type/request/mode) forwarded verbatim.
--   * Path-like fields (program/cwd/output/args) get `${workspaceFolder}` +
--     shell substitution. Each new worktree sees its own workspaceFolder
--     because the value is resolved from the current cwd at load time.
--   * buildFlags and env values only get `${workspaceFolder}` substitution
--     (no shell) -- protects strings containing literal `$` like bcrypt
--     hashes or PG connection passwords.
-- For test configs, dap-go.debug_test only cares about buildFlags + env,
-- but carrying the full config through is harmless (extra fields ignored)
-- and keeps M.debug_main's `dap.run(config)` path simple.
local function normalize(raw)
  ---@type GoTestEnv.Result
  local out = {}

  out.name = raw.name
  out.type = raw.type
  out.request = raw.request
  out.mode = raw.mode

  for _, k in ipairs({ "program", "cwd", "output" }) do
    if type(raw[k]) == "string" and raw[k] ~= "" then
      out[k] = sub_path(raw[k])
    end
  end

  if type(raw.args) == "table" then
    out.args = {}
    for _, a in ipairs(raw.args) do
      table.insert(out.args, sub_path(a))
    end
  end

  if type(raw.buildFlags) == "string" and raw.buildFlags ~= "" then
    out.buildFlags = sub_workspace(raw.buildFlags)
  end

  local merged = {}
  if type(raw.envFile) == "string" and raw.envFile ~= "" then
    local path = sub_path(raw.envFile)
    local parsed, err = parse_envfile(path)
    if parsed then
      for k, v in pairs(parsed) do merged[k] = v end
    else
      notify("envFile " .. tostring(err), vim.log.levels.WARN)
    end
  end
  if type(raw.env) == "table" then
    local xform = opts.expand_env_values and sub_path or sub_workspace
    for k, v in pairs(raw.env) do merged[k] = xform(v) end
  end
  if next(merged) then out.env = merged end
  return out
end

---@param path string
---@return integer?
local function mtime_of(path)
  local s = uv.fs_stat(path)
  return s and s.mtime and s.mtime.sec or nil
end

--- Ensure launch.json is parsed and in `cache.parsed`. Returns true on
--- success; on failure, notifies and returns false.
---@param override_path string?
---@return boolean
local function ensure_parsed(override_path)
  local path = resolve_path(override_path)
  if not path then
    notify(
      "no launch.json found (searched " .. table.concat(opts.launch_paths or defaults.launch_paths, ", ") .. ")",
      vim.log.levels.WARN
    )
    cache = { path = nil, mtime = nil, parsed = nil }
    return false
  end

  local mtime = mtime_of(path)
  if cache and cache.path == path and cache.mtime == mtime and cache.parsed and not override_path then
    return true
  end

  local f = io.open(path, "r")
  if not f then
    notify("could not read " .. path, vim.log.levels.ERROR)
    cache = { path = path, mtime = mtime, parsed = nil }
    return false
  end
  local content = f:read("*a")
  f:close()

  local parsed, err = parse_launchjs(content)
  if not parsed then
    notify("parse failed: " .. tostring(err), vim.log.levels.ERROR)
    cache = { path = path, mtime = mtime, parsed = nil }
    return false
  end

  cache = { path = path, mtime = mtime, parsed = parsed }
  return true
end

--- Deliver the matching config to `callback(normalized_or_nil)`. Handles the
--- resolution cascade: config_name hard pin → session pick → single match →
--- `vim.ui.select` prompt. Calls back with nil if the user cancels or no
--- matching config exists.
---@param opts_local { mode: string }
---@param callback fun(config: GoTestEnv.Result?)
local function resolve(opts_local, callback)
  local matches = filter_configs(cache and cache.parsed or {}, opts_local.mode)
  if #matches == 0 then
    notify(
      ("no type=go mode=%s configs in %s"):format(opts_local.mode, cache and cache.path or "<none>"),
      vim.log.levels.WARN
    )
    callback(nil)
    return
  end

  -- config_name (from setup) wins over session pick.
  local pinned = opts.config_name or session_pick[opts_local.mode]
  if pinned then
    for _, c in ipairs(matches) do
      if c.name == pinned then callback(normalize(c)); return end
    end
    -- Named pick no longer present — fall through to prompt / single-match.
    if session_pick[opts_local.mode] then session_pick[opts_local.mode] = nil end
  end

  if #matches == 1 then
    callback(normalize(matches[1]))
    return
  end

  vim.ui.select(matches, {
    prompt = ("Pick a %s config:"):format(opts_local.mode),
    format_item = function(c) return c.name end,
  }, function(choice)
    if not choice then callback(nil); return end
    session_pick[opts_local.mode] = choice.name
    notify(("picked '%s' (cached for this session; :GoTestEnvPick to reset)"):format(choice.name))
    callback(normalize(choice))
  end)
end

--- Load a launch.json config asynchronously. Parses (and caches) the file,
--- then resolves a matching config via: config_name → session pick → single
--- match → interactive picker. Callback fires with the normalized config, or
--- nil if the user cancelled or none matched.
--- The file cache invalidates on mtime change; it does NOT watch the
--- referenced envFile — use `:GoTestEnvReload` (or `M.reload()`) after editing it.
---@param override_path string?
---@param callback fun(config: GoTestEnv.Result?)
---@param mode string? "test" (default) or "debug"
function M.load(override_path, callback, mode)
  if not ensure_parsed(override_path) then callback({}) ; return end
  resolve({ mode = mode or "test" }, function(config)
    callback(config or {})
  end)
end

--- Clear the file cache AND the session picks, then trigger a fresh load.
--- Reason for clearing picks: the most common reason to reload is "I edited
--- launch.json" — which might have renamed / removed the pinned config.
---@param override_path string?
function M.reload(override_path)
  cache = nil
  session_pick = {}
  M.load(override_path, function() end)
end

--- Clear the session pick for `mode` (defaults to "test") without re-reading
--- launch.json. Next `debug_test` / `debug_main` will prompt again if the
--- file has >1 matching config.
---@param mode string?
function M.clear_pick(mode)
  session_pick[mode or "test"] = nil
  notify(("cleared session pick (%s)"):format(mode or "test"))
end

--- Report what's currently cached.
function M.status()
  if not cache then
    notify("not yet loaded", vim.log.levels.INFO)
    return
  end
  local picks = {}
  for k, v in pairs(session_pick) do
    picks[#picks + 1] = k .. "=" .. v
  end
  notify(
    ("cached from %s; session picks: %s"):format(
      cache.path or "<none>",
      #picks > 0 and table.concat(picks, ", ") or "<none>"
    ),
    vim.log.levels.INFO
  )
end

--- Run the test under the cursor with the launch.json config merged in.
--- Prompts once per session if multiple test configs exist; remembers
--- the pick until :GoTestEnvReload or :GoTestEnvPick clears it.
---@param override_path string?
function M.debug_test(override_path)
  local ok, dap_go = pcall(require, "dap-go")
  if not ok then
    notify("require('dap-go') failed — install nvim-dap-go", vim.log.levels.ERROR)
    return
  end
  M.load(override_path, function(config)
    if not config then return end
    dap_go.debug_test(config)
  end, "test")
end

--- Launch a main-program debug session using a `mode=debug` config from
--- launch.json. Uses the same picker + session-cache flow as debug_test,
--- keyed separately so your "which test?" and "which main?" picks don't
--- stomp each other. If no matching config exists, notifies and exits --
--- falls back to nothing (use <leader>dc / dap.continue() for the stock
--- dap-go built-ins if you want those).
---@param override_path string?
function M.debug_main(override_path)
  local ok, dap = pcall(require, "dap")
  if not ok then
    notify("require('dap') failed — nvim-dap is required", vim.log.levels.ERROR)
    return
  end
  M.load(override_path, function(config)
    if not config or not next(config) then return end
    dap.run(config)
  end, "debug")
end

--- Configure module behavior. Merges over defaults; invalidates caches.
---@param user_opts GoTestEnv.Opts?
function M.setup(user_opts)
  opts = vim.tbl_deep_extend("force", defaults, user_opts or {})
  cache = nil
  session_pick = {}
end

pcall(vim.api.nvim_create_user_command, "GoTestEnvReload", function(cmd)
  M.reload(cmd.args ~= "" and cmd.args or nil)
end, { nargs = "?", complete = "file", desc = "Reload go-test-env launch.json + clear session picks" })

pcall(vim.api.nvim_create_user_command, "GoTestEnvStatus", function()
  M.status()
end, { desc = "Show the cached go-test-env config" })

pcall(vim.api.nvim_create_user_command, "GoTestEnvPick", function(cmd)
  M.clear_pick(cmd.args ~= "" and cmd.args or nil)
end, { nargs = "?", desc = "Clear the session pick (arg: 'test' or 'debug', default 'test')" })

return M
