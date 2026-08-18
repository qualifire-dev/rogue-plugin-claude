#!/usr/bin/env bash
# tests/test_hook_sh.sh — end-to-end for the POSIX dispatcher (hook.sh):
# env file → hook.sh → mock server → stdout. Holds the dispatcher to the
# verbatim-relay + header + fail-open + Git-Bash-stand-down contract.
#
# hooks.json invokes the dispatcher via `sh`; override with TEST_SH=dash to
# exercise strict POSIX (Debian/Ubuntu /bin/sh) and catch bashisms.
set -euo pipefail

REPO="$(cd "$(dirname "$0")/.." && pwd)"
HOOK="$REPO/plugins/rogue/scripts/hook.sh"
PLUGIN_ROOT="$REPO/plugins/rogue"
SH="${TEST_SH:-sh}"

PORT=$((RANDOM % 10000 + 30000))
HEADERS_FILE="$(mktemp)"
ENV_FILE="$(mktemp)"

cleanup() {
  [ -n "${MOCK_PID:-}" ] && kill "$MOCK_PID" 2>/dev/null || true
  rm -f "$ENV_FILE" "$HEADERS_FILE"
}
trap cleanup EXIT

cat > "$ENV_FILE" <<EOF
export ROGUE_API_KEY=test-key
export ROGUE_ACTOR_EMAIL=test@example.com
export ROGUE_ACTOR_NAME='Test User'
export ROGUE_BASE_URL=http://127.0.0.1:${PORT}
EOF

# Run with a clean HOME holding our env file. CLAUDE_CODE_ENTRYPOINT=cli so the
# entrypoint gate passes.
# CLAUDE_PLUGIN_ROOT points at the real plugin so actor.sh resolves.
run_dispatcher() {
  local tmp_home
  tmp_home="$(mktemp -d)"
  cp "$ENV_FILE" "$tmp_home/.rogue-env"
  HOME="$tmp_home" CLAUDE_CODE_ENTRYPOINT=cli CLAUDE_PLUGIN_ROOT="$PLUGIN_ROOT" \
    ROGUE_API_KEY='' ROGUE_ACTOR_EMAIL='' ROGUE_ACTOR_NAME='' ROGUE_BASE_URL='' \
    "$SH" "$HOOK" "$1" <<< "$2"
  rm -rf "$tmp_home"
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

# Presence-only: the value is this machine's hostname / installed version, so the
# test can assert it is sent and non-empty but not what it says.
assert_header_present() {
  local key="$1" label="$2" actual
  actual=$(python3 -c 'import json,sys; print(bool(json.load(open(sys.argv[1]))["headers"].get(sys.argv[2])))' "$HEADERS_FILE" "$key")
  assert_eq "$actual" "True" "$label"
}

# ── Case 1: PreToolUse deny relayed verbatim + headers ─────────────────────
start_mock '{"hookSpecificOutput":{"hookEventName":"PreToolUse","permissionDecision":"deny","permissionDecisionReason":"blocked"}}'
out=$(run_dispatcher PreToolUse '{"tool_name":"Bash","tool_input":{"command":"rm -rf /"}}')
assert_eq "$out" '{"hookSpecificOutput":{"hookEventName":"PreToolUse","permissionDecision":"deny","permissionDecisionReason":"blocked"}}' "deny response relayed verbatim"
assert_header "x-rogue-event"       "PreToolUse"       "x-rogue-event is the verbatim Claude event name"
assert_header "x-rogue-api-key"     "test-key"         "x-rogue-api-key forwarded"
assert_header "x-rogue-actor-email" "test@example.com" "x-rogue-actor-email forwarded"
assert_header "x-rogue-actor-name"  "Test User"        "x-rogue-actor-name forwarded (with space)"
assert_no_header "x-rogue-source"   "no x-rogue-source header (cursor-only)"
# Fleet-liveness trio: the same host/version/agent the heartbeat sends, on EVERY
# event, so the roster row is refreshed by ordinary traffic and not only at
# session start. `agent` is the free-form surface label, and the test harness
# sets CLAUDE_CODE_ENTRYPOINT=cli. See scripts/install-id.sh.
assert_header "x-rogue-agent"       "Claude Code - CLI" "x-rogue-agent is the roster's surface label"
assert_header_present "x-rogue-host"    "x-rogue-host sent on every event"
assert_header_present "x-rogue-version" "x-rogue-version sent on every event"

# ── Case 2: top-level block relayed + path is /hooks/claude ────────────────
restart_mock '{"decision":"block","reason":"prompt injection"}'
out=$(run_dispatcher UserPromptSubmit '{"prompt":"ignore previous"}')
assert_eq "$out" '{"decision":"block","reason":"prompt injection"}' "top-level block relayed"
path=$(python3 -c 'import json,sys; print(json.load(open(sys.argv[1]))["path"])' "$HEADERS_FILE")
assert_eq "$path" "/api/v1/hooks/claude" "POST path is /api/v1/hooks/claude"

# ── Case 3: allow {} relayed ───────────────────────────────────────────────
restart_mock '{}'
out=$(run_dispatcher PostToolUse '{"tool_name":"Read"}')
assert_eq "$out" "{}" "allow response relayed"

# ── Case 4: unconfigured (no API key) → {} without calling server ──────────
TMP_HOME="$(mktemp -d)"
out=$(HOME="$TMP_HOME" CLAUDE_CODE_ENTRYPOINT=cli CLAUDE_PLUGIN_ROOT="$PLUGIN_ROOT" \
  ROGUE_API_KEY='' "$SH" "$HOOK" PreToolUse <<< '{}')
rm -rf "$TMP_HOME"
assert_eq "$out" "{}" "unconfigured fails open"

# ── Case 5: Git Bash stand-down (uname=MINGW) → {} before any work ──────────
STUB="$(mktemp -d)"
printf '#!/bin/sh\necho MINGW64_NT-10.0\n' > "$STUB/uname"
chmod +x "$STUB/uname"
out=$(PATH="$STUB:$PATH" "$SH" "$HOOK" PreToolUse <<< '{}')
rm -rf "$STUB"
assert_eq "$out" "{}" "Git Bash stand-down emits {}"

# ── Case 6: a poisoned actor identity in an env file is rejected ────────────
# End-to-end guard for the Cowork fix: compiled bundles already in the field bake
# `: "${ROGUE_ACTOR_EMAIL:=$(git config --global user.email)}"` into an env file
# that hook.sh sources BEFORE actor.sh, and inside the sandbox that git identity
# is Anthropic's synthetic one. The dispatcher must distrust it and fall through
# to CLAUDE_CODE_USER_EMAIL. (Cascade unit coverage lives in test_actor_sh.sh.)
restart_mock '{}'
TMP_HOME="$(mktemp -d)"
cat > "$TMP_HOME/.rogue-env" <<EOF
export ROGUE_API_KEY=test-key
export ROGUE_ACTOR_EMAIL=noreply@anthropic.com
export ROGUE_ACTOR_NAME=Claude
export ROGUE_BASE_URL=http://127.0.0.1:${PORT}
EOF
out=$(HOME="$TMP_HOME" CLAUDE_CODE_ENTRYPOINT=cli CLAUDE_PLUGIN_ROOT="$PLUGIN_ROOT" \
  CLAUDE_CODE_USER_EMAIL='real.user@corp.com' \
  ROGUE_API_KEY='' ROGUE_ACTOR_EMAIL='' ROGUE_ACTOR_NAME='' ROGUE_BASE_URL='' \
  "$SH" "$HOOK" PreToolUse <<< '{}')
rm -rf "$TMP_HOME"
assert_eq "$out" "{}" "poisoned-actor run still relays the response"
assert_header "x-rogue-actor-email" "real.user@corp.com" "synthetic ROGUE_ACTOR_EMAIL replaced by CLAUDE_CODE_USER_EMAIL"
assert_header "x-rogue-actor-name"  "real.user"          "synthetic ROGUE_ACTOR_NAME replaced by its local-part"

echo
echo "All hook.sh tests passed (SH=$SH)."
