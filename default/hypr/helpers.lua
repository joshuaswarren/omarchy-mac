-- Shared helpers for Hyprland Lua configuration.

o = o or {}

local function shell_quote(value)
  return "'" .. tostring(value):gsub("'", "'\\''") .. "'"
end

o.shell_quote = shell_quote

local function file_exists(path)
  local file = io.open(path, "r")
  if file then
    file:close()
    return true
  end

  return false
end

-- Hyprland reaps its own children, so os.execute() can't retrieve an exit status
-- from inside the compositor. Read a marker off stdout instead.
function o.shell_succeeds(command)
  -- Subshell, so the redirection covers every command rather than binding to
  -- the last one and letting an earlier one write its own OK into the pipe.
  local pipe = io.popen("( " .. command .. " ) >/dev/null 2>&1 && echo OK")
  if not pipe then
    return false
  end

  local output = pipe:read("*a") or ""
  pipe:close()

  return output:find("OK", 1, true) ~= nil
end

function o.cmd_present(command)
  if command:find("/", 1, true) then
    return file_exists(command)
  end

  local path = os.getenv("PATH") or "/usr/local/bin:/usr/bin"
  for directory in (path .. ":"):gmatch("([^:]*):") do
    if file_exists((directory ~= "" and directory or ".") .. "/" .. command) then
      return true
    end
  end

  return false
end

function o.cmd_missing(command)
  return not o.cmd_present(command)
end

local function command_from(value, description)
  if type(value) ~= "table" then
    return value
  end

  if value.omarchy then
    return "omarchy-launch-" .. value.omarchy
  elseif value.focus and value.launch then
    return o.launch_sole(value.focus, value.launch)
  elseif value.launch then
    return o.launch(value.launch)
  elseif value.webapp then
    if value.focus then
      return o.launch_webapp_sole(description, value.webapp)
    else
      return o.launch_webapp(value.webapp)
    end
  elseif value.tui then
    if value.focus then
      return "omarchy-launch-or-focus-tui " .. shell_quote(value.tui)
    else
      return "omarchy-launch-tui " .. shell_quote(value.tui)
    end
  end

  return value
end

function o.preinstalled_bindings_enabled()
  if _G.omarchy_preinstalled_bindings ~= nil then
    return _G.omarchy_preinstalled_bindings == true
  end

  return not file_exists((os.getenv("HOME") or "") .. "/.local/state/omarchy/preinstalls-removed")
end

-- The MacBook's own keyboard as Hyprland names it: SPI on M1, MTP on M2 and later.
local builtin_keyboards = { "apple-spi-keyboard", "apple-mtp-keyboard" }
local overlay_prefixes = {
  "omarchy-menu",
  "omarchy-shell shell toggle ",
  "omarchy-shell -q shell togglePanelAt ",
}
-- Pickers that paste into the focused window stay with that window's screen.
local pastes_into_focused_window = {
  ["omarchy-shell shell toggle omarchy.emojis"] = true,
  ["omarchy-shell shell toggle omarchy.clipboard"] = true,
}
local apple_silicon

local function opens_overlay(command)
  if type(command) ~= "string" or pastes_into_focused_window[command] then
    return false
  end

  for _, prefix in ipairs(overlay_prefixes) do
    if command:sub(1, #prefix) == prefix then
      return true
    end
  end

  return false
end

function o.apple_silicon()
  if apple_silicon == nil then
    apple_silicon = o.shell_succeeds("omarchy-hw-apple-silicon")
  end

  return apple_silicon
end

function o.focus_builtin_screen()
  for _, monitor in ipairs(hl.get_monitors()) do
    if monitor.name:match("^eDP%-") then
      if not monitor.focused then
        hl.dispatch(hl.dsp.focus({ monitor = monitor.name }))
      end
      return
    end
  end
end

-- A menu or panel pressed on the MacBook's own keyboard opens on the MacBook's
-- own screen; apps keep opening on the focused screen. Hyprland runs every bind
-- matching a key press in the order they were added, so this bind, scoped to the
-- built-in keyboard, moves focus before the menu bind runs. Other keyboards only
-- match the menu bind.
local function bind_builtin_screen_focus(keys)
  if o.apple_silicon() then
    hl.bind(keys, o.focus_builtin_screen, { device = { inclusive = true, list = builtin_keyboards } })
  end
end

function o.bind(keys, description, dispatcher, options)
  local opts = options or {}

  if description then
    opts.description = description
  end

  dispatcher = command_from(dispatcher, description)

  if opens_overlay(dispatcher) and not opts.locked then
    bind_builtin_screen_focus(keys)
  end

  if type(dispatcher) == "string" then
    dispatcher = hl.dsp.exec_cmd(dispatcher)
  end

  hl.bind(keys, dispatcher, opts)
end

function o.rebind(keys, description, dispatcher, options)
  hl.unbind(keys)
  o.bind(keys, description, dispatcher, options)
end

function o.launch(command)
  return "uwsm-app -- " .. command
end

function o.exec_on_start(command)
  hl.on("hyprland.start", function()
    hl.exec_cmd(command)
  end)
end

function o.launch_on_start(command)
  o.exec_on_start(o.launch(command))
end

function o.launch_webapp(url)
  return "omarchy-launch-webapp " .. shell_quote(url)
end

function o.launch_webapp_sole(name, url)
  return "omarchy-launch-or-focus-webapp " .. shell_quote(name) .. " " .. shell_quote(url)
end

function o.launch_sole(match, command)
  return "omarchy-launch-or-focus " .. shell_quote(match) .. " " .. shell_quote(o.launch(command))
end

function o.bind_toggle(keys, description, toggle, options)
  o.bind(keys, description, "omarchy-toggle-" .. toggle, options)
end

function o.notify(message)
  return "omarchy-notification-send -u low " .. shell_quote(message)
end

function o.window(match, rules)
  rules.match = rules.match or {}

  if type(match) == "string" then
    rules.match.class = match
  else
    for key, value in pairs(match) do
      rules.match[key] = value
    end
  end

  hl.window_rule(rules)
end

local modifier_names = { "SHIFT", "CAPS", "CTRL", "CONTROL", "ALT", "MOD1", "MOD2", "MOD3", "SUPER", "WIN", "LOGO", "MOD4", "META", "MOD5" }

-- Hyprland reads a modifier out of any string that contains one's name, so
-- "NONE" or "" is no modifier at all.
local function holds_modifier(mods)
  if type(mods) ~= "string" then
    return mods ~= nil
  end

  mods = mods:upper()
  for _, name in ipairs(modifier_names) do
    if mods:find(name, 1, true) then
      return true
    end
  end

  return false
end

-- Hyprland rejects a gesture another one already covers, and gives Lua no way
-- to list what's registered. On a Mac, record each one so the default workspace
-- swipe, added after the user's files, can step aside for the user's own.
if hl and hl.gesture and not o.registered_gestures and o.apple_silicon() then
  local register_gesture = hl.gesture
  o.registered_gestures = {}

  hl.gesture = function(gesture, ...)
    if type(gesture) == "table" then
      table.insert(o.registered_gestures, {
        fingers = tonumber(gesture.fingers),
        direction = type(gesture.direction) == "string" and gesture.direction:lower() or "",
        modified = holds_modifier(gesture.mods),
      })
    end

    return register_gesture(gesture, ...)
  end
end
