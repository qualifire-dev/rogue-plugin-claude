#!/usr/bin/env bash
# Point THIS machine's Claude Code at the plugin WORKING TREE and a LOCAL Rogue API,
# so you can exercise uncommitted plugin changes against a backend you control.
#
#   bash tests/manual/local_api.sh up [--url URL] [--key KEY] [--ship] [--beacon-interval N]
#   bash tests/manual/local_api.sh sync      # re-push working-tree edits, no reinstall
#   bash tests/manual/local_api.sh status    # what is installed, where it points
#   bash tests/manual/local_api.sh check     # assert the log looks like this branch
#   bash tests/manual/local_api.sh ship [--reset]   # force a log upload NOW
#   bash tests/manual/local_api.sh probe     # one headless session, no interactive restart
#   bash tests/manual/local_api.sh down      # undo everything `up` did
#
# This is the sibling of live_session.sh. That script is a self-contained, asserting
# run against a fake node receiver and it installs from `git archive HEAD`. This one
# installs the WORKING TREE and leaves it installed, so your normal interactive
# sessions drive it and your own API sees the traffic.
#
# WHAT `up` CHANGES ON YOUR MACHINE (all of it undone by `down`)
#
#   * Adds a marketplace `rogue-localdev` sourced from a copy of your working tree,
#     and installs `rogue@rogue-localdev` at user scope.
#   * DISABLES `rogue@rogue-marketplace` if you have it, so exactly one plugin
#     answers each event. Two enabled copies would double every POST and write two
#     log lines per event, which makes the log unreadable for exactly the thing you
#     are trying to observe.
#   * Replaces `~/.rogue-env`, keeping the original at `~/.rogue-env.localdev-backup`.
#     It has to be that file and not the process environment: `hook.sh` sources the
#     env files AFTER the process environment is already set, with no save/restore,
#     so `~/.rogue-env`'s ROGUE_API_KEY beats anything you export. (`hook.ps1` and
#     `hook.mjs` apply process env last and do not have this behaviour - an
#     sh-dispatcher divergence from the documented precedence, tracked separately.)
#
#     ~/.rogue-env IS SHARED BY ALL SIX PLUGINS. While this is up, any Codex, Cursor,
#     Gemini, Copilot or Antigravity install on this machine also talks to your local
#     API and authenticates with the local key. That is usually what you want for a
#     backend test; it is not what you want left running.
#
#   * Nothing else. $HOME stays real, the log stays at its real path (~/.rogue/logs/
#     claude.log) so /rogue:status reads the same file you are watching.
set -u

REPO="$(CDPATH= cd -- "$(dirname -- "$0")/../.." && pwd)"
MARKET_NAME=rogue-localdev
MARKET_DIR="$HOME/.rogue-localdev/market"
ENV_FILE="$HOME/.rogue-env"
ENV_BACKUP="$HOME/.rogue-env.localdev-backup"
STATE="$HOME/.rogue-localdev/state"
LOG="${ROGUE_LOG_FILE:-$HOME/.rogue/logs/claude.log}"

DEFAULT_URL=http://localhost:8000
DEFAULT_KEY=localdev-key

say() { printf '%s\n' "$*"; }
die() { printf '%s\n' "$*" >&2; exit 1; }
rule() { printf '\n── %s %s\n' "$1" "$(printf '─%.0s' $(seq 1 $((70 - ${#1}))))"; }

command -v claude >/dev/null 2>&1 || die "need the \`claude\` CLI on PATH"

# The version the marketplace will advertise, read the same way build-release.sh
# does. It becomes the cache directory name, which `sync` has to find again.
plugin_version() {
  sed -n 's/.*"version"[[:space:]]*:[[:space:]]*"\([^"]*\)".*/\1/p' \
    "$REPO/plugins/rogue/.claude-plugin/plugin.json" | head -1
}

install_path() {
  node -e '
    const fs = require("fs"), os = require("os");
    const f = os.homedir() + "/.claude/plugins/installed_plugins.json";
    try {
      const p = JSON.parse(fs.readFileSync(f, "utf8")).plugins["rogue@" + process.env.MK];
      if (p && p.length) process.stdout.write(p[p.length - 1].installPath || "");
    } catch (e) {}
  ' 2>/dev/null
}

# ── copy the working tree into the marketplace ────────────────────────────────
# Only the two paths a Claude marketplace install reads: the manifest and the
# plugin. Copying the whole repo would drag .git along for no benefit.
stage_tree() {
  rm -rf "$MARKET_DIR"
  mkdir -p "$MARKET_DIR/.claude-plugin" || die "cannot write $MARKET_DIR"
  cp "$REPO/.claude-plugin/marketplace.json" "$MARKET_DIR/.claude-plugin/marketplace.json"
  mkdir -p "$MARKET_DIR/plugins"
  # -R, not `cp -a`: BSD cp has no -a. Follows the same portability rule as the
  # dispatchers (wc -c over stat, etc).
  cp -R "$REPO/plugins/rogue" "$MARKET_DIR/plugins/rogue"
  # Rename the marketplace so it cannot collide with a real `rogue-marketplace`
  # entry. The plugin inside is still called `rogue`, hence every claude command
  # below is marketplace-qualified.
  sed -i.bak "s/\"name\": *\"rogue-marketplace\"/\"name\": \"$MARKET_NAME\"/" \
    "$MARKET_DIR/.claude-plugin/marketplace.json"
  rm -f "$MARKET_DIR/.claude-plugin/marketplace.json.bak"
}

cmd_up() {
  URL="$DEFAULT_URL"; KEY="$DEFAULT_KEY"; SHIP=0; BEACON=''
  while [ $# -gt 0 ]; do
    case "$1" in
      --url) URL="${2:?--url needs a value}"; shift 2 ;;
      --key) KEY="${2:?--key needs a value}"; shift 2 ;;
      --ship) SHIP=1; shift ;;
      # The Stop-triggered beacon is throttled to 900s by default, so a test session
      # shorter than 15 minutes sees exactly ONE beacon - indistinguishable from the
      # old SessionStart-only behaviour, which makes the feature unobservable. 0 means
      # every turn.
      --beacon-interval) BEACON="${2:?--beacon-interval needs a value}"; shift 2 ;;
      *) die "unknown argument: $1" ;;
    esac
  done
  case "${BEACON:-0}" in *[!0-9]*) die "--beacon-interval takes seconds, got: $BEACON" ;; esac

  case "$URL" in
    # The brackets are ESCAPED. `http://[::1]:*` is a glob bracket expression, not
    # the literal IPv6 loopback - it matches one character from the set, so the arm
    # never fires for the address it names and the URL falls through to `die`.
    http://localhost:*|http://127.0.0.1:*|http://\[::1\]:*) ;;
    *) die "refusing to point at a non-local URL ($URL). This rewrites ~/.rogue-env
   for EVERY Rogue plugin on the machine; a typo here sends your sessions'
   prompts and tool calls somewhere you did not intend." ;;
  esac

  rule "the local API"
  if curl -sS -o /dev/null --max-time 3 "$URL" 2>/dev/null; then
    say "  something is listening on $URL"
  else
    say "  WARNING: nothing answered at $URL yet."
    say "  Continuing anyway - start it before you run a session. Every hook fails"
    say "  open, so an unreachable API costs you nothing but an outcome=fail line."
  fi

  rule "install the working tree"
  stage_tree
  say "  staged $(plugin_version) from $REPO -> $MARKET_DIR"
  claude plugin marketplace add "$MARKET_DIR" --scope user 2>&1 | sed 's/^/  /'
  claude plugin install "rogue@$MARKET_NAME" --scope user 2>&1 | sed 's/^/  /'
  MK="$MARKET_NAME" ; export MK
  IP="$(install_path)"
  [ -n "$IP" ] || die "  the install produced no record - check the output above"
  say "  installed to $IP"

  # Exactly one plugin per event. Recorded so `down` only re-enables what it
  # actually disabled.
  mkdir -p "$(dirname "$STATE")"
  : > "$STATE"
  if claude plugin list 2>/dev/null | grep -q 'rogue@rogue-marketplace'; then
    if claude plugin disable rogue@rogue-marketplace --scope user >/dev/null 2>&1; then
      say "  disabled rogue@rogue-marketplace (it would double every event)"
      echo "disabled_prod=1" >> "$STATE"
    fi
  fi

  rule "credentials"
  if [ -f "$ENV_FILE" ]; then
    # Never clobber a real backup: a second `up` without a `down` would otherwise
    # overwrite the saved original with the localdev one and lose it for good.
    if [ -f "$ENV_BACKUP" ]; then
      say "  $ENV_BACKUP already exists - keeping it, not re-backing-up"
    else
      cp "$ENV_FILE" "$ENV_BACKUP" && say "  backed up $ENV_FILE -> $ENV_BACKUP"
      echo "backed_up=1" >> "$STATE"
    fi
  fi
  ( umask 077
    {
      echo "# Written by tests/manual/local_api.sh - LOCAL DEVELOPMENT ONLY."
      echo "# Restore the original with: bash tests/manual/local_api.sh down"
      echo "export ROGUE_API_KEY=$KEY"
      echo "export ROGUE_BASE_URL=$URL"
      echo "export ROGUE_ACTOR_EMAIL=${ROGUE_ACTOR_EMAIL:-localdev@rogue.security}"
      echo "export ROGUE_ACTOR_NAME=${ROGUE_ACTOR_NAME:-Local Dev}"
      # Shipping itself is unconditional now - there is no ROGUE_SHIP_LOGS. What
      # --ship buys is OBSERVABILITY: without this the 15-minute self-throttle means
      # only the first turn of a run uploads, and "nothing arrived" reads as a bug.
      [ "$SHIP" = 1 ] && echo "export ROGUE_SHIP_MIN_INTERVAL=0"
      [ -n "$BEACON" ] && echo "export ROGUE_HEARTBEAT_MIN_INTERVAL=$BEACON"
    } > "$ENV_FILE"
  )
  say "  wrote $ENV_FILE (mode 600) -> $URL"
  say "  log shipping is always on - your API must serve POST /api/v1/hooks/logs"
  [ "$SHIP" = 1 ] && say "  --ship: upload throttle disabled, so every turn ships"
  [ -n "$BEACON" ] && say "  beacon throttle ${BEACON}s (0 = a beacon on every Stop)"

  rule "next"
  say "  1. Start your local API on $URL"
  say "  2. RESTART Claude Code - a plugin is loaded at session start, so this"
  say "     session is still running the old copy."
  say "  3. Use it normally, then:  bash tests/manual/local_api.sh check"
  say
  say "  Edited a script since? Re-push it without a reinstall:"
  say "     bash tests/manual/local_api.sh sync"
}

# `sync` exists because the install COPIES the tree - editing plugins/rogue in the
# repo does nothing until the copy is refreshed. Refreshing the installed copy in
# place beats uninstall/reinstall: the install record, the version and the enabled
# state all stay put, and a running session picks up the next hook invocation
# immediately (each event spawns a fresh `sh hook.sh`, nothing is cached in-process).
cmd_sync() {
  MK="$MARKET_NAME"; export MK
  IP="$(install_path)"
  [ -n "$IP" ] || die "rogue@$MARKET_NAME is not installed - run \`up\` first"
  [ -d "$IP" ] || die "the install record points at $IP, which does not exist"
  stage_tree
  # Copy CONTENTS, so files deleted in the working tree since the install still
  # linger - acceptable, and far safer than rm -rf on a path read out of a JSON file.
  cp -R "$MARKET_DIR/plugins/rogue/." "$IP/" || die "copy into $IP failed"
  say "synced $REPO/plugins/rogue -> $IP"
  say "Takes effect on the next hook invocation. No restart needed for script edits."
  say "hooks.json changes DO need a restart (the event registration is read once)."
}

cmd_status() {
  MK="$MARKET_NAME"; export MK
  rule "plugins"
  claude plugin list 2>/dev/null | grep -i rogue | sed 's/^/  /' || say "  (none)"
  IP="$(install_path)"
  [ -n "$IP" ] && say "  localdev install path: $IP"
  if [ -n "$IP" ] && [ -f "$IP/scripts/surface.sh" ]; then
    say "  the installed copy HAS scripts/surface.sh (this branch's change)"
  elif [ -n "$IP" ]; then
    say "  the installed copy has NO scripts/surface.sh - it predates this branch,"
    say "  or \`sync\` has not run since you switched branches"
  fi
  rule "credentials"
  if [ -f "$ENV_FILE" ]; then
    sed 's/^export ROGUE_API_KEY=.*/export ROGUE_API_KEY=<redacted>/' "$ENV_FILE" | sed 's/^/  /'
  else
    say "  no $ENV_FILE"
  fi
  [ -f "$ENV_BACKUP" ] && say "  original saved at $ENV_BACKUP"
  rule "the log"
  say "  $LOG"
  [ -f "$LOG" ] && tail -8 "$LOG" | sed 's/^/  /' || say "  (nothing yet)"
}

# What this branch is supposed to have changed, asserted against real lines that a
# real session wrote. Deliberately narrow: it reads the log only, so it says nothing
# about what the API did with the request - that is your backend's to check.
cmd_check() {
  [ -f "$LOG" ] || die "no $LOG yet - run a session first"
  rule "lines this run wrote"
  tail -12 "$LOG" | sed 's/^/  /'

  rule "verdict"
  fails=0
  ok()   { say "  ok: $1"; }
  bad()  { say "  FAIL: $1"; fails=$((fails + 1)); }

  # DISPATCHER lines only. `event=ShipLogs` lines are written by ship-logs.sh, which
  # is the byte-identical shared script - it takes the slug as an argument and has no
  # surface signal at all, so an absent surface= is correct there per the spec ("absent
  # when the surface cannot be determined"). Counting them as dispatcher lines made
  # every assertion below fail as soon as one landed in the tail, i.e. exactly when
  # --ship is on and the thing under test is working.
  recent="$(tail -40 "$LOG" | grep -v 'event=ShipLogs')"
  total="$(printf '%s\n' "$recent" | grep -c 'provider=claude')"
  tagged="$(printf '%s\n' "$recent" | grep -c 'provider=claude surface=')"

  [ "$total" -gt 0 ] && ok "the hooks are firing ($total recent lines)" \
                     || bad "no provider=claude lines at all - the plugin is not loaded"

  if [ "$tagged" = "$total" ] && [ "$total" -gt 0 ]; then
    ok "every recent line carries surface= ($tagged/$total)"
  else
    bad "only $tagged of $total recent lines carry surface= - a stale install, or \`sync\` has not run"
  fi

  # Position is part of the contract the backend parses on: provider, then surface,
  # then event. A token in the wrong place is worse than a missing one.
  #
  # EVERY tagged line, not any: the obvious `grep -q '<correct shape>'` passes as
  # soon as ONE line is right, so a run where most lines carry the token in the
  # wrong place still reported ok. Count the tagged lines that do NOT match instead.
  misplaced="$(printf '%s\n' "$recent" | grep 'surface=' \
               | grep -vc 'provider=claude surface=[a-z_]* event=')"
  [ "${misplaced:-0}" = 0 ] && ok "surface= sits between provider= and event= on every tagged line" \
                            || bad "$misplaced tagged line(s) do not have surface= between provider= and event="

  # The closed list. Anything else means something leaked into the token.
  stray="$(printf '%s\n' "$recent" | sed -n 's/.*surface=\([^ ]*\).*/\1/p' \
           | grep -vc '^\(cli\|desktop\|cowork\)$')"
  [ "${stray:-0}" = 0 ] && ok "every slug is from claude's closed list" \
                        || bad "$stray line(s) carry a slug outside cli/desktop/cowork"

  # The two things that must never appear, per the spec. Spelled as if/else rather
  # than `grep -q … && bad … || ok …`: in that form the `||` arm also runs whenever
  # the `&&` arm returns non-zero, so a future edit to bad() would silently report
  # both a failure and an ok for the same line.
  if printf '%s\n' "$recent" | grep -q 'surface=unknown'; then
    bad "a line says surface=unknown"
  else
    ok "no surface=unknown"
  fi
  # `surface=` followed by a space OR end-of-line. Anchoring on the space alone
  # missed an empty token at the end of a line.
  if printf '%s\n' "$recent" | grep -qE 'surface=( |$)'; then
    bad "a line has an empty surface="
  else
    ok "no empty surface="
  fi

  # Did the API answer? An Unauthorized here is a backend-side key mismatch, not a
  # plugin failure - the plugin relayed exactly what it got.
  rule "what your API answered"
  printf '%s\n' "$recent" | grep 'raw=' | tail -4 | sed 's/^/  /' || say "  (no raw= lines)"

  # A SUCCESSFUL SHIP WRITES NOTHING. ship-logs.sh logs only notable outcomes - a
  # fail, a skip, a stall - and deliberately never the happy path, because a line per
  # run would mean every run has new bytes to ship and would destroy the "an idle
  # machine makes no HTTP request at all" property the throttle depends on. So these
  # lines are a FAILURE feed, not a progress feed: the count you want is ZERO, and the
  # evidence of success is the offset, which advances only on a 2xx.
  rule "shipping and the Stop beacon"
  ships="$(grep -c 'event=ShipLogs' "$LOG" 2>/dev/null)"
  if [ "${ships:-0}" = 0 ]; then
    say "  no ShipLogs lines - nothing has FAILED to ship (success is silent)"
  else
    say "  $ships ShipLogs line(s) - these are failures/skips, not progress:"
    grep 'event=ShipLogs' "$LOG" 2>/dev/null | tail -3 | sed 's/^/    /'
  fi
  SHIP_STATE="$HOME/.rogue/ship/claude.state"
  if [ -r "$SHIP_STATE" ]; then
    _off="$(sed -n 's/^offset=\([0-9]*\)$/\1/p' "$SHIP_STATE" | head -1)"
    _size="$(wc -c < "$LOG" | tr -d ' ')"
    if [ -n "$_off" ]; then
      if [ "$_off" = "$_size" ]; then
        say "  offset $_off == log size: every byte has been accepted (2xx)"
      else
        say "  offset $_off of $_size bytes accepted; $((_size - _off)) pending"
        say "  Flush now with: bash tests/manual/local_api.sh ship"
      fi
    fi
  else
    say "  no ship state yet at $SHIP_STATE - nothing has been uploaded yet. Shipping is"
    say "  unconditional, so this means no turn has run, or every run was throttled;"
    say "  \`up --ship\` disables the throttle and \`ship\` forces one upload now."
  fi
  BEACON_STAMP="$HOME/.rogue/beacon/.last-claude"
  if [ -r "$BEACON_STAMP" ]; then
    _bs="$(head -n1 "$BEACON_STAMP" | tr -d '[:space:]')"
    _now="$(date -u +%s)"
    case "$_bs" in
      ''|*[!0-9]*) say "  beacon stamp is NOT an integer ($_bs) - the throttle reads it as untrusted" ;;
      *) say "  last beacon $(( _now - _bs ))s ago (stamp $_bs)" ;;
    esac
  else
    say "  no beacon stamp yet at $BEACON_STAMP"
  fi

  say
  [ "$fails" = 0 ] && say "LOCAL API CHECK PASSED" || say "$fails failure(s)"
  return "$fails"
}

# Force one shipper run NOW, instead of waiting for the next Stop and guessing.
# `--reset` first clears the offset state, so the whole log re-ships from byte 0 - the
# only way to get a repeatable, observable POST at your API on demand.
#
# ROGUE_DEBUG is forced on: a successful run prints NOTHING (see the note in `check`),
# so without it a working ship looks identical to one that did nothing at all.
cmd_ship() {
  RESET=0
  [ "${1:-}" = "--reset" ] && RESET=1
  MK="$MARKET_NAME"; export MK
  IP="$(install_path)"
  [ -n "$IP" ] || die "rogue@$MARKET_NAME is not installed - run \`up\` first"
  [ -f "$IP/scripts/ship-logs.sh" ] || die "no shipper at $IP/scripts/ship-logs.sh"

  SHIP_STATE="$HOME/.rogue/ship/claude.state"
  rule "force a ship"
  if [ "$RESET" = 1 ]; then
    rm -f "$HOME"/.rogue/ship/*.state 2>/dev/null
    say "  cleared the offset state - the whole log will re-ship from byte 0"
  fi
  before="$(sed -n 's/^offset=\([0-9]*\)$/\1/p' "$SHIP_STATE" 2>/dev/null | head -1)"
  [ -n "$before" ] || before=0

  # The actor is INHERITED, never re-resolved inside the shipper: the six plugins'
  # cascades differ, so a second cascade would key the uploaded logs to a different
  # identity for this same machine and they would join to nothing on the backend.
  # shellcheck disable=SC1090
  [ -r "$ENV_FILE" ] && . "$ENV_FILE"
  [ -n "${ROGUE_ACTOR_EMAIL:-}" ] \
    || die "no ROGUE_ACTOR_EMAIL to inherit - the shipper would skip with reason=no-actor"
  export ROGUE_ACTOR_EMAIL ROGUE_ACTOR_NAME
  say "  running $IP/scripts/ship-logs.sh (slug=claude version=$(plugin_version) family=claude)"
  ROGUE_DEBUG=1 sh "$IP/scripts/ship-logs.sh" "$IP" claude "$(plugin_version)" claude 2>&1 \
    | sed 's/^/  ship: /'

  after="$(sed -n 's/^offset=\([0-9]*\)$/\1/p' "$SHIP_STATE" 2>/dev/null | head -1)"
  [ -n "$after" ] || after=0
  say
  if [ "$after" -gt "$before" ]; then
    say "  OFFSET ADVANCED $before -> $after ($((after - before)) bytes accepted with a 2xx)"
    say "  That is durable proof your API accepted them - the offset moves on 2xx only."
  elif [ "$before" -gt 0 ]; then
    say "  offset unchanged at $before. Tell the two cases apart by the ship: lines:"
    say "    no POST line at all -> nothing new on disk (an idle run makes no request)"
    say "    a POST line then outcome=fail http=NNN -> your API rejected the bytes"
  else
    say "  no offset recorded, and shipping is unconditional - so this is not a flag."
    say "  Check the ship: lines above for a reason (no actor, no curl), and that your"
    say "  API answers POST /api/v1/hooks/logs with a 2xx."
  fi
}

# A headless probe, for when you do not want to restart your editor to see whether
# the API is wired up. Claude Code did NOT run plugin-provided hooks in a `claude -p`
# run on 2.1.223, so this registers the INSTALLED plugin's own hooks.json through
# --settings - the same trick, and the same caveat, as live_session.sh.
cmd_probe() {
  MK="$MARKET_NAME"; export MK
  IP="$(install_path)"
  [ -n "$IP" ] || die "rogue@$MARKET_NAME is not installed - run \`up\` first"
  command -v node >/dev/null 2>&1 || die "need node for this subcommand"
  SETTINGS="$HOME/.rogue-localdev/hooks-settings.json"
  mkdir -p "$(dirname "$SETTINGS")"
  ROGUE_LOCAL_ROOT="$IP" ROGUE_LOCAL_OUT="$SETTINGS" node -e '
    const fs = require("fs");
    const root = process.env.ROGUE_LOCAL_ROOT, out = process.env.ROGUE_LOCAL_OUT;
    const hooks = JSON.parse(fs.readFileSync(root + "/hooks/hooks.json", "utf8")).hooks;
    // The only edit: expand ${CLAUDE_PLUGIN_ROOT}, which Claude Code substitutes for
    // a plugin hook but not for a settings hook.
    const expanded = JSON.parse(
      JSON.stringify(hooks).replace(/\$\{CLAUDE_PLUGIN_ROOT\}/g, root));
    fs.writeFileSync(out, JSON.stringify({ hooks: expanded }, null, 2));
    console.log("  registered " + Object.keys(expanded).length + " events from " + root);
  ' || die "could not build the settings file"
  rule "one headless session"
  ( cd "$HOME/.rogue-localdev" || exit 1
    env CLAUDE_PLUGIN_ROOT="$IP" \
      claude --settings "$SETTINGS" --output-format text \
        -p 'Run the shell command `echo rogue-localdev-probe` and then reply with just the word done.' \
      2>&1 | sed 's/^/  claude: /' )
  cmd_check
}

cmd_down() {
  rule "undo"
  claude plugin uninstall "rogue@$MARKET_NAME" --scope user >/dev/null 2>&1 \
    && say "  uninstalled rogue@$MARKET_NAME"
  claude plugin marketplace remove "$MARKET_NAME" >/dev/null 2>&1 \
    && say "  removed the $MARKET_NAME marketplace"
  # Uninstalling leaves the extracted tree in the cache, and that leftover is not
  # inert: it is a NEWER copy than your real install, so anything resolving the
  # plugin root by "newest under the cache" - the last-resort layer of the
  # /rogue:status support snippet - would pick this one.
  if [ -d "$HOME/.claude/plugins/cache/$MARKET_NAME" ]; then
    rm -rf "$HOME/.claude/plugins/cache/$MARKET_NAME" && say "  removed its plugin cache"
  fi
  if [ -f "$STATE" ] && grep -q '^disabled_prod=1' "$STATE"; then
    claude plugin enable rogue@rogue-marketplace --scope user >/dev/null 2>&1 \
      && say "  re-enabled rogue@rogue-marketplace"
  fi
  if [ -f "$ENV_BACKUP" ]; then
    mv "$ENV_BACKUP" "$ENV_FILE" && say "  restored $ENV_FILE from the backup"
  else
    say "  no backup to restore - $ENV_FILE still points at the local API."
    say "  Run /rogue:setup to write your real credentials back."
  fi
  rm -rf "$HOME/.rogue-localdev"
  say "  removed the staging directory"
  say
  say "  RESTART Claude Code to unload the plugin."
}

case "${1:-}" in
  up)     shift; cmd_up "$@" ;;
  sync)   cmd_sync ;;
  status) cmd_status ;;
  check)  cmd_check ;;
  ship)   shift; cmd_ship "$@" ;;
  probe)  cmd_probe ;;
  down)   cmd_down ;;
  # 2,11p: the usage block above, which grew a `ship` line. Keep this range in step
  # with it - a stale range silently stops printing the last subcommand.
  *)      sed -n '2,11p' "$0" | sed 's/^# \{0,1\}//' ; exit 1 ;;
esac
