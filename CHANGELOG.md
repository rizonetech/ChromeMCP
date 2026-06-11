# Changelog

All notable changes to ChromeMCP are recorded here. Format loosely follows
[Keep a Changelog](https://keepachangelog.com/en/1.1.0/); versions follow
[Semantic Versioning](https://semver.org/spec/v2.0.0.html).

## [0.2.0] — 2026-06-11

### Added

- **npm bootstrap package** (`chromemcp` on npm). `npx @rizonetech/chromemcp install` runs
  the bundled `scripts/install.sh` to install ChromeMCP to `~/ChromeMCP`.
  `npm i -g chromemcp` then delegates all subsequent `chromemcp` invocations
  to the real CLI at `~/ChromeMCP/chromemcp`. The npm package is a thin
  bootstrap shim — the runtime stays at a stable path independent of npm/nvm
  version churn. Entry point: `bin/chromemcp-npm`.
- **Codex-isolated stack** via `chromemcp codex-bridge`, `codex-chrome`,
  `codex-up`, `codex-down`, and `codex-status`. The Codex stack uses MCP
  `8941`, upstream MCP `8942`, Chrome CDP `9232`, token file
  `~/.config/chromemcp-codex/token`, and Windows profile
  `%LOCALAPPDATA%\ChromeMCP-Codex\Profile`, leaving the default Claude/shared
  stack on `8931/8932/9222` untouched.
- **Codex lane allocation** via `chromemcp codex-lane acquire|release|env|config|status`.
  Multiple Codex overnight runs can claim separate lanes: lane 1 uses
  `8941/8942/9232`, lane 2 uses `8951/8952/9242`, and higher lanes follow the
  same `+10` pattern with separate token paths, PID files, logs, and Windows
  Chrome profiles.
- **Stale lane reclamation** — `codex-lane acquire` records the owner PID and
  host; when a lock's owner process is gone (crashed overnight run on the same
  host), the next `acquire` reclaims that lane automatically. `codex-lane
  status` reports such locks as `stale`. Locks from other hosts are never
  reclaimed.
- **`codex-lane config [N]`** emits a ready-to-paste MCP client config JSON
  with the lane's real port and token path (the static
  `mcp/client-config-codex.json` documents lane 1 only).
- **Lane-aware auto-bridge** — `mcp/start.sh` now elevates
  `Setup-WSL-Portproxy.ps1 -Port "$CDP_PORT"` directly when the stack runs on
  a non-default CDP port, so laned stacks self-heal bridge drift just like the
  default stack (`Setup-Bridge.cmd` remains the 9222 path). `mcp-up-codex` no
  longer force-disables the auto-bridge.
- **Lane test suite** at `tests/codex-lane.test.sh` covering acquisition,
  exhaustion, stale reclaim, host/liveness guards, config output, and wrapper
  argument validation.
- **Restructured README** — deep content moved to `docs/TROUBLESHOOTING.md`
  (reconnection, bridge self-healing, systemd supervision) and
  `docs/CONFIGURATION.md` (full env-var reference, log rotation details).
  README is now ~120 lines covering what/why, architecture, requirements,
  install, quick start, client connection, CLI reference, and links.

### Fixed

- `codex-lane acquire --max N` with N above the validation ceiling now raises
  the ceiling for that invocation and searches the whole range, instead of
  aborting mid-scan with a confusing `exceeds CODEX_CHROMEMCP_MAX_LANE` error.
- The `mcp-up-codex`/`mcp-down-codex`/`mcp-status-codex`/`chrome-codex`/
  `setup-bridge-codex` wrappers reject a non-numeric lane argument with exit
  64 instead of silently falling back to lane 1.

### Verified Chrome versions

- **Last verified-working Chrome**: `148.0.7778.98` (Windows stable, 2026-05-19).
- **Supported range** (warning-free): Chrome major `140` through `150`.
  Setting `MCP_CHROME_MIN_MAJOR` / `MCP_CHROME_MAX_MAJOR` overrides the
  range locally. `mcp/start.sh` prints the live version and warns
  (without failing) when out of range — see [`docs/chrome-pinning.md`](docs/chrome-pinning.md)
  for how to pin Chrome on Windows Enterprise.

### Changed

- The launcher, focus helper, PID/log paths, token helper, and Python client
  defaults now honor environment overrides needed to run multiple local
  ChromeMCP instances side by side.
- **Consolidated canonical stack into this repo** (was split across
  `codex-plugins/plugins/chromemcp-browser`). The auth proxy, systemd unit,
  token management, healthz endpoint, bridge drift-heal, and full installer
  now live here. Codex-specific plugin packaging stays in `codex-plugins`.
  The embedded `plugins/` directory and codex-plugin scripts are removed —
  each client plugin now lives in its own repo.
- **Default install prefix changed to `~/ChromeMCP`** (was `~/.local/share/chromemcp`).
  Override with `CHROMEMCP_PREFIX`.
- **Pinned `@playwright/mcp` to `0.0.76`** (was `0.0.75`). The `latest`
  dist-tag on npm as of 2026-06-10. No MCP tool-name or argument changes
  relative to `0.0.75`. Partial progress toward roadmap initiative
  [`G1`](todo/production-readiness.md#g1-pin-to-a-stable-playwright-mcp-release)
  — the exact pin at `0.0.76` is an intermediate step; G1 stays open until
  upstream ships a non-alpha `playwright-core` as a stable transitive
  dependency.
- **Updated `playwright-core` / `playwright` override to `1.61.0-alpha-1781023400000`**
  to match what `@playwright/mcp@0.0.76` expects. Upstream still ships alpha
  playwright-core as a transitive dependency; the override aligns the locked
  version with what 0.0.76 declared. Drop the `overrides` block once upstream
  ships a stable playwright-core dependency.
- **Improved Codex plugin installation** so `scripts/install-codex-plugin.sh`
  now creates a tokenized user-local marketplace copy under
  `~/.codex/plugins/chromemcp-local/` instead of requiring users to hand-edit
  the tracked plugin `.mcp.json`. The repository copy keeps the `<TOKEN>`
  placeholder so bearer tokens stay out of git.

### Notes for upgraders

- Run `cd mcp && rm -rf node_modules package-lock.json && npm install` once
  to refresh the lockfile against the new pin and overrides. After that,
  `npm ci` works as expected.
- `npm ls` will report `playwright-core@1.61.0-alpha-1781023400000 overridden`
  — that is the intended outcome of this change, not a warning. The override
  pins the exact alpha that `@playwright/mcp@0.0.76` itself requires, which
  prevents npm from deduplicating to an incompatible stable release.
- Drop the `overrides` block once upstream ships a stable `playwright-core`
  dependency.

### Verified

- `npm ci` produces `node_modules/playwright-core/package.json` with
  `"version": "1.61.0-alpha-1781023400000"`.
- `bash mcp/test.sh` exits clean — `initialize`, `browser_tabs(list)`, and
  `browser_snapshot` all return successfully against a live Chrome via CDP.
- `bash mcp/demo-visible.sh` exits clean — opens a new tab, captures a
  screenshot, and closes the tab without leaving Chrome in a bad state.
- Codex plugin packaging and integration tests live in the
  `rizonetech/codex-plugins` repository.

## [0.1.0] — 2026-05-09

- Initial public layout: WSL↔Windows bridge (`Setup-Bridge.cmd` +
  `Setup-WSL-Portproxy.ps1`), MCP server wrapper (`mcp/start.sh`), Codex
  local plugin (`plugins/chromemcp-browser`), and convenience wrappers
  (`mcp-up`, `mcp-down`, `chrome`, `setup-bridge`).
