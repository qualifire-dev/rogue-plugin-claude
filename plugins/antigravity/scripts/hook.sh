#!/bin/sh
# Rogue Security hook bridge for Google Antigravity — POSIX sh implementation.
# Usage: hook.sh <eventName>   (PreToolUse, PostToolUse, PreInvocation,
# PostInvocation, Stop)
#
# Reads one Antigravity hook event JSON on stdin, POSTs it to the rogue-api
# /hooks/antigravity route, and relays the native Antigravity decision shape
# verbatim on stdout. PURE RELAY: no block-detection regex, no local modal.
# The only stdin enrichment is PreInvocation/PostInvocation/Stop, which append
# the transcript tail (see augment_with_transcript) so the backend can read
# recent turn content.
#
# FAIL-OPEN IS SAFETY-CRITICAL. PreToolUse must always resolve to an explicit
# decision — never a bare `{}` — so `fail_open_default` emits
# {"decision":"allow"} for PreToolUse and {} for every other event. This
# script MUST always `exit 0`; never `set -e`; never let curl propagate a
# non-zero exit. A block is carried in the relayed JSON body on stdout, never
# via the exit code.
#
# Exactly-one-runs (Windows): unlike Copilot (which selects one command per
# platform), both the sh entry and the PowerShell entry may run on a given
# Antigravity machine. Under Git Bash (uname MINGW*/MSYS*/CYGWIN*) this script
# stands down by emitting NOTHING and exiting 0, so it never contributes a
# decision when the PowerShell handler also runs on the same invocation.
# ROGUE_FORCE_UNAME overrides uname (for tests).
#
# Credential resolution (later file wins; process env wins over all):
#   1. ${PLUGIN_ROOT}/env        (baked into a compiled customer plugin)
#   2. /etc/rogue/env            (MDM-provisioned)
#   3. $HOME/.rogue-env          (per-user / installer-written)

EVENT="$1"

# --- Git Bash stand-down: emit NOTHING so the PowerShell handler owns Windows.
# Must run before ANY other work (env sourcing, actor resolution, POST) so a
# machine running both handlers never double-POSTs / double-decides.
_uname="${ROGUE_FORCE_UNAME:-$(uname -s 2>/dev/null)}"
case "$_uname" in
  MINGW*|MSYS*|CYGWIN*) exit 0 ;;   # empty stdout — no decision contributed
esac

# Self-locate the plugin root from $0 (the path we were invoked with:
# <root>/scripts/hook.sh).
PLUGIN_ROOT="$(CDPATH= cd -- "$(dirname -- "$0")/.." 2>/dev/null && pwd)"
[ -n "$PLUGIN_ROOT" ] || PLUGIN_ROOT="."

# Env precedence (later wins): bundled → MDM → per-user.
[ -r "${PLUGIN_ROOT}/env" ] && . "${PLUGIN_ROOT}/env"
[ -r /etc/rogue/env ]       && . /etc/rogue/env
[ -r "$HOME/.rogue-env" ]   && . "$HOME/.rogue-env"

ROGUE_LOG_FILE="${ROGUE_LOG_FILE:-$HOME/.rogue/hook.log}"
log() {
  mkdir -p "$(dirname "$ROGUE_LOG_FILE")" 2>/dev/null
  printf '%s provider=antigravity event=%s %s\n' \
    "$(date -u +%Y-%m-%dT%H:%M:%SZ)" "$EVENT" "$*" >> "$ROGUE_LOG_FILE" 2>/dev/null
}
sanitize() { printf '%s' "$1" | tr -d '\000-\037\177'; }

# Per-event fail-open default. PreToolUse must resolve to an explicit
# decision (never a bare {}), or Antigravity would treat it as ambiguous;
# every other event is audit/monitor-only and fails open to a clean {}.
fail_open_default() {
  case "$EVENT" in
    PreToolUse) printf '{"decision":"allow"}' ;;
    *)          printf '{}' ;;
  esac
}

# PreInvocation/PostInvocation/Stop carry no message content inline — only a
# transcriptPath pointing at the session's transcript.jsonl. Append the last
# ~256KB of that file, base64-encoded, as "transcriptTailB64" so the backend
# can extract recent turn content. base64 output has no JSON-special
# characters, so appending it by re-closing the object is safe. Fail-open:
# any problem (no path, unreadable, empty) returns the body unchanged.
#
# Antigravity's transcript.jsonl line schema is undocumented — there is no
# known "turn end" marker line to poll for (unlike Copilot's events.jsonl, see
# plugins/copilot/scripts/hook.sh), so this wait is schema-agnostic: it polls
# file SIZE stability instead of a marker line, and is hard time-bounded
# (~2s). On timeout it fails open and tails whatever is on disk rather than
# hanging or guessing at an undocumented marker format.
# $1 = transcript path.
wait_for_transcript_flush() {
  _wtp="$1"
  _n=0
  _prev_size=-1
  # ~2s cap (20 * 0.1s), well inside the 30s hook budget. Returns as soon as
  # the file size is unchanged across two 0.1s-spaced reads (a schema-agnostic
  # proxy for "the writer has finished flushing"). ROGUE_FLUSH_WAIT_ITERS
  # overrides the iteration count (tests set it low to exercise fail-open).
  _max=${ROGUE_FLUSH_WAIT_ITERS:-20}
  while [ "$_n" -lt "$_max" ]; do
    _size=$(wc -c < "$_wtp" 2>/dev/null | tr -d '[:space:]')
    [ -n "$_size" ] || _size=0
    if [ "$_n" -gt 0 ] && [ "$_size" = "$_prev_size" ]; then
      return 0
    fi
    _prev_size="$_size"
    sleep 0.1
    _n=$((_n + 1))
  done
  return 0
}

augment_with_transcript() {
  _body="$1"
  _tp=$(printf '%s' "$_body" | sed -n 's/.*"transcriptPath"[[:space:]]*:[[:space:]]*"\([^"]*\)".*/\1/p')
  [ -n "$_tp" ] || { printf '%s' "$_body"; return; }
  [ -r "$_tp" ] || { printf '%s' "$_body"; return; }
  wait_for_transcript_flush "$_tp"
  _b64=$(tail -c 262144 "$_tp" 2>/dev/null | base64 2>/dev/null | tr -d '\r\n')
  [ -n "$_b64" ] || { printf '%s' "$_body"; return; }
  printf '%s,"transcriptTailB64":"%s"}' "${_body%\}}" "$_b64"
}

# Not configured: never POST without a key. Emit the per-event fail-open
# default so PreToolUse still resolves to an explicit allow decision.
if [ -z "${ROGUE_API_KEY:-}" ]; then
  log "outcome=unconfigured"
  fail_open_default
  exit 0
fi

[ -r "${PLUGIN_ROOT}/scripts/actor.sh" ] && . "${PLUGIN_ROOT}/scripts/actor.sh"

# Trim a trailing slash so a user-set ROGUE_BASE_URL with one doesn't yield
# "//" in the composed URL (mirrors hook.ps1's .TrimEnd('/')).
ROGUE_BASE_URL="${ROGUE_BASE_URL%/}"

URL="${ROGUE_API_URL:-${ROGUE_BASE_URL:-https://api.rogue.security}/api/v1/hooks/antigravity}"

# Buffer stdin so we can enrich it (PreInvocation/PostInvocation/Stop) before
# POSTing.
BODY="$(cat)"

# Heartbeat on the first invocation of a session (invocationNum == 0). Fire
# detached so the hook itself returns immediately regardless of heartbeat.sh's
# own latency.
if [ "$EVENT" = "PreInvocation" ]; then
  case "$BODY" in
    *'"invocationNum":0'*|*'"invocationNum": 0'*)
      ( nohup sh "${PLUGIN_ROOT}/scripts/heartbeat.sh" >/dev/null 2>&1 & ) ;;
  esac
fi

case "$EVENT" in
  PreInvocation|PostInvocation|Stop) BODY="$(augment_with_transcript "$BODY")" ;;
esac

# Capture body + HTTP status. -w appends a final line "<code>"; on any
# transport failure curl exits non-zero and the code is 000. Relay the body
# ONLY on a clean HTTP 200 so an error page (401/404/500) is never handed to
# Antigravity as a decision.
RAW=$(printf '%s' "$BODY" | curl -sS -X POST "$URL" \
  -H "x-rogue-api-key: $ROGUE_API_KEY" \
  -H "x-rogue-event: $EVENT" \
  -H "x-rogue-actor-email: $ROGUE_ACTOR_EMAIL" \
  -H "x-rogue-actor-name: $ROGUE_ACTOR_NAME" \
  -H 'Content-Type: application/json' \
  --data-binary @- --max-time 15 -w '\n%{http_code}')
RC=$?
CODE=$(printf '%s' "$RAW" | tail -n1)
RESP_BODY=$(printf '%s' "$RAW" | sed '$d')

log "http=$CODE rc=$RC raw=$(sanitize "$RESP_BODY" | head -c 400)"

# Fail-open on transport error, any non-200, or an empty body: emit the
# per-event default rather than relaying garbage as a decision.
if [ "$RC" -ne 0 ] || [ "$CODE" != "200" ] || [ -z "$RESP_BODY" ]; then
  log "outcome=allow http=$CODE rc=$RC"
  fail_open_default
  exit 0
fi

# rogue-api already returns the correct native Antigravity shape; relay it
# verbatim.
printf '%s' "$RESP_BODY"
exit 0
