#!/usr/bin/env bash
# Starts Playwright MCP as a long-running HTTP/SSE service against the
# project's bridged Chrome. Idempotent: re-running while already up is a no-op.
#
# Env overrides:
#   PORT          (default 8931)  - port the MCP server listens on
#   HOST          (default 127.0.0.1) - bind interface
#   CDP_ENDPOINT  (auto)          - upstream Chrome CDP URL (defaults to
#                                   http://<wsl-gateway>:9222 via the bridge)
set -euo pipefail

cd "$(dirname "$(readlink -f "$0")")"
PROJECT_ROOT="$(dirname "$(pwd)")"

PORT="${PORT:-8931}"
HOST="${HOST:-127.0.0.1}"

# Default CDP endpoint = bridged Chrome at WSL gateway IP.
if [ -z "${CDP_ENDPOINT:-}" ]; then
  WSLGW="$(ip route show | awk '/^default/ {print $3}')"
  CDP_ENDPOINT="http://${WSLGW}:9222"
fi

PID_FILE="$(pwd)/.playwright.pid"
LOG_FILE="$(pwd)/logs/playwright-mcp.log"
MCP_URL="http://${HOST}:${PORT}/mcp"

find_windows_exe() {
  local name="$1"
  local found
  found="$(command -v "$name" 2>/dev/null || true)"
  if [ -n "$found" ]; then
    printf '%s\n' "$found"
    return 0
  fi

  case "$name" in
    powershell.exe)
      for candidate in \
        /mnt/c/Windows/System32/WindowsPowerShell/v1.0/powershell.exe \
        /mnt/c/WINDOWS/System32/WindowsPowerShell/v1.0/powershell.exe
      do
        [ -x "$candidate" ] && printf '%s\n' "$candidate" && return 0
      done
      ;;
    cmd.exe)
      for candidate in \
        /mnt/c/Windows/System32/cmd.exe \
        /mnt/c/WINDOWS/System32/cmd.exe
      do
        [ -x "$candidate" ] && printf '%s\n' "$candidate" && return 0
      done
      ;;
  esac

  return 1
}

# --- Idempotency: if already running, just report and exit. ---------------
if [ -f "$PID_FILE" ] && kill -0 "$(cat "$PID_FILE")" 2>/dev/null; then
  if curl -s --max-time 2 "$MCP_URL" -o /dev/null --head 2>/dev/null \
     || curl -s --max-time 2 "http://${HOST}:${PORT}/" -o /dev/null 2>/dev/null; then
    echo "Playwright MCP already running (PID $(cat "$PID_FILE")) on ${MCP_URL}"
    exit 0
  fi
  echo "Stale PID file found; cleaning up."
  rm -f "$PID_FILE"
fi

# --- Pre-flight: verify upstream CDP is reachable. ------------------------
probe_cdp() {
  curl -s --max-time 4 "${CDP_ENDPOINT}/json/version" -o /dev/null
}

# WSL2 routing to the Windows-side portproxy can occasionally stall a fresh
# TCP connection. Retry a couple of times before declaring CDP unreachable
# so we don't trigger the auto-launch path on a flaky first probe.
initial_probe_cdp() {
  for i in 1 2 3; do
    probe_cdp && return 0
    sleep 0.3
  done
  return 1
}

# If CDP is down, try to auto-launch Chrome on Windows via the PowerShell
# launcher. The launcher is idempotent (no-op if Chrome is already up), so
# this is safe to call speculatively. Skip with MCP_NO_AUTO_CHROME=1.
if ! initial_probe_cdp; then
  POWERSHELL_EXE="$(find_windows_exe powershell.exe || true)"
  if [ -z "${MCP_NO_AUTO_CHROME:-}" ] && [ -n "$POWERSHELL_EXE" ]; then
    LAUNCHER_PS1="$(wslpath -w "${PROJECT_ROOT}/launcher/Launch-Chrome.ps1" 2>/dev/null || true)"
    if [ -n "$LAUNCHER_PS1" ]; then
      echo "Chrome CDP not reachable - auto-launching Chrome on Windows..."
      "$POWERSHELL_EXE" -NoProfile -ExecutionPolicy Bypass -File "$LAUNCHER_PS1" >/dev/null || true
      # Allow a few seconds for the bridge to forward the freshly-started Chrome.
      for i in $(seq 1 15); do
        probe_cdp && break
        sleep 0.5
      done
    fi
  fi
fi

# If CDP is STILL unreachable, the most likely remaining cause is that the
# WSL<->Windows bridge isn't installed. Auto-trigger Setup-Bridge.cmd, which
# self-elevates with a UAC prompt on the Windows desktop. One-time per
# machine. Skip with MCP_NO_AUTO_BRIDGE=1.
if ! probe_cdp; then
  CMD_EXE="$(find_windows_exe cmd.exe || true)"
  if [ -z "${MCP_NO_AUTO_BRIDGE:-}" ] && [ -n "$CMD_EXE" ]; then
    BRIDGE_CMD="$(wslpath -w "${PROJECT_ROOT}/Setup-Bridge.cmd" 2>/dev/null || true)"
    if [ -n "$BRIDGE_CMD" ]; then
      echo "Installing the WSL<->Windows bridge (one-time per machine)..."
      echo "  Approve the UAC prompt on your Windows desktop to continue."
      # The .cmd self-elevates via Start-Process -Verb RunAs and exits fast;
      # the elevated copy keeps running in the background.
      "$CMD_EXE" /c "$BRIDGE_CMD" </dev/null >/dev/null 2>&1 || true
      echo "  Waiting up to 90s for the bridge to come live..."
      for i in $(seq 1 180); do
        probe_cdp && break
        sleep 0.5
      done
    fi
  fi
fi

if ! probe_cdp; then
  echo "ERROR: Chrome CDP not reachable at ${CDP_ENDPOINT}" >&2
  echo "  Auto-launch + auto-bridge attempted; CDP still unreachable." >&2
  echo "  Possible causes:" >&2
  echo "    * UAC denied or timed out (re-run ./mcp-up to retry)" >&2
  echo "    * Chrome failed to start on Windows" >&2
  echo "    * MCP_NO_AUTO_CHROME or MCP_NO_AUTO_BRIDGE is set in the env" >&2
  echo "  Manual fallback from project root ${PROJECT_ROOT}:" >&2
  echo "    ./chrome           # launch Chrome with --remote-debugging-port=9222" >&2
  echo "    ./setup-bridge     # one-time, UAC required, exposes 9222 to WSL" >&2
  exit 1
fi

# --- Install deps if missing (deterministic via package-lock.json). -------
if [ ! -d node_modules ]; then
  echo "Installing MCP server packages (one-time)..."
  npm ci --silent
fi

# --- Launch detached. -----------------------------------------------------
mkdir -p logs
echo "Starting Playwright MCP..."
echo "  upstream CDP : ${CDP_ENDPOINT}"
echo "  listening on : ${MCP_URL}"

# nohup + setsid + & = fully detach, survives this shell exiting.
setsid nohup node node_modules/@playwright/mcp/cli.js \
  --port "$PORT" \
  --host "$HOST" \
  --allowed-hosts "localhost:${PORT},127.0.0.1:${PORT}" \
  --cdp-endpoint "$CDP_ENDPOINT" \
  --shared-browser-context \
  >> "$LOG_FILE" 2>&1 < /dev/null &
echo $! > "$PID_FILE"

# --- Wait for server to come up. ------------------------------------------
for i in $(seq 1 20); do
  if curl -s --max-time 1 "http://${HOST}:${PORT}/" -o /dev/null 2>/dev/null; then
    echo ""
    echo "Playwright MCP ready (PID $(cat "$PID_FILE"))."
    echo "  Endpoint     : ${MCP_URL}"
    echo "  Log          : ${LOG_FILE}"
    echo "  Stop         : ${PROJECT_ROOT}/mcp-down"
    echo ""
    echo "Connect any MCP client by adding the snippet from mcp/client-config.json"
    echo "to its mcp.json (e.g. ~/.claude.json or .mcp.json in your project)."
    exit 0
  fi
  sleep 0.5
done

echo "ERROR: Playwright MCP did not start within 10s. Check ${LOG_FILE}." >&2
tail -20 "$LOG_FILE" >&2 || true
exit 1
