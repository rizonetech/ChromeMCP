#!/usr/bin/env bash
# Shared lane helpers, parameterized by client.
#
# A "lane" is an isolated ChromeMCP stack instance: its own MCP/upstream/CDP
# ports, Windows Chrome profile, token file, and PID/log files. Each client
# (codex, claude, ...) gets its own port band so concurrent runs of different
# clients can never collide; lanes within a band step by +10 per lane.
#
#   client  MCP base  upstream base  CDP base   lane N ports
#   codex   8931      8932           9222       base + N*10
#   claude  8731      8732           9422       base + N*10
#
# The default (shared) stack stays on 8931/8932/9222 and is not a lane.

lane_client_validate() {
  local client="$1"
  case "$client" in
    codex|claude) return 0 ;;
    *)
      echo "ERROR: unknown lane client: $client (expected codex or claude)" >&2
      return 64
      ;;
  esac
}

lane_client_title() {
  case "$1" in
    codex) printf 'Codex\n' ;;
    claude) printf 'Claude\n' ;;
  esac
}

lane_mcp_base() {
  case "$1" in
    codex) printf '8931\n' ;;
    claude) printf '8731\n' ;;
  esac
}

lane_upstream_base() {
  case "$1" in
    codex) printf '8932\n' ;;
    claude) printf '8732\n' ;;
  esac
}

lane_cdp_base() {
  case "$1" in
    codex) printf '9222\n' ;;
    claude) printf '9422\n' ;;
  esac
}

# Max-lane ceiling. The legacy CODEX_CHROMEMCP_MAX_LANE override still wins
# for the codex client.
lane_max() {
  local client="$1"
  if [ "$client" = "codex" ] && [ -n "${CODEX_CHROMEMCP_MAX_LANE:-}" ]; then
    printf '%s\n' "$CODEX_CHROMEMCP_MAX_LANE"
    return 0
  fi
  printf '%s\n' "${CHROMEMCP_MAX_LANE:-9}"
}

# Default lane. The legacy CODEX_CHROMEMCP_LANE override still wins for codex.
lane_default() {
  local client="$1"
  if [ "$client" = "codex" ] && [ -n "${CODEX_CHROMEMCP_LANE:-}" ]; then
    printf '%s\n' "$CODEX_CHROMEMCP_LANE"
    return 0
  fi
  printf '%s\n' "${CHROMEMCP_LANE:-1}"
}

lane_validate() {
  local client="$1" lane="$2"
  lane_client_validate "$client" || return 64
  if ! [[ "$lane" =~ ^[1-9][0-9]*$ ]]; then
    echo "ERROR: lane must be a positive integer, got: $lane" >&2
    return 64
  fi
  local max
  max="$(lane_max "$client")"
  if [ "$lane" -gt "$max" ]; then
    echo "ERROR: $client lane $lane exceeds the max-lane ceiling ($max)" >&2
    return 64
  fi
}

# Resolve the lane from a wrapper's first positional argument.
# Empty or flag-like ("-...") args fall back to the client's default lane;
# anything else must be a positive integer or we fail loudly instead of
# silently using lane 1.
lane_from_arg() {
  local arg="${1-}" client="${2:-codex}"
  if [ -z "$arg" ] || [[ "$arg" == -* ]]; then
    lane_default "$client"
    return 0
  fi
  if [[ "$arg" =~ ^[1-9][0-9]*$ ]]; then
    printf '%s\n' "$arg"
    return 0
  fi
  echo "ERROR: lane must be a positive integer, got: $arg" >&2
  return 64
}

lane_suffix() {
  local client="$1" lane="$2"
  if [ "$lane" = "1" ]; then
    printf '%s\n' "$client"
  else
    printf '%s-%s\n' "$client" "$lane"
  fi
}

lane_profile_name() {
  local client="$1" lane="$2" title
  title="$(lane_client_title "$client")"
  if [ "$lane" = "1" ]; then
    printf 'ChromeMCP-%s\n' "$title"
  else
    printf 'ChromeMCP-%s-%s\n' "$title" "$lane"
  fi
}

lane_mcp_port() {
  printf '%s\n' $(($(lane_mcp_base "$1") + $2 * 10))
}

lane_upstream_port() {
  printf '%s\n' $(($(lane_upstream_base "$1") + $2 * 10))
}

lane_cdp_port() {
  printf '%s\n' $(($(lane_cdp_base "$1") + $2 * 10))
}

lane_token_path() {
  local suffix
  suffix="$(lane_suffix "$1" "$2")"
  printf '%s/chromemcp-%s/token\n' "${XDG_CONFIG_HOME:-$HOME/.config}" "$suffix"
}

# Lock-state directory for a client. The legacy CODEX_CHROMEMCP_LANE_STATE_DIR
# override still wins for codex; the default layout is
# <state>/chromemcp/<client>-lanes (codex's matches its pre-generalization
# path, so existing locks stay valid).
lane_state_dir() {
  local client="$1"
  if [ "$client" = "codex" ] && [ -n "${CODEX_CHROMEMCP_LANE_STATE_DIR:-}" ]; then
    printf '%s\n' "$CODEX_CHROMEMCP_LANE_STATE_DIR"
    return 0
  fi
  printf '%s/%s-lanes\n' \
    "${CHROMEMCP_LANE_STATE_ROOT:-${XDG_STATE_HOME:-$HOME/.local/state}/chromemcp}" \
    "$client"
}

lane_apply_runtime() {
  local client="$1" lane="$2" root="$3"
  lane_validate "$client" "$lane"

  local suffix profile
  suffix="$(lane_suffix "$client" "$lane")"
  profile="$(lane_profile_name "$client" "$lane")"

  export CHROMEMCP_LANE_CLIENT="$client"
  export CHROMEMCP_LANE="$lane"
  if [ "$client" = "codex" ]; then
    export CODEX_CHROMEMCP_LANE="$lane"
  fi
  export HOST="${HOST:-127.0.0.1}"
  export PORT="$(lane_mcp_port "$client" "$lane")"
  export UPSTREAM_PORT="$(lane_upstream_port "$client" "$lane")"
  export CDP_PORT="$(lane_cdp_port "$client" "$lane")"
  export MCP_CHROME_PROFILE_NAME="$profile"
  export MCP_TOKEN_PATH="$(lane_token_path "$client" "$lane")"
  export MCP_PID_FILE="$root/mcp/.playwright-${suffix}.pid"
  export MCP_LOG_FILE="$root/mcp/logs/playwright-mcp-${suffix}.log"
  export MCP_LOGROTATE_PID_FILE="$root/mcp/.logrotate-${suffix}.pid"
  if [ "$client" = "codex" ]; then
    export MCP_FOCUS_CHROME_SCRIPT="$root/launcher/Focus-Chrome-Codex.ps1"
    export MCP_STOP_COMMAND="$root/mcp-down-codex $lane"
    export MCP_CLIENT_CONFIG_HINT="mcp/client-config-codex.json (lane $lane: http://127.0.0.1:${PORT}/mcp)"
  else
    export MCP_FOCUS_CHROME_SCRIPT="$root/launcher/Focus-Chrome.ps1"
    export MCP_STOP_COMMAND="$root/lane down --client $client $lane"
    export MCP_CLIENT_CONFIG_HINT="chromemcp lane config --client $client $lane (http://127.0.0.1:${PORT}/mcp)"
  fi
  export CHROMEMCP_FOCUS_PORT="$CDP_PORT"
  export CHROMEMCP_FOCUS_PROFILE_NAME="$profile"
}

lane_print_shell() {
  local client="$1" lane="$2"
  lane_validate "$client" "$lane"

  local suffix profile mcp_port upstream_port cdp_port token_path
  suffix="$(lane_suffix "$client" "$lane")"
  profile="$(lane_profile_name "$client" "$lane")"
  mcp_port="$(lane_mcp_port "$client" "$lane")"
  upstream_port="$(lane_upstream_port "$client" "$lane")"
  cdp_port="$(lane_cdp_port "$client" "$lane")"
  token_path="$(lane_token_path "$client" "$lane")"

  printf 'export CHROMEMCP_LANE_CLIENT=%q\n' "$client"
  printf 'export CHROMEMCP_LANE=%q\n' "$lane"
  if [ "$client" = "codex" ]; then
    printf 'export CODEX_CHROMEMCP_LANE=%q\n' "$lane"
  fi
  printf 'export MCP_URL=%q\n' "http://127.0.0.1:${mcp_port}/mcp"
  printf 'export MCP_TOKEN_PATH=%q\n' "$token_path"
  printf 'export PORT=%q\n' "$mcp_port"
  printf 'export UPSTREAM_PORT=%q\n' "$upstream_port"
  printf 'export CDP_PORT=%q\n' "$cdp_port"
  printf 'export MCP_CHROME_PROFILE_NAME=%q\n' "$profile"
  printf 'export CHROMEMCP_LANE_SUFFIX=%q\n' "$suffix"
  if [ "$client" = "codex" ]; then
    printf 'export CHROMEMCP_CODEX_LANE_SUFFIX=%q\n' "$suffix"
  fi
}

lane_print_json() {
  local client="$1" lane="$2"
  lane_validate "$client" "$lane"
  python3 - "$client" "$lane" "$(lane_mcp_port "$client" "$lane")" \
    "$(lane_upstream_port "$client" "$lane")" "$(lane_cdp_port "$client" "$lane")" \
    "$(lane_profile_name "$client" "$lane")" "$(lane_token_path "$client" "$lane")" <<'PY'
import json
import sys
client, lane, mcp, upstream, cdp, profile, token = sys.argv[1:]
print(json.dumps({
    "client": client,
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

lane_print_config() {
  local client="$1" lane="$2"
  lane_validate "$client" "$lane"
  python3 - "$client" "$lane" "$(lane_mcp_port "$client" "$lane")" \
    "$(lane_token_path "$client" "$lane")" <<'PY'
import json
import sys
client, lane, mcp, token = sys.argv[1:]
print(json.dumps({
    "_comment": (
        f"ChromeMCP client config for {client} lane {lane}. "
        f"SUBSTITUTE <TOKEN> with the output of "
        f"'MCP_TOKEN_PATH={token} chromemcp token'."
    ),
    "mcpServers": {
        "chromemcp-playwright": {
            "type": "http",
            "url": f"http://localhost:{mcp}/mcp",
            "headers": {"Authorization": "Bearer <TOKEN>"},
        }
    },
}, indent=2))
PY
}
