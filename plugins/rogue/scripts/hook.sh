#!/usr/bin/env bash
# Usage: hook.sh <EventName>
# Reads JSON payload on stdin, POSTs to Rogue, relays response. Fail-open: any failure → "{}".
# Logs every invocation to $ROGUE_LOG_FILE (default ~/.rogue/logs/claude.log).

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

# Which SURFACE of Claude wrote this line - cli, desktop or cowork. One file per
# agent family means every surface on the machine appends to the same claude.log,
# and nothing on the line said which one. The mapping is shared with heartbeat.sh
# (see scripts/surface.sh) precisely so the line and the roster row it belongs to
# can never name different surfaces. Sourcing is guarded and the result may be
# empty; an empty SURFACE omits the token rather than writing surface=unknown.
# Unreachable here in practice: the gate above already returned when the
# entrypoint was unset, and any non-empty value maps to a slug.
SURFACE=""
if [ -r "${CLAUDE_PLUGIN_ROOT}/scripts/surface.sh" ]; then
  . "${CLAUDE_PLUGIN_ROOT}/scripts/surface.sh"
  SURFACE=$(rogue_surface_slug 2>/dev/null)
fi

# Log destination — ONE FILE PER AGENT. Every Rogue plugin shares ~/.rogue, so a
# machine running Claude Code + Codex + Cursor + … used to interleave all of them
# into a single hook.log with no way to tell whose line was whose. Precedence:
# explicit file → directory override → per-agent default.
ROGUE_LOG_DIR="${ROGUE_LOG_DIR:-$HOME/.rogue/logs}"
ROGUE_LOG_FILE="${ROGUE_LOG_FILE:-$ROGUE_LOG_DIR/claude.log}"
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
    # `${SURFACE:+ surface=$SURFACE}` expands to NOTHING when the slug is empty,
    # so an undetermined surface leaves the line exactly as older versions wrote
    # it - the token is optional, never `surface=` and never `surface=unknown`.
    printf '%s provider=claude%s event=%s %s\n' \
      "$(date -u +%Y-%m-%dT%H:%M:%SZ)" "${SURFACE:+ surface=$SURFACE}" \
      "$EVENT" "$*" >> "$ROGUE_LOG_FILE" 2>/dev/null )
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
# ~/.rogue/logs/claude.log alone, without re-instrumenting the script.
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

  # No local alert: Claude (CLI and Desktop/Cowork) shows the block reason
  # natively now, so the response relay below is the whole user-facing story.
  log "outcome=block reason=\"$(sanitize "$REASON")\""
else
  log "outcome=allow"
fi

printf '%s' "$RESP"
