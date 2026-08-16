#!/usr/bin/env bash
# Rogue presence heartbeat (Codex plugin). Fired from SessionStart in the background.
#
# POSTs /api/v1/hooks/status so this install shows up in the dashboard's Coding
# Agents roster (Connected / version / host / user) and so the org learns which
# plugin version is running (drives the "outdated" badge). Fire-and-forget: never
# blocks Codex, never affects allow/deny, exits 0 on every path.
set -u

# Codex sets PLUGIN_ROOT to the installed plugin directory.
PLUGIN_ROOT="${PLUGIN_ROOT:-}"

# Same env precedence as hook.sh (later wins): bundled → MDM → per-user.
[ -r "${PLUGIN_ROOT}/env" ] && . "${PLUGIN_ROOT}/env"
[ -r /etc/rogue/env ]                && . /etc/rogue/env
[ -r "$HOME/.rogue-env" ]            && . "$HOME/.rogue-env"

# Not configured → no-op (mirrors hook.sh fail-open on missing key).
[ -n "${ROGUE_API_KEY:-}" ] || exit 0

[ -r "${PLUGIN_ROOT}/scripts/actor.sh" ] && . "${PLUGIN_ROOT}/scripts/actor.sh"

# Plugin version from the manifest WITHOUT python3 (the /usr/bin/python3 stub
# fails silently on a fresh macOS). grep/sed are always present.
VER="unknown"
PJ="${PLUGIN_ROOT}/.codex-plugin/plugin.json"
if [ -r "$PJ" ]; then
  v=$(grep -oE '"version"[[:space:]]*:[[:space:]]*"[0-9][^"]*"' "$PJ" \
        | head -1 | grep -oE '[0-9]+\.[0-9]+\.[0-9]+')
  [ -n "$v" ] && VER="$v"
fi

# Family is the fixed enum "openai"; the surface (codex_app|codex_cli) rides the
# agent field. One table, in scripts/surface.sh, shared with hook.sh - which stamps
# the same slug on each log line and sends it as x-rogue-agent. The literal is a
# last-resort guard for a damaged install, not a second copy of the mapping.
AGENT=""
if [ -r "${PLUGIN_ROOT:-}/scripts/surface.sh" ]; then
  . "${PLUGIN_ROOT}/scripts/surface.sh"
  AGENT=$(codex_surface_slug 2>/dev/null)
fi
[ -n "$AGENT" ] || AGENT="codex_cli"

HOST=$(hostname 2>/dev/null || echo unknown)
esc() { printf '%s' "$1" | sed -e 's/\\/\\\\/g' -e 's/"/\\"/g'; }
BODY=$(printf '{"agent_family":"openai","agent":"%s","version":"%s","host":"%s","actor_email":"%s","actor_name":"%s"}' \
  "$(esc "$AGENT")" "$(esc "$VER")" "$(esc "$HOST")" \
  "$(esc "${ROGUE_ACTOR_EMAIL:-}")" "$(esc "${ROGUE_ACTOR_NAME:-}")")

curl -sS --max-time 10 -X POST \
  "${ROGUE_BASE_URL:-https://api.rogue.security}/api/v1/hooks/status" \
  -H "x-rogue-api-key: $ROGUE_API_KEY" \
  -H "Content-Type: application/json" \
  -d "$BODY" \
  >/dev/null 2>&1 || true

# ── ship the hook log ──────────────────────────────────────────────────────
# See plugins/rogue/scripts/heartbeat.sh for why this runs after the POST (the
# roster row must exist first), why it needs no extra backgrounding (hooks.json
# already detaches this script) and why the actor is passed in rather than
# re-resolved (a second cascade would key the log's source row differently from
# the roster row just posted).
#
# The SLUG AND THE FAMILY DIFFER HERE and that is not a mistake: the log file is
# `codex.log` (slug `codex`, matching the `provider=` token the dispatcher writes)
# while the roster family is `openai`, exactly as this script's own body reports.
# The shipper never derives one from the other - both are arguments.
if [ -r "${PLUGIN_ROOT}/scripts/ship-logs.sh" ]; then
  ROGUE_ACTOR_EMAIL="${ROGUE_ACTOR_EMAIL:-}" ROGUE_ACTOR_NAME="${ROGUE_ACTOR_NAME:-}" \
    sh "${PLUGIN_ROOT}/scripts/ship-logs.sh" \
      "${PLUGIN_ROOT}" codex "$VER" openai >/dev/null 2>&1 || true
fi

exit 0
