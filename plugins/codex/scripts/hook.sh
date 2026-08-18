#!/usr/bin/env bash
# Usage: hook.sh <EventName>
# Reads one Codex hook event JSON on stdin, POSTs it to the rogue-api
# /hooks/openai route, relays the native Codex response verbatim on stdout.
# Fail-open: any failure → "{}". Logs every invocation to $ROGUE_LOG_FILE.
#
# Unlike the Claude bridge this is a PURE RELAY: no block-detection regex and no
# security-alert modal. Codex surfaces the native deny shape itself (the Claude
# modal exists only because the Claude app doesn't display the block reason).

EVENT="$1"

# Codex sets PLUGIN_ROOT to the installed plugin directory.
PLUGIN_ROOT="${PLUGIN_ROOT:-}"

# Env precedence (later wins): bundled → MDM → per-user.
[ -r "${PLUGIN_ROOT}/env" ]  && . "${PLUGIN_ROOT}/env"
[ -r /etc/rogue/env ]               && . /etc/rogue/env
[ -r "$HOME/.rogue-env" ]           && . "$HOME/.rogue-env"

ROGUE_LOG_FILE="${ROGUE_LOG_FILE:-$HOME/.rogue/hook.log}"
log() {
  mkdir -p "$(dirname "$ROGUE_LOG_FILE")" 2>/dev/null
  printf '%s event=%s %s\n' "$(date -u +%Y-%m-%dT%H:%M:%SZ)" "$EVENT" "$*" >> "$ROGUE_LOG_FILE" 2>/dev/null
}
sanitize() { printf '%s' "$1" | tr -d '\000-\037\177'; }

if [ -z "${ROGUE_API_KEY:-}" ]; then
  log "outcome=unconfigured"
  echo '{}'
  exit 0
fi

. "${PLUGIN_ROOT}/scripts/actor.sh"
# Host + version + surface, resolved exactly as heartbeat.sh does. Sent on every
# event so the fleet roster's row stays fresh between session starts, which are
# the only moments the heartbeat runs. See install-id.sh.
. "${PLUGIN_ROOT}/scripts/install-id.sh"
# A degraded value is still sent (never a hard failure — see install-id.sh), but
# it is worth knowing about: an "unknown" host or version means this install
# reports itself imprecisely to the fleet roster.
[ -n "${ROGUE_INSTALL_ID_WARN:-}" ] && log "warn=install-id $ROGUE_INSTALL_ID_WARN"

URL="${ROGUE_API_URL:-${ROGUE_BASE_URL:-https://api.rogue.security}/api/v1/hooks/openai}"

# Capture body + HTTP status. -w appends a final line "<code>"; on any curl/transport
# failure curl exits non-zero and the code is 000. We relay the body ONLY on a clean
# HTTP 200 so an error page (401/404/500) is never handed to Codex as a hook decision.
RAW=$(curl -sS -X POST "$URL" \
  -H "x-rogue-api-key: $ROGUE_API_KEY" \
  -H "x-rogue-event: $EVENT" \
  -H "x-rogue-agent: $ROGUE_INSTALL_AGENT" \
  -H "x-rogue-host: $ROGUE_INSTALL_HOST" \
  -H "x-rogue-version: $ROGUE_INSTALL_VERSION" \
  -H "x-rogue-actor-email: $ROGUE_ACTOR_EMAIL" \
  -H "x-rogue-actor-name: $ROGUE_ACTOR_NAME" \
  -H 'Content-Type: application/json' \
  --data-binary @- --max-time 8 -w '\n%{http_code}')
RC=$?
CODE=$(printf '%s' "$RAW" | tail -n1)
BODY=$(printf '%s' "$RAW" | sed '$d')

log "outcome_raw=$(sanitize "$BODY" | head -c 400) http=$CODE rc=$RC"

# Fail-open on transport error or any non-200: emit a clean allow.
if [ "$RC" -ne 0 ] || [ "$CODE" != "200" ] || [ -z "$BODY" ]; then
  log "outcome=allow http=$CODE rc=$RC"
  echo '{}'
  exit 0
fi

# rogue-api already returns the correct native Codex shape; relay it verbatim.
printf '%s' "$BODY"
