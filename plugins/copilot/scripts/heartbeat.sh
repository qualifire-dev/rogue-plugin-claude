#!/usr/bin/env bash
# Rogue presence heartbeat (GitHub Copilot CLI plugin). Fired detached from
# sessionStart. POSTs /api/v1/hooks/status so this install shows up in the
# dashboard's Coding Agents roster and the org learns which plugin version runs
# (drives the "outdated" badge). Fire-and-forget: never blocks Copilot, always
# exits 0.
set -u

# Self-locate the plugin root from $0 (<root>/scripts/heartbeat.sh).
PLUGIN_ROOT="$(CDPATH= cd -- "$(dirname -- "$0")/.." 2>/dev/null && pwd)"
[ -n "$PLUGIN_ROOT" ] || PLUGIN_ROOT="${COPILOT_PLUGIN_ROOT:-.}"

# Same env precedence as hook.sh (later wins): bundled → MDM → per-user.
[ -r "${PLUGIN_ROOT}/env" ] && . "${PLUGIN_ROOT}/env"
[ -r /etc/rogue/env ]       && . /etc/rogue/env
[ -r "$HOME/.rogue-env" ]   && . "$HOME/.rogue-env"

# Not configured → no-op (mirrors hook.sh fail-open on missing key).
[ -n "${ROGUE_API_KEY:-}" ] || exit 0

[ -r "${PLUGIN_ROOT}/scripts/actor.sh" ] && . "${PLUGIN_ROOT}/scripts/actor.sh"

# Plugin version from the manifest WITHOUT python3 (the /usr/bin/python3 stub
# fails silently on a fresh macOS). grep/sed are always present.
VER="unknown"
PJ="${PLUGIN_ROOT}/plugin.json"
if [ -r "$PJ" ]; then
  v=$(grep -oE '"version"[[:space:]]*:[[:space:]]*"[0-9][^"]*"' "$PJ" \
        | head -1 | grep -oE '[0-9]+\.[0-9]+\.[0-9]+')
  [ -n "$v" ] && VER="$v"
fi

# Family is the fixed enum "copilot"; surface rides the agent field.
HOST=$(hostname 2>/dev/null || echo unknown)
esc() { printf '%s' "$1" | sed -e 's/\\/\\\\/g' -e 's/"/\\"/g'; }
BODY=$(printf '{"agent_family":"copilot","agent":"github_copilot","version":"%s","host":"%s","actor_email":"%s","actor_name":"%s"}' \
  "$(esc "$VER")" "$(esc "$HOST")" \
  "$(esc "${ROGUE_ACTOR_EMAIL:-}")" "$(esc "${ROGUE_ACTOR_NAME:-}")")

curl -sS --max-time 10 -X POST \
  "${ROGUE_BASE_URL:-https://api.rogue.security}/api/v1/hooks/status" \
  -H "x-rogue-api-key: $ROGUE_API_KEY" \
  -H "Content-Type: application/json" \
  -d "$BODY" \
  >/dev/null 2>&1 || true

exit 0
