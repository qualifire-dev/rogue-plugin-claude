#!/usr/bin/env bash
# LIVE end-to-end demo: install the plugin with the real Claude Code CLI, run a real
# prompt through a real Claude session, and watch this machine's hook log get
# uploaded to a local server. The one thing no automated suite in this repo does,
# because all of them drive the dispatcher directly rather than through Claude Code.
#
#   bash tests/manual/live_session.sh            # keeps the sandbox for inspection
#   KEEP=0 bash tests/manual/live_session.sh     # deletes it at the end
#
# Requires: the `claude` CLI, logged in (this uses your real credentials, so it
# spends a little of your quota), plus node and curl.
#
# WHAT IT TOUCHES ON YOUR MACHINE
#
#   * Adds a marketplace named `rogue-livetest` (a copy of HEAD with its name
#     rewritten, so it cannot collide with the `rogue-marketplace` entry you already
#     have) and installs `rogue@rogue-livetest` at user scope. BOTH are removed at
#     the end, including on Ctrl-C. Your existing `rogue@rogue-marketplace` install
#     is never touched.
#   * Credentials, base URL and log directory are passed as PROCESS ENVIRONMENT to the
#     `claude` invocations. Nothing is written to ~/.rogue-env, and NOTHING reaches
#     api.rogue.security - `ROGUE_BASE_URL` sends every request to the local receiver
#     instead, which also covers the plugin you already have installed (it would
#     otherwise POST this test's prompts to production).
#
#     One caveat this very script uncovered: `ROGUE_API_KEY` does NOT survive, because
#     the sh dispatchers source the env files WITHOUT preserving the process
#     environment first, so `~/.rogue-env`'s key overrides the sandbox's - and
#     heartbeat.sh then exports that key to the shipper it spawns. `hook.ps1` and
#     `hook.mjs` apply process env last and do not have this behaviour, and
#     `ship-logs.sh` explicitly saves and restores it, so this is an sh-dispatcher
#     divergence from a documented invariant. Tracked separately; the receiver is
#     therefore started with E2E_ACCEPT_ANY_KEY=1, and it records only a fingerprint
#     of a key it rejects, never the key.
#   * $HOME stays real, because the Claude CLI's own auth lives there. The shipper's
#     offset state therefore lands in your real ~/.rogue/ship/ - the run prints it and
#     deletes only the key it created.
#
# HOW THE HOOKS ARE REGISTERED, and why that is not cheating
#
# Claude Code did NOT run plugin-provided hooks in a headless `claude -p` run on
# 2.1.223 - verified with the plugin installed at user scope AND at local scope, in
# both a fresh directory and a trusted one, with the parent session's CLAUDE_*
# markers stripped. Hooks declared in SETTINGS do run there (proven both via a
# project `.claude/settings.json` and via `--settings`). So this script installs the
# plugin for real, then generates a settings file from THE INSTALLED PLUGIN'S OWN
# hooks/hooks.json - same event list, same command strings, `${CLAUDE_PLUGIN_ROOT}`
# expanded to the install path - and passes it with `--settings`.
#
# What that does exercise: the real installed tree, the real command strings
# (including the PowerShell siblings, which fail with 127 and are silenced by
# `; exit 0` exactly as the arbitration table says), the real dispatcher, the real
# per-event log, the real detached heartbeat, and the real shipper. It is also a
# faithful model of the MDM deployment shape, where settings.json carries the hooks.
#
# What it does NOT exercise: Claude Code's own plugin-hook loading. Verify that once,
# interactively, with `/rogue:status` in a normal session.
#
# WHY TWO SESSIONS. The shipper runs from SessionStart, so a session uploads whatever
# was on disk when it STARTED - the lines it is about to write are shipped by the NEXT
# session. That is the product's actual cadence (a lazy, at-most-every-15-minutes
# background upload), not a limitation of this script, so the demo shows it directly:
# session 1 writes hook lines, session 2 ships them.
set -u

REPO="$(CDPATH= cd -- "$(dirname -- "$0")/../.." && pwd)"
KEEP="${KEEP:-1}"
MARKETPLACE_NAME=rogue-livetest
API_KEY=livetest-key
ACTOR_EMAIL=livetest@rogue.security
ACTOR_NAME='Live Test'

for tool in claude node curl; do
  command -v "$tool" >/dev/null 2>&1 || { echo "need $tool on PATH"; exit 1; }
done

SB="$(mktemp -d "${TMPDIR:-/tmp}/rogue-live.XXXXXX")" || exit 1
RECV="$SB/recv"; PROJECT="$SB/project"; MARKET="$SB/marketplace"; LOGS="$SB/logs"
mkdir -p "$RECV" "$PROJECT" "$MARKET" "$LOGS"

RECEIVER_PID=""
INSTALLED=0
cleanup() {
  echo
  echo "── cleanup ─────────────────────────────────────────────────────────────"
  if [ "$INSTALLED" = 1 ]; then
    # ALWAYS marketplace-qualified. A bare `claude plugin uninstall rogue` matches by
    # plugin NAME, and this repo's plugin is called `rogue` in every marketplace - so
    # the unqualified form removed a pre-existing `rogue@rogue-marketplace` install
    # from enabledPlugins while cleaning up after this test. Reinstalling restored it,
    # but the record came back pinned to the marketplace's current version rather than
    # the one that was there before.
    claude plugin uninstall "rogue@$MARKETPLACE_NAME" --scope user >/dev/null 2>&1 \
      && echo "  uninstalled rogue@$MARKETPLACE_NAME (user scope)"
    claude plugin marketplace remove "$MARKETPLACE_NAME" >/dev/null 2>&1 \
      && echo "  removed the $MARKETPLACE_NAME marketplace"
  fi
  [ -n "$RECEIVER_PID" ] && kill "$RECEIVER_PID" 2>/dev/null && echo "  stopped the receiver"
  # Only the state this run created. The key is the log's basename, and the log lived
  # in the sandbox, so this cannot touch state for your real ~/.rogue/logs files.
  rm -f "$HOME/.rogue/ship/claude.state" "$HOME/.rogue/ship/.last-claude" 2>/dev/null
  echo "  removed the sandbox's shipper state"
  if [ "$KEEP" = 1 ]; then echo "  sandbox kept at $SB"; else rm -rf "$SB"; echo "  sandbox removed"; fi
}
trap 'cleanup' EXIT INT TERM

echo "── the receiver ────────────────────────────────────────────────────────"
# E2E_ACCEPT_ANY_KEY=1 because the request comes from a REAL session, and the sh
# dispatchers source ~/.rogue-env AFTER reading the process environment - so that
# file's ROGUE_API_KEY wins over this sandbox's and every request would 401 on your
# own credential (see the note in the header). The receiver never records a key,
# only a fingerprint of a rejected one.
E2E_API_KEY="$API_KEY" E2E_ACCEPT_ANY_KEY=1 \
  node "$REPO/tests/e2e_receiver.mjs" "$RECV" >"$SB/recv.out" 2>&1 &
RECEIVER_PID=$!
i=0
while [ ! -s "$RECV/port" ] && [ "$i" -lt 100 ]; do i=$((i + 1)); sleep 0.1; done
PORT="$(cat "$RECV/port" 2>/dev/null)"
[ -n "$PORT" ] || { echo "the receiver never started (see $SB/recv.out)"; exit 1; }
BASE="http://127.0.0.1:$PORT"
echo "  listening on $BASE"

echo
echo "── install, the way a user would ───────────────────────────────────────"
# HEAD, not the working tree: `git archive` gives exactly what a marketplace clone
# would hand Claude Code, so an uncommitted edit cannot make this pass.
git -C "$REPO" archive HEAD | tar -x -C "$MARKET"
sed -i.bak "s/\"name\": *\"rogue-marketplace\"/\"name\": \"$MARKETPLACE_NAME\"/" \
  "$MARKET/.claude-plugin/marketplace.json" && rm -f "$MARKET/.claude-plugin/marketplace.json.bak"
claude plugin marketplace add "$MARKET" --scope user 2>&1 | sed 's/^/  /'
claude plugin install "rogue@$MARKETPLACE_NAME" --scope user 2>&1 | sed 's/^/  /'
INSTALLED=1

PLUGIN_ROOT="$(ls -d "$HOME/.claude/plugins/cache/$MARKETPLACE_NAME/rogue"/* 2>/dev/null | tail -1)"
[ -n "$PLUGIN_ROOT" ] || { echo "  the install produced no plugin directory"; exit 1; }
echo "  installed to $PLUGIN_ROOT"
for f in hooks/hooks.json scripts/hook.sh scripts/heartbeat.sh scripts/ship-logs.sh; do
  [ -f "$PLUGIN_ROOT/$f" ] && echo "    has $f" || { echo "    MISSING $f"; exit 1; }
done

echo
echo "── hooks, taken verbatim from the installed plugin ─────────────────────"
SETTINGS="$SB/hooks-settings.json"
# Values through the ENVIRONMENT, not argv: with `node -e`, process.argv holds no
# script path, so argv.slice(2) drops the first argument and silently shifts the rest.
ROGUE_LIVE_ROOT="$PLUGIN_ROOT" ROGUE_LIVE_OUT="$SETTINGS" node -e '
const fs = require("fs");
const root = process.env.ROGUE_LIVE_ROOT, out = process.env.ROGUE_LIVE_OUT;
const hooks = JSON.parse(fs.readFileSync(root + "/hooks/hooks.json", "utf8")).hooks;
// The ONLY edit: expand ${CLAUDE_PLUGIN_ROOT}, which Claude Code substitutes for a
// plugin hook but not for a settings hook. Everything else - the event list, the
// `; exit 0` polyglot, the PowerShell siblings, the detached SessionStart entries -
// is byte-identical to what the plugin ships.
const expanded = JSON.parse(
  JSON.stringify(hooks).replace(/\$\{CLAUDE_PLUGIN_ROOT\}/g, root),
);
fs.writeFileSync(out, JSON.stringify({ hooks: expanded }, null, 2));
const events = Object.keys(expanded);
let n = 0;
for (const e of events) for (const m of expanded[e]) n += (m.hooks || []).length;
console.log(`  ${events.length} events, ${n} hook entries: ${events.join(", ")}`);
' || exit 1

# Every ROGUE_* knob rides the process env, which beats every env file (see the
# header). CLAUDE_PLUGIN_ROOT is exported because the detached SessionStart entries
# read it from the environment inside their single-quoted `sh -c`, where a
# placeholder would not expand. ROGUE_SHIP_LOGS=1 because shipping is opt-in until
# /hooks/logs is deployed; ROGUE_SHIP_MIN_INTERVAL=0 so the second session is not
# skipped by the 15-minute throttle.
run_session() { # <prompt>
  ( cd "$PROJECT" || exit 1
    env CLAUDE_PLUGIN_ROOT="$PLUGIN_ROOT" \
        ROGUE_BASE_URL="$BASE" \
        ROGUE_API_KEY="$API_KEY" \
        ROGUE_ACTOR_EMAIL="$ACTOR_EMAIL" \
        ROGUE_ACTOR_NAME="$ACTOR_NAME" \
        ROGUE_LOG_DIR="$LOGS" \
        ROGUE_SHIP_LOGS=1 \
        ROGUE_SHIP_MIN_INTERVAL=0 \
        claude --settings "$SETTINGS" -p "$1" --output-format text 2>&1 | sed 's/^/  claude: /' )
}
# `grep -c` already prints 0 when it matches nothing, and exits 1 while doing so - so
# a `|| echo 0` fallback appended a SECOND zero and every numeric test then failed with
# "integer expression expected". Default only the empty case, which is the missing file.
count() {
  _n="$(grep -c "\"kind\":\"$1\"" "$RECV/envelopes.jsonl" 2>/dev/null)"
  printf '%s' "${_n:-0}"
}
# Hook-event POSTs are counted from other.log rather than envelopes.jsonl: the receiver
# records only the URL for /hooks/claude, deliberately, because those bodies carry the
# prompt and the tool calls and this sandbox is kept for inspection by default.
hook_posts() {
  _h="$(grep -c '/hooks/claude' "$RECV/other.log" 2>/dev/null)"
  printf '%s' "${_h:-0}"
}

echo
echo "── session 1: a real prompt in a real session ──────────────────────────"
# A prompt that makes Claude use a tool, so PreToolUse/PostToolUse fire too and the
# log holds more than a session boundary.
run_session 'Run the shell command `echo rogue-live-test` and then reply with just the word done.'
echo
echo "  the hook log this session wrote:"
[ -s "$LOGS/claude.log" ] && sed 's/^/    /' "$LOGS/claude.log" || echo "    (nothing - the hooks did not run)"
echo "  the receiver saw $(hook_posts) hook-event POSTs and $(count status) heartbeats"

echo
echo "── session 2: its SessionStart ships session 1's log ───────────────────"
shipped_before="$(count logs)"
run_session 'Reply with just the word ok.'
# The shipper is detached from the heartbeat, so give it a moment to finish.
i=0
while [ "$i" -lt 150 ] && [ "$(count logs)" -le "$shipped_before" ]; do i=$((i + 1)); sleep 0.1; done

echo
echo "── what the server received ────────────────────────────────────────────"
echo "  upload envelopes (payload stripped):"
grep '"kind":"logs"' "$RECV/envelopes.jsonl" 2>/dev/null | sed 's/^/    /'
echo
echo "  the log, as the server rebuilt it from content_b64:"
[ -f "$RECV/reassembled-claude.log" ] && sed 's/^/    /' "$RECV/reassembled-claude.log" \
  || echo "    (nothing was uploaded)"
echo
echo "  the offset state the plugin kept:"
sed 's/^/    /' "$HOME/.rogue/ship/claude.state" 2>/dev/null || echo "    (none)"

echo
echo "── verdict ─────────────────────────────────────────────────────────────"
fails=0
check() { if [ "$2" = "$3" ]; then echo "  ok: $1"; else echo "  FAIL: $1 (expected [$2], got [$3])"; fails=$((fails + 1)); fi; }
yn() { [ "$1" -gt 0 ] && echo yes || echo no; }

check "the hooks fired in a real session" "yes" "$([ -s "$LOGS/claude.log" ] && echo yes || echo no)"
check "the API received hook events"      "yes" "$(yn "$(hook_posts)")"
check "the heartbeat registered the install" "yes" "$(yn "$(count status)")"
check "the log was uploaded"              "yes" "$(yn "$(count logs)")"
# The rebuilt bytes must be a PREFIX of the file on disk: session 2 keeps appending
# after its own SessionStart shipped, so equality would be a race, while a mismatched
# prefix means a corrupt, truncated or reordered chunk.
if [ -f "$RECV/reassembled-claude.log" ] && [ -s "$LOGS/claude.log" ]; then
  n="$(wc -c < "$RECV/reassembled-claude.log" | tr -d ' ')"
  check "the uploaded bytes match the file on disk exactly" \
    "$(head -c "$n" "$LOGS/claude.log" | shasum | cut -d' ' -f1)" \
    "$(shasum < "$RECV/reassembled-claude.log" | cut -d' ' -f1)"
else
  echo "  FAIL: nothing to compare"; fails=$((fails + 1))
fi
# THE INVARIANT IS "the shipper reports the SAME actor the heartbeat did", not "the
# actor this script passed in": ~/.rogue-env overrides the process environment in the
# sh dispatchers (see the header), so the identity here is the developer's, and that
# is fine - what must never happen is the shipper resolving a SECOND identity through
# a cascade of its own, which would orphan the logs from the roster row. Comparing the
# two envelopes tests exactly that, and is immune to which of the two keys won.
envelope_field() { # <kind> <field>
  sed -n "s/.*\"kind\":\"$1\".*\"$2\":\"\([^\"]*\)\".*/\1/p" "$RECV/envelopes.jsonl" 2>/dev/null | tail -1
}
heartbeat_actor="$(envelope_field status actor_email)"
check "the heartbeat reported an actor at all" "yes" \
  "$([ -n "$heartbeat_actor" ] && echo yes || echo no)"
check "the upload reports the SAME actor, not a re-resolved one" "$heartbeat_actor" \
  "$(envelope_field logs actor_email)"
_prod="$(grep -c 'api.rogue.security' "$SB/recv.out" 2>/dev/null)"
check "nothing reached production" "0" "${_prod:-0}"

echo
[ "$fails" = 0 ] && echo "LIVE TEST PASSED" || echo "$fails failure(s)"
exit "$fails"
