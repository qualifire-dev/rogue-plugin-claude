#!/usr/bin/env bash
# Silent plugin auto-updater. Fires from the SessionStart hook in the
# background so it never blocks Claude Code startup. Compares the installed
# plugin version against the latest GitHub release; if newer, re-runs the
# one-line installer to upgrade in place. New version takes effect on the
# next session.
#
# Opt-outs:
#   ROGUE_AUTO_UPDATE=0       — disable entirely
#   ROGUE_PLUGIN_VERSION=v1.x — pinned, never updates
#
# Runs at most once per 24h (cached in ~/.rogue/.auto-update-check).
# Silent on every failure path. All activity logs to ~/.rogue/auto-update.log
# for diagnostics.

[ -z "${CLAUDE_CODE_ENTRYPOINT:-}" ] && exit 0

# Git Bash stand-down: auto-update.ps1 owns native Windows (same reason as hook.sh).
case "$(uname -s 2>/dev/null)" in
  MINGW*|MSYS*|CYGWIN*) exit 0 ;;
esac

set -u

LOG="$HOME/.rogue/auto-update.log"
mkdir -p "$(dirname "$LOG")" 2>/dev/null || exit 0
exec >>"$LOG" 2>&1
date "+%F %T --- auto-update tick ---"

# Pull creds + flags from the same files the hooks read, in the same precedence
# order (later wins): bundled plugin env → MDM → per-user. The bundled
# ${CLAUDE_PLUGIN_ROOT}/env is where compiled/managed plugins pin flags like
# ROGUE_AUTO_UPDATE=0 or ROGUE_PLUGIN_VERSION, so it must be sourced here too.
[ -r "${CLAUDE_PLUGIN_ROOT:-}/env" ] && . "${CLAUDE_PLUGIN_ROOT}/env"
[ -r /etc/rogue/env ] && . /etc/rogue/env
[ -r "$HOME/.rogue-env" ] && . "$HOME/.rogue-env"

if [ "${ROGUE_AUTO_UPDATE:-1}" = "0" ]; then
  echo "ROGUE_AUTO_UPDATE=0, skipping"
  exit 0
fi
if [ -n "${ROGUE_PLUGIN_VERSION:-}" ]; then
  echo "ROGUE_PLUGIN_VERSION=$ROGUE_PLUGIN_VERSION pinned, skipping"
  exit 0
fi

# Rate-limit to once per day.
CACHE="$HOME/.rogue/.auto-update-check"
TTL=86400
if [ -f "$CACHE" ]; then
  NOW=$(date +%s 2>/dev/null || echo 0)
  MTIME=$(stat -f %m "$CACHE" 2>/dev/null || stat -c %Y "$CACHE" 2>/dev/null || echo 0)
  if [ $((NOW - MTIME)) -lt "$TTL" ]; then
    echo "checked within TTL, skipping"
    exit 0
  fi
fi
touch "$CACHE" 2>/dev/null

REPO="${ROGUE_PLUGIN_REPO:-qualifire-dev/rogue-plugin-claude}"

PLUGIN_JSON="${CLAUDE_PLUGIN_ROOT:-}/.claude-plugin/plugin.json"
if [ ! -f "$PLUGIN_JSON" ]; then
  echo "no plugin.json at $PLUGIN_JSON"
  exit 0
fi
# Read the version WITHOUT python3 — the /usr/bin/python3 stub fails silently on
# a fresh macOS (no Xcode CLT), which would mask updates. grep/sed are always
# present (same approach as heartbeat.sh / build-release.sh).
INSTALLED=$(grep -oE '"version"[[:space:]]*:[[:space:]]*"[0-9][^"]*"' "$PLUGIN_JSON" 2>/dev/null \
  | head -1 | grep -oE '[0-9]+\.[0-9]+\.[0-9]+')
if [ -z "$INSTALLED" ]; then
  echo "no installed version found"
  exit 0
fi
INSTALLED_TAG="v${INSTALLED}"

LATEST=$(curl -fsSL --max-time 5 "https://api.github.com/repos/${REPO}/releases/latest" 2>/dev/null \
  | grep -oE '"tag_name"[[:space:]]*:[[:space:]]*"[^"]*"' | head -1 \
  | sed -E 's/.*"tag_name"[[:space:]]*:[[:space:]]*"([^"]*)".*/\1/')
if [ -z "$LATEST" ]; then
  echo "could not resolve latest release"
  exit 0
fi

if [ "$LATEST" = "$INSTALLED_TAG" ]; then
  echo "up to date at $INSTALLED_TAG"
  exit 0
fi

echo "upgrade available: $INSTALLED_TAG -> $LATEST, running installer"

# Re-run the one-line installer in non-interactive mode. Creds already in env
# from sourcing ~/.rogue-env above, so no prompts.
INSTALLER_URL="${ROGUE_INSTALLER_URL:-https://raw.githubusercontent.com/qualifire-dev/rogue-plugin-claude/main/install.sh}"
curl -fsSL --max-time 60 "$INSTALLER_URL" | ROGUE_NON_INTERACTIVE=1 bash
RC=$?
echo "installer exited rc=$RC"
