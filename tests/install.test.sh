#!/usr/bin/env bash
# Transaction and permission tests for scripts/install.sh.
# Run: bash tests/install.test.sh
set -u

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
INSTALLER="$ROOT/scripts/install.sh"
PASS=0
FAIL=0
CASE_DIRS=()

pass() { echo "ok:   $1"; PASS=$((PASS + 1)); }
fail() { echo "FAIL: $1"; FAIL=$((FAIL + 1)); }

cleanup() {
  local path
  for path in "${CASE_DIRS[@]}"; do
    rm -rf --one-file-system -- "$path"
  done
}
trap cleanup EXIT

new_case() {
  CASE_ROOT="$(mktemp -d -t chromemcp-installer-test-XXXXXX)"
  CASE_DIRS+=("$CASE_ROOT")
  TEST_HOME="$CASE_ROOT/home"
  PREFIX="$TEST_HOME/ChromeMCP"
  BIN_DIR="$TEST_HOME/.local/bin"
  FAKE_BIN="$CASE_ROOT/bin"
  FAKE_LOG="$CASE_ROOT/calls.log"
  SERVICE_STATE="$CASE_ROOT/service.state"
  START_FAILURE_MARKER="$CASE_ROOT/start-failed"
  OUTPUT="$CASE_ROOT/output.log"
  mkdir -p "$PREFIX/mcp/logs" "$BIN_DIR" "$FAKE_BIN"
  printf 'active\n' > "$SERVICE_STATE"
  : > "$FAKE_LOG"

  printf 'old-prefix\n' > "$PREFIX/old-marker"
  printf 'operator log\n' > "$PREFIX/mcp/logs/operator.log"
  printf '#!/usr/bin/env bash\nprintf "old-version\\n"\n' > "$PREFIX/chromemcp"
  chmod 0700 "$PREFIX/chromemcp"
  ln -s "$PREFIX/chromemcp" "$BIN_DIR/chromemcp"

  cat > "$FAKE_BIN/npm" <<'FAKE_NPM'
#!/usr/bin/env bash
printf 'npm-ci %s\n' "$PWD" >> "$FAKE_LOG"
if [ "${FAKE_NPM_FAIL:-0}" = "1" ]; then
  exit 42
fi
mkdir -p node_modules/permission-probe
printf '{}\n' > node_modules/permission-probe/package.json
chmod 0777 node_modules/permission-probe node_modules/permission-probe/package.json
FAKE_NPM

  cat > "$FAKE_BIN/systemctl" <<'FAKE_SYSTEMCTL'
#!/usr/bin/env bash
case " $* " in
  *" is-active "*)
    [ "$(cat "$SERVICE_STATE")" = "active" ]
    ;;
  *" stop "*)
    printf 'stop\n' >> "$FAKE_LOG"
    printf 'inactive\n' > "$SERVICE_STATE"
    ;;
  *" start "*)
    if [ "${FAKE_START_FAIL_ONCE:-0}" = "1" ] && [ ! -e "$START_FAILURE_MARKER" ]; then
      : > "$START_FAILURE_MARKER"
      printf 'start-fail\n' >> "$FAKE_LOG"
      exit 1
    fi
    printf 'start\n' >> "$FAKE_LOG"
    printf 'active\n' > "$SERVICE_STATE"
    ;;
  *" list-unit-files "*)
    exit 0
    ;;
  *)
    printf 'unexpected-systemctl %s\n' "$*" >> "$FAKE_LOG"
    exit 1
    ;;
esac
FAKE_SYSTEMCTL

  cat > "$FAKE_BIN/curl" <<'FAKE_CURL'
#!/usr/bin/env bash
printf 'health\n' >> "$FAKE_LOG"
[ "${FAKE_HEALTH_FAIL:-0}" != "1" ]
FAKE_CURL

  chmod 0700 "$FAKE_BIN/npm" "$FAKE_BIN/systemctl" "$FAKE_BIN/curl"
}

run_installer() {
  env \
    HOME="$TEST_HOME" \
    CHROMEMCP_PREFIX="$PREFIX" \
    CHROMEMCP_BIN_DIR="$BIN_DIR" \
    FAKE_LOG="$FAKE_LOG" \
    SERVICE_STATE="$SERVICE_STATE" \
    START_FAILURE_MARKER="$START_FAILURE_MARKER" \
    FAKE_NPM_FAIL="${FAKE_NPM_FAIL:-0}" \
    FAKE_HEALTH_FAIL="${FAKE_HEALTH_FAIL:-0}" \
    FAKE_START_FAIL_ONCE="${FAKE_START_FAIL_ONCE:-0}" \
    PATH="$FAKE_BIN:$PATH" \
    bash "$INSTALLER" --from-source > "$OUTPUT" 2>&1
}

run_uninstaller() {
  env \
    HOME="$TEST_HOME" \
    CHROMEMCP_PREFIX="$PREFIX" \
    CHROMEMCP_BIN_DIR="$BIN_DIR" \
    FAKE_LOG="$FAKE_LOG" \
    SERVICE_STATE="$SERVICE_STATE" \
    PATH="$FAKE_BIN:$PATH" \
    bash "$INSTALLER" --uninstall > "$OUTPUT" 2>&1
}

no_transaction_debris() {
  ! find "$TEST_HOME" -maxdepth 1 \
    \( -name '.chromemcp-stage.*' -o -name '.chromemcp-backup.*' \) \
    -print -quit | grep -q .
}

# --- T1: successful install hardens permissions and commits cleanly -------
new_case
FAKE_NPM_FAIL=0
FAKE_HEALTH_FAIL=0
if run_installer; then
  npm_line="$(grep -n '^npm-ci ' "$FAKE_LOG" | head -1 | cut -d: -f1)"
  stop_line="$(grep -n '^stop$' "$FAKE_LOG" | head -1 | cut -d: -f1)"
  writable="$(find -P "$PREFIX" \( -type d -o -type f \) -perm /022 -print -quit)"
  if [ "$(stat -c '%a' "$PREFIX")" = "700" ] \
      && [ -z "$writable" ] \
      && [ -f "$PREFIX/mcp/logs/operator.log" ] \
      && [ ! -e "$PREFIX/old-marker" ] \
      && [ "$(readlink "$BIN_DIR/chromemcp")" = "$PREFIX/chromemcp" ] \
      && [ "$(cat "$SERVICE_STATE")" = "active" ] \
      && [ -n "$npm_line" ] && [ -n "$stop_line" ] \
      && [ "$npm_line" -lt "$stop_line" ] \
      && no_transaction_debris; then
    pass "success stages before stop, preserves logs, hardens permissions, and removes backup"
  else
    fail "successful transaction invariants; output=$(tr '\n' ' ' < "$OUTPUT")"
  fi
else
  fail "successful install exited nonzero; output=$(tr '\n' ' ' < "$OUTPUT")"
fi

# --- T2: npm/staging failure never stops or mutates the live install -------
new_case
FAKE_NPM_FAIL=1
FAKE_HEALTH_FAIL=0
if run_installer; then
  fail "pre-stop npm failure unexpectedly succeeded"
elif [ -f "$PREFIX/old-marker" ] \
    && [ "$(cat "$SERVICE_STATE")" = "active" ] \
    && ! grep -q '^stop$' "$FAKE_LOG" \
    && [ "$(readlink "$BIN_DIR/chromemcp")" = "$PREFIX/chromemcp" ] \
    && no_transaction_debris; then
  pass "pre-stop staging failure leaves service and live prefix untouched"
else
  fail "pre-stop staging failure mutated live state; output=$(tr '\n' ' ' < "$OUTPUT")"
fi

# --- T3: post-swap health failure restores prefix, link, and service -------
new_case
FAKE_NPM_FAIL=0
FAKE_HEALTH_FAIL=1
if run_installer; then
  fail "post-swap health failure unexpectedly succeeded"
else
  call_sequence="$(grep -E '^(stop|start|health)$' "$FAKE_LOG" | tr '\n' ' ' | sed 's/ $//')"
  if [ -f "$PREFIX/old-marker" ] \
      && [ -f "$PREFIX/mcp/logs/operator.log" ] \
      && [ "$(cat "$PREFIX/chromemcp")" = $'#!/usr/bin/env bash\nprintf "old-version\\n"' ] \
      && [ "$(readlink "$BIN_DIR/chromemcp")" = "$PREFIX/chromemcp" ] \
      && [ "$(cat "$SERVICE_STATE")" = "active" ] \
      && [ "$call_sequence" = "stop start health stop start" ] \
      && grep -q 'Rollback complete' "$OUTPUT" \
      && no_transaction_debris; then
    pass "post-swap health failure restores prior prefix and restarts prior service"
  else
    fail "health rollback invariants; calls='$call_sequence' output=$(tr '\n' ' ' < "$OUTPUT")"
  fi
fi

# --- T4: post-swap start failure also restores the prior active runtime ----
new_case
FAKE_NPM_FAIL=0
FAKE_HEALTH_FAIL=0
FAKE_START_FAIL_ONCE=1
if run_installer; then
  fail "post-swap service-start failure unexpectedly succeeded"
else
  call_sequence="$(grep -E '^(stop|start|start-fail|health)$' "$FAKE_LOG" | tr '\n' ' ' | sed 's/ $//')"
  if [ -f "$PREFIX/old-marker" ] \
      && [ "$(readlink "$BIN_DIR/chromemcp")" = "$PREFIX/chromemcp" ] \
      && [ "$(cat "$SERVICE_STATE")" = "active" ] \
      && [ "$call_sequence" = "stop start-fail stop start" ] \
      && grep -q 'Rollback complete' "$OUTPUT" \
      && no_transaction_debris; then
    pass "post-swap service-start failure restores prior prefix and service"
  else
    fail "start rollback invariants; calls='$call_sequence' output=$(tr '\n' ' ' < "$OUTPUT")"
  fi
fi
unset FAKE_START_FAIL_ONCE

# --- T5: uninstall refuses a symlinked prefix without touching its target --
new_case
EXTERNAL_PREFIX="$CASE_ROOT/external-prefix"
mv "$PREFIX" "$EXTERNAL_PREFIX"
ln -s "$EXTERNAL_PREFIX" "$PREFIX"
if run_uninstaller; then
  fail "symlinked-prefix uninstall unexpectedly succeeded"
elif [ -L "$PREFIX" ] \
    && [ -f "$EXTERNAL_PREFIX/old-marker" ] \
    && [ -f "$EXTERNAL_PREFIX/mcp/logs/operator.log" ] \
    && grep -q 'unsafe ChromeMCP install prefix' "$OUTPUT"; then
  pass "uninstall refuses a symlinked prefix without deleting its external target"
else
  fail "symlink-prefix safety; output=$(tr '\n' ' ' < "$OUTPUT")"
fi

echo
echo "passed=$PASS failed=$FAIL"
[ "$FAIL" -eq 0 ]
