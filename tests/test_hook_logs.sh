#!/usr/bin/env sh
# Cross-plugin contract test for THE HOOK LOG (see CLAUDE.md § "The hook log").
#
# One file per agent under ~/.rogue/logs/, one shared line format, one rotation
# policy — across all six dispatchers. This suite exists because that contract is
# duplicated six times (the repo has no shared library) and a copy/paste drift in
# any one of them is invisible until someone reads a customer's log.
#
# Everything here runs on the UNCONFIGURED path (ROGUE_API_KEY empty), so no mock
# server and no network are needed: a dispatcher with no key still logs
# `outcome=unconfigured` and fails open. HOME is redirected per case so the
# developer's real ~/.rogue is never touched.
#
# Run under dash as well as bash: `sh tests/test_hook_logs.sh`.
# Set SH=dash to force a specific shell for the dispatchers under test.

set -u
REPO="$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)"
SH="${SH:-sh}"
FAILS=0
TMPROOT="$(mktemp -d "${TMPDIR:-/tmp}/rogue-logtest.XXXXXX")"
trap 'rm -rf "$TMPROOT"' EXIT INT TERM

pass() { echo "  ok: $1"; }
fail() { echo "FAIL: $1"; FAILS=$((FAILS + 1)); }
check() { # check <label> <expected> <actual>
  if [ "$2" = "$3" ]; then pass "$1"; else fail "$1 (expected [$2], got [$3])"; fi
}

# ── the six dispatchers ────────────────────────────────────────────────────
# Each row: slug | event name | invocation (run with cwd=$REPO, env prefixed).
# Keep the event names in each agent's own casing — the log line echoes them
# verbatim, and a case slip is exactly the kind of drift this suite catches.
dispatch() { # dispatch <slug> <event>  → runs the dispatcher for <slug>
  case "$1" in
    claude)
      CLAUDE_CODE_ENTRYPOINT=cli CLAUDE_PLUGIN_ROOT="$REPO/plugins/rogue" \
        "$SH" "$REPO/plugins/rogue/scripts/hook.sh" "$2" ;;
    codex)
      PLUGIN_ROOT="$REPO/plugins/codex" \
        "$SH" "$REPO/plugins/codex/scripts/hook.sh" "$2" ;;
    cursor)
      CURSOR_PLUGIN_ROOT="$REPO/plugins/cursor" \
        "$SH" "$REPO/plugins/cursor/scripts/hook.sh" "$2" ;;
    copilot)
      PLUGIN_ROOT="$REPO/plugins/copilot" \
        "$SH" "$REPO/plugins/copilot/scripts/hook.sh" "$2" ;;
    antigravity)
      PLUGIN_ROOT="$REPO/plugins/antigravity" \
        "$SH" "$REPO/plugins/antigravity/scripts/hook.sh" "$2" ;;
    gemini)
      node "$REPO/plugins/gemini/scripts/hook.mjs" "$2" ;;
  esac
}

event_for() { # the dispatchers' own casing for a pre-tool event
  case "$1" in
    claude|antigravity) echo PreToolUse ;;
    codex)              echo PreToolUse ;;
    cursor|copilot)     echo preToolUse ;;
    gemini)             echo BeforeTool ;;
  esac
}

SLUGS='claude codex cursor copilot antigravity gemini'

# `gemini` needs node; skip it (loudly) rather than failing the suite on a box
# without it — every other dispatcher is pure sh + curl.
if ! command -v node >/dev/null 2>&1; then
  echo "NOTE: node not found — skipping the gemini dispatcher"
  SLUGS='claude codex cursor copilot antigravity'
fi

# fire <slug> <home> [VAR=value ...] — run the dispatcher in an isolated HOME.
# ROGUE_LOG_FILE / ROGUE_LOG_DIR / ROGUE_LOG_MAX_BYTES are blanked unless a caller
# overrides them, so a value exported in the developer's own shell can't leak in
# and mask a default-path regression.
fire() {
  _slug=$1; _home=$2; shift 2
  ( cd "$REPO" || exit 1
    export HOME="$_home" ROGUE_API_KEY='' ROGUE_LOG_FILE='' ROGUE_LOG_DIR='' ROGUE_LOG_MAX_BYTES=''
    for _kv in "$@"; do export "${_kv?}"; done
    printf '{}' | dispatch "$_slug" "$(event_for "$_slug")" >/dev/null 2>&1 )
}

# What landed under <home>, as a sorted space-separated list of relative paths.
tree_of() { find "$1" -type f 2>/dev/null | sed "s|^$1||" | sort | tr '\n' ' '; }

echo "== default path: one file per agent under ~/.rogue/logs/"
for slug in $SLUGS; do
  home="$TMPROOT/default-$slug"; mkdir -p "$home"
  fire "$slug" "$home"
  check "$slug writes only ~/.rogue/logs/$slug.log" "/.rogue/logs/$slug.log " "$(tree_of "$home")"
done

echo
echo "== line format: '<ts> provider=<slug> event=<Event> …'"
for slug in $SLUGS; do
  home="$TMPROOT/fmt-$slug"; mkdir -p "$home"
  ev=$(event_for "$slug")
  fire "$slug" "$home"
  line=$(cat "$home/.rogue/logs/$slug.log" 2>/dev/null)
  # Timestamp must be a UTC ISO-8601 second-precision stamp, no fractional part:
  # the shipper's line splitter and the backend's parser both key off it.
  case "$line" in
    [0-9][0-9][0-9][0-9]-[0-9][0-9]-[0-9][0-9]T[0-9][0-9]:[0-9][0-9]:[0-9][0-9]Z" provider=$slug event=$ev "*)
      pass "$slug line is '<ts> provider=$slug event=$ev …'" ;;
    *)
      fail "$slug line shape [$line]" ;;
  esac
  case "$line" in
    *outcome=unconfigured*) pass "$slug logs outcome=unconfigured with no API key" ;;
    *) fail "$slug missing outcome=unconfigured [$line]" ;;
  esac
done

echo
echo "== ROGUE_LOG_DIR relocates, keeping the per-agent basename"
for slug in $SLUGS; do
  home="$TMPROOT/dir-$slug"; mkdir -p "$home"
  fire "$slug" "$home" "ROGUE_LOG_DIR=$home/custom"
  check "$slug honors ROGUE_LOG_DIR" "/custom/$slug.log " "$(tree_of "$home")"
done

echo
echo "== ROGUE_LOG_FILE (exact path) beats ROGUE_LOG_DIR"
for slug in $SLUGS; do
  home="$TMPROOT/file-$slug"; mkdir -p "$home"
  fire "$slug" "$home" "ROGUE_LOG_FILE=$home/exact.log" "ROGUE_LOG_DIR=$home/custom"
  check "$slug honors ROGUE_LOG_FILE over ROGUE_LOG_DIR" "/exact.log " "$(tree_of "$home")"
done

echo
echo "== rotation at ROGUE_LOG_MAX_BYTES"
for slug in $SLUGS; do
  home="$TMPROOT/rot-$slug"; mkdir -p "$home/.rogue/logs"
  logf="$home/.rogue/logs/$slug.log"
  # 30 lines x ~12 bytes = ~350B, comfortably over the 100B cap below. (An
  # earlier version of this test seeded 99 bytes against a 100 byte cap and
  # "failed" — the boundary is `>=`, so keep the seed clearly above it.)
  i=0; while [ "$i" -lt 30 ]; do echo "OLD-LINE-$i" >> "$logf"; i=$((i + 1)); done
  fire "$slug" "$home" "ROGUE_LOG_MAX_BYTES=100"
  cur=$(wc -l < "$logf" 2>/dev/null | tr -d '[:space:]')
  old=$(wc -l < "$logf.1" 2>/dev/null | tr -d '[:space:]')
  check "$slug rotated the old log to $slug.log.1" "30" "${old:-missing}"
  check "$slug started a fresh $slug.log" "1" "${cur:-missing}"
done

echo
echo "== ROGUE_LOG_MAX_BYTES=0 disables rotation"
for slug in $SLUGS; do
  home="$TMPROOT/norot-$slug"; mkdir -p "$home/.rogue/logs"
  logf="$home/.rogue/logs/$slug.log"
  i=0; while [ "$i" -lt 30 ]; do echo "OLD-LINE-$i" >> "$logf"; i=$((i + 1)); done
  fire "$slug" "$home" "ROGUE_LOG_MAX_BYTES=0"
  cur=$(wc -l < "$logf" 2>/dev/null | tr -d '[:space:]')
  rotated=$([ -e "$logf.1" ] && echo yes || echo no)
  check "$slug appended instead of rotating" "31" "${cur:-missing}"
  check "$slug created no $slug.log.1" "no" "$rotated"
done

echo
echo "== no dispatcher writes the legacy shared ~/.rogue/hook.log"
for slug in $SLUGS; do
  home="$TMPROOT/legacy-$slug"; mkdir -p "$home"
  fire "$slug" "$home"
  legacy=$([ -e "$home/.rogue/hook.log" ] && echo yes || echo no)
  check "$slug leaves ~/.rogue/hook.log alone" "no" "$legacy"
done

echo
if [ "$FAILS" -eq 0 ]; then
  echo "All hook-log contract tests passed (SH=$SH)."
  exit 0
fi
echo "$FAILS failure(s)."
exit 1
