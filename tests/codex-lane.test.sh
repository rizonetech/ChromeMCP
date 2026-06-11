#!/usr/bin/env bash
# Tests for codex-lane allocation. Run: bash tests/codex-lane.test.sh
set -u

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
LANE_BIN="$ROOT/codex-lane"
PASS=0
FAIL=0

fail() { echo "FAIL: $1"; FAIL=$((FAIL + 1)); }
pass() { echo "ok:   $1"; PASS=$((PASS + 1)); }

# Each test gets a fresh state dir.
new_state() {
  STATE="$(mktemp -d)"
  export CODEX_CHROMEMCP_LANE_STATE_DIR="$STATE"
}

# Create a lock the way cmd_acquire does.
make_lock() {
  local lane="$1" pid="$2" host="$3"
  mkdir -p "$STATE/lane-$lane.lock"
  {
    printf 'lane=%s\n' "$lane"
    printf 'owner=test\n'
    printf 'pid=%s\n' "$pid"
    printf 'created_at=2026-06-11T00:00:00Z\n'
    printf 'host=%s\n' "$host"
  } > "$STATE/lane-$lane.lock/meta"
}

# Find a PID that is certainly dead.
dead_pid() {
  local p
  for p in $(seq 99999 -1 90000); do
    if ! kill -0 "$p" 2>/dev/null; then printf '%s\n' "$p"; return 0; fi
  done
  return 1
}

HOST="$(hostname)"
DEAD="$(dead_pid)"

# --- T1: --max above the default validate ceiling searches the full range ---
new_state
for n in $(seq 1 9); do make_lock "$n" "$$" "$HOST"; done
out="$("$LANE_BIN" acquire --max 12 --format plain 2>&1)"; rc=$?
if [ "$rc" -eq 0 ] && [[ "$out" == lane=10\ * ]]; then
  pass "acquire --max 12 grants lane 10 when 1-9 are locked"
else
  fail "acquire --max 12 should grant lane 10, got rc=$rc out=$out"
fi
rm -rf "$STATE"

# --- T2: exhausted range reports 'no free' with exit 75 ---
new_state
for n in 1 2 3 4; do make_lock "$n" "$$" "$HOST"; done
out="$("$LANE_BIN" acquire 2>&1)"; rc=$?
if [ "$rc" -eq 75 ] && [[ "$out" == *"no free"* ]]; then
  pass "exhausted range exits 75 with 'no free' message"
else
  fail "exhausted range: expected rc=75 + 'no free', got rc=$rc out=$out"
fi
rm -rf "$STATE"

# --- T3: stale lock (dead pid, same host) is reclaimed ---
new_state
make_lock 1 "$DEAD" "$HOST"
out="$("$LANE_BIN" acquire --format plain 2>&1)"; rc=$?
if [ "$rc" -eq 0 ] && [[ "$out" == *"lane=1 mcp="* ]]; then
  pass "stale lock (dead pid) is reclaimed"
else
  fail "stale lock should be reclaimed as lane 1, got rc=$rc out=$out"
fi
rm -rf "$STATE"

# --- T4: live lock (running pid, same host) is NOT reclaimed ---
new_state
make_lock 1 "$$" "$HOST"
out="$("$LANE_BIN" acquire --format plain 2>&1)"; rc=$?
if [ "$rc" -eq 0 ] && [[ "$out" == lane=2\ * ]]; then
  pass "live lock is respected; next lane granted"
else
  fail "live lock: expected lane 2, got rc=$rc out=$out"
fi
rm -rf "$STATE"

# --- T5: dead-pid lock from another host is NOT reclaimed ---
new_state
make_lock 1 "$DEAD" "definitely-not-this-host"
out="$("$LANE_BIN" acquire --format plain 2>&1)"; rc=$?
if [ "$rc" -eq 0 ] && [[ "$out" == lane=2\ * ]]; then
  pass "foreign-host lock is respected; next lane granted"
else
  fail "foreign-host lock: expected lane 2, got rc=$rc out=$out"
fi
rm -rf "$STATE"

# --- T6: 'config' emits a client config with the lane's real port ---
new_state
out="$("$LANE_BIN" config 3 2>&1)"; rc=$?
if [ "$rc" -eq 0 ] && [[ "$out" == *"http://localhost:8961/mcp"* ]] \
   && [[ "$out" == *"mcpServers"* ]] && [[ "$out" == *"chromemcp-codex-3/token"* ]]; then
  pass "config 3 emits client JSON for port 8961 with lane-3 token path"
else
  fail "config 3: expected lane-3 client JSON, got rc=$rc out=$out"
fi
rm -rf "$STATE"

# --- T7: status marks a stale lock ---
new_state
make_lock 2 "$DEAD" "$HOST"
out="$("$LANE_BIN" status 2>&1)"; rc=$?
if [ "$rc" -eq 0 ] && [[ "$out" == *"lane 2: stale"* ]]; then
  pass "status reports stale lock on lane 2"
else
  fail "status stale: expected 'lane 2: stale', got rc=$rc out=$out"
fi
rm -rf "$STATE"

# --- T8: wrappers reject a non-numeric, non-flag lane argument ---
out="$("$ROOT/mcp-status-codex" notalane 2>&1)"; rc=$?
if [ "$rc" -eq 64 ] && [[ "$out" == *"ERROR"* ]] && [[ "$out" == *"notalane"* ]]; then
  pass "mcp-status-codex rejects 'notalane' with exit 64"
else
  fail "wrapper invalid lane: expected rc=64 ERROR mentioning 'notalane', got rc=$rc"
fi

echo
echo "passed=$PASS failed=$FAIL"
[ "$FAIL" -eq 0 ]
