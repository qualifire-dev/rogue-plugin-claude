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
  --data-binary @- --max-time 10 || echo '{}')

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
if printf '%s' "$RESP" | grep -qiE '"decision"[[:space:]]*:[[:space:]]*"block"|"continue"[[:space:]]*:[[:space:]]*false|"permissionDecision"[[:space:]]*:[[:space:]]*"deny"|"behavior"[[:space:]]*:[[:space:]]*"deny"'; then
  BLOCK=1
fi

if [ "$BLOCK" = "1" ]; then
  # Extract reason. First-match heuristic across the field names the formatter
  # uses (permissionDecisionReason for PreToolUse, reason for everything else,
  # stopReason for continue:false). Limitation: doesn't handle JSON-escaped
  # quotes inside reason text — Rogue's reasons don't contain them.
  REASON=$(printf '%s' "$RESP" | sed -E -n 's/.*"permissionDecisionReason"[[:space:]]*:[[:space:]]*"([^"]*)".*/\1/p' | head -1)
  [ -z "$REASON" ] && REASON=$(printf '%s' "$RESP" | sed -E -n 's/.*"reason"[[:space:]]*:[[:space:]]*"([^"]*)".*/\1/p' | head -1)
  [ -z "$REASON" ] && REASON=$(printf '%s' "$RESP" | sed -E -n 's/.*"stopReason"[[:space:]]*:[[:space:]]*"([^"]*)".*/\1/p' | head -1)
  [ -z "$REASON" ] && REASON=$(printf '%s' "$RESP" | sed -E -n 's/.*"message"[[:space:]]*:[[:space:]]*"([^"]*)".*/\1/p' | head -1)
  [ -z "$REASON" ] && REASON="prompt blocked"

  log "outcome=block reason=\"$(sanitize "$REASON")\""
  if [ "${CLAUDE_CODE_ENTRYPOINT:-}" != "cli" ]; then
    # Build a clear, self-explanatory alert: an outcome+what title, then the
    # server reason under a "Why:" label, then the override instruction. Naming
    # the blocked thing (prompt / tool call) and the fix makes the modal
    # actionable instead of dumping a raw detection code.
    case "$EVENT" in
      UserPromptSubmit)            NOUN="prompt" ;;
      PreToolUse|PermissionRequest) NOUN="tool call" ;;
      *)                           NOUN="action" ;;
    esac
    ALERT_TITLE="⛔ Rogue blocked this $NOUN"
    ALERT_MSG="Why:
$REASON"
    # Only add the override line if the reason doesn't already explain rgx!,
    # so we don't print the instruction twice.
    case "$REASON" in
      *rgx!*) : ;;
      *) ALERT_MSG="$ALERT_MSG

To allow it: prepend \"rgx!\" to your prompt and resend (marks it a false positive)." ;;
    esac
    # Background the alert so hook.sh returns immediately. Capture exit code
    # afterward so TCC denials / osascript failures become visible in the log.
    #
    # The trailing `>/dev/null 2>&1 </dev/null` redirects the SUBSHELL's own fds —
    # not just security-alert.sh's. Without it the subshell inherits hook.sh's
    # stdout/stderr (the pipe Claude reads) and, because it waits for the modal to
    # capture alert_rc, holds that pipe OPEN until the dialog is dismissed. Claude
    # waits for stdout EOF up to the hook `timeout`, so a dismissal slower than the
    # timeout makes Claude time the hook out and fail-open — silently letting a
    # blocked prompt through. Detaching the subshell's fds lets hook.sh reach EOF
    # the instant it exits, so the block applies regardless of when the modal closes.
    ( bash "${CLAUDE_PLUGIN_ROOT}/scripts/security-alert.sh" "$ALERT_TITLE" "$ALERT_MSG" critical >/dev/null 2>&1; log "alert_rc=$? entrypoint=${CLAUDE_CODE_ENTRYPOINT:-unset}" ) >/dev/null 2>&1 </dev/null &
  else
    log "alert_skipped=cli"
  fi
else
  log "outcome=allow"
fi

printf '%s' "$RESP"
