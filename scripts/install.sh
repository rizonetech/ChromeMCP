#!/usr/bin/env bash
# ChromeMCP installer.
#
# Release install (latest GitHub release):
#   curl -fsSL https://raw.githubusercontent.com/rizonetech/ChromeMCP/main/scripts/install.sh | bash
#
# From a repo checkout (dev / pre-release):
#   bash scripts/install.sh --from-source
#
# Upgrade / uninstall:
#   chromemcp upgrade        (wraps install.sh --upgrade)
#   bash scripts/install.sh --uninstall
#
# Env overrides:
#   CHROMEMCP_PREFIX        install dir (default: $HOME/ChromeMCP)
#   CHROMEMCP_BIN_DIR       directory for the chromemcp symlink
#                           (default: $HOME/.local/bin)
set -euo pipefail
umask 077

REPO_OWNER="${CHROMEMCP_REPO_OWNER:-rizonetech}"
REPO_NAME="${CHROMEMCP_REPO_NAME:-ChromeMCP}"
PREFIX="${CHROMEMCP_PREFIX:-$HOME/ChromeMCP}"
BIN_DIR="${CHROMEMCP_BIN_DIR:-$HOME/.local/bin}"

MODE="install"
WANT_TAG=""
FROM_SOURCE=""

for arg in "$@"; do
  case "$arg" in
    --upgrade)       MODE="upgrade" ;;
    --uninstall)     MODE="uninstall" ;;
    --from-source)   FROM_SOURCE=1 ;;
    --version)       echo "install.sh: --version requires an argument (e.g. --version=v0.1.1)" >&2; exit 64 ;;
    --version=*)     WANT_TAG="${arg#--version=}" ;;
    --prefix=*)      PREFIX="${arg#--prefix=}" ;;
    --bin-dir=*)     BIN_DIR="${arg#--bin-dir=}" ;;
    --help|-h)       sed -n '2,17p' "$0"; exit 0 ;;
    *)               echo "install.sh: unknown arg: $arg" >&2; exit 64 ;;
  esac
done

# --- Prerequisite checks ---------------------------------------------------
require_cmd() {
  if ! command -v "$1" >/dev/null 2>&1; then
    echo "ERROR: missing prerequisite: $1" >&2
    echo "  Install $1 (apt: 'sudo apt install $1') and re-run." >&2
    exit 1
  fi
}

require_cmd bash
require_cmd curl
require_cmd tar
require_cmd sed
require_cmd readlink
require_cmd find

if [ "$MODE" != "uninstall" ]; then
  require_cmd node
  NODE_MAJOR=$(node -e 'console.log(parseInt(process.versions.node.split(".")[0], 10))')
  if [ "$NODE_MAJOR" -lt 18 ]; then
    echo "ERROR: node >= 18.18 required; you have $(node -v)" >&2
    exit 1
  fi
  require_cmd npm
fi

# Resolve the parent directory, but never dereference the final install-prefix
# component. A symlink at the live prefix could otherwise redirect uninstall or
# rollback cleanup outside the operator-selected location.
normalize_prefix() {
  local raw="$PREFIX" base parent home_real

  while [ "$raw" != "/" ] && [ "${raw%/}" != "$raw" ]; do
    raw="${raw%/}"
  done
  if [ -z "$raw" ] || [ "$raw" = "/" ] || [ -L "$raw" ]; then
    echo "ERROR: unsafe ChromeMCP install prefix: $raw" >&2
    exit 64
  fi

  base="${raw##*/}"
  case "$base" in
    ''|.|..)
      echo "ERROR: unsafe ChromeMCP install prefix: $raw" >&2
      exit 64
      ;;
  esac

  parent="${raw%/*}"
  if [ "$parent" = "$raw" ]; then
    parent="."
  elif [ -z "$parent" ]; then
    parent="/"
  fi

  if [ "$MODE" = "uninstall" ] && [ ! -d "$parent" ]; then
    parent="$(readlink -m -- "$parent")"
  else
    mkdir -p -- "$parent"
    parent="$(cd -P -- "$parent" && pwd)"
  fi

  if [ "$parent" = "/" ]; then
    PREFIX="/$base"
  else
    PREFIX="$parent/$base"
  fi
  if [ -L "$PREFIX" ]; then
    echo "ERROR: refusing to use symlinked ChromeMCP install prefix: $PREFIX" >&2
    exit 64
  fi
  if [ -e "$PREFIX" ] && [ ! -d "$PREFIX" ]; then
    echo "ERROR: ChromeMCP install prefix exists but is not a directory: $PREFIX" >&2
    exit 64
  fi

  if [ -d "$HOME" ]; then
    home_real="$(cd -P -- "$HOME" && pwd)"
    if [ "$PREFIX" = "$home_real" ]; then
      echo "ERROR: refusing to use the home directory as the ChromeMCP install prefix." >&2
      exit 64
    fi
  fi
}

normalize_bin_dir() {
  local raw="$BIN_DIR"

  while [ "$raw" != "/" ] && [ "${raw%/}" != "$raw" ]; do
    raw="${raw%/}"
  done
  if [ -z "$raw" ]; then
    echo "ERROR: CHROMEMCP_BIN_DIR cannot be empty." >&2
    exit 64
  fi

  if [ "$MODE" = "uninstall" ] && [ ! -d "$raw" ]; then
    BIN_DIR="$(readlink -m -- "$raw")"
    return
  fi

  mkdir -p -- "$raw"
  BIN_DIR="$(cd -P -- "$raw" && pwd)"
}

normalize_prefix
normalize_bin_dir

# --- Uninstall path -------------------------------------------------------
if [ "$MODE" = "uninstall" ]; then
  if [ -L "$BIN_DIR/chromemcp" ]; then
    rm -- "$BIN_DIR/chromemcp"
    echo "Removed $BIN_DIR/chromemcp"
  fi
  if [ -d "$PREFIX" ]; then
    rm -rf --one-file-system -- "$PREFIX"
    echo "Removed $PREFIX"
  fi
  if systemctl --user list-unit-files --type=service 2>/dev/null | grep -q '^chromemcp.service'; then
    echo "Note: the chromemcp.service systemd unit is still installed."
    echo "  Run 'chromemcp disable' BEFORE uninstall next time, or remove manually:"
    echo "    systemctl --user disable --now chromemcp.service"
    echo "    rm ~/.config/systemd/user/chromemcp.service && systemctl --user daemon-reload"
  fi
  echo "chromemcp uninstalled."
  exit 0
fi

# --- Transaction state + cleanup -----------------------------------------
WORKDIR=""
STAGE_DIR=""
BACKUP_ROOT=""
PREFIX_PARENT="${PREFIX%/*}"
TRANSACTION_STARTED=0
TRANSACTION_COMMITTED=0
OLD_PREFIX_MOVED=0
NEW_PREFIX_MOVED=0
SERVICE_WAS_ACTIVE=0
SERVICE_STOP_ATTEMPTED=0
SERVICE_START_ATTEMPTED=0
LINK_PATH="$BIN_DIR/chromemcp"
LINK_STATE="absent"
LINK_TARGET=""
LINK_MUTATED=0
ROLLBACK_RESTORED=0

safe_remove_generated_dir() {
  local path="$1" kind="$2"

  [ -n "$path" ] || return 0
  case "$path" in
    "$PREFIX_PARENT"/.chromemcp-"$kind".*) ;;
    *)
      echo "ERROR: refusing to remove unexpected transaction path: $path" >&2
      return 1
      ;;
  esac

  if [ -L "$path" ]; then
    rm -f -- "$path"
  elif [ -e "$path" ]; then
    rm -rf --one-file-system -- "$path"
  fi
}

restore_previous_link() {
  [ "$LINK_MUTATED" = "1" ] || return 0

  case "$LINK_STATE" in
    symlink)
      if [ -e "$LINK_PATH" ] && [ ! -L "$LINK_PATH" ]; then
        echo "WARNING: cannot restore $LINK_PATH because it became a non-symlink." >&2
        return 1
      fi
      rm -f -- "$LINK_PATH"
      ln -s -- "$LINK_TARGET" "$LINK_PATH"
      ;;
    absent)
      if [ -L "$LINK_PATH" ]; then
        rm -f -- "$LINK_PATH"
      elif [ -e "$LINK_PATH" ]; then
        echo "WARNING: refusing to remove unexpected non-symlink at $LINK_PATH." >&2
        return 1
      fi
      ;;
  esac
}

restart_previous_service() {
  [ "$SERVICE_WAS_ACTIVE" = "1" ] || return 0
  echo "Restarting the previous chromemcp.service..." >&2
  if systemctl --user start chromemcp.service; then
    echo "Previous chromemcp.service restarted." >&2
    return 0
  fi
  echo "ERROR: failed to restart the previous chromemcp.service." >&2
  return 1
}

rollback_install() {
  local rollback_failed=0 new_prefix_removed=1

  echo "Install failed; rolling back the ChromeMCP prefix..." >&2
  if [ "$SERVICE_START_ATTEMPTED" = "1" ]; then
    systemctl --user stop chromemcp.service >/dev/null 2>&1 || true
  fi

  if [ "$NEW_PREFIX_MOVED" = "1" ]; then
    if [ -L "$PREFIX" ]; then
      if ! rm -f -- "$PREFIX"; then
        rollback_failed=1
        new_prefix_removed=0
      fi
    elif [ -e "$PREFIX" ]; then
      if ! rm -rf --one-file-system -- "$PREFIX"; then
        rollback_failed=1
        new_prefix_removed=0
      fi
    fi
  fi

  if [ "$OLD_PREFIX_MOVED" = "1" ]; then
    if [ "$new_prefix_removed" = "1" ] \
        && [ -d "$BACKUP_ROOT/live" ] && [ ! -L "$BACKUP_ROOT/live" ]; then
      if mv -- "$BACKUP_ROOT/live" "$PREFIX"; then
        ROLLBACK_RESTORED=1
      else
        echo "ERROR: prior prefix remains at $BACKUP_ROOT/live" >&2
        rollback_failed=1
      fi
    else
      echo "ERROR: rollback backup is missing: $BACKUP_ROOT/live" >&2
      rollback_failed=1
    fi
  elif [ "$new_prefix_removed" = "1" ]; then
    ROLLBACK_RESTORED=1
  fi

  if [ "$ROLLBACK_RESTORED" = "1" ]; then
    restore_previous_link || rollback_failed=1
    restart_previous_service || rollback_failed=1
  else
    echo "ERROR: leaving chromemcp.service stopped because the prior prefix was not restored." >&2
    rollback_failed=1
  fi

  if [ "$rollback_failed" = "0" ]; then
    echo "Rollback complete." >&2
    return 0
  fi
  echo "ERROR: rollback was incomplete; inspect the paths above before retrying." >&2
  return 1
}

cleanup_on_exit() {
  local rc=$?
  trap - EXIT INT TERM
  set +e

  if [ "$rc" -ne 0 ]; then
    if [ "$TRANSACTION_STARTED" = "1" ] && [ "$TRANSACTION_COMMITTED" = "0" ]; then
      rollback_install || true
    elif [ "$SERVICE_WAS_ACTIVE" = "1" ] && [ "$SERVICE_STOP_ATTEMPTED" = "1" ]; then
      restart_previous_service || true
    fi
  fi

  safe_remove_generated_dir "$STAGE_DIR" stage || true
  if [ -n "$BACKUP_ROOT" ]; then
    if [ "$OLD_PREFIX_MOVED" = "0" ] || [ "$ROLLBACK_RESTORED" = "1" ] || [ "$TRANSACTION_COMMITTED" = "1" ]; then
      safe_remove_generated_dir "$BACKUP_ROOT" backup || true
    else
      echo "Rollback backup preserved at: $BACKUP_ROOT" >&2
    fi
  fi
  if [ -n "$WORKDIR" ] && [ -d "$WORKDIR" ] && [ ! -L "$WORKDIR" ]; then
    rm -rf --one-file-system -- "$WORKDIR"
  fi
  exit "$rc"
}

trap cleanup_on_exit EXIT
trap 'exit 130' INT
trap 'exit 143' TERM

# --- Resolve source: tarball or in-tree -----------------------------------
WORKDIR="$(mktemp -d -t chromemcp-install-XXXXXX)"

if [ -n "$FROM_SOURCE" ]; then
  SOURCE_DIR="$(cd "$(dirname "$(readlink -f "$0")")/.." && pwd)"
  echo "Installing from local source: $SOURCE_DIR"
else
  # Discover the tag we want.
  if [ -z "$WANT_TAG" ]; then
    # Use GitHub API to find the latest release tag.
    LATEST_JSON="$WORKDIR/latest.json"
    if ! curl -fsSL "https://api.github.com/repos/$REPO_OWNER/$REPO_NAME/releases/latest" -o "$LATEST_JSON"; then
      echo "ERROR: could not query GitHub API for latest release." >&2
      echo "  Either the network is down, the repo $REPO_OWNER/$REPO_NAME has no published release yet," >&2
      echo "  or you've hit the unauthenticated GitHub API rate limit (60/hr per IP)." >&2
      echo "  Workaround: clone the repo and run 'bash scripts/install.sh --from-source'," >&2
      echo "  or if you have a source checkout: 'chromemcp update'." >&2
      exit 1
    fi
    WANT_TAG=$(sed -n 's/.*"tag_name":[[:space:]]*"\([^"]*\)".*/\1/p' "$LATEST_JSON" | head -1)
    if [ -z "$WANT_TAG" ]; then
      echo "ERROR: could not parse latest tag from GitHub response." >&2
      head -20 "$LATEST_JSON" >&2 || true
      exit 1
    fi
  fi
  WANT_VERSION="${WANT_TAG#v}"

  # --upgrade short-circuits if the installed version equals the latest.
  if [ "$MODE" = "upgrade" ] && [ -r "$PREFIX/VERSION" ]; then
    CURRENT_VERSION="$(tr -d '\n\r ' < "$PREFIX/VERSION")"
    if [ "$CURRENT_VERSION" = "$WANT_VERSION" ]; then
      echo "Already up to date (installed: $CURRENT_VERSION, latest: $WANT_VERSION)."
      exit 0
    fi
    echo "Upgrading $CURRENT_VERSION -> $WANT_VERSION"
  fi

  echo "Downloading ChromeMCP $WANT_TAG..."
  TARBALL_URL="https://github.com/$REPO_OWNER/$REPO_NAME/releases/download/$WANT_TAG/chromemcp-$WANT_VERSION.tar.gz"
  if ! curl -fsSL "$TARBALL_URL" -o "$WORKDIR/release.tar.gz"; then
    echo "ERROR: download failed: $TARBALL_URL" >&2
    exit 1
  fi
  mkdir -p "$WORKDIR/extracted"
  tar -xzf "$WORKDIR/release.tar.gz" -C "$WORKDIR/extracted"
  # The tarball is "chromemcp-VERSION/...". Find that one inner dir.
  SOURCE_DIR=$(find "$WORKDIR/extracted" -maxdepth 1 -mindepth 1 -type d | head -1)
  if [ -z "$SOURCE_DIR" ] || [ ! -d "$SOURCE_DIR" ]; then
    echo "ERROR: tarball didn't contain a single top-level directory." >&2
    exit 1
  fi
fi

# --- Build a complete same-filesystem stage before stopping the service ---
echo "Install dir : $PREFIX"
echo "Bin dir     : $BIN_DIR"
echo "Staging the complete install before touching the live prefix..."

if [ -L "$LINK_PATH" ]; then
  LINK_STATE="symlink"
  LINK_TARGET="$(readlink -- "$LINK_PATH")"
elif [ -e "$LINK_PATH" ]; then
  echo "ERROR: refusing to replace non-symlink command path: $LINK_PATH" >&2
  exit 1
fi

STAGE_DIR="$(mktemp -d "$PREFIX_PARENT/.chromemcp-stage.XXXXXX")"
chmod 0700 "$STAGE_DIR"

# Use rsync if available. Fall back to a tar pipe for minimal hosts. Neither
# path dereferences symlinks, and both stay on the source filesystem.
if command -v rsync >/dev/null 2>&1; then
  rsync -a --delete --one-file-system \
    --exclude='.git' \
    --exclude='mcp/node_modules' \
    --exclude='mcp/logs' \
    --exclude='mcp/.playwright-mcp' \
    --exclude='mcp/demo-output' \
    --exclude='mcp/.playwright*.pid' \
    --exclude='mcp/.logrotate*.pid' \
    --exclude='__pycache__' \
    "$SOURCE_DIR/" "$STAGE_DIR/"
else
  ( cd "$SOURCE_DIR" && tar --one-file-system \
        --exclude='.git' --exclude='mcp/node_modules' \
        --exclude='mcp/logs' --exclude='mcp/.playwright-mcp' \
        --exclude='mcp/demo-output' --exclude='mcp/.playwright*.pid' \
        --exclude='mcp/.logrotate*.pid' \
        --exclude='__pycache__' \
        -cf - . ) | ( cd "$STAGE_DIR" && tar -xf - )
fi

# Make sure the wrappers are executable (rsync respects mode but a tar pipe
# may strip the +x bit if the source files lost it).
for f in chromemcp mcp-up mcp-down mcp-status mcp-enable mcp-disable \
         mcp-logs mcp-token bridge-check chrome setup-bridge \
         chrome-codex setup-bridge-codex mcp-up-codex mcp-down-codex \
         mcp-status-codex codex-lane lane; do
  [ -f "$STAGE_DIR/$f" ] && chmod +x "$STAGE_DIR/$f"
done
[ -f "$STAGE_DIR/scripts/install.sh" ] && chmod +x "$STAGE_DIR/scripts/install.sh"

# Drop a VERSION file derived from --version or VERSION file in source.
if [ -n "${WANT_VERSION:-}" ]; then
  echo "$WANT_VERSION" > "$STAGE_DIR/VERSION"
elif [ ! -f "$STAGE_DIR/VERSION" ] && [ -f "$SOURCE_DIR/VERSION" ]; then
  cp "$SOURCE_DIR/VERSION" "$STAGE_DIR/VERSION"
fi

# Tighten copied source before running package installation, then harden again
# afterward in case a dependency creates permissive files.
find -P "$STAGE_DIR" -type d -exec chmod go-w {} +
find -P "$STAGE_DIR" -type f -exec chmod go-w {} +
chmod 0700 "$STAGE_DIR"

if [ -f "$STAGE_DIR/mcp/package.json" ]; then
  if [ ! -f "$STAGE_DIR/mcp/package-lock.json" ]; then
    echo "ERROR: staged MCP package is missing package-lock.json." >&2
    exit 1
  fi
  echo "Installing MCP server deps via npm ci..."
  ( cd "$STAGE_DIR/mcp" && npm ci --no-audit --no-fund )
fi

# Preserve ordinary local logs on upgrade when the live directory is real.
# The copy is best effort because the service remains active during staging.
if [ -d "$PREFIX/mcp/logs" ] && [ ! -L "$PREFIX/mcp/logs" ]; then
  mkdir -p "$STAGE_DIR/mcp/logs"
  if command -v rsync >/dev/null 2>&1; then
    if ! rsync -a --one-file-system "$PREFIX/mcp/logs/" "$STAGE_DIR/mcp/logs/"; then
      echo "WARNING: some existing MCP logs could not be copied into the stage." >&2
    fi
  elif ! ( cd "$PREFIX/mcp" && tar --one-file-system -cf - logs ) \
      | ( cd "$STAGE_DIR/mcp" && tar -xf - ); then
    echo "WARNING: some existing MCP logs could not be copied into the stage." >&2
  fi
fi

find -P "$STAGE_DIR" -type d -exec chmod go-w {} +
find -P "$STAGE_DIR" -type f -exec chmod go-w {} +
chmod 0700 "$STAGE_DIR"

if [ ! -x "$STAGE_DIR/chromemcp" ] || [ ! -x "$STAGE_DIR/scripts/install.sh" ]; then
  echo "ERROR: staged ChromeMCP install is incomplete." >&2
  exit 1
fi
if find -P "$STAGE_DIR" \( -type d -o -type f \) -perm /022 -print -quit | grep -q .; then
  echo "ERROR: staged ChromeMCP install still contains group/other-writable paths." >&2
  exit 1
fi
echo "Stage complete and permission-hardened."

# Reserve a rollback directory on the same parent filesystem before the stop.
BACKUP_ROOT="$(mktemp -d "$PREFIX_PARENT/.chromemcp-backup.XXXXXX")"
chmod 0700 "$BACKUP_ROOT"

if systemctl --user is-active --quiet chromemcp.service 2>/dev/null; then
  SERVICE_WAS_ACTIVE=1
  SERVICE_STOP_ATTEMPTED=1
  echo "Stopping chromemcp.service before the atomic swap..."
  systemctl --user stop chromemcp.service
  echo "Service stopped."
fi

# Each rename is atomic and the stage/backup live on PREFIX_PARENT, so no copy
# can occur during the swap. The EXIT trap restores the backup on any failure.
TRANSACTION_STARTED=1
# Defer handled termination signals across the two-rename critical section so
# transaction flags always describe the on-disk state seen by rollback.
DEFERRED_SIGNAL=0
trap 'DEFERRED_SIGNAL=130' INT
trap 'DEFERRED_SIGNAL=143' TERM
if [ -d "$PREFIX" ]; then
  mv -- "$PREFIX" "$BACKUP_ROOT/live"
  OLD_PREFIX_MOVED=1
fi
mv -- "$STAGE_DIR" "$PREFIX"
STAGE_DIR=""
NEW_PREFIX_MOVED=1
trap 'exit 130' INT
trap 'exit 143' TERM
if [ "$DEFERRED_SIGNAL" -ne 0 ]; then
  exit "$DEFERRED_SIGNAL"
fi

if [ "$SERVICE_WAS_ACTIVE" = "1" ]; then
  echo "Starting chromemcp.service from the new prefix..."
  SERVICE_START_ATTEMPTED=1
  if ! systemctl --user start chromemcp.service; then
    echo "ERROR: failed to start chromemcp.service from the new prefix." >&2
    exit 1
  fi
  echo "Verifying service health..."
  if curl --fail --silent --max-time 5 --retry 30 --retry-delay 1 --retry-connrefused \
       -o /dev/null http://127.0.0.1:8931/healthz; then
    echo "Service restarted and healthy."
  else
    echo "ERROR: Service started but health check failed after 30 attempts." >&2
    echo "  Check logs: journalctl --user -u chromemcp -n 50" >&2
    exit 1
  fi
fi

# Refresh the CLI link only after the runtime swap and health verification.
LINK_MUTATED=1
ln -sfn -- "$PREFIX/chromemcp" "$LINK_PATH"
echo "Symlinked   : $LINK_PATH -> $PREFIX/chromemcp"

INSTALLED_VERSION="$( "$PREFIX/chromemcp" version 2>/dev/null || echo unknown )"

# The new prefix is healthy and reachable. Removing the rollback copy is the
# final commit step. If cleanup itself fails, retain the healthy new install
# rather than attempting a rollback from a potentially partial backup.
TRANSACTION_COMMITTED=1
if ! safe_remove_generated_dir "$BACKUP_ROOT" backup; then
  echo "ERROR: new install is healthy, but rollback backup cleanup failed: $BACKUP_ROOT" >&2
  exit 1
fi
BACKUP_ROOT=""

# PATH check: warn if BIN_DIR isn't on it.
case ":$PATH:" in
  *":$BIN_DIR:"*)
    ;;
  *)
    echo ""
    echo "NOTE: $BIN_DIR is not on your PATH. Add this line to your shell rc:"
    echo "  export PATH=\"$BIN_DIR:\$PATH\""
    ;;
esac

echo ""
echo "ChromeMCP $INSTALLED_VERSION installed."
echo ""
echo "Next steps (run from anywhere on PATH):"
echo "  chromemcp setup-bridge    # one-time, Windows-side, UAC required"
echo "  chromemcp chrome          # launch signed-in Chrome with CDP"
echo "  chromemcp up              # start the MCP server"
echo "  chromemcp token           # print the bearer token for your client config"
echo "  chromemcp test            # smoke test"
echo ""
echo "Optional isolated lane (only for concurrent/conflicting browser workflows):"
echo "  chromemcp codex-lane acquire --format shell"
echo "                              # claim a numbered Codex lane for a run"
echo "  chromemcp codex-bridge N    # one-time/UAC per lane, exposes that lane's CDP port"
echo "  chromemcp codex-chrome N    # launch that lane's Chrome profile"
echo "  chromemcp codex-up N        # start that lane's MCP server"
echo "  chromemcp codex-status N    # verify that lane's MCP health"
echo ""
echo "Optional (auto-restart + survives logout):"
echo "  chromemcp enable          # install the systemd user unit"
