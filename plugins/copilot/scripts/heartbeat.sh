#!/usr/bin/env bash
# Usage: heartbeat.sh [TriggerEvent]     (default sessionStart)
#
# Rogue presence heartbeat (GitHub Copilot CLI plugin). Fired detached from
# sessionStart and from agentStop. POSTs /api/v1/hooks/status so this install shows
# up in the dashboard's Coding Agents roster and the org learns which plugin version
# runs (drives the "outdated" badge). Fire-and-forget: never blocks Copilot, always
# exits 0.
#
# TWO TRIGGERS, ONE SCRIPT, exactly as in the Claude plugin. sessionStart fires it
# once per session; agentStop fires it once per TURN. agentStop exists because a
# session left open for days used to produce exactly one beacon and one log upload
# for its whole lifetime - the roster row went stale and the hook log sat on disk
# unshipped. Everything below is unchanged for sessionStart; the only difference on
# an agentStop is that the beacon POST is rate-limited (scripts/beacon.sh) so a
# per-turn trigger does not become a per-turn request. The log shipper needs no such
# gate: it already throttles itself, and a run with nothing new makes no request.
#
# THE agentStop TRIGGER IS SPAWNED BY hook.sh, NOT BY hooks.json, unlike the Claude
# plugin's. Copilot skips untrusted command hooks until the user reviews them via
# /hooks, so a new hooks.json entry would silently disable EVERY Rogue hook on every
# existing install until each user re-approved. The dispatcher already runs on
# agentStop, so firing from there keeps the command strings byte-identical and trust
# intact. agentStop and NOT subagentStop: a subagent's stop is not a user turn, and
# both would beacon for the same turn.
set -u

# Which hook fired us. Anything other than sessionStart is treated as a
# high-frequency trigger and throttled; defaulting to sessionStart keeps the existing
# hooks.json entry - which passes no argument - behaving exactly as it does today.
TRIGGER="${1:-sessionStart}"

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

# ── beacon throttle ────────────────────────────────────────────────────────
# The rule lives in scripts/beacon.sh, a byte-identical copy of
# scripts/shared/beacon.sh shared with the other four sh-side plugins. Every
# per-plugin difference is an argument: the stamp slug (`copilot`, matching the log
# file, not the roster's `github_copilot` display label), and whether this trigger is
# the session one. The knob (ROGUE_HEARTBEAT_MIN_INTERVAL, numeric zero disables,
# non-numeric falls back to the default) is read from the environment inside the
# library, which is correct because the env files were sourced above.
#
# `-r` guarded so a partial or older install degrades to an unthrottled beacon -
# today's behaviour - rather than erroring out under `set -u`.
BEACON_UNTHROTTLED=0
[ "$TRIGGER" = "sessionStart" ] && BEACON_UNTHROTTLED=1
if [ -r "${PLUGIN_ROOT}/scripts/beacon.sh" ]; then
  . "${PLUGIN_ROOT}/scripts/beacon.sh"
else
  rogue_beacon_claim() { return 0; }
fi

# rogue_beacon_claim writes the stamp itself, BEFORE the request - deciding and
# stamping are one call so a caller cannot leave the window permanently open by
# forgetting the second half.
if rogue_beacon_claim copilot "$BEACON_UNTHROTTLED"; then
  curl -sS --max-time 10 -X POST \
    "${ROGUE_BASE_URL:-https://api.rogue.security}/api/v1/hooks/status" \
    -H "x-rogue-api-key: $ROGUE_API_KEY" \
    -H "Content-Type: application/json" \
    -d "$BODY" \
    >/dev/null 2>&1 || true
fi

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
      "${PLUGIN_ROOT}" copilot "$VER" copilot >/dev/null 2>&1 || true
fi

exit 0
