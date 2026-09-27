#!/bin/bash

source "$(dirname "${BASH_SOURCE[0]}")/base-test.sh"

require_command lua

grep -Fx 'require("default.hypr.monitor-removal")' "$ROOT/default/hypr/omarchy.lua" >/dev/null ||
  fail "the Omarchy Hyprland config loads the monitor removal handler"
pass "the Omarchy Hyprland config loads the monitor removal handler"

# Replays the event order of Hyprland 0.56.2's CMonitor::onDisconnect: focus is
# warped to the first remaining monitor (monitor.focused), the removed monitor's
# workspaces move over hidden, then monitor.removed fires, all in one event-loop
# turn. hl.timer callbacks only run once that turn is over.
OMARCHY_PATH="$ROOT" lua - <<'LUA' || fail "a monitor removal keeps the focused workspace in front"
local handlers, timers, dispatched = {}, {}, {}
local active = { id = 1, name = "1" }
local workspaces = { ["1"] = true, ["5"] = true, ["name:notes"] = true }

hl = {
  on = function(event, callback)
    handlers[event] = callback
  end,
  timer = function(callback, opts)
    assert(opts.type == "oneshot" and opts.timeout > 0)
    table.insert(timers, callback)
  end,
  get_active_workspace = function()
    return active
  end,
  get_workspace = function(selector)
    return workspaces[selector] and {} or nil
  end,
  dispatch = function(action)
    table.insert(dispatched, action.workspace)
  end,
  dsp = {
    focus = function(args)
      return args
    end,
  },
}

local function turn_ends()
  while #timers > 0 do
    local pending = timers
    timers = {}
    for _, callback in ipairs(pending) do
      callback()
    end
  end
end

local function focus(workspace)
  active = workspace
  handlers["monitor.focused"]()
  turn_ends()
end

local function unplug(backup_workspace)
  if backup_workspace then
    active = backup_workspace
    handlers["monitor.focused"]()
  end
  handlers["workspace.active"]()
  handlers["monitor.removed"]()
  turn_ends()
end

dofile(os.getenv("OMARCHY_PATH") .. "/default/hypr/bootstrap.lua")
require("default.hypr.monitor-removal")

-- Working on the external display's workspace 5 when it is unplugged.
focus({ id = 5, name = "5" })
unplug({ id = 1, name = "1" })
assert(#dispatched == 1 and dispatched[1] == "5", "the workspace you were on comes to the front of the built-in panel")

-- Working on the built-in panel: Hyprland leaves focus alone, and so does this.
dispatched = {}
focus({ id = 1, name = "1" })
unplug(nil)
assert(#dispatched == 0, "unplugging a display you were not on changes nothing")

-- A focus change the user made earlier is not mistaken for the removal's warp.
dispatched = {}
focus({ id = 5, name = "5" })
focus({ id = 1, name = "1" })
unplug(nil)
assert(#dispatched == 0, "an earlier focus change does not switch the workspace later")

-- An empty workspace is gone once hidden, so there is nothing to bring back.
dispatched = {}
workspaces["5"] = nil
focus({ id = 5, name = "5" })
unplug({ id = 1, name = "1" })
assert(#dispatched == 0, "a workspace that no longer exists is not recreated")

-- Named workspaces carry negative ids, which a selector would read as relative.
dispatched = {}
focus({ id = -1337, name = "notes" })
unplug({ id = 1, name = "1" })
assert(#dispatched == 1 and dispatched[1] == "name:notes", "a named workspace is focused by name")
LUA
pass "a monitor removal keeps the focused workspace in front"
