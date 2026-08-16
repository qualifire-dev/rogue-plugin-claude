#!/usr/bin/env sh
# Contract test for THE BEACON THROTTLE in plugins/rogue/scripts/heartbeat.sh.
#
# heartbeat.sh is fired from two triggers with very different rates: SessionStart
# (once per session) and Stop (once per TURN). The throttle is the only thing
# standing between the Stop trigger and a /hooks/status POST on every single turn
# of every session in a fleet, so every branch of it is pinned here.
#
# No network and no mock server: a stub `curl` on PATH records one line per call,
# which is exactly the observable that matters ("did the beacon go out"). HOME is
# redirected per case, so the developer's real ~/.rogue/beacon is never touched.
#
# Run under dash as well as bash: `sh tests/test_heartbeat_sh.sh`.

set -u
REPO="$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)"
SH="${SH:-sh}"
FAILS=0
TMPROOT="$(mktemp -d "${TMPDIR:-/tmp}/rogue-hbtest.XXXXXX")"
trap 'rm -rf "$TMPROOT"' EXIT
trap 'rm -rf "$TMPROOT"; exit 130' INT
trap 'rm -rf "$TMPROOT"; exit 143' TERM

pass() { echo "  ok: $1"; }
fail() { echo "FAIL: $1"; FAILS=$((FAILS + 1)); }
check() { if [ "$2" = "$3" ]; then pass "$1"; else fail "$1 (expected [$2], got [$3])"; fi; }

# A self-contained plugin tree with a stub curl. The stub appends to $SB_CALLS
# rather than making a request, so "how many beacons went out" is a line count.
HOME_SB="$TMPROOT/home"
ROOT="$TMPROOT/root"
mkdir -p "$TMPROOT/bin" "$ROOT/.claude-plugin" "$ROOT/scripts" "$HOME_SB"
cp "$REPO/plugins/rogue/scripts/heartbeat.sh" \
   "$REPO/plugins/rogue/scripts/surface.sh" \
   "$REPO/plugins/rogue/scripts/actor.sh" "$ROOT/scripts/"
echo '{"version":"9.9.9"}' > "$ROOT/.claude-plugin/plugin.json"
printf '#!/bin/sh\necho POST >> "$SB_CALLS"\nexit 0\n' > "$TMPROOT/bin/curl"
chmod +x "$TMPROOT/bin/curl"
echo 'export ROGUE_API_KEY=k' > "$HOME_SB/.rogue-env"

STAMP="$HOME_SB/.rogue/beacon/.last-claude"

# beacons <trigger> <interval-or-empty> → number of beacon POSTs that went out.
# `env` rather than an assignment prefix: the interval is often empty, and a
# `${x:+VAR=$x}` prefix is NOT treated as an assignment by every shell - it silently
# became a command argument under zsh while this suite was being written, which made
# two cases pass for the wrong reason.
beacons() {
  : > "$TMPROOT/calls"
  env SB_CALLS="$TMPROOT/calls" PATH="$TMPROOT/bin:$PATH" HOME="$HOME_SB" \
      CLAUDE_PLUGIN_ROOT="$ROOT" CLAUDE_CODE_ENTRYPOINT=cli \
      ROGUE_HEARTBEAT_MIN_INTERVAL="$2" \
      "$SH" "$ROOT/scripts/heartbeat.sh" "$1" >/dev/null 2>&1
  wc -l < "$TMPROOT/calls" | tr -d ' '
}
set_stamp() { mkdir -p "${STAMP%/*}"; printf '%s\n' "$1" > "$STAMP"; }
clear_stamp() { rm -rf "${STAMP%/*}"; }

echo "── SessionStart is NEVER throttled ───────────────────────────────────"
# The existing trigger must behave exactly as it did before the throttle existed.
# A new session is precisely when the roster wants an update: a re-install with a
# new version, or the same user on a different surface, both arrive this way.
clear_stamp
check "fires with no stamp on disk" "1" "$(beacons SessionStart '')"
set_stamp "$(date -u +%s)"
check "fires again immediately, stamp notwithstanding" "1" "$(beacons SessionStart '')"

echo "── Stop IS throttled ─────────────────────────────────────────────────"
set_stamp "$(date -u +%s)"
check "skipped inside the window" "0" "$(beacons Stop '')"
set_stamp 0
check "fires once the window has elapsed" "1" "$(beacons Stop '')"
clear_stamp
check "fires when no stamp exists yet" "1" "$(beacons Stop '')"

echo "── the interval knob ─────────────────────────────────────────────────"
# Numeric zero disables the throttle, a non-numeric value falls back to the
# default. Same rule as ROGUE_LOG_MAX_BYTES and ROGUE_SHIP_MIN_INTERVAL - one
# convention across the repo. Zero on a Stop trigger really does mean a beacon per
# turn; that is the knob doing what it says, and the DEFAULT is the fleet's guard.
set_stamp "$(date -u +%s)"
check "zero disables the throttle" "1" "$(beacons Stop 0)"
set_stamp "$(date -u +%s)"
check "a padded zero counts as zero too" "1" "$(beacons Stop 000)"
set_stamp "$(date -u +%s)"
check "a non-numeric value falls back to the default" "0" "$(beacons Stop abc)"
set_stamp "$(date -u +%s)"
# dash answers `-lt` on a value wider than a signed 64-bit int with "Illegal
# number" on stderr and a FALSE - which reads as "not throttled" and would loose a
# beacon on every turn. The clamp is what stops that.
check "a value too wide for int64 falls back to the default" "0" \
  "$(beacons Stop 99999999999999999999999)"
set_stamp "$(date -u +%s)"
check "a small interval still throttles inside its window" "0" "$(beacons Stop 3600)"

echo "── a stamp we cannot trust never silences the beacon ─────────────────"
# Every unreadable or unparseable case must answer "not throttled". The failure
# mode being avoided is a corrupt stamp that quietly stops presence reporting for
# a machine - which looks identical to an uninstalled plugin on the roster.
set_stamp "not-a-number"
check "a corrupt stamp does not throttle" "1" "$(beacons Stop '')"
set_stamp 99999999999
check "a stamp in the FUTURE does not throttle" "1" "$(beacons Stop '')"
set_stamp ""
check "an empty stamp does not throttle" "1" "$(beacons Stop '')"

echo "── the stamp is written before the request ───────────────────────────"
# Crash-loop guard as much as a rate limit: a beacon that hangs or dies must still
# cost the next turn its attempt, rather than retrying on every single one.
clear_stamp
beacons Stop '' >/dev/null
check "a fired beacon leaves a stamp behind" "yes" \
  "$([ -s "$STAMP" ] && echo yes || echo no)"
stamp_is_integer() { # a `case` nested in a command substitution is a parse error
  case "$(cat "$STAMP" 2>/dev/null)" in ''|*[!0-9]*) echo no ;; *) echo yes ;; esac
}
check "the stamp holds an epoch-seconds integer" "yes" "$(stamp_is_integer)"
check "the stamp directory is owner-only" "700" \
  "$(ls -ld "${STAMP%/*}" | awk '{print substr($1,2,9)}' \
     | sed 's/rwx/7/;s/r-x/5/;s/---/0/g' | tr -d '-')"

echo "── the unconfigured and no-session paths still short-circuit ─────────"
clear_stamp
: > "$TMPROOT/calls"
# `env -u`, because this suite is very likely being run FROM a Claude Code session,
# whose own CLAUDE_CODE_ENTRYPOINT is inherited by every child. Without the unset
# the "no session" case silently tests the "session" path and passes for the wrong
# reason - which is exactly what it did on the first run.
env -u CLAUDE_CODE_ENTRYPOINT \
    SB_CALLS="$TMPROOT/calls" PATH="$TMPROOT/bin:$PATH" HOME="$HOME_SB" \
    CLAUDE_PLUGIN_ROOT="$ROOT" "$SH" "$ROOT/scripts/heartbeat.sh" Stop >/dev/null 2>&1
check "no CLAUDE_CODE_ENTRYPOINT means no beacon" "0" \
  "$(wc -l < "$TMPROOT/calls" | tr -d ' ')"
check "and it leaves no stamp, so the next real turn is not skipped" "no" \
  "$([ -e "$STAMP" ] && echo yes || echo no)"

echo "── hooks.json registers the Stop trigger ─────────────────────────────"
HJ="$REPO/plugins/rogue/hooks/hooks.json"
# The argument is what makes the throttle apply: heartbeat.sh defaults to
# SessionStart, so a Stop entry that forgot to pass it would beacon every turn.
check "Stop spawns the heartbeat with the Stop argument" "1" \
  "$(grep -c 'heartbeat.sh\\" Stop' "$HJ")"
check "SessionStart still spawns it with no argument" "1" \
  "$(grep -c 'heartbeat.sh\\" >/dev/null' "$HJ")"
check "the Stop heartbeat is detached" "1" \
  "$(grep -c 'nohup sh \\"\$CLAUDE_PLUGIN_ROOT/scripts/heartbeat.sh\\" Stop' "$HJ")"

echo
if [ "$FAILS" = 0 ]; then echo "ALL HEARTBEAT SH TESTS PASSED"; else echo "$FAILS failure(s)"; fi
exit "$FAILS"
