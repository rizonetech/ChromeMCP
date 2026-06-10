# Troubleshooting

## Common errors

**`ERROR: Chrome CDP not reachable at http://172.x.x.x:9222`**
`chromemcp up` already tries to auto-launch Chrome and auto-install or auto-refresh the bridge. If the error persists, you either denied the UAC prompt or have `MCP_NO_AUTO_CHROME` / `MCP_NO_AUTO_BRIDGE` set. Run `chromemcp bridge-check` to see `drift` / `missing` / `ok` state, then re-run `chromemcp up` and approve the UAC prompt, or run `chromemcp chrome` and `chromemcp setup-bridge` explicitly.

**Bridge install reports "Could not find vEthernet (WSL) adapter."**
WSL2 isn't running on the Windows side. Open any WSL shell first, then re-run `chromemcp setup-bridge`.

**MCP server logs say "browser already in use" or won't connect.**
A previous Playwright MCP process is still attached to Chrome. Run `chromemcp down`, wait a moment, then `chromemcp up`.

**Want to nuke the profile and start fresh?**
Close Chrome, then on Windows delete `%LOCALAPPDATA%\ChromeMCP\Profile`. The next `chromemcp chrome` recreates it.

## Reconnection across Chrome crashes

If Chrome on Windows crashes, closes, or updates itself, the upstream CDP WebSocket dies. ChromeMCP's auth proxy watchdog handles this automatically:

- Every 10 s the proxy polls `<CDP_ENDPOINT>/json/version`. State is visible at `GET http://127.0.0.1:8931/healthz`:
  ```json
  {"status":"ok","cdp":{"endpoint":"http://172.x.x.x:9222","healthy":true,"downSeconds":0,"reconnects":3}}
  ```
- While CDP is down, `/mcp` requests return `HTTP 503` + JSON-RPC error `code: -32099` with `data.downSeconds` so clients can show a useful retry message.
- After 60 s of CDP down, the proxy fires `chromemcp chrome` once to relaunch Chrome on Windows (suppressed by `MCP_NO_AUTO_CHROME=1`).
- On CDP recovery the proxy restarts the `@playwright/mcp` child cleanly; the auth-proxy itself stays up and HTTP connections from clients are preserved.
- After 180 s of CDP down the proxy exits non-zero so systemd (if enabled) restarts the whole stack.

Watchdog knobs:

| Env var | Default | Effect |
|---|---|---|
| `MCP_CDP_PROBE_INTERVAL_MS` | `10000` | Time between CDP health probes |
| `MCP_CDP_RELAUNCH_AFTER_MS` | `60000` | CDP downtime before triggering `chromemcp chrome` |
| `MCP_CDP_BAIL_AFTER_MS` | `180000` | CDP downtime before exit(1) to force supervisor restart |
| `MCP_NO_AUTO_CHROME=1` | unset | Suppress the relaunch trigger |
| `MCP_NO_WATCHDOG=1` | unset | Disable the watchdog entirely |

## Bridge self-healing across reboots

WSL2's vEthernet gateway IP can change after a Windows reboot, `wsl --shutdown`, or a Hyper-V reset. When that happens, the bridge points at a stale IP. `chromemcp up` detects and recovers automatically:

1. Probes Chrome's CDP through the current bridge.
2. If that fails, runs `chromemcp chrome` to auto-launch Chrome on Windows.
3. If CDP is *still* unreachable, queries `netsh interface portproxy` and compares its `listenaddress` to the current WSL gateway IP.
4. **Drift detected** (listenaddress ≠ current gateway): runs `Setup-Bridge.cmd /refresh`, which deletes stale entries and re-creates one pinned to the current gateway. Approve the UAC prompt once and the bridge is back.
5. **No portproxy entry**: runs the first-time install path.
6. On success, prints `Bridge OK at <IP>:9222`.

For an explicit health check without starting the MCP server:

```bash
chromemcp bridge-check        # report only; exits 0 (ok), 1 (drift), 2 (missing), 3 (interop broken)
chromemcp bridge-check --fix  # report and, on drift, trigger setup-bridge /refresh
```

The UAC prompt only appears when drift or first-time install is needed — not on every `chromemcp up`.

## Process supervision (systemd)

By default `chromemcp up` runs the auth-proxy in a `setsid nohup …&` background. For crash auto-restart, install the systemd user unit:

```bash
chromemcp enable     # install + start chromemcp.service
chromemcp status     # human-readable status
chromemcp disable    # uninstall the unit; revert to ad-hoc mode
```

When the unit is installed, `chromemcp up` / `chromemcp down` route through `systemctl --user` automatically. Crashes restart in ≤ 10 s; `StartLimitBurst=5 / IntervalSec=60` prevents restart storms.

**Requirements:**
- systemd must be PID 1 inside WSL. Add to `/etc/wsl.conf`:
  ```ini
  [boot]
  systemd=true
  ```
  Then run `wsl --shutdown` from Windows PowerShell once. `systemctl --user is-system-running` should print `running`.
- `loginctl enable-linger $USER` is run by `chromemcp enable`. If it warns about needing sudo, run `sudo loginctl enable-linger $USER` manually.
