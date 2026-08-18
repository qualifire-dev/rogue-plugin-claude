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
# Host + version + surface. Shared with hook.sh, which sends the same three as
# headers on every event: same values, same roster row. See install-id.sh.
[ -r "${PLUGIN_ROOT}/scripts/install-id.sh" ] && . "${PLUGIN_ROOT}/scripts/install-id.sh"

# Family is the fixed enum "openai"; the surface rides the agent field.
esc() { printf '%s' "$1" | sed -e 's/\\/\\\\/g' -e 's/"/\\"/g'; }
BODY=$(printf '{"agent_family":"openai","agent":"%s","version":"%s","host":"%s","actor_email":"%s","actor_name":"%s"}' \
  "$(esc "${ROGUE_INSTALL_AGENT:-codex_cli}")" "$(esc "${ROGUE_INSTALL_VERSION:-unknown}")" \
  "$(esc "${ROGUE_INSTALL_HOST:-unknown}")" \
  "$(esc "${ROGUE_ACTOR_EMAIL:-}")" "$(esc "${ROGUE_ACTOR_NAME:-}")")

curl -sS --max-time 10 -X POST \
  "${ROGUE_BASE_URL:-https://api.rogue.security}/api/v1/hooks/status" \
  -H "x-rogue-api-key: $ROGUE_API_KEY" \
  -H "Content-Type: application/json" \
  -d "$BODY" \
  >/dev/null 2>&1 || true

exit 0
