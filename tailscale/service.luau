--!nonstrict
-- Tailscale service: poll status, toggle connection, run peer actions.
-- Owns the CLI and every desktop action; the panel and widget are views over `status`.

local pollInFlight = false
local toggleInFlight = false
local probeInFlight = false
local probeRetryTicks = 0
local lastStatusKey = ""
local resolvedCommand = nil
local PROBE_RETRY_TICKS = 6

local FALLBACK_COMMANDS = {
  "tailscale",
  "/run/current-system/sw/bin/tailscale",
  "/usr/bin/tailscale",
  "/usr/local/bin/tailscale",
}

local status = {
  probing = true,
  installed = false,
  running = false,
  ip = "",
  hostname = "",
  peerCount = 0,
  peers = {},
  exitNode = nil,
  error = "",
}

local peersById = {}

local function cfg(key)
  return noctalia.getConfig(key)
end

local function log(msg)
  noctalia.log(`tailscale: {msg}`)
end

local function refreshIntervalSec()
  return math.clamp(math.floor(cfg("refresh_interval") or 5), 1, 60)
end

-- First 100.x address, or the first address of any kind.
local function tailscaleIp(ips)
  if type(ips) ~= "table" then
    return ""
  end
  for _, ip in ips do
    if type(ip) == "string" and string.sub(ip, 1, 4) == "100." then
      return ip
    end
  end
  return if type(ips[1]) == "string" then ips[1] else ""
end

local function publishStatus()
  local parts = {
    tostring(status.probing),
    tostring(status.installed),
    tostring(status.running),
    status.ip,
    status.hostname,
    tostring(status.peerCount),
    status.error,
    if type(status.exitNode) == "table" then `{status.exitNode.id}:{status.exitNode.online}` else "",
  }
  for _, peer in status.peers do
    table.insert(parts, `{peer.id}:{peer.ip}:{peer.online}`)
  end
  local key = table.concat(parts, "|")
  if key == lastStatusKey then
    return
  end
  lastStatusKey = key
  noctalia.state.set("status", status)
end

local function setStatus(patch)
  for k, v in pairs(patch) do
    status[k] = v
  end
  publishStatus()
end

-- exitNode is assigned directly: a nil in a setStatus() patch is invisible to pairs().
local function clearStatus(message)
  peersById = {}
  status.exitNode = nil
  setStatus({ running = false, ip = "", hostname = "", peerCount = 0, peers = {}, error = message })
end

local function shellQuote(s)
  return "'" .. tostring(s):gsub("'", "'\\''") .. "'"
end

local function configuredCommand()
  local cmd = noctalia.string.trim(cfg("command") or "")
  return if cmd ~= "" then cmd else nil
end

local function tailscaleCmd()
  return resolvedCommand or configuredCommand() or "tailscale"
end

local function runTailscale(args, callback, timeoutMs)
  noctalia.runAsync(`{shellQuote(tailscaleCmd())} {args}`, callback, timeoutMs)
end

local function parseStatusJson(stdout)
  local decoded = noctalia.json.decode(stdout)
  if type(decoded) ~= "table" then
    return nil, noctalia.tr("errors.parse-failed")
  end

  local running = decoded.BackendState == "Running"
  local ip = ""
  local hostname = ""
  local peers = {}
  peersById = {}

  if running and type(decoded.Self) == "table" then
    hostname = if type(decoded.Self.HostName) == "string" then decoded.Self.HostName else ""
    ip = tailscaleIp(decoded.Self.TailscaleIPs)
  end

  if type(decoded.Peer) == "table" then
    for peerId, peer in pairs(decoded.Peer) do
      if type(peer) == "table" then
        local entry = {
          id = peerId,
          hostname = if type(peer.HostName) == "string" then peer.HostName else "",
          dnsName = if type(peer.DNSName) == "string" then peer.DNSName else "",
          ip = tailscaleIp(peer.TailscaleIPs),
          online = peer.Online == true,
          os = if type(peer.OS) == "string" then peer.OS else "",
        }
        table.insert(peers, entry)
        peersById[peerId] = entry
      end
    end
  end

  local exitNode = nil
  if type(decoded.ExitNodeStatus) == "table" then
    exitNode = {
      id = if type(decoded.ExitNodeStatus.ID) == "string" then decoded.ExitNodeStatus.ID else "",
      online = decoded.ExitNodeStatus.Online == true,
      ip = tailscaleIp(decoded.ExitNodeStatus.TailscaleIPs),
    }
  end

  return {
    running = running,
    ip = ip,
    hostname = hostname,
    peerCount = #peers,
    peers = peers,
    exitNode = exitNode,
    error = "",
  }, nil
end

local function pollStatus()
  if pollInFlight or not status.installed then
    return
  end
  pollInFlight = true
  runTailscale("status --json", function(result)
    pollInFlight = false
    if type(result) ~= "table" then
      clearStatus(noctalia.tr("errors.parse-failed"))
      return
    end
    if result.timedOut or result.exitCode ~= 0 then
      clearStatus(if result.stderr ~= "" then result.stderr else noctalia.tr("errors.parse-failed"))
      return
    end
    local parsed, err = parseStatusJson(result.stdout or "")
    if parsed == nil then
      clearStatus(err)
      return
    end
    status.exitNode = parsed.exitNode
    setStatus(parsed)
  end, 15000)
end

local function probeCommand(index)
  if probeInFlight then
    return
  end
  local configured = configuredCommand()
  local candidates = if configured ~= nil then { configured } else FALLBACK_COMMANDS
  if index > #candidates then
    log("tailscale CLI not found after probing fallbacks")
    resolvedCommand = nil
    status.probing = false
    status.installed = false
    clearStatus(noctalia.tr("errors.not-installed"))
    return
  end
  local cmd = candidates[index]
  probeInFlight = true
  noctalia.runAsync(`{shellQuote(cmd)} version`, function(result)
    probeInFlight = false
    if type(result) == "table" and result.exitCode == 0 and not result.timedOut then
      resolvedCommand = cmd
      log(`using {cmd}`)
      setStatus({ probing = false, installed = true, error = "" })
      pollStatus()
      return
    end
    probeCommand(index + 1)
  end, 5000)
end

local function copyText(text, notifyKey, subst)
  if type(text) ~= "string" or text == "" then
    return
  end
  noctalia.copyToClipboard(text, "text/plain;charset=utf-8")
  noctalia.notify(noctalia.tr("title"), noctalia.tr(notifyKey, subst))
end

local ADMIN_URL = "https://login.tailscale.com/admin"

local function openUrl(url)
  noctalia.runAsync(`xdg-open {shellQuote(url)}`)
end

-- The host resolves the emulator: $TERMINAL first, then its own discovery list.
local function launchInTerminal(command)
  if not noctalia.runInTerminal(command) then
    noctalia.notifyError(noctalia.tr("title"), noctalia.tr("errors.no-terminal"))
  end
end

local function executePeerAction(action, peerId)
  local peer = if type(peerId) == "string" then peersById[peerId] else nil
  if peer == nil then
    noctalia.notifyError(noctalia.tr("title"), noctalia.tr("errors.peer-not-found"))
    return
  end

  local ip = peer.ip
  if ip == "" then
    noctalia.notifyError(noctalia.tr("title"), noctalia.tr("errors.peer-no-ip"))
    return
  end

  -- The admin console addresses machines by Tailscale IP; hostnames are rejected.
  if action == "admin-console" then
    openUrl(`{ADMIN_URL}/machines/{ip}`)
  elseif action == "copy-ip" then
    copyText(ip, "notify.copied-ip", { ip = ip })
  elseif action == "copy-hostname" then
    local name = peer.hostname
    if name == "" then
      name = peer.dnsName
    end
    if name == "" then
      name = noctalia.tr("panel.unknown_host")
    end
    copyText(name, "notify.copied-hostname", { hostname = name })
  elseif action == "ssh" then
    local user = noctalia.string.trim(cfg("ssh_user") or "")
    launchInTerminal(`ssh {if user ~= "" then `{user}@{ip}` else ip}`)
  elseif action == "ping" then
    launchInTerminal(`ping -c {math.clamp(math.floor(cfg("ping_count") or 5), 1, 20)} {ip}`)
  end
end

local function toggleTailscale()
  if toggleInFlight or not status.installed then
    return
  end
  toggleInFlight = true
  local direction = if status.running then "down" else "up"
  runTailscale(direction, function(result)
    toggleInFlight = false
    local ok = type(result) == "table" and result.exitCode == 0 and not result.timedOut
    if ok then
      noctalia.notify(noctalia.tr("title"), noctalia.tr(`notify.{if direction == "down" then "disconnected" else "connected"}`))
    elseif type(result) == "table" and not result.timedOut then
      noctalia.notifyError(noctalia.tr("title"), noctalia.tr("errors.toggle-failed"))
    end
    pollStatus()
  end, 30000)
end

local function handleCommand(cmd)
  if type(cmd) ~= "table" then
    return
  end

  if cmd.action == "toggle" then
    toggleTailscale()
  elseif cmd.action == "refresh" then
    pollStatus()
  elseif cmd.action == "open_admin" then
    openUrl(ADMIN_URL)
  elseif cmd.action == "copy_self_ip" then
    copyText(status.ip, "notify.copied-ip", { ip = status.ip })
  elseif cmd.action == "peer_action" then
    executePeerAction(cmd.peerAction, cmd.peerId)
  end
end

function onIpc(event, payload)
  if event == "toggle" then
    toggleTailscale()
  elseif event == "refresh" then
    pollStatus()
  elseif event == "open_admin" then
    openUrl(ADMIN_URL)
  elseif event == "peer_action" then
    local data = if type(payload) == "string" and payload ~= "" then noctalia.json.decode(payload) else payload
    if type(data) == "table" then
      executePeerAction(data.action, data.peerId)
    end
  end
end

noctalia.state.watch("command", handleCommand)

function onConfigChanged()
  noctalia.setUpdateInterval(refreshIntervalSec() * 1000)
  resolvedCommand = nil
  probeRetryTicks = 0
  setStatus({ probing = true, installed = false, error = "" })
  probeCommand(1)
end

function update()
  if not status.installed then
    probeRetryTicks += 1
    if probeRetryTicks % PROBE_RETRY_TICKS == 0 then
      probeCommand(1)
    end
    return
  end
  pollStatus()
end

noctalia.setUpdateInterval(refreshIntervalSec() * 1000)
publishStatus()
probeCommand(1)
