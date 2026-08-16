#!/usr/bin/env bash
# Rogue presence heartbeat. Fired from SessionStart in the background.
#
# POSTs /api/v1/hooks/status so this install shows up in the dashboard's Coding
# Agents roster (Connected / version / host / user) and so the org learns which
# plugin version is running. Pure side-effect: fire-and-forget, never blocks
# Claude Code, never affects allow/deny, and exits 0 on every path.
#
# The roster dedups one row per (host | actor-email | family), so we always
# send a stable x-rogue-host + x-rogue-actor-email.
set -u

# Git Bash stand-down: heartbeat.ps1 owns native Windows (same reason as hook.sh).
case "$(uname -s 2>/dev/null)" in
  MINGW*|MSYS*|CYGWIN*) exit 0 ;;
esac

# Same env precedence as hook.sh (later wins): bundled → MDM → per-user.
[ -r "${CLAUDE_PLUGIN_ROOT:-}/env" ] && . "${CLAUDE_PLUGIN_ROOT}/env"
[ -r /etc/rogue/env ]                && . /etc/rogue/env
[ -r "$HOME/.rogue-env" ]            && . "$HOME/.rogue-env"

# Not configured → no-op (mirrors hook.sh fail-open on missing key).
[ -n "${ROGUE_API_KEY:-}" ] || exit 0

# CLAUDE_CODE_ENTRYPOINT used to `exit 0` right here, ABOVE everything. It now
# guards only the beacon POST below, because this script also ships the hook log
# and those are different questions: the entrypoint decides whether there is a
# *session* to report presence for, while the log on disk is worth uploading
# regardless (a manual support run, or a future Claude build that stops exporting
# the var, would otherwise silently stop shipping logs with no other symptom).
# Moving it is behaviour-neutral for the beacon itself - both are bare `exit 0`
# guards ahead of any side effect, and the beacon still fires exactly when it did.

# Actor identity via the shared cascade (env → git → CLAUDE_CODE_USER_EMAIL → host/whoami).
# actor.sh uses ${CLAUDE_CODE_USER_EMAIL%@*} with no default — that aborts under
# `set -u` on bash >=4.4 when the var is unset, so relax nounset across the source.
set +u
[ -r "${CLAUDE_PLUGIN_ROOT:-}/scripts/actor.sh" ] && . "${CLAUDE_PLUGIN_ROOT}/scripts/actor.sh"
set -u

# Plugin version from the manifest, WITHOUT python3 (the /usr/bin/python3 stub
# fails silently on a fresh macOS — see hook.sh). grep/sed are always present.
VER="unknown"
PJ="${CLAUDE_PLUGIN_ROOT:-}/.claude-plugin/plugin.json"
if [ -r "$PJ" ]; then
  v=$(grep -oE '"version"[[:space:]]*:[[:space:]]*"[0-9][^"]*"' "$PJ" \
        | head -1 | grep -oE '[0-9]+\.[0-9]+\.[0-9]+')
  [ -n "$v" ] && VER="$v"
fi

# Family is the fixed enum value "claude". The surface rides the separate
# x-rogue-agent header (free-form display label), derived from
# CLAUDE_CODE_ENTRYPOINT (the same var hook.sh uses to tell GUI from cli).
# Unknown → CLI.
# One table, in scripts/surface.sh, shared with hook.sh - which stamps the matching
# SLUG on each log line. A `case` copied into both would eventually drift, and a log
# line naming a different surface than the roster row for the same session is worse
# than a line that names none. The literal below is a last-resort guard for a
# damaged install (missing file), not a second copy of the mapping.
if [ -r "${CLAUDE_PLUGIN_ROOT:-}/scripts/surface.sh" ]; then
  . "${CLAUDE_PLUGIN_ROOT}/scripts/surface.sh"
  AGENT=$(rogue_surface_label 2>/dev/null)
fi
[ -n "${AGENT:-}" ] || AGENT="Claude Code - CLI"

# POST /api/v1/hooks/status (GET route is gone). The former x-rogue-agent-*
# headers now ride the JSON body; x-rogue-api-key stays a header. Backslash- and
# quote-escape each value so a name/host with a " or \ can't break the JSON.
HOST=$(hostname 2>/dev/null || echo unknown)
esc() { printf '%s' "$1" | sed -e 's/\\/\\\\/g' -e 's/"/\\"/g'; }
BODY=$(printf '{"agent_family":"claude","agent":"%s","version":"%s","host":"%s","actor_email":"%s","actor_name":"%s"}' \
  "$(esc "$AGENT")" "$(esc "$VER")" "$(esc "$HOST")" \
  "$(esc "${ROGUE_ACTOR_EMAIL:-}")" "$(esc "${ROGUE_ACTOR_NAME:-}")")

# The beacon, and ONLY the beacon, is gated on there being a session (see the note
# where that check used to live).
if [ -n "${CLAUDE_CODE_ENTRYPOINT:-}" ]; then
  curl -sS --max-time 10 -X POST \
    "${ROGUE_BASE_URL:-https://api.rogue.security}/api/v1/hooks/status" \
    -H "x-rogue-api-key: $ROGUE_API_KEY" \
    -H "Content-Type: application/json" \
    -d "$BODY" \
    >/dev/null 2>&1 || true
fi

# ── ship the hook log ──────────────────────────────────────────────────────
# AFTER the heartbeat POST when both run: the beacon creates or refreshes the roster
# row for this install, so this order means it exists before the logs land. It is an
# ordering preference, NOT a prerequisite - the backend resolves-or-creates the log
# source from the identity fields the shipper itself sends - which is why shipping
# is deliberately OUTSIDE the gate above rather than sequenced behind the POST.
#
# This script is ALREADY detached by hooks.json, so the upload delays nothing a user
# sees and needs no second backgrounding; and the shipper's own 15-minute throttle
# means the common case is that it makes no request at all.
#
# The actor is PASSED IN, never re-resolved. The shipper deliberately carries no
# cascade of its own: the plugins' cascades differ (actor.sh ends at `hostname`,
# Cursor's at "$USER@$(hostname)"), so a re-resolve would key the log's source
# row differently from the roster row this script just posted, and the logs would
# attach to nothing. actor.sh exports both vars, so the child would inherit them
# anyway - the explicit prefix states the contract at the call site and also
# covers an install whose actor.sh predates that export.
#
# `-r` guarded so a partial or older install is a no-op rather than an error, and
# `|| true` because this script runs under `set -u` and must exit 0 regardless.
if [ -r "${CLAUDE_PLUGIN_ROOT:-}/scripts/ship-logs.sh" ]; then
  ROGUE_ACTOR_EMAIL="${ROGUE_ACTOR_EMAIL:-}" ROGUE_ACTOR_NAME="${ROGUE_ACTOR_NAME:-}" \
    sh "${CLAUDE_PLUGIN_ROOT}/scripts/ship-logs.sh" \
      "${CLAUDE_PLUGIN_ROOT}" claude "$VER" claude >/dev/null 2>&1 || true
fi

exit 0
