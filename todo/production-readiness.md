# ChromeMCP — Production Readiness Roadmap

> Living checklist of what ChromeMCP needs to deliver on its mission ("easy to install + works out of the box for Windows↔WSL2 browser automation"), then graduate to OSS v1.0, then to a production service. Sourced from the 2026-05-07 readiness audit; re-prioritized on 2026-05-18 against the mission axis.

## Mission

ChromeMCP makes a signed-in, full-Chrome browser on Windows drivable by MCP clients running inside WSL2, with zero hand-tuning of port-proxies, firewalls, or CDP endpoints.

**Two non-negotiables:**
1. **Easy to install** — `git clone` → one script → working stack. No reading 15 setup docs.
2. **Works out of the box** — survives WSL IP drift, Chrome crashes, and Windows reboots without manual re-running of setup scripts.

Everything below is graded against these two first, then against OSS / production milestones.

## How to use this doc

- Each gap below has actionable subtasks (`- [ ]`) and explicit **acceptance criteria** so "done" is not subjective.
- File-line references (e.g. `mcp/start.sh:65`) are starting points, not exhaustive — anchors only.
- Severity legend (mission-first):
  - 🔴 **Critical** — blocks "easy to install" or "works out of the box"
  - 🟠 **High** — blocks shared / CI use, OSS recommendation, or causes silent failure after install
  - 🟡 **Medium** — blocks "stable" claim or v1.0 OSS milestone hygiene
  - 🟢 **Low** — polish / hygiene; doesn't affect end-user experience
- Items within each severity section are ordered by mission priority (top = highest mission impact).
- Three "roadmap" sections at the bottom cross-reference these gaps into ship gates for **install-and-forget** (the bullseye), **v1.0 OSS**, and **production service** milestones.

---

## 🔴 Critical

### G1. Pin to a stable Playwright MCP release
**Why it matters.** `mcp/package.json` pins `@playwright/mcp@0.0.74`, transitively pulling `playwright-core@1.60.0-alpha-1778101408000`. Pre-release software has no API stability contract — tool names, argument shapes, and protocol details can shift between any two builds.

- [ ] Subscribe to `@playwright/mcp` releases: watch https://github.com/microsoft/playwright-mcp/releases
- [ ] Audit the changelog of any candidate stable release for breaking tool-name / argument changes
- [ ] Update `mcp/package.json` to pin to the chosen stable version with **exact** match (no caret)
- [ ] Run full smoke suite (after G15 lands) against the pinned version
- [ ] Re-run `bash mcp/test.sh` and `bash mcp/demo-visible.sh`
- [ ] Document supported `@playwright/mcp` version in `README.md` (e.g. "Tested with `@playwright/mcp` 0.1.x")
- [ ] Add a `CHANGELOG.md` entry recording the upgrade and any compatibility notes
- [ ] If upstream stabilization stalls > 60 days: evaluate vendoring a known-good fork

**Acceptance criteria.** `mcp/package.json` pins an exact non-alpha version of `@playwright/mcp`; `npm ci` produces a `playwright-core` whose version does **not** contain `-alpha-` or `-beta-`; smoke suite passes; `CHANGELOG.md` records the version and date.

---

### G5. WSL2 vEthernet IP drift auto-heal
**Why it matters.** `Setup-WSL-Portproxy.ps1` captures *today's* WSL gateway IP and bakes it into a `netsh portproxy` entry and a Defender firewall rule. WSL2 may assign a different gateway IP after Windows reboots, hyper-V resets, or distro upgrades, silently breaking the bridge.

**User-facing impact.** The stack stops working after a Windows reboot until the user re-runs `setup-bridge`. Direct breach of the "works out of the box" promise.

- [ ] In `mcp/start.sh`: capture current WSL gateway via `ip route show | awk '/^default/ {print $3}'` (already done — line 20)
- [ ] Read the netsh portproxy entry from Windows side (via `powershell.exe netsh interface portproxy show v4tov4`) and parse the listenaddress
- [ ] Compare current gateway IP to bridge listenaddress; if mismatch, log and trigger automatic `./setup-bridge` refresh
- [ ] Or simpler: if first-stage and second-stage CDP probes both fail despite `Launch-Chrome.ps1` succeeding, treat as drift and re-run `Setup-Bridge.cmd` (we already have stage-2 auto-trigger)
- [ ] Add a `./bridge-check` standalone script for explicit verification
- [ ] Update `Setup-WSL-Portproxy.ps1` to support `-Refresh` mode that idempotently updates the listenaddress + firewall rule without needing `-Remove` first
- [ ] Add a startup banner in `mcp-up` showing "bridge OK at <IP>:9222" when bridge passes pre-flight
- [ ] Document the self-healing behavior in `README.md`

**Acceptance criteria.** After a forced WSL gateway IP change (e.g. `wsl --shutdown` followed by IP change), first `./mcp-up` detects drift and refreshes the bridge automatically; CDP becomes reachable without the user knowing what happened.

---

### G11. Installer / packaging
**Why it matters.** Today, ChromeMCP discovery is git clone + read README. No npm package, no Winget manifest, no auto-update channel. Onboarding cost is high.

**User-facing impact.** Every new user must clone the repo and read multiple setup docs to get a working install. There is no `curl ... | bash`-style one-liner. Direct breach of the "easy to install" promise.

- [ ] Decide minimum viable distribution: GitHub Releases tarball + `install.sh` (cheapest) | npm publish (`@rizonetech/chromemcp`) | Winget for the Windows-side launcher
- [ ] Write `scripts/install.sh`: download latest GitHub release tarball, extract to `~/.local/share/chromemcp`, symlink `chromemcp` into `~/.local/bin`
- [ ] Add `--upgrade` flag to `install.sh` that compares installed version (from `package.json` or a `VERSION` file) to latest release tag
- [ ] Optional: publish to npm as `@rizonetech/chromemcp` with `bin` entries for the wrappers
- [ ] Optional: Winget manifest in `winget-pkgs/manifests/r/Rizonetech/ChromeMCP/...`
- [ ] Add a release workflow (`.github/workflows/release.yml`) that builds the tarball on tag push and publishes the GitHub Release
- [ ] Update `README.md` with one-line install instructions

**Acceptance criteria.** `curl -fsSL https://github.com/.../install.sh | bash` works on a fresh WSL2 + Chrome host and produces a working `chromemcp` command.

---

## 🟠 High

### G2. Authentication on the MCP endpoint
**Why it matters.** The MCP server listens on `127.0.0.1:8931` with no auth. Any process on the host (including malicious npm install scripts, sibling containers sharing the loopback, or other users on a shared machine) can drive a fully signed-in Chrome with all your cookies and saved sessions. The current security model is "trust everything that resolves localhost" — fine on a single-user dev box, dangerous on a CI runner, jumpbox, or shared dev VM.

> **Mission note.** Demoted from 🔴 Critical (severity-axis) to 🟠 High (mission-axis): for the single-developer-machine bullseye, this isn't a blocker. It becomes mission-critical the moment ChromeMCP is recommended for shared hosts or CI.

- [ ] Decide auth model: shared bearer token (simplest) | per-client tokens with revocation | mTLS (heaviest)
- [ ] Generate a token at first run: write to `~/.config/chromemcp/token` with `0600` perms
- [ ] Add `--auth-token` flag (or env var `MCP_AUTH_TOKEN`) to `mcp/start.sh` and pass to the MCP CLI
- [ ] Verify: every JSON-RPC request must carry `Authorization: Bearer <token>` header; reject with HTTP 401 otherwise
- [ ] Update `mcp/client-config.json` template to include the header (and document where to read the token from)
- [ ] Update `mcp/test.sh` and `mcp/demo-visible.sh` to read and send the token
- [ ] Add `MCP_NO_AUTH=1` opt-out env var for explicit single-user dev mode (with a warning printed at startup)
- [ ] Document the threat model in `SECURITY.md` (see G13)
- [ ] Ensure token rotation works: deleting `~/.config/chromemcp/token` and restarting regenerates
- [ ] Add a `--print-token` flag to expose the current token for client config

**Acceptance criteria.** A request without a valid token returns HTTP 401; `mcp/test.sh` works only after picking up the token from disk; setting `MCP_NO_AUTH=1` permits unauthenticated access with a loud warning logged on every request.

---

### G3. Process supervision
**Why it matters.** `mcp/start.sh:61-67` spawns the node process with `setsid nohup ... &` — fire-and-forget. If `node` crashes, OOMs, or hits an uncaught exception, no restart happens. The PID file is the only liveness signal, and it lies (it stays even after the process is gone).

- [ ] Decide supervisor: **systemd user unit** (preferred for WSL2/Linux) | `pm2` (cross-platform JS) | NSSM/Windows Service for Windows-side
- [ ] Write `~/.config/systemd/user/chromemcp.service` with: `Restart=on-failure`, `RestartSec=5`, `StartLimitBurst=5`
- [ ] Add `./mcp-enable` script that installs the unit + enables linger (so it survives logout)
- [ ] Add `./mcp-disable` script to unwind cleanly
- [ ] Wire health check: `ExecStartPost=/usr/bin/curl -fsS --max-time 5 http://127.0.0.1:8931/`
- [ ] Update `mcp-up`/`mcp-down` to detect supervised mode and `systemctl --user start/stop chromemcp` instead of running `start.sh` directly
- [ ] Add `./mcp-status` (or `mcp-up status`) that calls `systemctl --user status` for at-a-glance state
- [ ] Document supervisor section in `README.md` with toggle instructions
- [ ] Verify: `kill -9 $(cat mcp/.playwright.pid)` triggers automatic restart within 10s and `systemctl --user status chromemcp` shows recovered state

**Acceptance criteria.** `kill -9` of the node process triggers automatic restart in ≤ 10s; service survives logout; `./mcp-status` reports human-readable health.

---

### G4. Reconnection on Chrome crash / disconnect
**Why it matters.** The MCP server holds a persistent CDP WebSocket to Chrome. When Chrome crashes, restarts, or is closed by the user, the socket dies. Playwright MCP currently does not re-attach; subsequent tool calls return errors until you `./mcp-down && ./mcp-up`.

- [ ] Read Playwright MCP source to determine current reconnect behavior (search for `reconnect`, `disconnected`, `wsEndpoint`)
- [ ] If no auto-reconnect: implement a watchdog inside `mcp/start.sh` that polls CDP `/json/version` every 10s
- [ ] On detected disconnect: log the event, attempt to reattach via the same CDP endpoint (waiting for it to come back up)
- [ ] If CDP unreachable for > 60s: trigger `./chrome` (auto-launch) to recover
- [ ] If reattachment succeeds: clear any stale tab state, log resumed
- [ ] If reattachment fails after 5 attempts: signal supervisor to restart the MCP server (G3)
- [ ] Surface a clear MCP-protocol-level error to clients during the dead window: `{"error": {"code": -32099, "message": "Chrome temporarily unavailable, retry in N seconds"}}`
- [ ] Add `mcp_chrome_reconnects_total` counter (G7)
- [ ] Add an integration test: kill Chrome.exe, verify MCP recovers within 30s of Chrome relaunch

**Acceptance criteria.** Killing Chrome and relaunching it within 30s leaves the MCP server able to handle tool calls without manual restart; reconnect events appear in logs.

---

### G10. Subnet-mask auto-detection (replace hardcoded /20)
**Why it matters.** `launcher/Setup-WSL-Portproxy.ps1:56` hardcodes `/20` as the WSL2 subnet mask:
```powershell
Subnet = ($ip -replace '\.\d+$', '.0') + '/20'
```
Microsoft has changed WSL2's subnet allocation in past Windows updates. If they change the default mask, the firewall rule's `RemoteAddress` becomes wrong and may either over-permit (loose mask) or block legitimate WSL traffic (tight mask).

**User-facing impact.** Users on non-default WSL2 network configs hit silent firewall mismatches at install time. Setup looks like it succeeded but tools fail with cryptic CDP errors. Breaches "easy to install."

- [ ] Replace the hardcoded `/20` in `Get-WslAdapterIP` with detection: read `PrefixLength` from `Get-NetIPAddress -InterfaceIndex $adapter.ifIndex`
- [ ] Compute subnet from IP + actual prefix length (use a helper function, not regex math)
- [ ] If detection fails (for whatever Microsoft reason), fall back to `/20` with a `Write-Warning`
- [ ] Add a Pester (or plain PowerShell) unit test for the subnet computation
- [ ] Verify on multiple WSL2 distros: Ubuntu, Debian, Alpine

**Acceptance criteria.** `Setup-Bridge.cmd` succeeds and produces a correctly-masked firewall rule on hosts where the WSL2 prefix length is anything other than /20.

---

## 🟡 Medium

### G6. Log rotation
**Why it matters.** `mcp/logs/playwright-mcp.log` grows unbounded. A long-running session in CI or on a dev VM will eventually fill the disk.

- [ ] Decide implementation: in-script (rotate inside `start.sh`) | `logrotate` config installed via setup script | systemd journal (free if G3 lands)
- [ ] Implement size-based rotation: when log > 10 MB, rename to `playwright-mcp.log.1`, shift older files to `.2..5`, drop `.6+`
- [ ] Add `MCP_LOG_MAX_MB` env var to override threshold
- [ ] Add `MCP_LOG_KEEP` env var to override retention count (default 5)
- [ ] Test by writing 20 MB of synthetic data; verify rotation happens cleanly
- [ ] Document log location and rotation policy in `README.md`
- [ ] Add `mcp-logs` helper that tails or greps the active log + recent rotated copies

**Acceptance criteria.** Total log directory size stays ≤ 50 MB regardless of uptime; rotation occurs without service interruption; old logs are recoverable for at least the most recent 5 cycles.

---

### G7. Structured logging + metrics
**Why it matters.** Single text log with no levels, no JSON, no counters. Hard to alert on, hard to grep at scale, impossible to graph SLIs.

#### Structured logging
- [ ] Wrap node stdout/stderr with a small Node script that timestamps and JSON-formats each line: `{ts, level, msg, source}`
- [ ] OR: contribute a `--log-format=json` flag upstream to `@playwright/mcp` if it doesn't exist
- [ ] Standardize log levels: `DEBUG`, `INFO`, `WARN`, `ERROR`
- [ ] Add `MCP_LOG_LEVEL` env var (default `INFO`)
- [ ] Switch local-dev tooling (`mcp/test.sh`, `mcp/demo-visible.sh`) to read JSON logs

#### Metrics
- [ ] Expose `/metrics` endpoint with Prometheus text format (separate port, e.g. 8932)
- [ ] Implement counters:
  - `mcp_tool_calls_total{tool="..."}`
  - `mcp_tool_errors_total{tool="...",code="..."}`
  - `mcp_chrome_reconnects_total`
  - `mcp_session_starts_total`
- [ ] Implement histograms:
  - `mcp_tool_duration_seconds{tool="..."}`
  - `mcp_chrome_cdp_latency_seconds`
- [ ] Implement gauges:
  - `mcp_active_sessions`
  - `mcp_chrome_tabs_open`
- [ ] Add a sample Grafana dashboard JSON in `docs/grafana-dashboard.json`
- [ ] Document metric semantics in `docs/METRICS.md`

**Acceptance criteria.** `curl http://127.0.0.1:8932/metrics` returns parseable Prometheus text; tool calls increment the counters; importing the sample dashboard into Grafana renders panels with non-zero data.

---

### G8. Regression test suite
**Why it matters.** `mcp/test.sh` covers `initialize` + `browser_tabs(list)` + `browser_snapshot` only. It does not exercise `browser_click`, `browser_navigate`, `browser_take_screenshot`, `browser_evaluate`, file uploads, drag-drop, console reading, or network interception. A regression in any of those silently breaks downstream consumers.

- [ ] Create `mcp/tests/` directory structure
- [ ] Build a shared test harness: `mcp/tests/_harness.py` (shared init/teardown, session helpers)
- [ ] Write per-feature smoke tests:
  - [ ] `tests/test_tabs.sh` — list, new, activate, close
  - [ ] `tests/test_navigate.sh` — `browser_navigate` to multiple URLs
  - [ ] `tests/test_click.sh` — load fixture page, click button, assert state changed
  - [ ] `tests/test_screenshot.sh` — full-page + viewport-only, byte-size sanity
  - [ ] `tests/test_evaluate.sh` — `browser_evaluate` returning a primitive and an object
  - [ ] `tests/test_console.sh` — emit `console.log` from page, assert captured
  - [ ] `tests/test_network.sh` — capture a network request, assert URL/status
  - [ ] `tests/test_snapshot.sh` — accessibility tree shape sanity
  - [ ] `tests/test_select.sh` — `browser_select_option`
  - [ ] `tests/test_type.sh` — `browser_type` into an input
- [ ] Build `mcp/tests/run-all.sh` — runs the suite, reports pass/fail count, exits non-zero on any failure
- [ ] Use a local fixture page (`mcp/tests/fixtures/`) with deterministic content rather than depending on external sites
- [ ] Add GitHub Actions workflow (`.github/workflows/smoke.yml`) that boots Chrome on the runner and runs the suite on every PR
- [ ] Track coverage informally: list each MCP tool surface and tick which has at least one test
- [ ] Target: ≥ 80% of advertised MCP tool surface covered by at least one test case

**Acceptance criteria.** `bash mcp/tests/run-all.sh` exits 0 on a healthy stack; the GitHub Actions workflow runs green on each push to `main`; a coverage table in the repo lists tested vs. untested MCP tools.

---

### G9. Chrome version pinning + upgrade testing
**Why it matters.** Chrome auto-updates on Windows. A breaking CDP change (rare but documented in Chrome's protocol changelogs) could silently break the stack between two `chrome.exe` releases.

- [ ] Document the **minimum supported Chrome major version** in `README.md`
- [ ] Document the **last verified-working Chrome version** (currently 147.0.7727.138) in `CHANGELOG.md`
- [ ] In `mcp/start.sh`: query CDP `/json/version`, parse `Browser` field, warn (do not fail) if outside known-good range
- [ ] Document Chrome Enterprise policy registry snippets in `docs/chrome-pinning.md` (`UpdatesSuppressedDurationMin`, `UpdatesSuppressedStartTime`, `TargetVersionPrefix`)
- [ ] Subscribe to https://chromereleases.googleblog.com/ (or the equivalent feed) for release notice
- [ ] Add a CI nightly job that runs the smoke suite against latest stable Chrome on a Windows runner
- [ ] On Chrome breakage: open a tracking issue with the breaking change documented

**Acceptance criteria.** `./mcp-up` prints supported Chrome range and current Chrome version; mismatch shows a yellow warning but doesn't fail; `docs/chrome-pinning.md` has registry / policy snippets that work on Chrome Enterprise.

---

## 🟡 Medium-Low

### G12. Multi-user / multi-profile story (or explicit non-support)
**Why it matters.** One Chrome profile, one MCP server, one bridge per machine. Two devs sharing a Windows host (rare but real) cannot isolate their sessions.

- [ ] Decide scope: keep single-user and **document loudly in `README.md`** | implement multi-profile support
- [ ] If single-user (recommended): add explicit "single-user only" callout to README and `SECURITY.md`
- [ ] If multi-profile:
  - [ ] Parameterize CDP port (default 9222), MCP port (default 8931), and profile dir name via `--profile <name>`
  - [ ] Each profile gets its own bridge entry on its own port
  - [ ] Each profile gets its own MCP server on its own port
  - [ ] Add `chromemcp init <name>` to scaffold a profile + free port range
  - [ ] Update `mcp/client-config.json` template to use the named profile's port
  - [ ] Document multi-profile pattern in README

**Acceptance criteria.** Either: README has a clear "single-user only by design" section, OR two named profiles run side-by-side without conflict on the same host.

---

### G13. SECURITY.md + threat model
**Why it matters.** GitHub auto-prompts for security disclosures via `SECURITY.md`. Without one, researchers have no path to report a CDP-attach or Playwright-MCP vulnerability that affects this stack.

- [ ] Create `SECURITY.md` with:
  - [ ] Supported versions table (latest minor, etc.)
  - [ ] Reporting channel: dedicated email (`security@rizonetech.com`) and/or GitHub Private Vulnerability Reporting
  - [ ] Expected response time (e.g. "acknowledge within 5 business days, fix within 30 days for critical")
  - [ ] Coordinated disclosure preference: 90-day default
  - [ ] Out-of-scope items (e.g. "Chrome bugs themselves — report to Google")
- [ ] Document the **threat model** explicitly:
  - [ ] CDP gives full Chrome control (read/write all cookies, navigate to anywhere, exfiltrate cleartext data, install extensions)
  - [ ] The MCP endpoint at `localhost:8931` inherits CDP's full power
  - [ ] Without auth (G2 unmerged), any process on the host can drive the browser
  - [ ] The bridge exposes CDP to all of WSL — assume the WSL distro is single-tenant
  - [ ] Recommended: do NOT run on shared dev VMs / CI runners until G2 lands
- [ ] Enable GitHub's Private Vulnerability Reporting in repo Settings → Code security
- [ ] Link `SECURITY.md` from `README.md`
- [ ] Add a security FAQ section: "Why localhost-only?", "What if I'm on a multi-user host?"

**Acceptance criteria.** `SECURITY.md` exists at the repo root; GitHub repo "Security" tab is populated with the policy; Private Vulnerability Reporting is enabled.

---

## 🟢 Low

### G14. CONTRIBUTING.md + Code of Conduct + Issue/PR templates
**Why it matters.** Cosmetic for OSS hygiene; signals "this is a real project" to first-time contributors. Cheap to add.

- [ ] Create `CONTRIBUTING.md`:
  - [ ] Dev setup steps (matches `README.md` quick start)
  - [ ] How to run smoke tests
  - [ ] Commit message style (currently informal — pick one: Conventional Commits, or "imperative mood, ≤ 72 chars")
  - [ ] PR conventions (link to issue, include test plan, etc.)
  - [ ] Coding style references (link to G15 lint rules)
- [ ] Create `CODE_OF_CONDUCT.md` — adopt Contributor Covenant 2.1 verbatim
- [ ] Add `.github/ISSUE_TEMPLATE/bug_report.md` with the WSL/Windows/Chrome version fields pre-filled
- [ ] Add `.github/ISSUE_TEMPLATE/feature_request.md`
- [ ] Add `.github/PULL_REQUEST_TEMPLATE.md` with checklist (tests pass, README updated if user-facing, CHANGELOG entry if behavior change)
- [ ] Link from `README.md` in a "Contributing" section near the bottom

**Acceptance criteria.** Files exist, render correctly on GitHub, first new issue uses the template.

---

### G15. Lint / format CI
**Why it matters.** Code quality currently kept entirely by the author's discipline. A first contributor PR introducing a bashism, an unquoted variable expansion, or a malformed PowerShell parameter goes uncaught.

- [ ] Add `shellcheck` to a GitHub Actions workflow on PRs touching `*.sh` or wrapper scripts
- [ ] Add `PSScriptAnalyzer` to a GitHub Actions workflow on PRs touching `*.ps1` or `*.cmd`
- [ ] Add `prettier` (or `biome`) for `*.json` and `*.md` formatting
- [ ] Add a top-level `Makefile` (or `npm run lint`) target: `make lint` runs all of the above locally
- [ ] Add pre-commit hook templates in `.githooks/` and document `git config core.hooksPath`
- [ ] Configure GitHub branch protection on `main`: require lint + smoke tests to pass before merge
- [ ] Optional: add `markdownlint-cli2` for stricter README/docs hygiene

**Acceptance criteria.** A PR introducing `if [ $foo == bar ]` (unquoted, wrong operator) fails CI; a PR introducing a real fix passes.

---

## Roadmap: Install-and-forget release (the bullseye)

Ship gate: every box below checked. This is the milestone that delivers on the mission — `git clone` → one script → working stack that survives a Windows reboot.

- [ ] **G11** — one-line installer covering both Windows-side bridge setup and WSL-side MCP install
- [ ] **G5** — IP-drift auto-heal in `mcp-up` (cheap version: re-run `setup-bridge` if stage-2 trigger fires after Chrome auto-launch)
- [ ] **G10** — subnet auto-detection in `Setup-WSL-Portproxy.ps1`
- [ ] **G1** — pin to stable `@playwright/mcp` so today's install still works in 3 months
- [ ] **G3 (lite)** — at minimum: PID file truthfulness + `./mcp-status` that doesn't lie
- [ ] **G4 (lite)** — detect Chrome disconnect, surface clear error, don't silently zombie
- [ ] **First-run smoke test.** Fresh `git clone` on a clean Windows + WSL2 VM → run the installer → `./mcp-up` → at least one MCP tool call succeeds, without consulting any docs beyond the README quick-start.

**Implicit deliverables.** README quick-start is genuinely one screen long; the installer prints a clear next-step when it finishes; failure modes surface human-readable errors, not stack traces.

---

## Roadmap: v1.0 OSS release (builds on install-and-forget)

Ship gate: install-and-forget release **plus** every box below.

- [ ] **G6** — log rotation in `start.sh` (10 MB threshold, keep 5)
- [ ] **G13** — `SECURITY.md` + threat-model section
- [ ] **G14** — `CONTRIBUTING.md`, `CODE_OF_CONDUCT.md`, issue/PR templates
- [ ] **G15** — minimal CI: shellcheck + PSScriptAnalyzer on PRs
- [ ] **G8 (lite)** — second smoke test covering at minimum `browser_click` + `browser_navigate`
- [ ] `CHANGELOG.md` exists with entries from `0.0.1` to `0.1.0`
- [ ] `package.json` `"version"` bumped to `0.1.0`, git tag `v0.1.0` pushed
- [ ] GitHub Release published with release notes

**Implicit deliverables.** Updated README quick-start to note `SECURITY.md`; OSS hygiene files linked from README; a green CI badge in README.

---

## Roadmap: production service (expensive path, ~2-4 weeks)

Ship gate: everything from v1.0 release **plus** every box below.

- [ ] **G2** — bearer-token auth on the MCP endpoint, with `MCP_NO_AUTH` opt-out
- [ ] **G3 (full)** — systemd user unit (or NSSM service for Windows-side) with `Restart=on-failure`
- [ ] **G4 (full)** — Chrome-disconnect detection + auto-reattach + supervisor-driven restart fallback
- [ ] **G7 (full)** — JSON structured logs + Prometheus `/metrics` endpoint + sample Grafana dashboard
- [ ] **G8 (full)** — regression suite covering ≥ 80% of MCP tool surface; CI green on every push
- [ ] **G9** — Chrome version range documented; pinning policy docs published; nightly CI against latest stable Chrome
- [ ] Per-client session isolation: either expose an isolation primitive in the MCP tool surface, or **explicitly document the contention model** in README (currently `--shared-browser-context` allows races)
- [ ] **Canary tab.** Periodic (every 5 min) `browser_tabs(new)` → `https://example.com` → `browser_take_screenshot` → tab close. Emit success/failure as a metric for "stack alive AND Chrome responsive."
- [ ] **Audit log.** Every `tools/call` recorded with `{ts, tool, args_hash, caller_token_id, duration_ms, error_code}`. Append-only, separate file from runtime log, retention ≥ 90 days.

**Implicit deliverables.** Updated README with production-deployment section; runbook (`docs/runbook.md`) covering common failure modes (Chrome crash, bridge drift, token rotation, cert expiry if mTLS); SLO doc declaring availability and latency targets.

---

## What ChromeMCP isn't going to be (and that's fine)

These are **not** on any roadmap — listing them so scope creep gets called out early.

- A multi-tenant SaaS product. The "your signed-in Chrome" model is fundamentally per-developer-machine.
- A drop-in replacement for headless Playwright in CI. Different shape, different goals.
- An "enterprise" product without significant scope expansion (RBAC, secrets management, compliance attestations, support contracts).
- A cross-platform tool for native macOS or native Linux desktops. WSL2 + Windows is the explicit target; portability would require redesigning the bridge layer.

---

## Notes / changelog

- 2026-05-07 — initial roadmap drafted from the readiness audit. Status: 0/15 gaps closed.
- 2026-05-18 — added mission statement; re-prioritized severities against the mission axis (G11 🟢→🔴, G5 🟠→🔴, G10 🟡→🟠, G2 🔴→🟠); inserted "Install-and-forget release" as the first roadmap milestone ahead of v1.0 OSS.
