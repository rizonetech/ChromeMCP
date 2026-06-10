# Configuration Reference

All settings are environment variables passed when starting `chromemcp up` (or exported beforehand). Defaults are sensible; override only what you need.

## Server

| Variable | Default | What it does |
|---|---|---|
| `PORT` | `8931` | MCP server listen port |
| `HOST` | `127.0.0.1` | MCP server bind interface |
| `CDP_ENDPOINT` | `http://<wsl-gateway>:9222` | Upstream Chrome CDP URL |

The Chrome side uses port `9222` by default. The PowerShell launcher accepts `-Port` to change that. If you change Chrome's port, run `Setup-WSL-Portproxy.ps1` directly with a matching `-Port`.

## Auth

| Variable | Default | What it does |
|---|---|---|
| `MCP_NO_AUTH=1` | unset | Disable bearer-token auth (local debugging only — logs a warning on every request) |

See [`SECURITY.md`](../SECURITY.md) for the full threat model.

## Startup behaviour

| Variable | Default | What it does |
|---|---|---|
| `MCP_NO_AUTO_CHROME=1` | unset | Don't auto-launch Chrome on `chromemcp up` |
| `MCP_NO_AUTO_BRIDGE=1` | unset | Don't auto-install/refresh the bridge on `chromemcp up` |
| `MCP_VISIBLE_INTERACTIONS=0` | `1` | Don't focus Chrome before tool calls |

## Logging

| Variable | Default | What it does |
|---|---|---|
| `MCP_LOG_LEVEL` | `INFO` | Log verbosity: `DEBUG` / `INFO` / `WARN` / `ERROR` |
| `MCP_LOG_FORMAT` | `text` | `json` for newline-delimited JSON (pipe to `jq`) |
| `MCP_LOG_MAX_MB` | `10` | Rotate active log file when it exceeds this size |
| `MCP_LOG_KEEP` | `5` | Number of rotated files to keep (`.1`–`.N`) |
| `MCP_LOG_ROTATE_INTERVAL_SEC` | `30` | How often the rotator checks file size |

Log location depends on mode:

| Mode | Log location | Tail |
|---|---|---|
| Supervised (`chromemcp enable`) | systemd journal | `chromemcp logs` (→ `journalctl --user -u chromemcp`) |
| Ad-hoc (`chromemcp up` without enable) | `mcp/logs/playwright-mcp.log` + rotated `.1`…`.N` | `chromemcp logs` (file `tail -F`) |

`chromemcp logs` auto-detects the mode. Flags:

| Flag | Effect |
|---|---|
| `--all` / `-a` | (file mode) include rotated files |
| `--grep <pat>` / `-g` | grep across active + rotated files, or filter journal |
| `--file` / `--journal` | force a specific source |
| `--since "10 min ago"` | passed through to `journalctl` |

Worst-case log directory size = `(MCP_LOG_KEEP + 1) × MCP_LOG_MAX_MB` plus a small overshoot. With defaults that's ~60 MB. Tighten with:

```bash
MCP_LOG_MAX_MB=8 MCP_LOG_KEEP=4 chromemcp up   # cap at ~40 MB
```

Supervised mode uses journald's own size/age caps (`journalctl --user --vacuum-size=...` to tune) and does not run the file rotator.

## Watchdog / reconnection

| Variable | Default | Effect |
|---|---|---|
| `MCP_CDP_PROBE_INTERVAL_MS` | `10000` | Time between CDP health probes |
| `MCP_CDP_RELAUNCH_AFTER_MS` | `60000` | CDP downtime before triggering `chromemcp chrome` |
| `MCP_CDP_BAIL_AFTER_MS` | `180000` | CDP downtime before exit(1) to force supervisor restart |
| `MCP_NO_WATCHDOG=1` | unset | Disable the watchdog entirely |

See [`docs/TROUBLESHOOTING.md`](TROUBLESHOOTING.md) for the full reconnection behaviour.

## Chrome version

| Variable | Default | What it does |
|---|---|---|
| `MCP_CHROME_MIN_MAJOR` | `140` | Warn (not fail) if Chrome major is below this |
| `MCP_CHROME_MAX_MAJOR` | `150` | Warn (not fail) if Chrome major is above this |

See [`docs/chrome-pinning.md`](chrome-pinning.md) for how to pin Chrome on Windows Enterprise.

## Metrics

`GET http://127.0.0.1:8931/metrics` — Prometheus text exposition, unauthenticated. See [`docs/METRICS.md`](METRICS.md) and [`docs/grafana-dashboard.json`](grafana-dashboard.json).
