#!/bin/sh
# Claude's SURFACE, derived from CLAUDE_CODE_ENTRYPOINT — one table, two consumers.
#
#   hook.sh      stamps the SLUG on every log line   (surface=cli)
#   heartbeat.sh sends the LABEL as the roster agent  (Claude Code - CLI)
#
# They must never disagree: a log line and the roster row it belongs to would then
# name different surfaces for one session, which is worse than the log saying
# nothing at all. That is the whole reason this mapping lives in its own file
# instead of as a `case` copy-pasted into both scripts. Add a surface HERE.
#
#   slug     | label                 | when
#   ---------|-----------------------|--------------------------------------
#   cowork   | Claude Cowork         | entrypoint contains "cowork"
#   desktop  | Claude Code - Desktop | entrypoint contains "desktop"
#   cli      | Claude Code - CLI     | any other NON-EMPTY entrypoint
#   (none)   | Claude Code - CLI     | entrypoint empty or unset
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
  case "$(printf '%s' "${CLAUDE_CODE_ENTRYPOINT:-}" | tr '[:upper:]' '[:lower:]')" in
    '')        ;;
    *cowork*)  printf 'cowork' ;;
    *desktop*) printf 'desktop' ;;
    *)         printf 'cli' ;;
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
