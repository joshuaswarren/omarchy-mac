-- Unplugging a monitor, or the lid disabling the laptop panel, keeps you on the
-- workspace you were on. Hyprland first warps focus to whichever monitor it
-- lists first and only then moves the removed monitor's workspaces over, so the
-- one you were on lands hidden behind that monitor's own. Measured on Hyprland
-- 0.56.2 (CMonitor::onDisconnect).
--
-- That warp is the only focus change made in the same event-loop turn as the
-- removal, so the workspace focused before it is kept for one turn and, when a
-- monitor.removed follows within that turn, focused again.

local focused = nil
local before_removal = nil

local function active_workspace()
  local ws = hl.get_active_workspace()
  if not ws or ws.special or type(ws.id) ~= "number" then
    return nil
  end

  -- Named workspaces have negative ids, which a selector reads as relative.
  if ws.id > 0 then
    return tostring(ws.id)
  end
  return "name:" .. ws.name
end

local function later(fn)
  hl.timer(fn, { timeout = 1, type = "oneshot" })
end

focused = active_workspace()

hl.on("workspace.active", function()
  focused = active_workspace()
end)

hl.on("monitor.focused", function()
  before_removal = focused
  focused = active_workspace()
  later(function()
    before_removal = nil
  end)
end)

hl.on("monitor.removed", function()
  local workspace = before_removal
  before_removal = nil
  if not workspace then
    return
  end

  -- Let the removal finish before switching the surviving monitor.
  later(function()
    if active_workspace() ~= workspace and hl.get_workspace(workspace) then
      hl.dispatch(hl.dsp.focus({ workspace = workspace }))
    end
  end)
end)
