# Tailscale

Monitor your Tailscale tailnet from the Noctalia bar: see connection state, browse
peers, copy IPs, SSH or ping devices, and connect or disconnect without leaving
the shell.

## Plugin

| Field | Value |
| --- | --- |
| ID | `jadeezomg/tailscale` |
| Entries | Service `service`, bar widget `tailscale`, panel `panel`, shortcut `toggle` |
| Dependency | `tailscale` CLI on `PATH` |
| Plugin API | 16 (Noctalia v5.0.0-beta.6+) |

## Requirements

Install [Tailscale](https://tailscale.com/download) so the `tailscale` command is
available and you are logged in (`tailscale up` works in a terminal).

Interface traffic rates use `noctalia.systemStats()` (plugin API 16). Enable
**Settings → Services → System monitor**, then turn on **Show Traffic** in the
widget settings; the first `tailscale*` interface is used. On vertical bars, rates
appear in the tooltip instead.

## Usage

1. Enable the plugin in Noctalia settings.
2. Add the **Tailscale** bar widget from the Add-widget picker.
3. **Left-click** the widget to open the peer panel.
4. **Right-click** the widget to connect or disconnect Tailscale.
5. Add the **Tailscale** control-center tile from **Settings → Control Center → Shortcuts**; click to toggle connect/disconnect.

The panel lists tailnet devices with quick actions (copy IP, SSH, ping, open in
admin console). Actions run in the service; the panel only sends commands.

## IPC

```sh
noctalia msg plugin jadeezomg/tailscale:service toggle
noctalia msg plugin jadeezomg/tailscale:service refresh
noctalia msg panel-toggle jadeezomg/tailscale:panel
```

Peer actions via IPC:

```sh
noctalia msg plugin jadeezomg/tailscale:service peer_action '{"action":"copy-ip","peerId":"<node-id>"}'
```

## Settings

| Setting | Type | Default | Description |
| --- | --- | --- | --- |
| `refresh_interval` | int | 5 | Seconds between status polls |
| `hide_disconnected` | bool | false | Hide offline peers |
| `close_on_action` | bool | true | Close panel after running an action |
| `ssh_user` | string | *(empty)* | Default SSH username |
| `ping_count` | int | 5 | Packets sent by ping action |
| `command` | string | *(empty)* | Full path to `tailscale` when auto-detection fails |

### Panel

The panel is **400×720** (set in `plugin.toml`). Noctalia does not apply custom width/height from plugin settings at runtime yet.

Host-provided options under **Settings → Plugins → Tailscale**: `panel_placement`, `panel_position`, `panel_open_near_click`.

### Widget settings

Per bar-widget instance — open from the bar layout editor, or **middle-click** the
widget on your bar (Settings → Plugins gear is for shared plugin/panel options only):

| Setting | Type | Default | Description |
| --- | --- | --- | --- |
| `show_glyph` | bool | true | Show the connection-state glyph |
| `show_ip` | bool | true | Show Tailscale IP on horizontal bars |
| `show_traffic` | bool | false | Show interface ↓/↑ rates on horizontal bars |
| `glyph_connected` | glyph | `network` | Icon when connected |
| `glyph_disconnected` | glyph | `network-off` | Icon when disconnected or unavailable |

### NixOS / custom PATH

Noctalia may not inherit the same `PATH` as your terminal. The service probes
common locations automatically (including `/run/current-system/sw/bin/tailscale`).
If detection still fails, set **Tailscale Command** in plugin settings to the
output of `which tailscale`.

SSH and ping use `noctalia.runInTerminal()`, and the admin console uses `xdg-open`.
Both resolve against the environment Noctalia itself runs in, so fix them there rather
than per plugin — if a terminal is not found, set `TERMINAL` (bare executable name, no
`-e`) somewhere the graphical session sees it, not only in your shell rc. Noctalia
checks `$TERMINAL` first, then its own discovery list; see
[Shell settings](https://docs.noctalia.dev/v5/configuration/shell/).

On NixOS that means `environment.sessionVariables` or an equivalent that reaches
systemd user services — variables exported from `.zshrc` never reach a shell started by
the compositor. The same applies to `$BROWSER`, which `xdg-open` honours ahead of the
registered `.desktop` handler: if it names a binary that does not exist, URLs silently
fail to open.
