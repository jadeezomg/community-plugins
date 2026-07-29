--!nonstrict
-- Tailscale panel: identity, exit node, peer list, connect/disconnect.
-- Pure view: it renders the `status` published by the service and sends it commands.

local installed = false
local probing = true
local running = false
local needsLogin = false
local ip = ""
local hostname = ""
local peerCount = 0
local peers = {}
local exitNode = nil
local cmdNonce = 0

local function cfg(key)
  return noctalia.getConfig(key)
end

local function closeAfterAction()
  return cfg("close_on_action") ~= false
end

local function sendCommand(action, extra)
  cmdNonce += 1
  local cmd = { action = action, nonce = cmdNonce }
  if extra ~= nil then
    for k, v in pairs(extra) do
      cmd[k] = v
    end
  end
  noctalia.state.set("command", cmd)
end

-- Every panel action is fire-and-forget: hand it to the service, then honour close_on_action.
local function dispatch(action, extra)
  sendCommand(action, extra)
  if closeAfterAction() then
    panel.close()
  end
end

local function runPeerAction(action, peerId)
  dispatch("peer_action", { peerAction = action, peerId = peerId })
end

local function osGlyph(os)
  local lower = string.lower(if type(os) == "string" then os else "")
  if lower == "linux" then
    return "terminal"
  end
  if lower == "macos" then
    return "brand-apple"
  end
  if lower == "ios" or lower == "android" then
    return "device-mobile"
  end
  if lower == "windows" then
    return "device-laptop"
  end
  return "devices"
end

local function peerDisplayName(peer)
  if type(peer.hostname) == "string" and peer.hostname ~= "" then
    return peer.hostname
  end
  return noctalia.tr("panel.unknown_host")
end

local function sortedPeers()
  local list = {}
  local hideOffline = cfg("hide_disconnected") == true
  for _, peer in peers do
    if not hideOffline or peer.online == true then
      table.insert(list, peer)
    end
  end
  table.sort(list, function(a, b)
    if a.online ~= b.online then
      return a.online == true
    end
    return string.lower(peerDisplayName(a)) < string.lower(peerDisplayName(b))
  end)
  return list
end

local function subtitleText()
  if needsLogin then
    return noctalia.tr("panel.status_needs_login")
  end
  if not running then
    return noctalia.tr("panel.status_disconnected")
  end
  if peerCount > 0 then
    return `{noctalia.tr("panel.status_connected")} · {noctalia.tr("panel.subtitle_peers", { count = peerCount })}`
  end
  return noctalia.tr("panel.status_connected")
end

local function identityCard()
  if not running or ip == "" then
    return nil
  end
  -- ui.box is a leaf: it drops children and ignores padding. Cards are a padded row.
  return ui.row({ gap = 10, align = "center", padding = 12, radius = 8, fill = "surface_variant/0.45" }, {
    ui.glyph({ name = "world", color = "primary" }),
    ui.column({ gap = 2, flexGrow = 1 }, {
      ui.label({
        text = if hostname ~= "" then hostname else noctalia.tr("panel.unknown_host"),
        fontSize = 12,
        color = "on_surface_variant",
      }),
      ui.label({
        text = ip,
        fontFamily = "monospace",
        fontSize = 14,
        color = "on_surface",
      }),
    }),
    ui.button({
      glyph = "copy",
      variant = "ghost",
      onClick = "onCopySelfIp",
    }),
  })
end

local function exitNodeCard()
  if type(exitNode) ~= "table" then
    return nil
  end
  local statusText = if exitNode.online then noctalia.tr("panel.status_connected") else noctalia.tr("panel.status_disconnected")
  local detail = if exitNode.ip ~= "" then `{exitNode.ip} · {statusText}` else statusText
  return ui.row({
    gap = 10,
    align = "center",
    padding = 12,
    radius = 8,
    fill = "primary/0.1",
    border = "primary/0.3",
    borderWidth = 1,
  }, {
    ui.glyph({ name = "route", color = if exitNode.online then "primary" else "on_surface_variant" }),
    ui.column({ gap = 2, flexGrow = 1 }, {
      ui.label({ text = noctalia.tr("panel.exit_node"), fontWeight = "medium", color = "primary" }),
      ui.label({ text = detail, fontSize = 12, fontFamily = "monospace", color = "on_surface_variant" }),
    }),
  })
end

local function peerRow(peer, index)
  local peerId = peer.id
  local online = peer.online == true
  local stateColor = if online then "primary" else "on_surface_variant"

  return ui.row({
    key = "peer-" .. tostring(index),
    gap = 8,
    align = "center",
    padding = 8,
    fill = "surface_variant/0.45",
    radius = 8,
  }, {
    ui.label({ text = if online then "●" else "○", color = stateColor, fontSize = 12 }),
    ui.glyph({ name = osGlyph(peer.os), color = stateColor }),
    ui.column({ gap = 2, flexGrow = 1 }, {
      ui.label({ text = peerDisplayName(peer), fontWeight = "medium", fontSize = 13, color = "on_surface" }),
      ui.label({
        text = if type(peer.ip) == "string" then peer.ip else "",
        fontSize = 11,
        fontFamily = "monospace",
        color = "on_surface_variant",
      }),
    }),
    ui.button({
      key = "copy-" .. tostring(index),
      glyph = "copy",
      variant = "ghost",
      onClick = function()
        runPeerAction("copy-ip", peerId)
      end,
    }),
    ui.button({
      key = "ssh-" .. tostring(index),
      glyph = "terminal",
      variant = "ghost",
      enabled = online,
      onClick = function()
        runPeerAction("ssh", peerId)
      end,
    }),
    ui.button({
      key = "ping-" .. tostring(index),
      glyph = "radar",
      variant = "ghost",
      onClick = function()
        runPeerAction("ping", peerId)
      end,
    }),
    ui.button({
      key = "admin-" .. tostring(index),
      glyph = "external-link",
      variant = "ghost",
      onClick = function()
        runPeerAction("admin-console", peerId)
      end,
    }),
  })
end

local function peerListRows()
  if needsLogin or not running then
    local key = if needsLogin then "panel.needs_login" else "panel.not_connected"
    return { ui.label({ text = noctalia.tr(key), color = "on_surface_variant" }) }
  end

  local rows = sortedPeers()
  local children = {
    ui.label({ text = noctalia.tr("panel.devices"), fontWeight = "medium", fontSize = 14, color = "on_surface" }),
  }

  if #rows == 0 then
    table.insert(children, ui.label({
      text = noctalia.tr("panel.no_peers"),
      color = "on_surface_variant",
    }))
  else
    for index, peer in ipairs(rows) do
      table.insert(children, peerRow(peer, index))
    end
  end

  return children
end

local function renderMessage(key)
  panel.render(ui.column({ flexGrow = 1, gap = 12, align = "stretch" }, {
    ui.label({ text = noctalia.tr("panel.title"), fontSize = 16, fontWeight = "bold", color = "on_surface" }),
    ui.label({ text = noctalia.tr(key), color = "on_surface_variant" }),
  }))
end

local function render()
  if probing then
    renderMessage("tooltip.probing")
    return
  end

  if not installed then
    renderMessage("panel.not_installed")
    return
  end

  local body = {
    ui.row({ align = "center", justify = "space_between", gap = 8 }, {
      ui.column({ gap = 2, flexGrow = 1 }, {
        ui.label({ text = noctalia.tr("panel.title"), fontSize = 16, fontWeight = "bold", color = "on_surface" }),
        ui.label({
          text = subtitleText(),
          fontSize = 12,
          color = if needsLogin then "error" else "on_surface_variant",
        }),
      }),
      ui.button({ glyph = "x", variant = "ghost", onClick = "onClosePanel" }),
    }),
  }

  local identity = identityCard()
  if identity ~= nil then
    table.insert(body, identity)
  end

  local exitCard = exitNodeCard()
  if exitCard ~= nil then
    table.insert(body, exitCard)
  end

  table.insert(body, ui.scroll({ flexGrow = 1, gap = 6, align = "stretch" }, peerListRows()))
  table.insert(body, ui.button({
    text = noctalia.tr("panel.admin_console"),
    glyph = "external-link",
    variant = "secondary",
    onClick = "onAdminConsole",
  }))
  table.insert(body, ui.button({
    text = if running then noctalia.tr("panel.disconnect") else noctalia.tr("panel.connect"),
    glyph = if running then "link-off" else "link",
    variant = if running then "destructive" else "primary",
    enabled = not needsLogin,
    onClick = "onToggle",
  }))

  panel.render(ui.column({ flexGrow = 1, gap = 10, align = "stretch" }, body))
end

function onClosePanel()
  panel.close()
end

function onCopySelfIp()
  dispatch("copy_self_ip")
end

function onAdminConsole()
  dispatch("open_admin")
end

function onToggle()
  dispatch("toggle")
end

local function applyStatus(value)
  if type(value) ~= "table" then
    return
  end
  installed = value.installed == true
  probing = value.probing == true
  running = value.running == true
  needsLogin = value.needsLogin == true
  ip = if type(value.ip) == "string" then value.ip else ""
  hostname = if type(value.hostname) == "string" then value.hostname else ""
  peerCount = if type(value.peerCount) == "number" then value.peerCount else 0
  peers = if type(value.peers) == "table" then value.peers else {}
  exitNode = value.exitNode
  render()
end

function onOpen(_context)
  sendCommand("refresh")
  applyStatus(noctalia.state.get("status"))
end

function onConfigChanged()
  render()
end

noctalia.state.watch("status", applyStatus)
