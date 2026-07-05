# HybridCore Bridge — Counter-Strike 1.6 (AMX Mod X)

The in-game plugin that connects a **Counter-Strike 1.6** server to your
[HybridCore](https://github.com/HybridMindLabs/HybridCore) site.

It polls the site for queued commands (vote rewards, store purchases, giveaway
prizes, bans, …) and runs them on the server, then confirms the ones it
executed. All delivery, retries and expiry are handled by the site — the plugin
just polls, runs and acks.

## How it works

```
POST {site}/api/bridge/poll   →  { "commands": [ { "id": 12, "command": "hc_give_points STEAM_1:0:1 100" } ] }
   (plugin runs each command in the server console)
POST {site}/api/bridge/ack    ←  { "ids": [ 12 ] }
```

Authenticated with a per-server bearer token (`hcb_…`).

## Requirements

- **AMX Mod X 1.9+** (for the built-in JSON natives)
- **[AmxxEasyHttp](https://github.com/Next21Team/AmxxEasyHttp)** module (`easy_http`) installed and loaded
- HybridCore **≥ 0.2.0** on the site side

## Installation

1. **Install EasyHTTP** — copy its module into `addons/amxmodx/modules/` and add
   it to `addons/amxmodx/configs/modules.ini` (`easy_http`).

2. **Compile** `hybridcore_bridge.sma` (via `compile.exe`, the web compiler, or
   your build setup) and put the resulting `hybridcore_bridge.amxx` into
   `addons/amxmodx/plugins/`.

3. **Register the plugin** — add to `addons/amxmodx/configs/plugins.ini`:
   ```
   hybridcore_bridge.amxx
   ```

4. **Generate a token** — on the site: **Admin → Servers → (your server) →
   Bridge**, enable it and copy the `hcb_…` token (shown once).

5. **Configure** — the first run creates
   `addons/amxmodx/configs/hybridcore/config.cfg`. Edit it:
   ```
   hc_base_url "https://your-community.com"
   hc_bridge_token "hcb_xxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxx"
   hc_bridge_interval "5.0"
   hc_bridge_debug "0"
   ```
   Then `amx_reloadadmins` / restart the map (or the server).

## CVars

| CVar | Default | Description |
| --- | --- | --- |
| `hc_base_url` | `https://your-community.com` | Site base URL, no trailing slash |
| `hc_bridge_token` | `none` | Per-server bridge token (`hcb_…`) |
| `hc_bridge_interval` | `5.0` | Poll interval in seconds (min 2s) |
| `hc_bridge_debug` | `0` | `1` = verbose console output |

## Commands

- `hc_bridge_poll` (RCON) — force an immediate poll, useful for testing.

## Notes

- Commands are executed **exactly as queued by the site** — the site substitutes
  placeholders (`{steamid}`, `{name}`, `{points}`, …) before queueing. When you
  configure a reward's command on the site, write it for the in-game plugin that
  should receive it.
- `{steamid}` resolves to the player's **linked Steam account** (SteamID64). If
  the in-game command needs `STEAM_0:X:Y`, convert it in your reward plugin (or
  target a plugin that accepts a SteamID64).
- Delivery is **at-least-once**: the site re-sends unacked commands, so keep the
  server reachable. Executed commands are confirmed immediately after running.

## License

Proprietary — © HybridMind Labs.
