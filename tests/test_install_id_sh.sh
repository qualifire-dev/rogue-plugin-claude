#!/usr/bin/env bash
# Unit tests for plugins/rogue/scripts/install-id.sh — the surface id half.
#
# The id is the backend's PLUGIN_REPOS key, not a display string: while this
# sent "Claude Code - CLI" no Claude row ever resolved a latest version, so a
# regression here is silent (rows just never go "outdated"). Runs under dash,
# which is what Claude Code invokes the hook with.
set -u
REPO="$(cd "$(dirname "$0")/.." && pwd)"
SH="${TEST_SH:-sh}"
PLUGIN_ROOT="$REPO/plugins/rogue"
fails=0

agent_for() { # agent_for [VAR=VALUE ...]
  env -i HOME="${HOME:-/tmp}" PATH="$PATH" CLAUDE_PLUGIN_ROOT="$PLUGIN_ROOT" "$@" \
    "$SH" -c '. "$CLAUDE_PLUGIN_ROOT/scripts/install-id.sh"; printf "%s" "$ROGUE_INSTALL_AGENT"'
}

check() { # check <expected> <desc> [VAR=VALUE ...]
  expected="$1"; desc="$2"; shift 2
  got=$(agent_for "$@")
  if [ "$got" = "$expected" ]; then
    echo "  ok: $desc"
  else
    echo "FAIL [$desc]: expected <$expected> but got <$got>"
    fails=$((fails + 1))
  fi
}

echo "install-id.sh surface id ($SH)"
check claude_code         "no entrypoint at all falls back to the CLI surface"
check claude_code         "cli entrypoint"                    CLAUDE_CODE_ENTRYPOINT=cli
check claude_code_desktop "desktop entrypoint"                CLAUDE_CODE_ENTRYPOINT=claude-desktop
check claude_cowork       "legacy cowork entrypoint"          CLAUDE_CODE_ENTRYPOINT=remote_cowork
# The regression this fixed: Cowork spawns Claude Code with entrypoint
# local-agent, so entrypoint matching alone filed it under claude_code.
check claude_cowork       "CLAUDE_CODE_IS_COWORK wins over a local-agent entrypoint" \
  CLAUDE_CODE_ENTRYPOINT=local-agent CLAUDE_CODE_IS_COWORK=1
check claude_code         "local-agent alone is not assumed to be Cowork" \
  CLAUDE_CODE_ENTRYPOINT=local-agent

# Every id must be lowercase snake_case: the backend looks it up verbatim.
for id in $(agent_for CLAUDE_CODE_ENTRYPOINT=cli) $(agent_for CLAUDE_CODE_ENTRYPOINT=claude-desktop) \
          $(agent_for CLAUDE_CODE_IS_COWORK=1); do
  case "$id" in
    *[!a-z_]*) echo "FAIL [id is snake_case]: <$id>"; fails=$((fails + 1)) ;;
    *)         echo "  ok: <$id> is snake_case" ;;
  esac
done

[ "$fails" -eq 0 ] || { echo "$fails failure(s)"; exit 1; }
echo "all install-id tests passed"
