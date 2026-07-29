# Tailscale

Monitor your Tailscale tailnet from the Noctalia bar: see connection state, browse
peers, copy IPs, SSH or ping devices, and connect or disconnect without leaving
the shell.

## Plugin

| Field | Value |
| --- | --- |
| ID | `jadeezomg/tailscale` |
| Entries | Bar widget: `tailscale`; panel: `panel`; service: `service`; shortcut: `toggle` |

## Requirements

Install `tailscale` on `PATH` and sign in yourself with `sudo tailscale up` in a
terminal; the plugin reports the unauthenticated state but never signs in for you.
See [tailscale.com/download](https://tailscale.com/download) for packages.

To connect and disconnect from the plugin, grant your user prefs access once with
`sudo tailscale set --operator=$USER` — without it `tailscale up` / `down` are
root-only and the toggle fails.

The peer actions shell out to three more commands, each only when you use it:
`ssh` and `ping` run in a terminal, and `xdg-open` opens the admin console in your
browser. Everything else works without them.

Interface traffic rates need plugin API 16 (`noctalia.systemStats()`). Enable
**Settings → Services → System monitor**, then turn on **Show Traffic** in the
widget settings; the first `tailscale*` interface is used. On vertical bars, rates
appear in the tooltip instead.

## Usage

1. Enable the plugin in Noctalia settings.
2. Add the `tailscale` bar widget from the Add-widget picker.
3. **Left-click** the widget to open the peer panel.
4. **Right-click** the widget to connect or disconnect Tailscale.
5. Add the `toggle` shortcut under **Settings → Control Center → Shortcuts**; click
   the tile to connect or disconnect.

The panel lists tailnet devices with quick actions (copy IP, SSH, ping, open in
admin console). Actions run in the service; the panel only sends commands.

```sh
noctalia msg panel-toggle jadeezomg/tailscale:panel
```

## Settings

| Setting | Type | Default | Description |
| --- | --- | --- | --- |
| `refresh_interval` | int | 5 | Seconds between status polls (1–60). |
| `hide_disconnected` | bool | false | Hide offline peers in the panel list. |
| `name_source` | select | `machine` | Name shown for your device and each peer: `machine` for the Tailscale machine name, `hostname` for the OS hostname. |
| `close_on_action` | bool | true | Close the panel after SSH, ping, or admin-console actions. |
| `ssh_user` | string | *(empty)* | Default SSH username (`user@ip` when set). |
| `ping_count` | int | 5 | Packets sent by the ping action (1–20). |
| `command` | string | *(empty)* | Full path to `tailscale` when auto-detection fails. |

Per bar-widget instance — open from the bar layout editor, or **middle-click** the
widget (Settings → Plugins is for shared plugin/panel options only):

| Setting | Type | Default | Description |
| --- | --- | --- | --- |
| `show_glyph` | bool | true | Show the connection-state glyph. |
| `show_ip` | bool | true | Show your Tailscale IP on horizontal bars. |
| `show_traffic` | bool | false | Show interface ↓/↑ rates on horizontal bars. |
| `glyph_connected` | glyph | `network` | Icon when connected. |
| `glyph_disconnected` | glyph | `network-off` | Icon when disconnected or unavailable. |

The panel is **400×720** (set in `plugin.toml`). Host-provided options under
**Settings → Plugins → Tailscale**: `panel_placement`, `panel_position`,
`panel_open_near_click`.

## IPC

```sh
noctalia msg plugin jadeezomg/tailscale:service all toggle
noctalia msg plugin jadeezomg/tailscale:service all refresh
noctalia msg plugin jadeezomg/tailscale:service all open_admin
```

Service entries have no bar output, so the `target` must be `all`.

`toggle` runs `tailscale up` or `tailscale down`, and does nothing while
Tailscale is unauthenticated. `refresh` re-polls `tailscale status --json`.
`open_admin` opens the Tailscale admin console in your browser.

Peer actions (replace `<node-id>` with a peer id from status JSON):

```sh
noctalia msg plugin jadeezomg/tailscale:service all peer_action '{"action":"copy-ip","peerId":"<node-id>"}'
noctalia msg plugin jadeezomg/tailscale:service all peer_action '{"action":"ssh","peerId":"<node-id>"}'
noctalia msg plugin jadeezomg/tailscale:service all peer_action '{"action":"ping","peerId":"<node-id>"}'
noctalia msg plugin jadeezomg/tailscale:service all peer_action '{"action":"admin-console","peerId":"<node-id>"}'
```

Supported `action` values: `copy-ip`, `copy-hostname`, `ssh`, `ping`,
`admin-console`.

## Notes

- The service polls `tailscale status --json` on an interval and runs
  `tailscale up` / `tailscale down` for connect/disconnect.
- Signing in is out of scope. When Tailscale reports `NeedsLogin` (or provides an
  `AuthURL`), the bar, panel, and control-center tile report an unauthenticated
  state and the toggle goes inert; sign in yourself with `tailscale up` in a
  terminal and the plugin picks it up on the next poll. Reason: `tailscale up`,
  `down`, and `login` are prefs writes that require root unless you have run
  `sudo tailscale set --operator=$USER` once, and a bar widget is the wrong place
  to ask for a password. Connect/disconnect from the plugin needs that same
  `--operator` setup.
- SSH and ping open a terminal via `noctalia.runInTerminal()`; the admin console
  uses `xdg-open`. Neither is configured inside the plugin — set `TERMINAL` and
  ensure a browser handler exists in the environment Noctalia inherits. See
  [Shell settings](https://docs.noctalia.dev/v5/configuration/shell/).
- On NixOS, export session variables (for example via `environment.sessionVariables`)
  so they reach the compositor — values from `.zshrc` do not. The service also
  probes `/run/current-system/sw/bin/tailscale`; set `command` if detection still
  fails.
- `$BROWSER` is honoured by `xdg-open`; a missing binary can make admin-console
  links fail silently.
- The plugin makes no network requests itself beyond what the `tailscale` CLI
  performs. It writes no user data to disk.
