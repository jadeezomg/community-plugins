--!nonstrict
-- Tailscale bar widget: connection indicator, opens panel, right-click toggles VPN.

local installed = false
local probing = true
local running = false
local ip = ""
local hostname = ""
local peerCount = 0
local trafficDown = ""
local trafficUp = ""
local trafficReady = false

local UNITS = { "B/s", "KB/s", "MB/s", "GB/s" }

local function cfg(key)
  return noctalia.getConfig(key)
end

local function showTraffic()
  return cfg("show_traffic") == true
end

local function formatRate(bytesPerSec)
  if type(bytesPerSec) ~= "number" or bytesPerSec ~= bytesPerSec or bytesPerSec < 0 then
    return "—"
  end
  local value = bytesPerSec
  for index, unit in UNITS do
    if value < 1024 or index == #UNITS then
      return if index == 1 then `{math.floor(value + 0.5)} {unit}` else `{string.format("%.1f", value)} {unit}`
    end
    value /= 1024
  end
  return "—"
end

local function refreshTraffic()
  trafficReady = false
  trafficDown = ""
  trafficUp = ""

  if not showTraffic() then
    return
  end

  local stats = noctalia.systemStats()
  if stats == nil or type(stats.net) ~= "table" or type(stats.net.interfaces) ~= "table" then
    return
  end

  local rates = nil
  for name, data in pairs(stats.net.interfaces) do
    if type(name) == "string" and string.sub(name, 1, 9) == "tailscale" then
      rates = data
      break
    end
  end
  if type(rates) ~= "table" then
    return
  end

  trafficDown = formatRate(rates.rxBytesPerSec)
  trafficUp = formatRate(rates.txBytesPerSec)
  trafficReady = true
end

local function trafficLine()
  if not trafficReady then
    return ""
  end
  return `↓{trafficDown} ↑{trafficUp}`
end

local function isOnline()
  return running and installed and not probing
end

local function setTooltip()
  if probing then
    barWidget.setTooltip(noctalia.tr("tooltip.probing"))
    return
  end
  if not installed then
    barWidget.setTooltip(noctalia.tr("tooltip.not_installed"))
    return
  end
  if running then
    local lines = {}
    if hostname ~= "" and peerCount > 0 then
      table.insert(lines, noctalia.tr("tooltip.connected", { hostname = hostname, count = peerCount }))
    elseif hostname ~= "" then
      table.insert(lines, hostname)
    elseif ip ~= "" then
      table.insert(lines, ip)
    else
      table.insert(lines, noctalia.tr("panel.status_connected"))
    end
    if barWidget.isVertical() and showTraffic() and trafficReady then
      table.insert(lines, noctalia.tr("tooltip.traffic", { down = trafficDown, up = trafficUp }))
    end
    barWidget.setTooltip(table.concat(lines, "\n"))
  else
    barWidget.setTooltip(noctalia.tr("tooltip.disconnected"))
  end
end

local function barText()
  if barWidget.isVertical() or not isOnline() then
    return ""
  end

  local parts = {}
  if cfg("show_ip") ~= false and ip ~= "" then
    table.insert(parts, ip)
  end
  if showTraffic() and trafficLine() ~= "" then
    table.insert(parts, trafficLine())
  end
  return table.concat(parts, " · ")
end

local function render()
  local showGlyph = cfg("show_glyph") ~= false
  local text = barText()

  if not showGlyph and text == "" then
    barWidget.setVisible(false)
    setTooltip()
    return
  end

  barWidget.setVisible(true)

  if showGlyph then
    local online = isOnline()
    barWidget.setGlyph(cfg(if online then "glyph_connected" else "glyph_disconnected"))
    barWidget.setGlyphColor(if online then "primary" else "on_surface_variant")
  end

  barWidget.setText(text)
  setTooltip()
end

local function applyStatus(value)
  if type(value) ~= "table" then
    return
  end
  installed = value.installed == true
  probing = value.probing == true
  running = value.running == true
  ip = if type(value.ip) == "string" then value.ip else ""
  hostname = if type(value.hostname) == "string" then value.hostname else ""
  peerCount = if type(value.peerCount) == "number" then value.peerCount else 0
  render()
end

function update()
  refreshTraffic()
  render()
end

function onClick()
  noctalia.togglePanel("jadeezomg/tailscale:panel")
end

function onRightClick()
  if not installed then
    return
  end
  noctalia.state.set("command", { action = "toggle", nonce = noctalia.nowMs() })
end

noctalia.state.watch("status", applyStatus)

refreshTraffic()
applyStatus(noctalia.state.get("status") or { probing = true })
