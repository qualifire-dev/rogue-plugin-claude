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
echo "== ~/.rogue-env can relocate the log (env FILE, not just process env)"
# The documented precedence is bundled env -> MDM -> ~/.rogue-env -> process env,
# and every dispatcher resolves its log destination AFTER reading those files. The
# process-env cases above cannot catch a dispatcher that reads its own environment
# too early: `plugins/gemini/scripts/hook.mjs` did exactly that (module-level
# consts, while loadEnvFiles() runs later and returns a merged object WITHOUT
# mutating process.env), so ~/.rogue-env was silently ignored there.
for slug in $SLUGS; do
  home="$TMPROOT/envfile-$slug"; mkdir -p "$home/custom"
  printf 'export ROGUE_LOG_DIR=%s\n' "$home/custom" > "$home/.rogue-env"
  chmod 600 "$home/.rogue-env"
  fire "$slug" "$home"
  got=$(find "$home" -name '*.log' 2>/dev/null | sed "s|^$home||" | sort | tr '\n' ' ')
  check "$slug honors ROGUE_LOG_DIR from ~/.rogue-env" "/custom/$slug.log " "$got"
done

echo
echo "== a zero-padded zero cap (00) disables rotation, like 0"
# sh compares with `-ge`, so a `case` glob that only matched a bare "0" left "00"
# looking like a positive number and rotated on EVERY write. PowerShell's
# [int64]'00' and Node's Number("00") are both 0, so all three must agree.
for slug in $SLUGS; do
  home="$TMPROOT/cap00-$slug"; mkdir -p "$home/.rogue/logs"
  logf="$home/.rogue/logs/$slug.log"
  i=0; while [ "$i" -lt 30 ]; do echo "OLD-LINE-$i" >> "$logf"; i=$((i + 1)); done
  fire "$slug" "$home" "ROGUE_LOG_MAX_BYTES=00"
  rotated=$([ -e "$logf.1" ] && echo yes || echo no)
  check "$slug treats 00 as rotation-disabled" "no" "$rotated"
  check "$slug appended instead of rotating" "31" "$(wc -l < "$logf" 2>/dev/null | tr -d '[:space:]')"
done

echo
echo "== a non-numeric cap falls back to the default, it does NOT disable"
# A typo must never leave the log growing unbounded. Seed just over the 2 MiB
# default so "fell back to the default" is distinguishable from "disabled".
for slug in $SLUGS; do
  home="$TMPROOT/capbad-$slug"; mkdir -p "$home/.rogue/logs"
  logf="$home/.rogue/logs/$slug.log"
  head -c 2097153 /dev/zero | tr '\0' 'x' > "$logf"
  fire "$slug" "$home" "ROGUE_LOG_MAX_BYTES=not-a-number"
  rotated=$([ -e "$logf.1" ] && echo yes || echo no)
  check "$slug still rotates at the 2 MiB default" "yes" "$rotated"
done

echo
echo "== rotation replaces an EXISTING .1 rather than failing"
for slug in $SLUGS; do
  home="$TMPROOT/rot2-$slug"; mkdir -p "$home/.rogue/logs"
  logf="$home/.rogue/logs/$slug.log"
  echo "STALE-PREVIOUS-GENERATION" > "$logf.1"
  i=0; while [ "$i" -lt 30 ]; do echo "OLD-LINE-$i" >> "$logf"; i=$((i + 1)); done
  fire "$slug" "$home" "ROGUE_LOG_MAX_BYTES=100"
  if grep -q 'STALE-PREVIOUS-GENERATION' "$logf.1" 2>/dev/null; then
    fail "$slug left the stale .1 in place — rotation silently no-oped"
  else
    pass "$slug replaced the previous .1 generation"
  fi
done

echo
echo "== the log starts with the timestamp: no UTF-8 BOM, no leading blank"
# PowerShell 5.1's `Add-Content -Encoding UTF8` writes EF BB BF on create, which
# would break any parser anchored on the timestamp; the sh side must never grow
# one either, so both halves of the suite assert it.
for slug in $SLUGS; do
  home="$TMPROOT/bom-$slug"; mkdir -p "$home"
  fire "$slug" "$home"
  head3=$(od -An -tx1 -N3 "$home/.rogue/logs/$slug.log" 2>/dev/null | tr -s ' ' | sed 's/^ //;s/ $//')
  case "$head3" in
    "ef bb bf") fail "$slug log starts with a UTF-8 BOM" ;;
    *)          pass "$slug log has no UTF-8 BOM (head: $head3)" ;;
  esac
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
