# ChromeMCP

A small, opinionated stack that lets agents in **WSL2** drive your **real, signed-in Chrome on Windows** through the Model Context Protocol (MCP). You launch Chrome once with CDP enabled against a project-local profile, expose that debug port to WSL through a scoped portproxy + firewall rule, and run [Playwright MCP](https://github.com/microsoft/playwright-mcp) as a long-running HTTP/SSE service that any MCP client (Claude Code, Cursor, Continue, etc.) can attach to. Every client shares the same browser session — same tabs, same cookies, same logins. Multi-client by design: run Claude Code and Cursor simultaneously, both driving the same Chrome window.

## Architecture

```
┌─────────────── Windows host ───────────────┐    ┌──────── WSL2 ────────┐
│                                            │    │                      │
│  Chrome.exe                                │    │  Playwright MCP      │
│  ├─ profile: %LOCALAPPDATA%\ChromeMCP      │    │  (HTTP/SSE server)   │
│  └─ --remote-debugging-port=9222           │    │  localhost:8931/mcp  │
│         │                                  │    │       │              │
│         │ 127.0.0.1:9222 (CDP)             │    │       │              │
│         ▼                                  │    │       ▼              │
│  netsh portproxy ◄───── firewall ──────────┼────┤  CDP client          │
│  (vEthernet WSL IP)    (WSL subnet only)   │    │                      │
│                                            │    │  ▲ ▲ ▲               │
└────────────────────────────────────────────┘    │  │ │ │  MCP clients  │
                                                  │  Claude Code, Cursor,│
                                                  │  Continue, ...       │
                                                  └──────────────────────┘
```

The Chrome profile lives in `%LOCALAPPDATA%\ChromeMCP\Profile`, not in this repo (browser data belongs on Windows-native storage, not on a 9p share). The portproxy binds only to the WSL vEthernet adapter IP, and the firewall rule restricts source to the WSL subnet — your LAN cannot see port 9222.

## Requirements

- Windows 10/11 with WSL2 and Google Chrome **140+** ([pinning guide](docs/chrome-pinning.md))
- A WSL2 distro (tested on Ubuntu) with Node.js ≥ 18.18
- PowerShell 5.1+ on Windows (ships by default)
- Administrator rights on Windows for the one-time bridge setup

## Install

```bash
# One-liner (installs to ~/ChromeMCP):
curl -fsSL https://raw.githubusercontent.com/rizonetech/ChromeMCP/main/scripts/install.sh | bash

# Via npm / npx (no clone required):
npx chromemcp install

# From source:
git clone https://github.com/rizonetech/ChromeMCP.git ~/ChromeMCP
cd ~/ChromeMCP && bash scripts/install.sh --from-source
```

## Quick start

```bash
chromemcp setup-bridge   # one-time Windows bridge setup (UAC required)
chromemcp chrome         # launch Chrome with CDP
chromemcp up             # start the MCP server
chromemcp token          # print bearer token for client config
chromemcp test           # smoke test
```

Sign in to any sites you need in the new Chrome window. The profile persists across restarts — sign in once.

## Connect your MCP client

The server listens at `http://localhost:8931/mcp`. Get the token:

```bash
chromemcp token --header   # prints: Authorization: Bearer <token>
```

Merge into your client's MCP config:

```json
{
  "mcpServers": {
    "chromemcp-playwright": {
      "type": "http",
      "url": "http://localhost:8931/mcp",
      "headers": { "Authorization": "Bearer <TOKEN>" }
    }
  }
}
```

Older clients can target `/sse` instead of `/mcp`. Full per-client instructions: [docs/CLIENTS.md](docs/CLIENTS.md).

## CLI reference

| Command | What it does |
|---|---|
| `chromemcp up` | Start the MCP server (auto-launches Chrome and bridge if needed) |
| `chromemcp down` | Stop the MCP server |
| `chromemcp status` | Health report |
| `chromemcp test` | Smoke test (initialize + browser_tabs + browser_snapshot) |
| `chromemcp chrome` | Launch Chrome with CDP on Windows |
| `chromemcp setup-bridge` | Install/refresh the WSL↔Windows portproxy |
| `chromemcp bridge-check` | Diagnose bridge health (`--fix` to auto-repair) |
| `chromemcp token` | Print bearer token (`--header`, `--rotate`, `--path`) |
| `chromemcp logs` | Tail server logs (auto-detects systemd vs file mode) |
| `chromemcp enable` | Install systemd user unit (crash auto-restart) |
| `chromemcp disable` | Uninstall systemd unit; revert to ad-hoc mode |
| `chromemcp update` | Pull latest release and reinstall |

## Links

- [docs/CLIENTS.md](docs/CLIENTS.md) — per-client config (Claude Code, Cursor, Codex, Python)
- [docs/CONFIGURATION.md](docs/CONFIGURATION.md) — all environment variables
- [docs/TROUBLESHOOTING.md](docs/TROUBLESHOOTING.md) — common errors, reconnection, bridge self-healing
- [SECURITY.md](SECURITY.md) — threat model, auth proxy, network scoping
- [CHANGELOG.md](CHANGELOG.md) — version history
- [claude-plugins marketplace](https://github.com/rizonetech/claude-plugins) — Claude Code plugin
- [codex-plugins](https://github.com/rizonetech/codex-plugins) — Codex plugin

## License

[MIT](LICENSE) © 2026 [Rizonetech (Pty) Ltd.](https://rizonetech.com)
