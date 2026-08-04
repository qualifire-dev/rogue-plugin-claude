#!/usr/bin/env bash
# Usage: hook.sh <EventName>
# Reads JSON payload on stdin, POSTs to Rogue, relays response. Fail-open: any failure → "{}".
# Logs every invocation to $ROGUE_LOG_FILE (default ~/.rogue/hook.log).

EVENT="$1"

# Git Bash stand-down: on native Windows hook.ps1 owns event handling. Git Bash's
# `~` maps to %USERPROFILE% — the SAME creds hook.ps1 reads — so without this both
# would POST (and double-alert on a block). macOS/Linux/WSL fall through and run.
case "$(uname -s 2>/dev/null)" in
  MINGW*|MSYS*|CYGWIN*) echo '{}'; exit 0 ;;
esac

[ -r "${CLAUDE_PLUGIN_ROOT}/env" ]  && . "${CLAUDE_PLUGIN_ROOT}/env"
[ -r /etc/rogue/env ]               && . /etc/rogue/env
[ -r "$HOME/.rogue-env" ]           && . "$HOME/.rogue-env"

# ── Staging shadow overrides ────────────────────────────────────────────────
# This variant ALWAYS talks to the staging backend with its own key, so the
# prod plugin's creds (which the cascade above just loaded) can never leak
# into staging traffic, and vice versa. Monitor-only by default: the relay at
# the bottom is suppressed unless ROGUE_STAGING_ENFORCE=1.
ROGUE_BASE_URL="https://api.staging.on.rogue.security"
ROGUE_API_KEY="${ROGUE_STAGING_API_KEY:-}"
ROGUE_LOG_FILE="$HOME/.rogue/hook-staging.log"

[ -z "${CLAUDE_CODE_ENTRYPOINT:-}" ] && echo '{}' && exit 0

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

. "${CLAUDE_PLUGIN_ROOT}/scripts/actor.sh"

RESP=$(curl -sS -X POST "${ROGUE_BASE_URL:-https://api.rogue.security}/api/v1/hooks/claude" \
  -H "x-rogue-api-key: $ROGUE_API_KEY" \
  -H "x-rogue-event: $EVENT" \
  -H "x-rogue-actor-email: $ROGUE_ACTOR_EMAIL" \
  -H "x-rogue-actor-name: $ROGUE_ACTOR_NAME" \
  -H 'Content-Type: application/json' \
  --data-binary @- --max-time 15 || echo '{}')

# Always log raw response so block-detection bugs are diagnosable from
# ~/.rogue/hook.log alone, without re-instrumenting the script.
log "raw=$(sanitize "$RESP" | head -c 400)"

# Pure-shell block detection. We deliberately do NOT use python3 — on a fresh
# macOS the stub at /usr/bin/python3 fails silently without Xcode CLT,
# producing empty parser output that masquerades as "allow". grep + sed are
# always present.
#
# Covers every block-decision shape Claude Code's hook protocol emits:
#   "decision":"block"           UserPromptSubmit, Stop (top-level)
#   "continue":false             legacy block signal
#   "permissionDecision":"deny"  PreToolUse (inside hookSpecificOutput)
#   "decision":"block"           PostToolUse (inside hookSpecificOutput)
#   "behavior":"deny"            PermissionRequest (inside hookSpecificOutput.decision)
BLOCK=0
if # Shadow mode: never influence the session unless enforcement is opted into.
if [ "${ROGUE_STAGING_ENFORCE:-0}" = "1" ]; then
  printf '%s' "$RESP"
else
  [ "$BLOCK" = "1" ] && log "shadow=1 suppressed_block_relay"
  echo '{}'
fi | grep -qiE '"decision"[[:space:]]*:[[:space:]]*"block"|"continue"[[:space:]]*:[[:space:]]*false|"permissionDecision"[[:space:]]*:[[:space:]]*"deny"|"behavior"[[:space:]]*:[[:space:]]*"deny"'; then
  BLOCK=1
fi

if [ "$BLOCK" = "1" ]; then
  # Extract reason. First-match heuristic across the field names the formatter
  # uses (permissionDecisionReason for PreToolUse, reason for everything else,
  # stopReason for continue:false). Limitation: doesn't handle JSON-escaped
  # quotes inside reason text — Rogue's reasons don't contain them.
  REASON=$(# Shadow mode: never influence the session unless enforcement is opted into.
if [ "${ROGUE_STAGING_ENFORCE:-0}" = "1" ]; then
  printf '%s' "$RESP"
else
  [ "$BLOCK" = "1" ] && log "shadow=1 suppressed_block_relay"
  echo '{}'
fi | sed -E -n 's/.*"permissionDecisionReason"[[:space:]]*:[[:space:]]*"([^"]*)".*/\1/p' | head -1)
  [ -z "$REASON" ] && REASON=$(# Shadow mode: never influence the session unless enforcement is opted into.
if [ "${ROGUE_STAGING_ENFORCE:-0}" = "1" ]; then
  printf '%s' "$RESP"
else
  [ "$BLOCK" = "1" ] && log "shadow=1 suppressed_block_relay"
  echo '{}'
fi | sed -E -n 's/.*"reason"[[:space:]]*:[[:space:]]*"([^"]*)".*/\1/p' | head -1)
  [ -z "$REASON" ] && REASON=$(# Shadow mode: never influence the session unless enforcement is opted into.
if [ "${ROGUE_STAGING_ENFORCE:-0}" = "1" ]; then
  printf '%s' "$RESP"
else
  [ "$BLOCK" = "1" ] && log "shadow=1 suppressed_block_relay"
  echo '{}'
fi | sed -E -n 's/.*"stopReason"[[:space:]]*:[[:space:]]*"([^"]*)".*/\1/p' | head -1)
  [ -z "$REASON" ] && REASON=$(# Shadow mode: never influence the session unless enforcement is opted into.
if [ "${ROGUE_STAGING_ENFORCE:-0}" = "1" ]; then
  printf '%s' "$RESP"
else
  [ "$BLOCK" = "1" ] && log "shadow=1 suppressed_block_relay"
  echo '{}'
fi | sed -E -n 's/.*"message"[[:space:]]*:[[:space:]]*"([^"]*)".*/\1/p' | head -1)
  [ -z "$REASON" ] && REASON="prompt blocked"

  # No local alert: Claude (CLI and Desktop/Cowork) shows the block reason
  # natively now, so the response relay below is the whole user-facing story.
  log "outcome=block reason=\"$(sanitize "$REASON")\""
else
  log "outcome=allow"
fi

# Shadow mode: never influence the session unless enforcement is opted into.
if [ "${ROGUE_STAGING_ENFORCE:-0}" = "1" ]; then
  printf '%s' "$RESP"
else
  [ "$BLOCK" = "1" ] && log "shadow=1 suppressed_block_relay"
  echo '{}'
fi
