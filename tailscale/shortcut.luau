--!nonstrict
-- Control-center toggle tile: mirrors Tailscale status and toggles via the service.

local installed = false
local probing = true
local running = false
local needsLogin = false

local function render()
  local label = noctalia.tr("shortcut.disconnected")
  if probing then
    label = noctalia.tr("shortcut.probing")
  elseif not installed then
    label = noctalia.tr("shortcut.not_installed")
  elseif needsLogin then
    label = noctalia.tr("shortcut.needs_login")
  elseif running then
    label = noctalia.tr("shortcut.connected")
  end

  shortcut.setLabel(label)
  shortcut.setIcon("network", "network-off")
  shortcut.setActive(running and installed and not probing)
  shortcut.setEnabled(installed and not probing and not needsLogin)
end

local function applyStatus(value)
  if type(value) ~= "table" then
    return
  end
  installed = value.installed == true
  probing = value.probing == true
  running = value.running == true
  needsLogin = value.needsLogin == true
  render()
end

function onClick()
  if not installed or probing or needsLogin then
    return
  end
  noctalia.state.set("command", { action = "toggle", nonce = noctalia.nowMs() })
end

noctalia.state.watch("status", applyStatus)
applyStatus(noctalia.state.get("status") or { probing = true })
