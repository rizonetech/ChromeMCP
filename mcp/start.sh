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
if ! curl -s --max-time 2 "${CDP_ENDPOINT}/json/version" -o /dev/null; then
  echo "ERROR: Chrome CDP not reachable at ${CDP_ENDPOINT}" >&2
  echo "  Run from project root: ${PROJECT_ROOT}" >&2
  echo "    ./chrome           # launch Chrome with --remote-debugging-port=9222" >&2
  echo "    ./setup-bridge     # one-time, makes 9222 reachable from WSL" >&2
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
