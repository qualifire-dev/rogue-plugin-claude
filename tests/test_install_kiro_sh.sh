#!/usr/bin/env bash
# tests/test_install_kiro_sh.sh — black-box test of `install.sh --kiro`.
#
# Kiro is the one family whose plugin is wired in by FILES the installer writes
# rather than by a vendor CLI: a universal-v1 hook file for the IDE and the 3.0
# engine, two Crew wrapper scripts, a hooks block merged into every custom agent
# config for the 2.x engine, and a `rogue` agent created through kiro-cli and
# made the default only when the user set none (ADR 0001). Nothing else in the
# repo exercises that wiring, and a wrong hook file is silent: Kiro loads
# nothing and every event goes unrecorded.
#
# The installer runs for real, under a temporary HOME, with a fake `curl` that
# serves a locally built release tarball and a fake `kiro-cli` that records its
# invocations and simulates the three subcommands the installer uses. PATH is a
# symlink farm so no other coding agent on the developer's machine is detected
# (a real `claude` on PATH would otherwise be installed into).
set -euo pipefail

REPO="$(cd "$(dirname "$0")/.." && pwd)"
WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT
fails=0

ok()  { echo "  ok: $1"; }
bad() { echo "FAIL [$1]: $2"; fails=$((fails + 1)); }
check() { # <label> <expected> <actual>
  if [ "$2" = "$3" ]; then ok "$1"; else bad "$1" "expected [$2], got [$3]"; fi
}
json() { # json <file> <python-expr over d>
  python3 -c 'import json,sys; d=json.load(open(sys.argv[1])); print(eval(sys.argv[2]))' "$1" "$2"
}

# ── Fake toolchain ───────────────────────────────────────────────────────────
BIN="$WORK/bin"
FARM="$WORK/farm"
mkdir -p "$BIN" "$FARM"
for b in bash sh dirname basename date mkdir cat sed grep tr tail head awk wc hostname whoami \
         tar cp rm mv chmod find mktemp uname env printf sleep true node python3 ls touch; do
  src="$(command -v "$b" 2>/dev/null || true)"
  [ -n "$src" ] || continue
  ln -s "$src" "$FARM/$(basename "$src")" 2>/dev/null || true
done
command -v node >/dev/null || { echo "node is required (the agent-config merge runs on it)" >&2; exit 1; }

# `curl -o <file> <url>`: hands the installer the locally built tarball.
cat > "$BIN/curl" <<'STUB'
#!/usr/bin/env bash
out=""
while [ $# -gt 0 ]; do case "$1" in -o) out="$2"; shift ;; esac; shift; done
[ -n "$out" ] || exit 22
cp "$TARBALL" "$out"
STUB
chmod +x "$BIN/curl"

# kiro-cli 2.21.0's shape: `settings chat.defaultAgent` prints the value (exit
# 0) or "error: No value associated with chat.defaultAgent" (exit 1); `agent
# create --name X` writes X.json into the global agent dir from Kiro's
# defaults; `agent set-default X` records the choice.
cat > "$BIN/kiro-cli" <<'STUB'
#!/usr/bin/env bash
echo "$*" >> "$KIRO_CLI_LOG"
case "${1:-} ${2:-}" in
  "agent create")
    name=""
    while [ $# -gt 0 ]; do case "$1" in --name) name="$2"; shift ;; esac; shift; done
    mkdir -p "$HOME/.kiro/agents"
    printf '{\n  "name": "%s",\n  "description": "created by kiro-cli",\n  "tools": ["*"],\n  "prompt": ""\n}\n' \
      "$name" > "$HOME/.kiro/agents/$name.json" ;;
  "agent set-default")
    printf '%s' "$3" > "$KIRO_STATE/default" ;;
  "settings chat.defaultAgent")
    if [ -s "$KIRO_STATE/default" ]; then cat "$KIRO_STATE/default"; exit 0; fi
    echo "error: No value associated with chat.defaultAgent" >&2; exit 1 ;;
esac
exit 0
STUB
chmod +x "$BIN/kiro-cli"

# The release layout build-release.sh produces: the archive's top dir IS the plugin.
build_tarball() { # <version>
  local stage="$WORK/stage"
  rm -rf "$stage"; mkdir -p "$stage/rogue-plugin-kiro"
  cp -R "$REPO/plugins/kiro/." "$stage/rogue-plugin-kiro/"
  sed -i.bak -E "s/\"version\": \"[^\"]*\"/\"version\": \"$1\"/" "$stage/rogue-plugin-kiro/plugin.json"
  rm -f "$stage/rogue-plugin-kiro/plugin.json.bak"
  TARBALL="$WORK/rogue-plugin-kiro.tar.gz"
  tar -czf "$TARBALL" -C "$stage" rogue-plugin-kiro
}

OUT="$WORK/out"; ERR="$WORK/err"
# run_install <home> <path> [installer args...]
run_install() {
  local home="$1" path="$2"; shift 2
  mkdir -p "$home" "$home/state" "$home/ws"
  : > "$home/kiro-cli.log"
  set +e
  ( cd "$home/ws" && env -i PATH="$path" HOME="$home" TARBALL="$TARBALL" \
      KIRO_CLI_LOG="$home/kiro-cli.log" KIRO_STATE="$home/state" \
      NO_COLOR=1 ROGUE_NON_INTERACTIVE=1 ROGUE_API_KEY=test-key \
      bash "$REPO/install.sh" "$@" ) > "$OUT" 2> "$ERR"
  LAST_RC=$?
  set -e
}

seed_agents() { # <home>: one custom agent with its own hooks, one workspace agent, one broken file
  mkdir -p "$1/.kiro/agents" "$1/ws/.kiro/agents"
  cat > "$1/.kiro/agents/custom.json" <<'JSON'
{
  "name": "custom",
  "model": "claude-sonnet-4",
  "tools": ["fs_read", "execute_bash"],
  "hooks": [
    { "name": "mine", "trigger": "preToolUse", "matcher": "execute_bash", "action": { "type": "command", "command": "echo mine" }, "timeout": 5 }
  ],
  "prompt": "be careful"
}
JSON
  printf '{"name":"ws","tools":[]}\n' > "$1/ws/.kiro/agents/ws.json"
  printf '{"name": "broken", "tools": [\n' > "$1/.kiro/agents/broken.json"
}

FULL_PATH="$BIN:$FARM"

# ═════════════════════════════════════════════════════════════════════════════
# 1. Fresh HOME, kiro-cli present, no default agent set
# ═════════════════════════════════════════════════════════════════════════════
H="$WORK/home1"
mkdir -p "$H"
seed_agents "$H"
build_tarball 1.0.0
run_install "$H" "$FULL_PATH" --kiro
check "install exits 0" "0" "$LAST_RC"
[ "$LAST_RC" = 0 ] || { cat "$ERR"; }

PLUGIN="$H/.rogue/plugins/kiro"
HOOK="$PLUGIN/scripts/hook.sh"
[ -x "$HOOK" ] && ok "bridge lands under ~/.rogue/plugins/kiro and is executable" \
  || bad "bridge lands under ~/.rogue/plugins/kiro" "missing or not executable: $HOOK"
check "bridge carries the release version" "1.0.0" "$(json "$PLUGIN/plugin.json" 'd["version"]')"
[ -f "$PLUGIN/scripts/actor.sh" ] && [ -f "$PLUGIN/scripts/heartbeat.sh" ] && ok "shared helpers ship with the bridge" \
  || bad "shared helpers ship with the bridge" "actor.sh / heartbeat.sh missing"
[ -e "$H/.kiro/plugins" ] && bad "nothing is written under a Kiro-owned plugin path" "found $H/.kiro/plugins" \
  || ok "nothing is written under a Kiro-owned plugin path"

# ── the hook file: universal v1, every monitored event, no matcher ──────────
HF="$H/.kiro/hooks/rogue.json"
[ -f "$HF" ] && ok "hook file written to ~/.kiro/hooks/rogue.json" || bad "hook file written" "missing $HF"
check "hook file is v1"                 "v1" "$(json "$HF" 'd["version"]')"
check "hook file carries the 8 monitored events" \
  "SessionStart UserPromptSubmit PreToolUse PostToolUse Stop PostFileCreate PostFileSave PostFileDelete" \
  "$(json "$HF" '" ".join(h["trigger"] for h in d["hooks"])')"
check "every hook is a command action"  "True" "$(json "$HF" 'all(h["action"]["type"]=="command" for h in d["hooks"])')"
check "every hook has timeout 10"       "True" "$(json "$HF" 'all(h["timeout"]==10 for h in d["hooks"])')"
check "no hook carries a matcher"       "True" "$(json "$HF" 'all("matcher" not in h for h in d["hooks"])')"
check "every hook name is rogue-<event>" "True" "$(json "$HF" 'all(h["name"]=="rogue-"+h["trigger"] for h in d["hooks"])')"
check "hook commands run the bridge with the event and the kiro_ide surface" "True" \
  "$(json "$HF" 'all(h["action"]["command"]=="\"'"$HOOK"'\" "+h["trigger"]+" kiro_ide" for h in d["hooks"])')"

# ── the Crew wrappers ───────────────────────────────────────────────────────
for pair in pre:PreToolUse post:PostToolUse; do
  f="$H/.kiro/hooks/rogue-crew-${pair%%:*}.sh"; ev="${pair#*:}"
  [ -x "$f" ] && ok "crew wrapper $(basename "$f") is executable" || bad "crew wrapper $(basename "$f")" "missing or not executable"
  check "$(basename "$f") declares its event"          "# event: $ev" "$(sed -n 2p "$f")"
  check "$(basename "$f") execs the bridge by absolute path" \
    "exec $HOOK $ev kiro_crew" "$(grep '^exec ' "$f")"
  if grep -q '[;|&$`<>()]' "$f"; then bad "$(basename "$f") has no shell metacharacters" "$(grep -n '[;|&$`<>()]' "$f")"; else ok "$(basename "$f") has no shell metacharacters"; fi
done

# ── custom agents: merged, not replaced ─────────────────────────────────────
CUSTOM="$H/.kiro/agents/custom.json"
check "custom agent keeps its model"      "claude-sonnet-4" "$(json "$CUSTOM" 'd["model"]')"
check "custom agent keeps its tools"      "['fs_read', 'execute_bash']" "$(json "$CUSTOM" 'd["tools"]')"
check "custom agent keeps its prompt"     "be careful" "$(json "$CUSTOM" 'd["prompt"]')"
check "custom agent keeps its own hook beside Rogue's" "mine" "$(json "$CUSTOM" 'd["hooks"][0]["name"]')"
check "custom agent's own hook is untouched" "execute_bash" "$(json "$CUSTOM" 'd["hooks"][0]["matcher"]')"
check "custom agent gets the five 2.x triggers" \
  "agentSpawn userPromptSubmit preToolUse postToolUse stop" \
  "$(json "$CUSTOM" '" ".join(h["trigger"] for h in d["hooks"] if h["name"].startswith("rogue-"))')"
check "agent hooks run the bridge with the kiro_cli surface" "True" \
  "$(json "$CUSTOM" 'all(h["action"]["command"]=="\"'"$HOOK"'\" "+h["trigger"]+" kiro_cli" for h in d["hooks"] if h["name"].startswith("rogue-"))')"
check "agent hooks are the universal array form" "True" \
  "$(json "$CUSTOM" 'all(set(h)=={"name","trigger","action","timeout"} and h["action"]["type"]=="command" for h in d["hooks"] if h["name"].startswith("rogue-"))')"
check "agent hooks have timeout 10" "True" "$(json "$CUSTOM" 'all(h["timeout"]==10 for h in d["hooks"] if h["name"].startswith("rogue-"))')"
check "workspace agent (.kiro/agents) is merged too" "5" "$(json "$H/ws/.kiro/agents/ws.json" 'len(d["hooks"])')"
check "workspace agent keeps its fields" "ws" "$(json "$H/ws/.kiro/agents/ws.json" 'd["name"]')"

# ── unparseable config: skipped with a warning, run still succeeds ─────────
check "unparseable agent config is left byte for byte" \
  '{"name": "broken", "tools": [' "$(cat "$H/.kiro/agents/broken.json")"
grep -q "broken.json" "$ERR" && ok "unparseable agent config is named in a warning" \
  || bad "unparseable agent config is named in a warning" "$(cat "$ERR")"

# ── the rogue agent: created, merged, made default (none was set) ───────────
grep -q "^agent create --name rogue$" "$H/kiro-cli.log" && ok "rogue agent created via kiro-cli agent create --name rogue" \
  || bad "rogue agent created via kiro-cli" "$(cat "$H/kiro-cli.log")"
ROGUE="$H/.kiro/agents/rogue.json"
check "rogue agent keeps Kiro's defaults"  "created by kiro-cli" "$(json "$ROGUE" 'd["description"]')"
check "rogue agent carries the hooks"      "5" "$(json "$ROGUE" 'len([h for h in d["hooks"] if h["name"].startswith("rogue-")])')"
grep -q "^settings chat.defaultAgent$" "$H/kiro-cli.log" && ok "default agent is detected via kiro-cli settings chat.defaultAgent" \
  || bad "default agent detected via settings" "$(cat "$H/kiro-cli.log")"
grep -q "^agent set-default rogue$" "$H/kiro-cli.log" && ok "rogue set as default when none was set" \
  || bad "rogue set as default when none was set" "$(cat "$H/kiro-cli.log")"
check "the default is recorded" "rogue" "$(cat "$H/state/default")"

# ═════════════════════════════════════════════════════════════════════════════
# 2. Second run with a newer release: upgrades in place, one copy of each
# ═════════════════════════════════════════════════════════════════════════════
build_tarball 1.0.1
run_install "$H" "$FULL_PATH" --kiro
check "re-run exits 0" "0" "$LAST_RC"
check "re-run updates the bridge version" "1.0.1" "$(json "$PLUGIN/plugin.json" 'd["version"]')"
check "re-run leaves one hook file"       "1" "$(ls "$H/.kiro/hooks"/rogue*.json | wc -l | tr -d ' ')"
check "re-run leaves one wrapper per Crew event" "2" "$(ls "$H/.kiro/hooks"/rogue-crew-*.sh | wc -l | tr -d ' ')"
check "re-run leaves 8 hooks in the hook file" "8" "$(json "$HF" 'len(d["hooks"])')"
check "re-run does not duplicate the agent hooks" "6" "$(json "$CUSTOM" 'len(d["hooks"])')"
check "re-run still keeps the user's own hook" "mine" "$(json "$CUSTOM" 'd["hooks"][0]["name"]')"
check "re-run does not re-create the rogue agent" "0" "$(grep -c "^agent create" "$H/kiro-cli.log" || true)"
check "re-run does not touch the default once set" "0" "$(grep -c "^agent set-default" "$H/kiro-cli.log" || true)"
grep -q "rogue" "$ERR" && grep -qi "left unchanged\|already" "$ERR" && ok "re-run reports the default it found" \
  || bad "re-run reports the default it found" "$(cat "$ERR")"

# ═════════════════════════════════════════════════════════════════════════════
# 3. A default agent the user already chose is left alone and printed
# ═════════════════════════════════════════════════════════════════════════════
H3="$WORK/home3"
mkdir -p "$H3/state"
printf 'my-agent' > "$H3/state/default"
run_install "$H3" "$FULL_PATH" --kiro
check "install with a preset default exits 0" "0" "$LAST_RC"
grep -q "^agent create --name rogue$" "$H3/kiro-cli.log" && ok "rogue agent is still created" \
  || bad "rogue agent is still created" "$(cat "$H3/kiro-cli.log")"
check "an existing default is not overridden" "0" "$(grep -c "^agent set-default" "$H3/kiro-cli.log" || true)"
check "the existing default survives" "my-agent" "$(cat "$H3/state/default")"
grep -q "my-agent" "$ERR" && ok "the existing default is printed" || bad "the existing default is printed" "$(cat "$ERR")"

# ═════════════════════════════════════════════════════════════════════════════
# 4. No kiro-cli on PATH: IDE-only machine — hook file yes, rogue agent no
# ═════════════════════════════════════════════════════════════════════════════
H4="$WORK/home4"
mkdir -p "$H4/.kiro" "$WORK/bin-nocli"
cp "$BIN/curl" "$WORK/bin-nocli/curl"
run_install "$H4" "$WORK/bin-nocli:$FARM" --kiro
check "install without kiro-cli exits 0" "0" "$LAST_RC"
[ -f "$H4/.kiro/hooks/rogue.json" ] && ok "hook file written without kiro-cli" || bad "hook file written without kiro-cli" "missing"
[ -e "$H4/.kiro/agents/rogue.json" ] && bad "no rogue agent without kiro-cli" "rogue.json was written" \
  || ok "no rogue agent without kiro-cli"
check "kiro-cli was never called" "0" "$(wc -l < "$H4/kiro-cli.log" | tr -d ' ')"

# ═════════════════════════════════════════════════════════════════════════════
# 5. Auto-detection: no flag, kiro-cli on PATH → kiro is installed
# ═════════════════════════════════════════════════════════════════════════════
H5="$WORK/home5"
run_install "$H5" "$FULL_PATH"
check "auto-detect exits 0" "0" "$LAST_RC"
grep -q "Done.*kiro" "$ERR" && ok "auto-detect picks kiro from the kiro-cli command" || bad "auto-detect picks kiro" "$(tail -3 "$ERR")"
[ -f "$H5/.kiro/hooks/rogue.json" ] && ok "auto-detect installs the hook file" || bad "auto-detect installs the hook file" "missing"

# ~/.kiro alone (IDE, no CLI) is enough to detect.
H6="$WORK/home6"
mkdir -p "$H6/.kiro"
run_install "$H6" "$WORK/bin-nocli:$FARM"
check "auto-detect from ~/.kiro exits 0" "0" "$LAST_RC"
grep -q "Done.*kiro" "$ERR" && ok "auto-detect picks kiro from ~/.kiro" || bad "auto-detect picks kiro from ~/.kiro" "$(tail -3 "$ERR")"

# Nothing to detect: --kiro dies with a pointer. The app-bundle probe reads the
# real /Applications, which a temp HOME cannot hide, so the case is skipped on a
# machine that has the IDE.
if [ -d /Applications/Kiro.app ]; then
  echo "  skip: --kiro with no Kiro install (Kiro.app is installed on this machine)"
else
  H7="$WORK/home7"
  run_install "$H7" "$WORK/bin-nocli:$FARM" --kiro
  check "--kiro with no Kiro install fails loud" "1" "$LAST_RC"
  grep -q "kiro" "$ERR" && ok "--kiro failure names what was looked for" || bad "--kiro failure names what was looked for" "$(cat "$ERR")"
fi

echo ""
if [ "$fails" -eq 0 ]; then echo "test_install_kiro_sh: all passed"; else echo "test_install_kiro_sh: $fails failure(s)"; exit 1; fi
