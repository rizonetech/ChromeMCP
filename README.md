# ChromeMCP

A small, opinionated stack that lets agents in **WSL2** drive your **real, signed-in Chrome on Windows** through the Model Context Protocol (MCP).

You launch Chrome once with CDP enabled against a project-local profile, expose that debug port to WSL through a scoped portproxy + firewall rule, and run [Playwright MCP](https://github.com/microsoft/playwright-mcp) as a long-running HTTP/SSE service that any MCP client (Claude Code, Cursor, Continue, etc.) can attach to. Every client shares the same browser session — same tabs, same cookies, same logins.

## Why this exists

Most "browser for agents" setups spin up a throwaway headless Chromium with an empty profile. That's fine for scraping and useless for real work — your agent can't see the sites you're already logged into. ChromeMCP flips that around: the browser is your normal browser, kept alive between sessions, and the MCP server is the disposable bit.

It's also **multi-client by design**. Run Claude Code and Cursor at the same time, both pointing at the same MCP endpoint, both driving the same Chrome window.

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

Two things are worth pointing out:

- **The Chrome profile lives in `%LOCALAPPDATA%\ChromeMCP\Profile`, not in this repo.** Browser data is hundreds of MB of SQLite/mmap files accessed at high frequency — it belongs on Windows-native storage, not on a 9p share inside WSL.
- **The portproxy binds only to the WSL vEthernet adapter IP**, and the firewall rule restricts the source to the WSL subnet. CDP is effectively unauthenticated, so network scoping is the security boundary. Your LAN cannot see port 9222.

## Requirements

- Windows 10/11 with WSL2 and Google Chrome installed
- A WSL2 distro (tested on Ubuntu)
- Node.js ≥ 18.18 inside WSL
- PowerShell 5.1+ on Windows (ships with Windows by default)
- Administrator rights on Windows for the one-time bridge setup

## Quick start

From this repo's root inside WSL:

```bash
./mcp-up                         # brings up the entire stack
bash mcp/test.sh                 # sanity check (optional)
```

That single `./mcp-up` is enough. It pre-flights the upstream CDP endpoint and, if it's not reachable, transparently:

1. Launches Chrome on Windows via `launcher/Launch-Chrome.ps1` (idempotent, no-op if Chrome is already up).
2. Installs the WSL↔Windows bridge via `Setup-Bridge.cmd` if Chrome is up but its debug port isn't reachable from WSL — this pops a one-time UAC prompt on your Windows desktop. Approve it.
3. Starts the Playwright MCP HTTP/SSE service. First run also runs `npm ci` to install dependencies.

The first time, sign in to whichever sites you want the agent to access in the new Chrome window. The profile lives in `%LOCALAPPDATA%\ChromeMCP\Profile` and persists across restarts, so you only sign in once.

To opt out of either auto-step (e.g. for CI or restricted environments):

```bash
MCP_NO_AUTO_CHROME=1 ./mcp-up    # don't auto-launch Chrome
MCP_NO_AUTO_BRIDGE=1 ./mcp-up    # don't auto-install the bridge (skip UAC)
```

The individual scripts also still work for explicit, manual control:

```bash
./chrome                         # launch Chrome (e.g. with -Force or a custom -Port)
./setup-bridge                   # install the bridge by itself
./setup-bridge /remove           # tear the portproxy + firewall rule down
./mcp-down                       # stop the MCP server
```

## Connecting MCP clients

The MCP server listens at `http://localhost:8931/mcp`. Drop the snippet from [`mcp/client-config.json`](mcp/client-config.json) into your client's MCP config file:

- **Claude Code** — `~/.claude.json` (or a project-local `.mcp.json`)
- **Cursor** — `~/.cursor/mcp.json`
- **Continue** — your `config.json`'s `mcpServers` block

Only the inner `mcpServers` entry needs to be merged into existing files. The `/mcp` path uses the modern Streamable HTTP transport; older clients can target `/sse` instead.

## Repository layout

```
.
├── chrome              WSL wrapper → launcher/Launch-Chrome.ps1
├── chrome.cmd          Windows-side double-clickable wrapper
├── setup-bridge        WSL wrapper → Setup-Bridge.cmd (UAC elevation)
├── Setup-Bridge.cmd    Self-elevating wrapper for the portproxy script
├── mcp-up / mcp-down   WSL wrappers → mcp/start.sh / mcp/stop.sh
├── launcher/
│   ├── Launch-Chrome.ps1        Launches Chrome with CDP + project profile
│   └── Setup-WSL-Portproxy.ps1  netsh portproxy + Defender rule (admin)
└── mcp/
    ├── package.json             @playwright/mcp pinned dependency
    ├── start.sh / stop.sh       Long-running HTTP/SSE service
    ├── client-config.json       Drop-in snippet for MCP clients
    ├── test.sh                  Smoke test (initialize + browser_tabs + browser_snapshot)
    └── demo-visible.sh          Visible-effect demo (opens tab, screenshots, closes)
```

Every script is idempotent. Re-running `./chrome` while Chrome is already up does nothing. Re-running `./mcp-up` while the server is healthy reports its endpoint and exits zero. Re-running `./setup-bridge` refreshes the portproxy and firewall rule cleanly.

## Configuration

Sensible defaults; override with environment variables when starting `./mcp-up`:

| Variable | Default | What it does |
|---|---|---|
| `PORT` | `8931` | MCP server listen port |
| `HOST` | `127.0.0.1` | MCP server bind interface |
| `CDP_ENDPOINT` | `http://<wsl-gateway>:9222` | Upstream Chrome CDP URL |

The Chrome side uses `9222` by default; the PowerShell launcher takes `-Port` to change that. If you change Chrome's port, run `Setup-WSL-Portproxy.ps1` directly with a matching `-Port`.

## Troubleshooting

**`ERROR: Chrome CDP not reachable at http://172.x.x.x:9222`** — `./mcp-up` already tries to auto-launch Chrome and auto-install the bridge. If you still see this error, either you denied/ignored the UAC prompt for the bridge install, or you have `MCP_NO_AUTO_CHROME` / `MCP_NO_AUTO_BRIDGE` set in your environment. Re-run `./mcp-up` and approve the UAC prompt, or run `./chrome` and `./setup-bridge` explicitly.

**Bridge install reports "Could not find vEthernet (WSL) adapter."** — WSL2 isn't currently running on the Windows side. Open any WSL shell first, then re-run `./setup-bridge`.

**MCP server logs say "browser already in use" or won't connect.** — A previous Playwright MCP process is still attached to Chrome. Run `./mcp-down`, wait a moment, then `./mcp-up`.

**Want to nuke the profile and start fresh?** — Close Chrome, then on Windows delete `%LOCALAPPDATA%\ChromeMCP\Profile`. Next `./chrome` will recreate it.

## License

[MIT](LICENSE) © 2026 [Rizonetech (Pty) Ltd.](https://rizonetech.com)
