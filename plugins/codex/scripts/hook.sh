#!/usr/bin/env bash
# Usage: hook.sh <EventName>
# Reads one Codex hook event JSON on stdin, POSTs it to the rogue-api
# /hooks/openai route, relays the native Codex response verbatim on stdout.
# Fail-open: any failure → "{}". Logs every invocation to $ROGUE_LOG_FILE
# (default ~/.rogue/logs/codex.log).
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

# Log destination — ONE FILE PER AGENT. Every Rogue plugin shares ~/.rogue, so a
# machine running Codex + Claude Code + Cursor + … used to interleave all of them
# into a single hook.log with no way to tell whose line was whose. Precedence:
# explicit file → directory override → per-agent default.
ROGUE_LOG_DIR="${ROGUE_LOG_DIR:-$HOME/.rogue/logs}"
ROGUE_LOG_FILE="${ROGUE_LOG_FILE:-$ROGUE_LOG_DIR/codex.log}"
# Size cap. Over it, the current log is renamed to <file>.1 - exactly one
# generation kept, so worst case on disk is 2x this. A NUMERIC ZERO disables
# rotation; a NON-NUMERIC value falls back to this default, so a typo can
# never leave the log growing unbounded. Enforced on the WRITE PATH rather
# than by a periodic job because an UNCONFIGURED install writes a line per
# event and never runs anything else - a cap enforced anywhere else would
# not hold.
ROGUE_LOG_MAX_BYTES="${ROGUE_LOG_MAX_BYTES:-10485760}"
# Clamp per the rule above: anything non-numeric becomes the default.
case "$ROGUE_LOG_MAX_BYTES" in ""|*[!0-9]*) ROGUE_LOG_MAX_BYTES=10485760 ;; esac
# An all-digit value can still overflow the shell's integer type: dash answers
# `[ "$cap" -gt 0 ]` with "Illegal number" on stderr and a FALSE, which reads
# as "rotation disabled" and lets the log grow unbounded. Node has the same
# bug through Number() -> Infinity; PowerShell is the only one that already
# lands on the default, and only because its cast error is silenced. All
# three clamp explicitly now. 18 digits is the widest value guaranteed to fit
# a signed 64-bit int; leading zeros are stripped first so "000...0" still
# reads as the rotation-disabling zero.
_lcap="$ROGUE_LOG_MAX_BYTES"
while [ "${_lcap#0}" != "$_lcap" ]; do _lcap="${_lcap#0}"; done
if [ "${#_lcap}" -gt 18 ]; then ROGUE_LOG_MAX_BYTES=10485760; fi
rotate_log() {
  [ -f "$ROGUE_LOG_FILE" ] || return 0
  # Arithmetic, not a glob: "00" must mean zero here exactly as [int64]"00"
  # and Number("00") do in the PowerShell and Node dispatchers.
  [ "$ROGUE_LOG_MAX_BYTES" -gt 0 ] || return 0
  # `wc -c` not `stat`: BSD and GNU stat take different flags for file size.
  _lsz=$(wc -c < "$ROGUE_LOG_FILE" 2>/dev/null | tr -d '[:space:]')
  case "$_lsz" in ''|*[!0-9]*) return 0 ;; esac
  [ "$_lsz" -ge "$ROGUE_LOG_MAX_BYTES" ] && mv -f "$ROGUE_LOG_FILE" "$ROGUE_LOG_FILE.1" 2>/dev/null
  return 0
}
log() {
  # 0700 dir / 0600 file. The logged text is not only ours: it carries the
  # server's block reason, which quotes the content that tripped the rule - a
  # secret, a command, a slice of a prompt. Under the default umask the log
  # lands 0644 and every other account on the box can read it. The umask
  # applies to what THIS call creates, so a 0644 log from an older version
  # keeps its mode; Windows needs no counterpart, since another standard user
  # cannot read %USERPROFILE% to begin with.
  ( umask 077
    mkdir -p "$(dirname "$ROGUE_LOG_FILE")" 2>/dev/null
    rotate_log
    printf '%s provider=codex event=%s %s\n' \
      "$(date -u +%Y-%m-%dT%H:%M:%SZ)" "$EVENT" "$*" >> "$ROGUE_LOG_FILE" 2>/dev/null )
}
sanitize() { printf '%s' "$1" | tr -d '\000-\037\177'; }

if [ -z "${ROGUE_API_KEY:-}" ]; then
  log "outcome=unconfigured"
  echo '{}'
  exit 0
fi

. "${PLUGIN_ROOT}/scripts/actor.sh"

# Surface label (codex_app | codex_cli). Codex sets no app/cli entrypoint var, so
# the installer pins ROGUE_CODEX_SURFACE per surface; default to codex_cli.
SURFACE="${ROGUE_CODEX_SURFACE:-codex_cli}"

URL="${ROGUE_API_URL:-${ROGUE_BASE_URL:-https://api.rogue.security}/api/v1/hooks/openai}"

# Capture body + HTTP status. -w appends a final line "<code>"; on any curl/transport
# failure curl exits non-zero and the code is 000. We relay the body ONLY on a clean
# HTTP 200 so an error page (401/404/500) is never handed to Codex as a hook decision.
RAW=$(curl -sS -X POST "$URL" \
  -H "x-rogue-api-key: $ROGUE_API_KEY" \
  -H "x-rogue-event: $EVENT" \
  -H "x-rogue-agent: $SURFACE" \
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
