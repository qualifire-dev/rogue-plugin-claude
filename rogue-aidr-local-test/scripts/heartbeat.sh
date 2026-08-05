#!/usr/bin/env bash
# Rogue presence heartbeat. Fired from SessionStart in the background.
#
# POSTs /api/v1/hooks/status so this install shows up in the dashboard's Coding
# Agents roster (Connected / version / host / user) and so the org learns which
# plugin version is running. Pure side-effect: fire-and-forget, never blocks
# Claude Code, never affects allow/deny, and exits 0 on every path.
#
# The roster dedups one row per (host | actor-email | family), so we always
# send a stable x-rogue-host + x-rogue-actor-email.
set -u

# Git Bash stand-down: heartbeat.ps1 owns native Windows (same reason as hook.sh).
case "$(uname -s 2>/dev/null)" in
  MINGW*|MSYS*|CYGWIN*) exit 0 ;;
esac

# Same env precedence as hook.sh (later wins): bundled → MDM → per-user.
[ -r "${CLAUDE_PLUGIN_ROOT:-}/env" ] && . "${CLAUDE_PLUGIN_ROOT}/env"
[ -r /etc/rogue/env ]                && . /etc/rogue/env
[ -r "$HOME/.rogue-env" ]            && . "$HOME/.rogue-env"

[ -z "${CLAUDE_CODE_ENTRYPOINT:-}" ] && exit 0

# Not configured → no-op (mirrors hook.sh fail-open on missing key).
[ -n "${ROGUE_API_KEY:-}" ] || exit 0

# Actor identity via the shared cascade (env → git → CLAUDE_CODE_USER_EMAIL → host/whoami).
# actor.sh uses ${CLAUDE_CODE_USER_EMAIL%@*} with no default — that aborts under
# `set -u` on bash >=4.4 when the var is unset, so relax nounset across the source.
set +u
[ -r "${CLAUDE_PLUGIN_ROOT:-}/scripts/actor.sh" ] && . "${CLAUDE_PLUGIN_ROOT}/scripts/actor.sh"
set -u

# Plugin version from the manifest, WITHOUT python3 (the /usr/bin/python3 stub
# fails silently on a fresh macOS — see hook.sh). grep/sed are always present.
VER="unknown"
PJ="${CLAUDE_PLUGIN_ROOT:-}/.claude-plugin/plugin.json"
if [ -r "$PJ" ]; then
  v=$(grep -oE '"version"[[:space:]]*:[[:space:]]*"[0-9][^"]*"' "$PJ" \
        | head -1 | grep -oE '[0-9]+\.[0-9]+\.[0-9]+')
  [ -n "$v" ] && VER="$v"
fi

# Family is the fixed enum value "claude". The surface rides the separate
# x-rogue-agent header (free-form display label), derived from
# CLAUDE_CODE_ENTRYPOINT (the same var hook.sh uses to tell GUI from cli).
# Unknown → CLI.
case "$(printf '%s' "${CLAUDE_CODE_ENTRYPOINT:-}" | tr '[:upper:]' '[:lower:]')" in
  *cowork*)  AGENT="Claude Cowork" ;;
  *desktop*) AGENT="Claude Code - Desktop" ;;
  *)         AGENT="Claude Code - CLI" ;;
esac

# POST /api/v1/hooks/status (GET route is gone). The former x-rogue-agent-*
# headers now ride the JSON body; x-rogue-api-key stays a header. Backslash- and
# quote-escape each value so a name/host with a " or \ can't break the JSON.
HOST=$(hostname 2>/dev/null || echo unknown)
esc() { printf '%s' "$1" | sed -e 's/\\/\\\\/g' -e 's/"/\\"/g'; }
BODY=$(printf '{"agent_family":"claude","agent":"%s","version":"%s","host":"%s","actor_email":"%s","actor_name":"%s"}' \
  "$(esc "$AGENT")" "$(esc "$VER")" "$(esc "$HOST")" \
  "$(esc "${ROGUE_ACTOR_EMAIL:-}")" "$(esc "${ROGUE_ACTOR_NAME:-}")")

curl -sS --max-time 10 -X POST \
  "${ROGUE_BASE_URL:-https://api.rogue.security}/api/v1/hooks/status" \
  -H "x-rogue-api-key: $ROGUE_API_KEY" \
  -H "Content-Type: application/json" \
  -d "$BODY" \
  >/dev/null 2>&1 || true

exit 0
