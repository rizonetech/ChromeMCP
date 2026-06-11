#!/usr/bin/env bash
# Back-compat shim: Codex lane helpers, now delegating to the client-
# generalized lib/lanes.sh. Source this from codex-* wrappers.

# shellcheck source=lib/lanes.sh
. "$(dirname "${BASH_SOURCE[0]}")/lanes.sh"

codex_lane_default() { lane_default codex; }

codex_lane_validate() { lane_validate codex "$1"; }

codex_lane_from_arg() { lane_from_arg "${1-}" codex; }

codex_lane_suffix() { lane_suffix codex "$1"; }

codex_lane_profile_name() { lane_profile_name codex "$1"; }

codex_lane_mcp_port() { lane_mcp_port codex "$1"; }

codex_lane_upstream_port() { lane_upstream_port codex "$1"; }

codex_lane_cdp_port() { lane_cdp_port codex "$1"; }

codex_lane_token_path() { lane_token_path codex "$1"; }

codex_lane_apply_runtime() { lane_apply_runtime codex "$1" "$2"; }

codex_lane_print_shell() { lane_print_shell codex "$1"; }

codex_lane_print_json() { lane_print_json codex "$1"; }
