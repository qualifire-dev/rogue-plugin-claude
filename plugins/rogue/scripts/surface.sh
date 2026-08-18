#!/bin/sh
# Claude's SURFACE, derived from CLAUDE_CODE_ENTRYPOINT — one table, two consumers.
#
#   hook.sh      stamps the SLUG on every log line     (surface=cli)
#   hook.sh      sends the AGENT ID as x-rogue-agent    (claude_code)
#   heartbeat.sh sends the AGENT ID as the roster agent (claude_code)
#
# They must never disagree: a log line and the roster row it belongs to would then
# name different surfaces for one session, which is worse than the log saying
# nothing at all. That is the whole reason this mapping lives in its own file
# instead of as a `case` copy-pasted into both scripts. Add a surface HERE.
#
#   slug     | agent id            | label                 | when
#   ---------|---------------------|-----------------------|-------------------
#   cowork   | claude_cowork       | Claude Cowork         | IS_COWORK set, or entrypoint contains "cowork"
#   desktop  | claude_code_desktop | Claude Code - Desktop | entrypoint contains "desktop"
#   cli      | claude_code         | Claude Code - CLI     | any other NON-EMPTY entrypoint
#   (none)   | claude_code         | Claude Code - CLI     | entrypoint empty or unset
#
# CLAUDE_CODE_IS_COWORK is checked BEFORE the entrypoint, and that ordering is
# load-bearing: Cowork spawns Claude Code with CLAUDE_CODE_ENTRYPOINT=local-agent,
# NOT a *cowork* value, so matching the entrypoint alone files every LOCAL Cowork
# session under the CLI surface. Cloud Cowork does carry "remote_cowork", which is
# why the entrypoint arm still exists.
#
# The ROSTER field is the AGENT ID, not the label. The id is also the key the
# backend resolves the latest release from (PLUGIN_REPOS in
# services/coding-agent-versions.ts), so it must be a stable snake_case token:
# every sibling plugin sends one (github_copilot, codex_cli, gemini_cli,
# antigravity_ide), and rendering a human label is the dashboard's job. While this
# sent "Claude Code - CLI" it matched no key, so EVERY Claude row carried
# latest_version=null / update_available=false however old the install was.
# rogue_surface_label is kept for human-facing output only.
#
# Slugs are lowercase, contain no space and no `=`, so a reader can find the value
# by scanning to the next `key=` token. They are a closed set: never a path, a user
# name, a host, or anything else read off the environment.
#
# An EMPTY entrypoint yields an EMPTY slug, and the caller then omits the token
# entirely — the log never says `surface=unknown`. It cannot actually arise on the
# logging path (hook.sh and hook.ps1 both `exit 0` before their first log line when
# the variable is unset), so the omission is a guarantee about a case that does not
# occur rather than a state to design around. The LABEL side still defaults to the
# CLI, because the roster field is required and must carry something.
#
# Sourced, not executed: it defines functions and returns.

rogue_surface_slug() {
  # Checked first — see the CLAUDE_CODE_IS_COWORK note above. Deliberately ahead
  # of the empty-entrypoint arm too: a Cowork session is a Cowork session whether
  # or not it also exported an entrypoint.
  if [ -n "${CLAUDE_CODE_IS_COWORK:-}" ]; then
    printf 'cowork'
    return 0
  fi
  case "$(printf '%s' "${CLAUDE_CODE_ENTRYPOINT:-}" | tr '[:upper:]' '[:lower:]')" in
    '')        ;;
    *cowork*)  printf 'cowork' ;;
    *desktop*) printf 'desktop' ;;
    *)         printf 'cli' ;;
  esac
  return 0
}

# The roster's `agent` / the x-rogue-agent header. A stable snake_case id, NOT a
# display label — see the header note. Empty slug (no entrypoint) still answers
# claude_code, because the roster field is required and must carry something.
rogue_surface_agent_id() {
  case "$(rogue_surface_slug)" in
    cowork)  printf 'claude_cowork' ;;
    desktop) printf 'claude_code_desktop' ;;
    *)       printf 'claude_code' ;;
  esac
  return 0
}

rogue_surface_label() {
  case "$(rogue_surface_slug)" in
    cowork)  printf 'Claude Cowork' ;;
    desktop) printf 'Claude Code - Desktop' ;;
    *)       printf 'Claude Code - CLI' ;;
  esac
  return 0
}
