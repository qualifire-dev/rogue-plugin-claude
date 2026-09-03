#!/usr/bin/env bash
# tests/test_hook_sh_kiro.sh — end-to-end for the Kiro bash bridge
# (plugins/kiro/scripts/hook.sh): env file → hook.sh → mock server → exit code,
# stdout, stderr, log line.
#
# Kiro is the one family whose decision travels in the PROCESS EXIT CODE rather
# than the response body: PreToolUse blocks with exit 2 and the reason on stderr,
# UserPromptSubmit blocks with a JSON decision on stdout (honored by the IDE only),
# and Stop never blocks - a block there tells Kiro to keep working. Every failure
# is exit 0 with an EMPTY stdout, because on the 2.x engine a SessionStart hook's
# stdout is injected into the model's context and an error page must never land
# there. This suite holds the bridge to that table, case by case, with the
# verbatim payload captures under tests/fixtures/kiro/ as stdin.
#
# Kiro runs the hook command through `sh`; override with TEST_SH=dash to exercise
# strict POSIX and catch bashisms.
set -euo pipefail

REPO="$(cd "$(dirname "$0")/.." && pwd)"
HOOK="$REPO/plugins/kiro/scripts/hook.sh"
FIX="$REPO/tests/fixtures/kiro"
SH="${TEST_SH:-sh}"

PORT=$((RANDOM % 10000 + 30000))
HEADERS_FILE="$(mktemp)"
ENV_FILE="$(mktemp)"
OUT_FILE="$(mktemp)"
ERR_FILE="$(mktemp)"
# Optional REPLACEMENT for the bridge's whole PATH (see make_nojq_path).
TEST_PATH=""

cleanup() {
  [ -n "${MOCK_PID:-}" ] && kill "$MOCK_PID" 2>/dev/null || true
  rm -f "$ENV_FILE" "$HEADERS_FILE" "$OUT_FILE" "$ERR_FILE"
}
trap cleanup EXIT

cat > "$ENV_FILE" <<EOF
export ROGUE_API_KEY=test-key
export ROGUE_ACTOR_EMAIL=test@example.com
export ROGUE_ACTOR_NAME='Test User'
export ROGUE_BASE_URL=http://127.0.0.1:${PORT}
EOF

# run_bridge <event> <surface> <stdin-file>
# Runs with a clean HOME holding our env file. Clears ROGUE_* and KIRO_SESSION_ID
# from the process env so only the file (and an explicit KIRO_SID) drives the
# bridge. Writes stdout to $OUT_FILE, stderr to $ERR_FILE, and leaves the exit
# code - the decision channel under test - in LAST_RC. errexit is suspended
# around the call only: a nonzero exit is the expected result of half the cases.
run_bridge() {
  local tmp_home
  tmp_home="$(mktemp -d)"
  cp "$ENV_FILE" "$tmp_home/.rogue-env"
  set +e
  HOME="$tmp_home" \
    ROGUE_API_KEY='' ROGUE_ACTOR_EMAIL='' ROGUE_ACTOR_NAME='' ROGUE_BASE_URL='' \
    ROGUE_LOG_FILE="$tmp_home/kiro.log" \
    ROGUE_HOOK_TIMEOUT="${ROGUE_HOOK_TIMEOUT:-}" \
    KIRO_SESSION_ID="${KIRO_SID:-}" \
    PATH="${TEST_PATH:-$PATH}" \
    "$SH" "$HOOK" "$1" "$2" < "$3" > "$OUT_FILE" 2> "$ERR_FILE"
  LAST_RC=$?
  set -e
  LAST_HOME="$tmp_home"
  # KEEP_HOME=1 preserves the run's HOME so a caller can assert on kiro.log.
  [ "${KEEP_HOME:-0}" = "1" ] || rm -rf "$tmp_home"
}

# Build a PATH that has everything the bridge needs EXCEPT jq, so its concat
# fallback for the session_id injection runs. jq sits in the same directory as
# the rest of the toolchain, so hiding it means rebuilding PATH as a symlink farm.
make_nojq_path() {
  local d b src
  d="$(mktemp -d)"
  for b in "$SH" sh dirname basename date mkdir cat sed grep tr tail head awk wc hostname whoami git curl printf; do
    src="$(command -v "$b" 2>/dev/null || true)"
    [ -n "$src" ] || continue
    ln -s "$src" "$d/$(basename "$src")" 2>/dev/null || true
  done
  if PATH="$d" command -v jq >/dev/null 2>&1; then
    echo "FAIL [nojq farm]: jq is still reachable" >&2; exit 1
  fi
  printf '%s' "$d"
}

posted_body() {
  python3 -c 'import json,sys; print(json.load(open(sys.argv[1]))["body"])' "$HEADERS_FILE"
}
posted_field() {
  posted_body | python3 -c 'import json,sys; print(json.load(sys.stdin).get(sys.argv[1],""))' "$1"
}
posted_header() {
  python3 -c 'import json,sys; print(json.load(open(sys.argv[1]))["headers"].get(sys.argv[2], ""))' "$HEADERS_FILE" "$1"
}

# Readiness is probed with curl, not nc: the bridge needs curl anyway, and nc is
# not guaranteed on a CI runner (the Copilot suite's nc dependency is why that
# suite is NOT in validate.yml; this one is).
start_mock() {
  MOCK_RESPONSE="$1" MOCK_STATUS="${2:-200}" MOCK_DELAY="${3:-0}" \
    python3 "$REPO/tests/mock_server.py" "$PORT" "$HEADERS_FILE" &
  MOCK_PID=$!
  # Not a job: the kill in cleanup/restart would otherwise print "Terminated".
  disown "$MOCK_PID" 2>/dev/null || true
  for _ in $(seq 1 50); do
    curl -s -o /dev/null "http://127.0.0.1:$PORT/" 2>/dev/null && return 0
    sleep 0.1
  done
  echo "mock server failed to start" >&2; exit 1
}
# Kill the mock and wait for the port to actually close (the process is
# disowned, so `wait` cannot), or the next start_mock races the bind.
stop_mock() {
  [ -n "${MOCK_PID:-}" ] && kill "$MOCK_PID" 2>/dev/null || true
  for _ in $(seq 1 50); do
    curl -s -o /dev/null "http://127.0.0.1:$PORT/" 2>/dev/null || break
    sleep 0.1
  done
  MOCK_PID=""
}
restart_mock() {
  stop_mock
  start_mock "$@"
}

assert_eq() {
  if [ "$1" != "$2" ]; then echo "FAIL [$3]: expected <$2> but got <$1>" >&2; exit 1; fi
  echo "  ok: $3"
}
assert_contains() {
  case "$1" in *"$2"*) echo "  ok: $3" ;; *) echo "FAIL [$3]: <$1> does not contain <$2>" >&2; exit 1 ;; esac
}
assert_header() { assert_eq "$(posted_header "$1")" "$2" "$3"; }
assert_header_present() {
  local actual
  actual=$(python3 -c 'import json,sys; print(bool(json.load(open(sys.argv[1]))["headers"].get(sys.argv[2])))' "$HEADERS_FILE" "$1")
  assert_eq "$actual" "True" "$2"
}
# assert_fail_open <label>: exit 0, empty stdout, empty stderr, exactly one log line.
assert_fail_open() {
  assert_eq "$LAST_RC" "0" "$1: exit 0"
  assert_eq "$(cat "$OUT_FILE")" "" "$1: empty stdout"
  assert_eq "$(cat "$ERR_FILE")" "" "$1: empty stderr"
  assert_eq "$(wc -l < "$LAST_HOME/kiro.log" | tr -d ' ')" "1" "$1: exactly one log line"
  rm -rf "$LAST_HOME"
}

BLOCK='{"decision":"block","reason":"Coding Agent Security: DESTRUCTIVE_COMMAND"}'

# ── Case 1: PreToolUse allow → exit 0, empty stdout, headers + path + body ───
start_mock '{}'
run_bridge PreToolUse kiro_cli "$FIX/cli3-PreToolUse-execute_bash.json"
assert_eq "$LAST_RC" "0" "PreToolUse allow exits 0"
assert_eq "$(cat "$OUT_FILE")" "" "PreToolUse allow writes nothing to stdout"
assert_eq "$(cat "$ERR_FILE")" "" "PreToolUse allow writes nothing to stderr"
assert_header "x-rogue-event"       "PreToolUse"       "x-rogue-event is the canonical hook event"
assert_header "x-rogue-agent"       "kiro_cli"         "x-rogue-agent is the install-time surface"
assert_header "x-rogue-api-key"     "test-key"         "x-rogue-api-key forwarded"
assert_header "x-rogue-actor-email" "test@example.com" "x-rogue-actor-email forwarded"
assert_header "x-rogue-actor-name"  "Test User"        "x-rogue-actor-name forwarded (with space)"
assert_header_present "x-rogue-host"    "x-rogue-host sent on every event"
assert_header_present "x-rogue-version" "x-rogue-version sent on every event"
path=$(python3 -c 'import json,sys; print(json.load(open(sys.argv[1]))["path"])' "$HEADERS_FILE")
assert_eq "$path" "/api/v1/hooks/kiro" "POST path is /api/v1/hooks/kiro"
assert_eq "$(posted_body)" "$(cat "$FIX/cli3-PreToolUse-execute_bash.json")" "a 3.0 body (has session_id) is posted verbatim"

# ── Case 2: every surface rides the header verbatim ─────────────────────────
for sf in kiro_ide kiro_crew; do
  run_bridge PreToolUse "$sf" "$FIX/ide-PreToolUse-execute_bash.json"
  assert_header "x-rogue-agent" "$sf" "surface $sf is sent as x-rogue-agent"
done

# ── Case 3: 2.x camelCase names are sent as the canonical event ─────────────
# The installer may pass either dialect's trigger name; the route keys its
# monitored/blocking tables on the canonical PascalCase form.
for pair in preToolUse:PreToolUse agentSpawn:SessionStart userPromptSubmit:UserPromptSubmit postToolUse:PostToolUse stop:Stop; do
  arg=${pair%%:*}; want=${pair#*:}
  run_bridge "$arg" kiro_cli "$FIX/cli2-preToolUse-execute_bash.json"
  assert_header "x-rogue-event" "$want" "2.x trigger '$arg' is sent as $want"
done

# ── Case 4: allow on EVERY event: exit 0, no output ─────────────────────────
for f in "$FIX"/*.json; do
  name=$(basename "$f" .json)
  ev=$(python3 -c 'import json,sys; print(json.load(open(sys.argv[1]))["hook_event_name"])' "$f")
  run_bridge "$ev" kiro_cli "$f"
  assert_eq "$LAST_RC:$(cat "$OUT_FILE")$(cat "$ERR_FILE")" "0:" "$name allow → exit 0, silent"
done

# ── Case 5: PreToolUse block → exit 2, reason on stderr, empty stdout ────────
restart_mock "$BLOCK"
KEEP_HOME=1
run_bridge PreToolUse kiro_cli "$FIX/cli3-PreToolUse-execute_bash.json"
assert_eq "$LAST_RC" "2" "PreToolUse block exits 2"
assert_eq "$(cat "$OUT_FILE")" "" "PreToolUse block leaves stdout empty"
assert_eq "$(cat "$ERR_FILE")" "Coding Agent Security: DESTRUCTIVE_COMMAND" "PreToolUse block puts the reason on stderr"
assert_contains "$(cat "$LAST_HOME/kiro.log")" " provider=kiro surface=kiro_cli event=PreToolUse outcome=block" "block is logged"
rm -rf "$LAST_HOME"
KEEP_HOME=0

# 2.x dialect, same answer.
run_bridge preToolUse kiro_cli "$FIX/cli2-preToolUse-fs_write.json"
assert_eq "$LAST_RC" "2" "2.x preToolUse block exits 2"

# ── Case 5b: the reason is a JSON string — unescape it for the terminal ──────
restart_mock '{"decision":"block","reason":"Rogue blocked \"rm -rf\".\nUse rgx! to override."}'
run_bridge PreToolUse kiro_ide "$FIX/ide-PreToolUse-execute_bash.json"
assert_eq "$LAST_RC" "2" "escaped reason still exits 2"
assert_eq "$(cat "$ERR_FILE")" 'Rogue blocked "rm -rf".
Use rgx! to override.' "reason is JSON-unescaped on stderr"

# ── Case 5c: a block with no reason still blocks, with a default line ────────
restart_mock '{"decision":"block"}'
run_bridge PreToolUse kiro_cli "$FIX/cli3-PreToolUse-fs_write.json"
assert_eq "$LAST_RC" "2" "reason-less block exits 2"
assert_eq "$(cat "$ERR_FILE")" "Blocked by Rogue Security" "reason-less block prints a default reason"

# ── Case 5d: the block match is STRICT ──────────────────────────────────────
# "block" as some other field's value is an allow.
restart_mock '{"decision":"allow","reason":"no findings","rulesetMode":"block"}'
run_bridge PreToolUse kiro_cli "$FIX/cli3-PreToolUse-execute_bash.json"
assert_eq "$LAST_RC:$(cat "$OUT_FILE")" "0:" "an allow that merely mentions block is an allow"

# ── Case 6: UserPromptSubmit block → exit 0, JSON decision on stdout ─────────
restart_mock "$BLOCK"
run_bridge UserPromptSubmit kiro_ide "$FIX/ide-UserPromptSubmit.json"
assert_eq "$LAST_RC" "0" "UserPromptSubmit block exits 0"
assert_eq "$(cat "$OUT_FILE")" "$BLOCK" "UserPromptSubmit block relays the JSON decision on stdout"
assert_eq "$(cat "$ERR_FILE")" "" "UserPromptSubmit block writes nothing to stderr"

# ── Case 7: Stop NEVER blocks, whatever the server says ──────────────────────
for pair in "Stop:cli3-Stop" "stop:cli2-stop" "Stop:ide-Stop"; do
  ev=${pair%%:*}; fx=${pair#*:}
  KEEP_HOME=1
  run_bridge "$ev" kiro_cli "$FIX/$fx.json"
  assert_eq "$LAST_RC:$(cat "$OUT_FILE")$(cat "$ERR_FILE")" "0:" "$fx: server block → exit 0, silent"
  assert_contains "$(cat "$LAST_HOME/kiro.log")" "outcome=allow decision=block" "$fx: the ignored block is still logged"
  rm -rf "$LAST_HOME"
  KEEP_HOME=0
done

# ── Case 8: no other event carries a block either ───────────────────────────
for pair in "PostToolUse:cli3-PostToolUse-execute_bash" "SessionStart:cli3-SessionStart" "PostFileSave:ide-PostFileSave"; do
  ev=${pair%%:*}; fx=${pair#*:}
  run_bridge "$ev" kiro_ide "$FIX/$fx.json"
  assert_eq "$LAST_RC:$(cat "$OUT_FILE")$(cat "$ERR_FILE")" "0:" "$ev: server block → exit 0, silent"
done

# ── Case 9: non-200 → fail-open ─────────────────────────────────────────────
restart_mock "$BLOCK" 500
KEEP_HOME=1
run_bridge PreToolUse kiro_cli "$FIX/cli3-PreToolUse-execute_bash.json"
assert_fail_open "HTTP 500"

# ── Case 10: 200 with an EMPTY body → fail-open ─────────────────────────────
restart_mock ''
run_bridge PreToolUse kiro_cli "$FIX/cli3-PreToolUse-execute_bash.json"
assert_fail_open "empty body"

# ── Case 11: timeout → fail-open, inside the hook's own budget ───────────────
# The mock answers a block after 3s; the bridge gives up at 1s (ROGUE_HOOK_TIMEOUT
# overrides the 8s default, which itself sits under the hook file's 10s).
restart_mock "$BLOCK" 200 3
ROGUE_HOOK_TIMEOUT=1 run_bridge PreToolUse kiro_cli "$FIX/cli3-PreToolUse-execute_bash.json"
assert_fail_open "timeout"

# ── Case 12: server down (connection refused) → fail-open ───────────────────
stop_mock
run_bridge PreToolUse kiro_cli "$FIX/cli3-PreToolUse-execute_bash.json"
assert_fail_open "connection refused"
KEEP_HOME=0

# ── Case 13: unconfigured (no API key) → fail-open, no request ──────────────
TMP_HOME="$(mktemp -d)"
set +e
HOME="$TMP_HOME" ROGUE_API_KEY='' ROGUE_LOG_FILE="$TMP_HOME/kiro.log" \
  "$SH" "$HOOK" PreToolUse kiro_cli < "$FIX/cli3-PreToolUse-execute_bash.json" > "$OUT_FILE" 2> "$ERR_FILE"
rc=$?
set -e
assert_eq "$rc" "0" "unconfigured exits 0"
assert_eq "$(cat "$OUT_FILE")$(cat "$ERR_FILE")" "" "unconfigured is silent (no SessionStart hint either)"
assert_contains "$(cat "$TMP_HOME/kiro.log")" " provider=kiro surface=kiro_cli event=PreToolUse outcome=unconfigured" "unconfigured logs one line"
assert_eq "$(wc -l < "$TMP_HOME/kiro.log" | tr -d ' ')" "1" "unconfigured: exactly one log line"
rm -rf "$TMP_HOME"

# ── Case 14: session_id injected from KIRO_SESSION_ID when the body has none ─
start_mock '{}'
KIRO_SID="sess_0b7a4a1e-2c0f-4d8a-9e51-1234567890ab" run_bridge preToolUse kiro_cli "$FIX/cli2-preToolUse-execute_bash.json"
assert_eq "$(posted_field session_id)" "sess_0b7a4a1e-2c0f-4d8a-9e51-1234567890ab" "2.x body gets session_id from KIRO_SESSION_ID"
assert_eq "$(posted_field tool_name)" "execute_bash" "...and keeps its own fields"

# ── Case 14b: a body that already carries session_id is left alone ──────────
KIRO_SID="sess_should-not-win" run_bridge PreToolUse kiro_cli "$FIX/cli3-PreToolUse-execute_bash.json"
assert_eq "$(posted_field session_id)" "sess_2355ff25-7c42-4c86-9ebe-c2ca491c9709" "3.0 body keeps its own session_id"
assert_eq "$(posted_body)" "$(cat "$FIX/cli3-PreToolUse-execute_bash.json")" "...byte for byte"

# ── Case 14c: no KIRO_SESSION_ID → 2.x body posted verbatim ─────────────────
run_bridge preToolUse kiro_cli "$FIX/cli2-preToolUse-execute_bash.json"
assert_eq "$(posted_body)" "$(cat "$FIX/cli2-preToolUse-execute_bash.json")" "2.x body without an env session id is posted verbatim"

# ── Case 14d: a session id outside the token charset is never injected ──────
# The value is env-controlled text spliced into JSON on the no-jq path; one '"'
# would corrupt the payload, so the bridge refuses anything but a bare token.
KIRO_SID='sess_"x' run_bridge preToolUse kiro_cli "$FIX/cli2-preToolUse-execute_bash.json"
assert_eq "$(posted_field session_id)" "" "a session id with a quote is not injected"
assert_eq "$(posted_field tool_name)" "execute_bash" "...and the body stays valid JSON"

# ── Case 14e: the no-jq concat path injects the same field ──────────────────
TEST_PATH="$(make_nojq_path)"
KIRO_SID="sess_nojq-1" run_bridge preToolUse kiro_cli "$FIX/cli2-preToolUse-execute_bash.json"
assert_eq "$(posted_field session_id)" "sess_nojq-1" "no-jq path injects session_id"
assert_eq "$(posted_field tool_name)" "execute_bash" "no-jq path keeps the body valid"
rm -rf "$TEST_PATH"; TEST_PATH=""

# ── Case 15: an unknown surface omits the log token and defaults the header ─
KEEP_HOME=1
run_bridge PreToolUse not-a-surface "$FIX/cli3-PreToolUse-execute_bash.json"
assert_header "x-rogue-agent" "kiro_cli" "unrecognised surface falls back to kiro_cli on the wire"
line=$(cat "$LAST_HOME/kiro.log")
case "$line" in
  *" provider=kiro event=PreToolUse "*) echo "  ok: unrecognised surface omits the surface= token" ;;
  *) echo "FAIL [surface token]: <$line>" >&2; exit 1 ;;
esac
rm -rf "$LAST_HOME"
KEEP_HOME=0

echo
echo "All Kiro bridge tests passed (TEST_SH=$SH)."
