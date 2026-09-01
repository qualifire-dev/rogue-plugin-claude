#!/bin/sh
# Codex's SURFACE — one table, three consumers.
#
#   hook.sh      sends it as the x-rogue-agent header AND stamps it on each log line
#   heartbeat.sh sends it as the roster agent
#
# Codex exposes no app/cli entrypoint variable of its own, so the installer pins
# ROGUE_CODEX_SURFACE per surface and everything reads that one value. Keeping the
# read in one place is what stops a log line and the roster row for the same
# session from naming different surfaces.
#
#   slug       | when
#   -----------|-------------------------------------------------------
#   codex_app  | ROGUE_CODEX_SURFACE=codex_app
#   codex_cli  | ROGUE_CODEX_SURFACE=codex_cli, unset, or ANYTHING ELSE
#
# THE CLOSED LIST IS ENFORCED HERE, and that is the point of the function rather
# than a bare `${ROGUE_CODEX_SURFACE:-codex_cli}`. The variable comes from an env
# file, so its value is whatever someone wrote there: a value with a space or an
# `=` would break the log line's `key=value` shape, and an arbitrary string on a
# line or in a roster row is exactly the kind of uncontrolled content this token
# must never carry. Anything unrecognised is treated as unset.
#
# Sourced, not executed.

codex_surface_slug() {
  case "${ROGUE_CODEX_SURFACE:-}" in
    codex_app) printf 'codex_app' ;;
    *)         printf 'codex_cli' ;;
  esac
  return 0
}
