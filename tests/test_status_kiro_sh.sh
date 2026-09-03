#!/usr/bin/env bash
# tests/test_status_kiro_sh.sh — plugins/kiro/scripts/status.sh under a temp HOME.
#
# Kiro has no slash-command surface for a /rogue:status skill, so the status
# command IS this script, and it is the one diagnostic path support has on a
# Kiro machine. Like the other plugins' status skills it also POSTs
# /hooks/status, which upserts a roster row fingerprinted on
# host|actor|family|agent - so the body it sends has to be the heartbeat's,
# resolved through the same actor.sh / install-id.sh / kiro-host.sh, or the
# status run registers a second row for the install it is checking.
#
# A fake `curl` on PATH records the request and answers a canned 200; a fake
# `kiro-cli` answers the two subcommands the script uses; the IDE bundle is a
# fixture reached through ROGUE_KIRO_APP. HOME is a temp dir, so nothing under
# the developer's ~/.kiro or ~/.rogue is read or written.
set -u
REPO="$(cd "$(dirname "$0")/.." && pwd)"
SH="${TEST_SH:-sh}"
fails=0
WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT

ok()  { echo "  ok: $1"; }
bad() { echo "FAIL [$1]: $2"; fails=$((fails + 1)); }
assert_has()   { case "$2" in *"$1"*) ok "$3" ;; *) bad "$3" "expected <$1> in output" ;; esac; }
assert_lacks() { case "$2" in *"$1"*) bad "$3" "found <$1>, which must not appear" ;; *) ok "$3" ;; esac; }

# ── fake toolchain ───────────────────────────────────────────────────────────
# PATH is a symlink farm plus the fakes, so a real kiro-cli or Kiro.app on the
# developer's machine is never consulted and "kiro-cli absent" is a real case.
BIN="$WORK/bin"; FARM="$WORK/farm"; mkdir -p "$BIN" "$FARM"
for b in sh bash dash dirname basename date mkdir cat sed grep tr tail head awk wc hostname \
         cp rm mv chmod find mktemp uname env printf ls touch sort defaults; do
  src="$(command -v "$b" 2>/dev/null || true)"
  [ -n "$src" ] && ln -s "$src" "$FARM/$(basename "$src")" 2>/dev/null
done
# Records the argument vector and the stdin body (`--data-binary @-`), then
# answers like the route: a JSON body and, because the script asks for it with
# -w, the status code on its own line.
cat > "$BIN/curl" <<'STUB'
#!/bin/sh
printf '%s\n' "$*" >> "$CURL_LOG"
for a in "$@"; do [ "$a" = "@-" ] && { cat >> "$CURL_LOG"; echo >> "$CURL_LOG"; }; done
printf '%s\n%s' "${FAKE_BODY:-}" "${FAKE_CODE:-200}"
STUB
cat > "$BIN/kiro-cli" <<'STUB'
#!/bin/sh
case "$1 $2" in
  "--version ")                echo "kiro-cli 2.21.0" ;;
  "settings chat.defaultAgent") [ -n "${KIRO_FAKE_DEFAULT:-}" ] && { echo "\"$KIRO_FAKE_DEFAULT\""; exit 0; }
                               echo "error: No value associated with chat.defaultAgent" >&2; exit 1 ;;
esac
exit 0
STUB
chmod +x "$BIN/curl" "$BIN/kiro-cli"

APP="$WORK/Kiro.app"; mkdir -p "$APP/Contents"
printf '<plist version="1.0"><dict><key>CFBundleShortVersionString</key><string>1.0.437</string></dict></plist>\n' \
  > "$APP/Contents/Info.plist"

# ── a HOME with the plugin installed the way install.sh --kiro leaves it ─────
new_home() { # new_home <name> -> sets H, PLUGIN; plugin staged, no Kiro wiring yet
  H="$WORK/$1"; PLUGIN="$H/.rogue/plugins/kiro"
  mkdir -p "$PLUGIN" "$H/ws"
  cp -R "$REPO/plugins/kiro/." "$PLUGIN/"
  printf '{"name":"rogue","version":"1.0.0"}\n' > "$PLUGIN/plugin.json"
  printf 'export ROGUE_API_KEY=rsk_test1234\n' > "$H/.rogue-env"
}
wire_kiro() { # the hook file, the Crew wrappers, a rogue agent carrying the hooks
  mkdir -p "$H/.kiro/hooks" "$H/.kiro/agents" "$H/ws/.kiro/agents"
  cat > "$H/.kiro/hooks/rogue.json" <<JSON
{
  "version": "v1",
  "hooks": [
    {"name": "rogue-SessionStart", "trigger": "SessionStart", "action": {"type": "command", "command": "\"$PLUGIN/scripts/hook.sh\" SessionStart kiro_ide"}, "timeout": 10},
    {"name": "rogue-PreToolUse", "trigger": "PreToolUse", "action": {"type": "command", "command": "\"$PLUGIN/scripts/hook.sh\" PreToolUse kiro_ide"}, "timeout": 10}
  ]
}
JSON
  for w in pre post; do
    printf '#!/bin/sh\n# event: PreToolUse\nexec %s/scripts/hook.sh PreToolUse kiro_crew\n' "$PLUGIN" > "$H/.kiro/hooks/rogue-crew-$w.sh"
    chmod +x "$H/.kiro/hooks/rogue-crew-$w.sh"
  done
  printf '{"name":"rogue","hooks":[{"name":"rogue-preToolUse","trigger":"preToolUse"}]}\n' > "$H/.kiro/agents/rogue.json"
  printf '{"name":"custom","hooks":[]}\n' > "$H/.kiro/agents/custom.json"
  printf '{"name":"ws","hooks":[{"name":"rogue-preToolUse","trigger":"preToolUse"}]}\n' > "$H/ws/.kiro/agents/ws.json"
  mkdir -p "$H/.rogue/logs"
  printf '2026-09-03T10:00:00Z provider=kiro surface=kiro_cli event=PreToolUse outcome=allow http=200\n' \
    > "$H/.rogue/logs/kiro.log"
}

# run_status [path] — runs the script from the workspace; sets out, RC and the
# recorded curl calls (CURLS). Knobs travel as assignment prefixes on the call:
# FAKE_BODY / FAKE_CODE (the canned response), KIRO_FAKE_DEFAULT, ROGUE_KIRO_APP.
# Called directly, never inside $( ), so the three results survive.
run_status() {
  : > "$H/curl.log"
  ( cd "$H/ws" && env -i HOME="$H" PATH="${1:-$BIN:$FARM}" CURL_LOG="$H/curl.log" \
      ROGUE_KIRO_APP="${ROGUE_KIRO_APP:-$WORK/no-app}" KIRO_FAKE_DEFAULT="${KIRO_FAKE_DEFAULT:-}" \
      FAKE_BODY="${FAKE_BODY:-}" FAKE_CODE="${FAKE_CODE:-200}" \
      "$SH" "$PLUGIN/scripts/status.sh" ) > "$H/out" 2>&1
  RC=$?
  out=$(cat "$H/out")
  CURLS=$(cat "$H/curl.log")
}

echo "kiro status.sh ($SH)"
[ -f "$REPO/plugins/kiro/scripts/status.sh" ] || { bad "status.sh exists" "missing plugins/kiro/scripts/status.sh"; echo "$fails failure(s)"; exit 1; }
"$SH" -n "$REPO/plugins/kiro/scripts/status.sh" || bad "status.sh parses under $SH" "syntax error"

# ═════════════════════════════════════════════════════════════════════════════
echo "── a fully wired CLI + IDE machine, default agent rogue ─────────────────"
new_home full; wire_kiro
FAKE_BODY='{"ok":true,"connected":true,"organization":{"id":"org_123"},"agent":{"family":"kiro","agent":"kiro_cli","version":"1.0.0","latest_version":"1.2.0","update_available":true}}'
FAKE_BODY="$FAKE_BODY" KIRO_FAKE_DEFAULT=rogue ROGUE_KIRO_APP="$APP" run_status
[ "$RC" = 0 ] && ok "exits 0" || bad "exits 0" "rc=$RC: $out"
assert_has "$H/.rogue-env"                     "$out" "lists the per-user credential file"
assert_has 'API key resolved: ...1234'         "$out" "shows the key's last four characters only"
assert_lacks 'rsk_test1234'                    "$out" "never prints the whole key"
assert_has 'kiro_cli'                          "$out" "reports the CLI surface"
assert_has 'kiro-cli 2.21.0'                   "$out" "with the version kiro-cli --version prints"
assert_has 'kiro_ide'                          "$out" "reports the IDE surface"
assert_has 'Kiro.app 1.0.437'                  "$out" "with the version from the app bundle"
assert_has 'rogue.json'                        "$out" "names the hook file"
assert_has 'present (2 Rogue hooks, surface kiro_ide)' "$out" "counts the Rogue entries in the hook file and names their surface"
assert_has 'rogue-crew-{pre,post}.sh'          "$out" "names the Crew wrappers"
assert_has 'present, executable'               "$out" "reports the wrappers present and executable"
assert_has 'agent configs with Rogue hooks         2' "$out" "counts the agent configs carrying the hooks (home + workspace, not the one without)"
assert_has 'default agent (2.x engine)             rogue - covered' "$out" "reports the default agent as covered when its config carries the hooks"
assert_has 'HTTP 200'                          "$out" "reports the connection status code"
assert_has 'organization: org_123'             "$out" "reports the organization"
assert_has 'plugin 1.0.0 (latest 1.2.0, update available)' "$out" "reports running vs latest and the update flag"
assert_has 'provider=kiro surface=kiro_cli'    "$out" "tails the hook log"
# The roster row it upserts must be the heartbeat's row.
assert_has '/api/v1/hooks/status'              "$CURLS" "POSTs /hooks/status"
assert_has 'x-rogue-api-key: rsk_test1234'     "$CURLS" "authenticates with the resolved key"
assert_has '"agent_family":"kiro"'             "$CURLS" "body names family kiro"
assert_has '"agent":"kiro_cli"'                "$CURLS" "body keys the CLI surface when kiro-cli is present"
assert_has '"version":"1.0.0"'                 "$CURLS" "body carries the plugin version from plugin.json"
assert_has '"agent_version":"2.21.0"'          "$CURLS" "body carries the Kiro build"
assert_has '"default_agent":"rogue"'           "$CURLS" "body carries the default agent"
assert_has '"host":"'                          "$CURLS" "body carries the host"

echo "── the default agent moved away from the hooked one ─────────────────────"
new_home moved; wire_kiro
FAKE_BODY="$FAKE_BODY" KIRO_FAKE_DEFAULT=custom run_status
assert_has 'default agent (2.x engine)             custom - NOT covered' "$out" "flags a default whose config carries no Rogue hooks"
assert_has 'kiro-cli agent set-default rogue'  "$out" "names the fix"

echo "── no default set, no IDE ───────────────────────────────────────────────"
new_home nodefault; wire_kiro
FAKE_BODY="$FAKE_BODY" run_status
assert_has 'default agent (2.x engine)             (none set)' "$out" "reports no default"
assert_has 'kiro_ide    Kiro.app not found'    "$out" "reports the IDE absent"
assert_lacks '"default_agent"'                 "$CURLS" "sends no default_agent when none is set"

echo "── nothing wired: plugin present, Kiro never hooked ─────────────────────"
new_home bare
FAKE_BODY="$FAKE_BODY" run_status
assert_has 'rogue.json'                        "$out" "still names the hook file"
assert_has 'MISSING'                           "$out" "reports the hook file missing"
assert_has 'agent configs with Rogue hooks         0' "$out" "counts zero hooked agent configs"
assert_has 'install.sh --kiro'                 "$out" "points at the installer"
assert_has '(no hook log yet)'                 "$out" "reports an empty log without failing"

echo "── unconfigured: no key anywhere ────────────────────────────────────────"
new_home nokey; wire_kiro; rm -f "$H/.rogue-env"
run_status
assert_has 'API key: not resolved'             "$out" "reports the missing key"
[ "$RC" != 0 ] && ok "exits non-zero when unconfigured" || bad "exits non-zero when unconfigured" "rc=0"
[ -z "$CURLS" ] && ok "makes no request without a key" || bad "makes no request without a key" "$CURLS"

echo "── the key is rejected ──────────────────────────────────────────────────"
new_home badkey; wire_kiro
FAKE_BODY='{"error":"Unauthorized"}' FAKE_CODE=401 run_status
assert_has 'HTTP 401'                          "$out" "reports the status code"
assert_has 'invalid'                           "$out" "explains a 401 as an invalid key"
[ "$RC" != 0 ] && ok "exits non-zero on a failed check" || bad "exits non-zero on a failed check" "rc=0"

echo "── transport failure ────────────────────────────────────────────────────"
new_home offline; wire_kiro
FAKE_BODY='' FAKE_CODE=000 run_status
assert_has 'HTTP 000'                          "$out" "reports curl's 000"
assert_has 'network'                           "$out" "explains 000 as a network problem"

echo "── kiro-cli absent, IDE present: the row keys on the IDE ────────────────"
new_home ideonly; wire_kiro
NOCLI="$WORK/bin-nocli"; mkdir -p "$NOCLI"; cp "$BIN/curl" "$NOCLI/curl"
FAKE_BODY="$FAKE_BODY" ROGUE_KIRO_APP="$APP" run_status "$NOCLI:$FARM"
assert_has 'kiro_cli    kiro-cli not found'    "$out" "reports the CLI absent"
assert_has '"agent":"kiro_ide"'                "$CURLS" "body keys the IDE surface"
assert_has '"agent_version":"1.0.437"'         "$CURLS" "body carries the IDE build"
assert_has 'default agent (2.x engine)             (kiro-cli not found)' "$out" "no CLI means no default to report"

echo ""
if [ "$fails" = 0 ]; then echo "kiro status.sh: all checks passed"; else echo "kiro status.sh: $fails failure(s)"; exit 1; fi
