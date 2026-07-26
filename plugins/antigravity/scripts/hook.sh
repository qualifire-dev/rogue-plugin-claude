#!/bin/sh
# Rogue Security hook bridge for Google Antigravity — POSIX sh implementation.
# Usage: hook.sh <eventName>   (PreToolUse, PostToolUse, PreInvocation,
# PostInvocation, Stop)
#
# Reads one Antigravity hook event JSON on stdin, POSTs it to the rogue-api
# /hooks/antigravity route, and relays the native Antigravity decision shape
# verbatim on stdout. PURE RELAY: no block-detection regex, no local modal.
# There are exactly TWO stdin mutations: PreInvocation/PostInvocation/Stop append
# the transcript tail (see augment_with_transcript) so the backend can read
# recent turn content, and a subagent's events get their conversationId rewritten
# to the parent's (see reattribute_subagent).
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

# ── Subagent re-attribution ────────────────────────────────────────────────
# An Antigravity subagent (define_subagent → invoke_subagent) runs as its OWN
# conversation: its PreInvocation/PreToolUse/PostToolUse/PostInvocation/Stop all
# arrive with conversationId = the subagent's own id and carry NO parent
# reference (verified: the payload has no parentConversationId / agentId field).
# Persisted verbatim they become an ORPHANED audit session instead of appearing
# in the conversation that spawned them.
#
# The link lives in the PARENT's transcript: the `invoke_subagent` tool RESULT
# row (type INVOKE_SUBAGENT) lists each spawned conversationId, and the parent
# conversation id IS that transcript's directory name. That row is written when
# the tool completes — i.e. before the subagent's first hook can fire — so a
# plain lookup suffices and no flush retry is needed.
#
# Unlike Copilot (whose subagent ids are `toolu_…`/`call_…`, distinguishable at a
# glance), an Antigravity subagent id is an ordinary UUID — there is no way to
# tell from the payload whether a lookup is even worth doing. So the verdict is
# cached per conversation, BOTH ways: a "main" marker for ordinary conversations
# stops them re-scanning on every one of their ~18 events per turn. One scan per
# conversation, ~25ms.
#
# Fail-open: unresolved → body untouched (today's orphaned behaviour, never
# worse).
SUBAGENT_ID=""
SUBAGENT_NAME=""
BRAIN_DIR="${ROGUE_ANTIGRAVITY_BRAIN_DIR:-$HOME/.gemini/antigravity-cli/brain}"
SUBMAP_DIR="${ROGUE_ANTIGRAVITY_SUBMAP_DIR:-$HOME/.rogue/antigravity-submap}"

# Display name from the spawning call: `invoke_subagent`'s args carry a `Role`
# per subagent ("Cat Rhymer"), and the INVOKE_SUBAGENT result row lists the
# conversationIds in the SAME order (verified — the 1st id's own prompt is the
# 1st Prompt). So the name is the Nth Role where N is the id's position. This is
# available at spawn time, which matters: it is the only source present for a
# subagent's EARLY events.
#
# Caveat: with two `invoke_subagent` calls in one conversation the two lists are
# read in file order, which is not step order (see the sort in
# decodeTranscriptTail's counterpart), so positions could misalign. That affects
# only the display name — `x-rogue-subagent-id` is always exact.
# $1 = parent conversation id, $2 = subagent conversation id.
subagent_role_name() {
  _tf="$BRAIN_DIR/$1/.system_generated/logs/transcript_full.jsonl"
  [ -r "$_tf" ] || return 0
  # Position of $2 among the spawned ids. The ids sit inside the row's
  # JSON-STRING content, so their quotes are backslash-escaped — match the bare
  # UUID rather than a quoted one.
  _idx=$(grep '"INVOKE_SUBAGENT"' "$_tf" 2>/dev/null \
    | grep -o 'conversationId[^0-9a-f]*[0-9a-f-]\{36\}' \
    | grep -o '[0-9a-f-]\{36\}' \
    | grep -n "^$2\$" 2>/dev/null | head -1 | cut -d: -f1)
  [ -n "$_idx" ] || return 0
  grep '"invoke_subagent"' "$_tf" 2>/dev/null \
    | grep -o '"Role":"[^"]*"' \
    | sed -n "${_idx}p" \
    | sed 's/^"Role":"//; s/"$//'
}

# Fallback display name, from the parent's delivered-message records:
# messages/<uuid>.json carries {"sender": <child>, "renderDetails":
# {"messageTitle": "Message from <Role> (<TypeName>)"}}. Only exists once the
# subagent has reported back, so this is the late-but-richer source.
# $1 = parent conversation id, $2 = subagent conversation id.
subagent_message_name() {
  _md="$BRAIN_DIR/$1/.system_generated/messages"
  [ -d "$_md" ] || return 0
  for _mf in "$_md"/*.json; do
    [ -r "$_mf" ] || continue
    grep -q "\"$2\"" "$_mf" 2>/dev/null || continue
    sed -n 's/.*"messageTitle"[[:space:]]*:[[:space:]]*"\([^"]*\)".*/\1/p' "$_mf" 2>/dev/null \
      | sed 's/^Message from //' | head -1
    return 0
  done
}

# $1 = parent conversation id, $2 = subagent conversation id.
subagent_display_name() {
  _nm=$(subagent_role_name "$1" "$2")
  [ -n "$_nm" ] || _nm=$(subagent_message_name "$1" "$2")
  printf '%s' "$_nm"
}

# Echo "<parentConversationId>\n<displayName>" when $1 was spawned as a subagent.
# Two-stage on purpose: the broad grep prunes to candidate files in one process
# (fast), then the INVOKE_SUBAGENT filter rejects the false positives — a
# conversation id also appears inside other conversations' CONVERSATION_HISTORY
# summaries, which must NOT be read as a parent link.
resolve_subagent_parent() {
  _sub="$1"
  [ -d "$BRAIN_DIR" ] || return 1
  for _f in $(grep -l "$_sub" "$BRAIN_DIR"/*/.system_generated/logs/transcript_full.jsonl 2>/dev/null); do
    grep '"INVOKE_SUBAGENT"' "$_f" 2>/dev/null | grep -q "$_sub" || continue
    _pd=${_f%/.system_generated/logs/transcript_full.jsonl}
    _parent=${_pd##*/}
    [ -n "$_parent" ] && [ "$_parent" != "$_sub" ] || continue
    printf '%s\n%s' "$_parent" "$(subagent_display_name "$_parent" "$_sub")"
    return 0
  done
  return 1
}

# Rewrite BODY's subagent conversationId to its parent and set SUBAGENT_ID/NAME.
reattribute_subagent() {
  _cid=$(printf '%s' "$BODY" | sed -n 's/.*"conversationId"[[:space:]]*:[[:space:]]*"\([^"]*\)".*/\1/p' | head -1)
  [ -n "$_cid" ] || return

  _cache_file="$SUBMAP_DIR/$_cid"
  _map=""
  if [ -r "$_cache_file" ]; then
    _map=$(cat "$_cache_file" 2>/dev/null)
    [ "$_map" = "main" ] && return          # known ordinary conversation
  else
    _map=$(resolve_subagent_parent "$_cid") || _map=""
    mkdir -p "$SUBMAP_DIR" 2>/dev/null
    # Cache the negative too, so an ordinary conversation scans only once.
    printf '%s' "${_map:-main}" > "$_cache_file" 2>/dev/null
  fi
  [ -n "$_map" ] && [ "$_map" != "main" ] || return

  _parent=$(printf '%s' "$_map" | sed -n '1p')
  SUBAGENT_NAME=$(printf '%s' "$_map" | sed -n '2p')
  [ -n "$_parent" ] || return
  SUBAGENT_ID="$_cid"
  # Tolerate whitespace around the key/colon (a pretty-printed payload) and
  # normalize to compact form; a non-matching rewrite would leave the body
  # orphaned even though the parent was resolved.
  BODY=$(printf '%s' "$BODY" | sed "s/\"conversationId\"[[:space:]]*:[[:space:]]*\"$_cid\"/\"conversationId\":\"$_parent\"/")
  log "subagent=$_cid parent=$_parent name=$(sanitize "$SUBAGENT_NAME")"
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

# Re-attribute BEFORE enriching: augment_with_transcript re-closes the JSON
# object by hand, so mutating conversationId afterwards would have to skip past
# the appended base64 blob.
reattribute_subagent

case "$EVENT" in
  PreInvocation|PostInvocation|Stop) BODY="$(augment_with_transcript "$BODY")" ;;
esac

# Capture body + HTTP status. -w appends a final line "<code>"; on any
# transport failure curl exits non-zero and the code is 000. Relay the body
# ONLY on a clean HTTP 200 so an error page (401/404/500) is never handed to
# Antigravity as a decision.
# Subagent headers ride ONLY re-attributed events: the backend's
# enrichFromHeaders tags every canonical message of the event with
# subagent_id/subagent_name (aidr_message columns) so the rows are
# distinguishable inside the parent's transcript. Passed via a positional set so
# they are omitted entirely — not sent empty — on main-agent events.
set --
if [ -n "$SUBAGENT_ID" ]; then
  set -- -H "x-rogue-subagent-id: $SUBAGENT_ID" -H "x-rogue-subagent-name: $SUBAGENT_NAME"
fi

RAW=$(printf '%s' "$BODY" | curl -sS -X POST "$URL" \
  -H "x-rogue-api-key: $ROGUE_API_KEY" \
  -H "x-rogue-event: $EVENT" \
  -H "x-rogue-actor-email: $ROGUE_ACTOR_EMAIL" \
  -H "x-rogue-actor-name: $ROGUE_ACTOR_NAME" \
  "$@" \
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
