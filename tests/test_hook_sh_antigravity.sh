#!/usr/bin/env bash
# tests/test_hook_sh_antigravity.sh — end-to-end for the Antigravity POSIX-sh
# dispatcher (plugins/antigravity/scripts/hook.sh): env file → hook.sh → mock
# server → stdout. Holds the dispatcher to the verbatim-relay + header +
# per-event fail-open + Git-Bash-stand-down + PreInvocation-heartbeat contract.
#
# Antigravity CLI runs the `sh` command on macOS/Linux; override with
# TEST_SH=dash to exercise strict POSIX and catch bashisms.
set -euo pipefail

REPO="$(cd "$(dirname "$0")/.." && pwd)"
HOOK="$REPO/plugins/antigravity/scripts/hook.sh"
ACTOR="$REPO/plugins/antigravity/scripts/actor.sh"
SH="${TEST_SH:-sh}"

PORT=$((RANDOM % 10000 + 30000))
HEADERS_FILE="$(mktemp)"
ENV_FILE="$(mktemp)"
OUT_FILE="$(mktemp)"

cleanup() {
  [ -n "${MOCK_PID:-}" ] && kill "$MOCK_PID" 2>/dev/null || true
  rm -f "$ENV_FILE" "$HEADERS_FILE" "$OUT_FILE"
}
trap cleanup EXIT

cat > "$ENV_FILE" <<EOF
export ROGUE_API_KEY=test-key
export ROGUE_ACTOR_EMAIL=test@example.com
export ROGUE_ACTOR_NAME='Test User'
export ROGUE_BASE_URL=http://127.0.0.1:${PORT}
EOF

# Run with a clean HOME holding our env file. Clears ROGUE_* from the process
# env so only the file drives resolution (process env would otherwise win).
# Writes stdout to $OUT_FILE and RETURNS the dispatcher's exit code (command
# substitution would otherwise hide it in a subshell).
run_dispatcher() {
  local tmp_home rc
  tmp_home="$(mktemp -d)"
  cp "$ENV_FILE" "$tmp_home/.rogue-env"
  set +e
  HOME="$tmp_home" \
    ROGUE_API_KEY='' ROGUE_ACTOR_EMAIL='' ROGUE_ACTOR_NAME='' ROGUE_BASE_URL='' \
    ROGUE_LOG_FILE="$tmp_home/hook.log" \
    ROGUE_FORCE_UNAME="${ROGUE_FORCE_UNAME:-}" \
    "$SH" "$HOOK" "$1" <<< "$2" > "$OUT_FILE"
  rc=$?
  set -e
  rm -rf "$tmp_home"
  return $rc
}

start_mock() {
  MOCK_RESPONSE="$1" MOCK_STATUS="${2:-200}" \
    python3 "$REPO/tests/mock_server.py" "$PORT" "$HEADERS_FILE" &
  MOCK_PID=$!
  for _ in $(seq 1 50); do
    nc -z 127.0.0.1 "$PORT" 2>/dev/null && return 0
    sleep 0.1
  done
  echo "mock server failed to start" >&2; exit 1
}

restart_mock() {
  [ -n "${MOCK_PID:-}" ] && kill "$MOCK_PID" 2>/dev/null || true
  wait "$MOCK_PID" 2>/dev/null || true
  start_mock "$@"
}

stop_mock() {
  [ -n "${MOCK_PID:-}" ] && kill "$MOCK_PID" 2>/dev/null || true
  wait "$MOCK_PID" 2>/dev/null || true
  MOCK_PID=""
}

assert_eq() {
  if [ "$1" != "$2" ]; then echo "FAIL [$3]: expected <$2> but got <$1>" >&2; exit 1; fi
  echo "  ok: $3"
}

assert_header() {
  local key="$1" expected="$2" label="$3" actual
  actual=$(python3 -c 'import json,sys; print(json.load(open(sys.argv[1]))["headers"].get(sys.argv[2], ""))' "$HEADERS_FILE" "$key")
  assert_eq "$actual" "$expected" "$label"
}

assert_no_header() {
  local key="$1" label="$2" actual
  actual=$(python3 -c 'import json,sys; print(sys.argv[2] in json.load(open(sys.argv[1]))["headers"])' "$HEADERS_FILE" "$key")
  assert_eq "$actual" "False" "$label"
}

# ── Case 1: PreToolUse deny relayed verbatim + headers + path + exit 0 ─────
start_mock '{"decision":"deny","reason":"x"}'
set +e; run_dispatcher PreToolUse '{"toolName":"bash","toolArgs":{"command":"rm -rf /"}}'; LAST_RC=$?; set -e
out=$(cat "$OUT_FILE")
assert_eq "$out" '{"decision":"deny","reason":"x"}' "PreToolUse deny relayed verbatim"
assert_eq "$LAST_RC" "0" "PreToolUse deny still exits 0"
assert_header "x-rogue-event"       "PreToolUse"       "x-rogue-event is the verbatim Antigravity event name"
assert_header "x-rogue-api-key"     "test-key"         "x-rogue-api-key forwarded"
assert_header "x-rogue-actor-email" "test@example.com" "x-rogue-actor-email forwarded"
assert_header "x-rogue-actor-name"  "Test User"        "x-rogue-actor-name forwarded (with space)"
assert_no_header "x-rogue-source"   "no x-rogue-source header (cursor-only)"
assert_no_header "x-rogue-agent"    "no x-rogue-agent header (codex-only)"
path=$(python3 -c 'import json,sys; print(json.load(open(sys.argv[1]))["path"])' "$HEADERS_FILE")
assert_eq "$path" "/api/v1/hooks/antigravity" "POST path is /api/v1/hooks/antigravity"
body=$(python3 -c 'import json,sys; print(json.load(open(sys.argv[1]))["body"])' "$HEADERS_FILE")
assert_eq "$body" '{"toolName":"bash","toolArgs":{"command":"rm -rf /"}}' "request body passed through unchanged"

# ── Case 2: missing ROGUE_API_KEY on PreToolUse → {"decision":"allow"} ──────
TMP_HOME="$(mktemp -d)"
set +e
out=$(HOME="$TMP_HOME" ROGUE_API_KEY='' ROGUE_LOG_FILE="$TMP_HOME/h.log" "$SH" "$HOOK" PreToolUse <<< '{}')
rc=$?
set -e
rm -rf "$TMP_HOME"
assert_eq "$out" '{"decision":"allow"}' "unconfigured PreToolUse fails open to decision:allow"
assert_eq "$rc" "0" "unconfigured PreToolUse exits 0"

# ── Case 3: missing key on PostToolUse → {} ─────────────────────────────────
TMP_HOME="$(mktemp -d)"
set +e
out=$(HOME="$TMP_HOME" ROGUE_API_KEY='' ROGUE_LOG_FILE="$TMP_HOME/h.log" "$SH" "$HOOK" PostToolUse <<< '{}')
rc=$?
set -e
rm -rf "$TMP_HOME"
assert_eq "$out" "{}" "unconfigured PostToolUse fails open to {}"
assert_eq "$rc" "0" "unconfigured PostToolUse exits 0"

# ── Case 4: non-200 on PreToolUse → {"decision":"allow"} ───────────────────
restart_mock '{"decision":"deny"}' 500
set +e; run_dispatcher PreToolUse '{"toolName":"bash"}'; LAST_RC=$?; set -e
out=$(cat "$OUT_FILE")
assert_eq "$out" '{"decision":"allow"}' "non-200 PreToolUse fails open to decision:allow"
assert_eq "$LAST_RC" "0" "non-200 PreToolUse exits 0"

# ── Case 5: unreachable server on PreToolUse → {"decision":"allow"} ────────
stop_mock
set +e; run_dispatcher PreToolUse '{"toolName":"bash"}'; LAST_RC=$?; set -e
out=$(cat "$OUT_FILE")
assert_eq "$out" '{"decision":"allow"}' "unreachable server PreToolUse fails open to decision:allow"
assert_eq "$LAST_RC" "0" "unreachable server PreToolUse exits 0"

# ── Case 6: Git Bash stand-down (ROGUE_FORCE_UNAME=MINGW64) → EMPTY stdout ──
set +e
out=$(ROGUE_FORCE_UNAME=MINGW64 "$SH" "$HOOK" PreToolUse <<< '{}')
rc=$?
set -e
assert_eq "$out" "" "Git Bash stand-down emits EMPTY stdout (no decision contributed)"
assert_eq "$rc" "0" "Git Bash stand-down exits 0"

# ── Case 7: PreInvocation with invocationNum:0 → heartbeat.sh invoked ──────
# hook.sh self-locates PLUGIN_ROOT from $0 (dirname of the invoked path), so to
# assert the heartbeat launch without depending on (or clobbering) the real
# heartbeat.sh — owned by a concurrent task and not guaranteed to exist yet —
# stage a throwaway plugin root: copy the hook.sh under test + the real
# actor.sh into <tmp>/scripts/, plus a STUB heartbeat.sh that just touches a
# marker file. Invoking hook.sh via that path makes PLUGIN_ROOT resolve to the
# tmp root, so "${PLUGIN_ROOT}/scripts/heartbeat.sh" hits our stub.
restart_mock '{}'
STAGE="$(mktemp -d)"
mkdir -p "$STAGE/scripts"
cp "$HOOK" "$STAGE/scripts/hook.sh"
cp "$ACTOR" "$STAGE/scripts/actor.sh"
MARKER="$STAGE/heartbeat-fired"
cat > "$STAGE/scripts/heartbeat.sh" <<EOF
#!/bin/sh
touch "$MARKER"
EOF
chmod +x "$STAGE/scripts/hook.sh" "$STAGE/scripts/heartbeat.sh"

tmp_home="$(mktemp -d)"
cp "$ENV_FILE" "$tmp_home/.rogue-env"
set +e
HOME="$tmp_home" \
  ROGUE_API_KEY='' ROGUE_ACTOR_EMAIL='' ROGUE_ACTOR_NAME='' ROGUE_BASE_URL='' \
  ROGUE_LOG_FILE="$tmp_home/hook.log" \
  "$SH" "$STAGE/scripts/hook.sh" PreInvocation <<< '{"invocationNum":0}' > "$OUT_FILE"
rc=$?
set -e
rm -rf "$tmp_home"
assert_eq "$rc" "0" "PreInvocation invocationNum:0 exits 0"
# heartbeat.sh is launched via a backgrounded `nohup ... &`; give it a moment
# to actually run before asserting the marker.
for _ in $(seq 1 30); do
  [ -f "$MARKER" ] && break
  sleep 0.1
done
if [ -f "$MARKER" ]; then
  echo "  ok: PreInvocation invocationNum:0 launches heartbeat.sh"
else
  echo "FAIL [heartbeat launch]: marker file $MARKER was never created" >&2
  exit 1
fi
rm -rf "$STAGE"

# ── Case 8: PreInvocation with invocationNum != 0 → heartbeat NOT invoked ──
restart_mock '{}'
STAGE="$(mktemp -d)"
mkdir -p "$STAGE/scripts"
cp "$HOOK" "$STAGE/scripts/hook.sh"
cp "$ACTOR" "$STAGE/scripts/actor.sh"
MARKER="$STAGE/heartbeat-fired"
cat > "$STAGE/scripts/heartbeat.sh" <<EOF
#!/bin/sh
touch "$MARKER"
EOF
chmod +x "$STAGE/scripts/hook.sh" "$STAGE/scripts/heartbeat.sh"

tmp_home="$(mktemp -d)"
cp "$ENV_FILE" "$tmp_home/.rogue-env"
set +e
HOME="$tmp_home" \
  ROGUE_API_KEY='' ROGUE_ACTOR_EMAIL='' ROGUE_ACTOR_NAME='' ROGUE_BASE_URL='' \
  ROGUE_LOG_FILE="$tmp_home/hook.log" \
  "$SH" "$STAGE/scripts/hook.sh" PreInvocation <<< '{"invocationNum":3}' > "$OUT_FILE"
rc=$?
set -e
rm -rf "$tmp_home"
assert_eq "$rc" "0" "PreInvocation invocationNum:3 exits 0"
sleep 0.3
if [ -f "$MARKER" ]; then
  echo "FAIL [heartbeat non-launch]: marker file was created for invocationNum!=0" >&2
  exit 1
else
  echo "  ok: PreInvocation invocationNum!=0 does not launch heartbeat.sh"
fi
rm -rf "$STAGE"

# ── Case 9: PreInvocation transcript-tail enrichment (augment_with_transcript) ─
TDIR="$(mktemp -d)"
printf '%s\n' \
  '{"type":"user.message","timestamp":"2026-07-20T09:00:00.000Z","data":{"content":"hi"}}' \
  '{"type":"assistant.message","timestamp":"2026-07-20T09:00:02.000Z","data":{"content":"ANTIGRAVITY final"}}' \
  > "$TDIR/transcript.jsonl"
restart_mock '{}'
PAYLOAD=$(printf '{"invocationNum":1,"transcriptPath":"%s"}' "$TDIR/transcript.jsonl")
set +e; run_dispatcher PreInvocation "$PAYLOAD"; LAST_RC=$?; set -e
assert_eq "$LAST_RC" "0" "PreInvocation transcript enrichment exits 0"
body=$(python3 -c 'import json,sys; print(json.load(open(sys.argv[1]))["body"])' "$HEADERS_FILE")
valid=$(printf '%s' "$body" | python3 -c 'import json,sys; d=json.load(sys.stdin); print("transcriptTailB64" in d)')
assert_eq "$valid" "True" "PreInvocation body is valid JSON with transcriptTailB64"
b64=$(printf '%s' "$body" | python3 -c 'import json,sys; print(json.load(sys.stdin).get("transcriptTailB64",""))')
decoded=$(python3 -c 'import base64,sys; print(base64.b64decode(sys.argv[1]).decode("utf-8","replace"))' "$b64")
case "$decoded" in
  *'ANTIGRAVITY final'*) echo "  ok: transcriptTailB64 decodes to the transcript" ;;
  *) echo "FAIL [PreInvocation tail decode]: <$decoded>" >&2; exit 1 ;;
esac
rm -rf "$TDIR"

# ── Case 10: PreToolUse does NOT get transcript enrichment ─────────────────
TDIR="$(mktemp -d)"
printf '%s\n' '{"type":"assistant.message","data":{"content":"should not appear"}}' > "$TDIR/transcript.jsonl"
restart_mock '{}'
PAYLOAD=$(printf '{"toolName":"bash","transcriptPath":"%s"}' "$TDIR/transcript.jsonl")
set +e; run_dispatcher PreToolUse "$PAYLOAD"; LAST_RC=$?; set -e
assert_eq "$LAST_RC" "0" "PreToolUse with transcriptPath still exits 0"
body=$(python3 -c 'import json,sys; print(json.load(open(sys.argv[1]))["body"])' "$HEADERS_FILE")
case "$body" in
  *transcriptTailB64*) echo "FAIL [PreToolUse tail]: PreToolUse should not be enriched; body=<$body>" >&2; exit 1 ;;
  *) echo "  ok: PreToolUse body is not enriched with transcript tail" ;;
esac
rm -rf "$TDIR"

echo
echo "All antigravity hook.sh tests passed (SH=$SH)."
