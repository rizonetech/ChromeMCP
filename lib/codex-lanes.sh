#!/usr/bin/env bash
# Shared Codex lane helpers.

codex_lane_default() {
  printf '%s\n' "${CODEX_CHROMEMCP_LANE:-1}"
}

codex_lane_validate() {
  local lane="$1"
  if ! [[ "$lane" =~ ^[1-9][0-9]*$ ]]; then
    echo "ERROR: Codex lane must be a positive integer, got: $lane" >&2
    return 64
  fi
  if [ "$lane" -gt "${CODEX_CHROMEMCP_MAX_LANE:-9}" ]; then
    echo "ERROR: Codex lane $lane exceeds CODEX_CHROMEMCP_MAX_LANE=${CODEX_CHROMEMCP_MAX_LANE:-9}" >&2
    return 64
  fi
}

# Resolve the lane from a wrapper's first positional argument.
# Empty or flag-like ("-...") args fall back to the default lane (the caller
# passes them through to the downstream script); anything else must be a
# positive integer or we fail loudly instead of silently using lane 1.
codex_lane_from_arg() {
  local arg="${1-}"
  if [ -z "$arg" ] || [[ "$arg" == -* ]]; then
    codex_lane_default
    return 0
  fi
  if [[ "$arg" =~ ^[1-9][0-9]*$ ]]; then
    printf '%s\n' "$arg"
    return 0
  fi
  echo "ERROR: Codex lane must be a positive integer, got: $arg" >&2
  return 64
}

codex_lane_suffix() {
  local lane="$1"
  if [ "$lane" = "1" ]; then
    printf 'codex\n'
  else
    printf 'codex-%s\n' "$lane"
  fi
}

codex_lane_profile_name() {
  local lane="$1"
  if [ "$lane" = "1" ]; then
    printf 'ChromeMCP-Codex\n'
  else
    printf 'ChromeMCP-Codex-%s\n' "$lane"
  fi
}

codex_lane_mcp_port() {
  local lane="$1"
  printf '%s\n' $((8931 + lane * 10))
}

codex_lane_upstream_port() {
  local lane="$1"
  printf '%s\n' $((8932 + lane * 10))
}

codex_lane_cdp_port() {
  local lane="$1"
  printf '%s\n' $((9222 + lane * 10))
}

codex_lane_token_path() {
  local lane="$1"
  local suffix
  suffix="$(codex_lane_suffix "$lane")"
  printf '%s/chromemcp-%s/token\n' "${XDG_CONFIG_HOME:-$HOME/.config}" "$suffix"
}

codex_lane_apply_runtime() {
  local lane="$1"
  local root="$2"
  codex_lane_validate "$lane"

  local suffix profile
  suffix="$(codex_lane_suffix "$lane")"
  profile="$(codex_lane_profile_name "$lane")"

  export CODEX_CHROMEMCP_LANE="$lane"
  export HOST="${HOST:-127.0.0.1}"
  export PORT="$(codex_lane_mcp_port "$lane")"
  export UPSTREAM_PORT="$(codex_lane_upstream_port "$lane")"
  export CDP_PORT="$(codex_lane_cdp_port "$lane")"
  export MCP_CHROME_PROFILE_NAME="$profile"
  export MCP_TOKEN_PATH="$(codex_lane_token_path "$lane")"
  export MCP_PID_FILE="$root/mcp/.playwright-${suffix}.pid"
  export MCP_LOG_FILE="$root/mcp/logs/playwright-mcp-${suffix}.log"
  export MCP_LOGROTATE_PID_FILE="$root/mcp/.logrotate-${suffix}.pid"
  export MCP_FOCUS_CHROME_SCRIPT="$root/launcher/Focus-Chrome-Codex.ps1"
  export MCP_STOP_COMMAND="$root/mcp-down-codex $lane"
  export MCP_CLIENT_CONFIG_HINT="mcp/client-config-codex.json (lane $lane: http://127.0.0.1:${PORT}/mcp)"
  export CHROMEMCP_FOCUS_PORT="$CDP_PORT"
  export CHROMEMCP_FOCUS_PROFILE_NAME="$profile"
}

codex_lane_print_shell() {
  local lane="$1"
  codex_lane_validate "$lane"

  local suffix profile mcp_port upstream_port cdp_port token_path
  suffix="$(codex_lane_suffix "$lane")"
  profile="$(codex_lane_profile_name "$lane")"
  mcp_port="$(codex_lane_mcp_port "$lane")"
  upstream_port="$(codex_lane_upstream_port "$lane")"
  cdp_port="$(codex_lane_cdp_port "$lane")"
  token_path="$(codex_lane_token_path "$lane")"

  printf 'export CODEX_CHROMEMCP_LANE=%q\n' "$lane"
  printf 'export MCP_URL=%q\n' "http://127.0.0.1:${mcp_port}/mcp"
  printf 'export MCP_TOKEN_PATH=%q\n' "$token_path"
  printf 'export PORT=%q\n' "$mcp_port"
  printf 'export UPSTREAM_PORT=%q\n' "$upstream_port"
  printf 'export CDP_PORT=%q\n' "$cdp_port"
  printf 'export MCP_CHROME_PROFILE_NAME=%q\n' "$profile"
  printf 'export CHROMEMCP_CODEX_LANE_SUFFIX=%q\n' "$suffix"
}

codex_lane_print_json() {
  local lane="$1"
  codex_lane_validate "$lane"
  python3 - "$lane" "$(codex_lane_mcp_port "$lane")" "$(codex_lane_upstream_port "$lane")" \
    "$(codex_lane_cdp_port "$lane")" "$(codex_lane_profile_name "$lane")" \
    "$(codex_lane_token_path "$lane")" <<'PY'
import json
import sys
lane, mcp, upstream, cdp, profile, token = sys.argv[1:]
print(json.dumps({
    "lane": int(lane),
    "mcp_url": f"http://127.0.0.1:{mcp}/mcp",
    "mcp_port": int(mcp),
    "upstream_port": int(upstream),
    "cdp_port": int(cdp),
    "profile_name": profile,
    "token_path": token,
}, sort_keys=True))
PY
}
