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
# Host + version + surface. Shared with hook.sh, which sends the same three as
# headers on every event: same values, same roster row. See install-id.sh.
[ -r "${PLUGIN_ROOT}/scripts/install-id.sh" ] && . "${PLUGIN_ROOT}/scripts/install-id.sh"

# Family is the fixed enum "copilot"; surface rides the agent field.
esc() { printf '%s' "$1" | sed -e 's/\\/\\\\/g' -e 's/"/\\"/g'; }
BODY=$(printf '{"agent_family":"copilot","agent":"%s","version":"%s","host":"%s","actor_email":"%s","actor_name":"%s"}' \
  "$(esc "${ROGUE_INSTALL_AGENT:-github_copilot}")" "$(esc "${ROGUE_INSTALL_VERSION:-unknown}")" \
  "$(esc "${ROGUE_INSTALL_HOST:-unknown}")" \
  "$(esc "${ROGUE_ACTOR_EMAIL:-}")" "$(esc "${ROGUE_ACTOR_NAME:-}")")

curl -sS --max-time 10 -X POST \
  "${ROGUE_BASE_URL:-https://api.rogue.security}/api/v1/hooks/status" \
  -H "x-rogue-api-key: $ROGUE_API_KEY" \
  -H "Content-Type: application/json" \
  -d "$BODY" \
  >/dev/null 2>&1 || true

# ── ship the hook log ──────────────────────────────────────────────────────
# See plugins/rogue/scripts/heartbeat.sh for why this runs after the POST (the
# roster row must exist first), why it needs no extra backgrounding (this script is
# already detached) and why the actor is passed in rather than re-resolved (a
# second cascade would key the log's source row differently from the roster row).
#
# Slug `copilot` (the log file and the dispatcher's `provider=` token) with family
# `copilot`; the roster's display label is `github_copilot`, which is this script's
# business and not the shipper's - it takes the family, never the label.
if [ -r "${PLUGIN_ROOT}/scripts/ship-logs.sh" ]; then
  ROGUE_ACTOR_EMAIL="${ROGUE_ACTOR_EMAIL:-}" ROGUE_ACTOR_NAME="${ROGUE_ACTOR_NAME:-}" \
    sh "${PLUGIN_ROOT}/scripts/ship-logs.sh" \
      "${PLUGIN_ROOT}" copilot "${ROGUE_INSTALL_VERSION:-unknown}" copilot >/dev/null 2>&1 || true
fi

exit 0
