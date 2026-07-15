#!/usr/bin/env bash
# Tests for the client-generalized lane CLI. Run: bash tests/lane.test.sh
set -u

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
LANE_BIN="$ROOT/lane"
PASS=0
FAIL=0

fail() { echo "FAIL: $1"; FAIL=$((FAIL + 1)); }
pass() { echo "ok:   $1"; PASS=$((PASS + 1)); }

new_state() {
  STATE_ROOT="$(mktemp -d)"
  export CHROMEMCP_LANE_STATE_ROOT="$STATE_ROOT"
  unset CODEX_CHROMEMCP_LANE_STATE_DIR 2>/dev/null || true
}

dead_pid() {
  local p
  for p in $(seq 99999 -1 90000); do
    if ! kill -0 "$p" 2>/dev/null; then printf '%s\n' "$p"; return 0; fi
  done
  return 1
}
DEAD="$(dead_pid)"
HOST="$(hostname)"

# --- T1: claude lane 1 gets the claude port band and identity ---
new_state
out="$("$LANE_BIN" env --client claude 1 --format plain 2>&1)"; rc=$?
if [ "$rc" -eq 0 ] && [[ "$out" == *"8741/mcp"* ]] && [[ "$out" == *"cdp=9432"* ]] \
   && [[ "$out" == *"profile=ChromeMCP-Claude"* ]] && [[ "$out" == *"chromemcp-claude/token"* ]]; then
  pass "claude lane 1 -> MCP 8741, CDP 9432, ChromeMCP-Claude profile"
else
  fail "claude lane 1 env: got rc=$rc out=$out"
fi
rm -rf "$STATE_ROOT"

# --- T2: codex via the generic CLI matches codex-lane exactly ---
new_state
a="$("$LANE_BIN" env --client codex 2 --format plain 2>&1)"
b="$("$ROOT/codex-lane" env 2 --format plain 2>&1)"
if [ -n "$a" ] && [ "$a" = "$b" ]; then
  pass "lane --client codex matches codex-lane output"
else
  fail "codex parity: lane='$a' codex-lane='$b'"
fi
rm -rf "$STATE_ROOT"

# --- T3: claude and codex lane locks are independent ---
new_state
o1="$("$LANE_BIN" acquire --client claude --format plain 2>&1)"; r1=$?
o2="$("$LANE_BIN" acquire --client codex --format plain 2>&1)"; r2=$?
if [ "$r1" -eq 0 ] && [ "$r2" -eq 0 ] && [[ "$o1" == *"lane=1 "* ]] && [[ "$o2" == *"lane=1 "* ]]; then
  pass "claude lane 1 and codex lane 1 coexist (separate state)"
else
  fail "client isolation: claude rc=$r1 '$o1' codex rc=$r2 '$o2'"
fi
rm -rf "$STATE_ROOT"

# --- T4: claude config emits the claude lane's port and token path ---
new_state
out="$("$LANE_BIN" config --client claude 2 2>&1)"; rc=$?
if [ "$rc" -eq 0 ] && [[ "$out" == *"http://localhost:8751/mcp"* ]] \
   && [[ "$out" == *"chromemcp-claude-2/token"* ]]; then
  pass "config --client claude 2 emits port 8751 + lane-2 token path"
else
  fail "claude config: got rc=$rc out=$out"
fi
rm -rf "$STATE_ROOT"

# --- T5: unknown client is rejected ---
new_state
out="$("$LANE_BIN" env --client gemini 1 2>&1)"; rc=$?
if [ "$rc" -eq 64 ] && [[ "$out" == *"ERROR"* ]] && [[ "$out" == *"gemini"* ]]; then
  pass "unknown client 'gemini' rejected with exit 64"
else
  fail "unknown client: expected rc=64 ERROR, got rc=$rc out=$out"
fi
rm -rf "$STATE_ROOT"

# --- T6: stale reclaim works for claude lanes ---
new_state
mkdir -p "$STATE_ROOT/claude-lanes/lane-1.lock"
{
  printf 'lane=1\nowner=test\npid=%s\ncreated_at=2026-06-11T00:00:00Z\nhost=%s\n' "$DEAD" "$HOST"
} > "$STATE_ROOT/claude-lanes/lane-1.lock/meta"
out="$("$LANE_BIN" acquire --client claude --format plain 2>&1)"; rc=$?
if [ "$rc" -eq 0 ] && [[ "$out" == *"lane=1 mcp="* ]]; then
  pass "stale claude lock reclaimed"
else
  fail "claude stale reclaim: got rc=$rc out=$out"
fi
rm -rf "$STATE_ROOT"

# --- T7: Windows-style slash flags default to lane 1 for claude wrappers ---
new_state
out="$(bash -c ". '$ROOT/lib/lanes.sh'; lane_from_arg /refresh claude" 2>&1)"; rc=$?
if [ "$rc" -eq 0 ] && [ "$out" = "1" ]; then
  pass "slash-style flags default to claude lane 1"
else
  fail "claude slash flag lane parse: expected lane 1, got rc=$rc out=$out"
fi
rm -rf "$STATE_ROOT"

echo
echo "passed=$PASS failed=$FAIL"
[ "$FAIL" -eq 0 ]
