#!/usr/bin/env bash
# Install the local ChromeMCP Codex marketplace/plugin entries.
#
# This intentionally performs a conservative append. If an entry already exists,
# it leaves the config alone so it never trashes a user's Codex configuration.
set -euo pipefail

ROOT="$(cd "$(dirname "$(readlink -f "$0")")/.." && pwd)"

if ! command -v wslpath >/dev/null 2>&1; then
  echo "ERROR: install-codex-plugin.sh must run inside WSL for this repository layout." >&2
  exit 1
fi

WIN_ROOT="$(wslpath -w "$ROOT")"
if [[ "$WIN_ROOT" == \\\\wsl.localhost\\* ]]; then
  WIN_ROOT="\\\\?\\UNC\\${WIN_ROOT#\\\\}"
fi

if [ -n "${CODEX_CONFIG:-}" ]; then
  CONFIG="$CODEX_CONFIG"
elif [ -n "${USERPROFILE:-}" ] && [ -d "$(wslpath -u "$USERPROFILE" 2>/dev/null || true)" ]; then
  CONFIG="$(wslpath -u "$USERPROFILE")/.codex/config.toml"
else
  WIN_USERPROFILE="$(
    powershell.exe -NoProfile -Command '[Console]::OutputEncoding=[Text.Encoding]::UTF8; $env:USERPROFILE' 2>/dev/null \
      | tr -d '\r' \
      | tail -n 1
  )"
  if [ -z "$WIN_USERPROFILE" ]; then
    echo "ERROR: Could not resolve the Windows user profile for Codex config." >&2
    exit 1
  fi
  CONFIG="$(wslpath -u "$WIN_USERPROFILE")/.codex/config.toml"
fi

mkdir -p "$(dirname "$CONFIG")"
touch "$CONFIG"

if grep -q '^\[marketplaces\.chromemcp-local\]' "$CONFIG" || \
   grep -q '^\[plugins\."chromemcp-browser@chromemcp-local"\]' "$CONFIG"; then
  echo "ChromeMCP Codex plugin entries already exist in:"
  echo "  $CONFIG"
  echo "Leaving the file unchanged. Update the source manually if this clone moved:"
  echo "  $WIN_ROOT"
  exit 0
fi

cat >> "$CONFIG" <<EOF

# ChromeMCP local Codex marketplace.
[marketplaces.chromemcp-local]
source_type = "local"
source = '$WIN_ROOT'

[plugins."chromemcp-browser@chromemcp-local"]
enabled = true
EOF

echo "Installed ChromeMCP Codex plugin entries in:"
echo "  $CONFIG"
echo
echo "Next:"
echo "  1. Restart Codex."
echo "  2. Start ChromeMCP: $ROOT/mcp-up"
echo "  3. Verify it:       bash $ROOT/mcp/test.sh"

