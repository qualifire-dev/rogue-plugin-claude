#!/usr/bin/env bash
# Rogue presence heartbeat (Google Antigravity plugin). Fired detached from
# the first PreInvocation. POSTs /api/v1/hooks/status so this install shows up
# in the dashboard's Coding Agents roster and the org learns which plugin
# version runs (drives the "outdated" badge). Fire-and-forget: never blocks
# Antigravity, always exits 0.
#
# Main-and-functions, like hook.sh: everything below is a function and only
# `main "$@"` runs. The one ordering that matters is the same as the
# dispatcher's — the env files are sourced before anything derived from them.
set -u

PLUGIN_ROOT=""
AGENT=""       # which of the three surfaces this install is reporting for
VER="unknown"  # plugin version, from the bundled VERSION file
HOST="unknown" # hostname; both set by resolve_version via install-id.sh

# Self-locate the plugin root from $0 (<root>/scripts/heartbeat.sh).
locate_plugin_root() {
  PLUGIN_ROOT="$(CDPATH= cd -- "$(dirname -- "$0")/.." 2>/dev/null && pwd)"
  [ -n "$PLUGIN_ROOT" ] || PLUGIN_ROOT="."
}

# Same env precedence as hook.sh (later wins): bundled → MDM → per-user.
load_env() {
  [ -r "${PLUGIN_ROOT}/env" ] && . "${PLUGIN_ROOT}/env"
  [ -r /etc/rogue/env ]       && . /etc/rogue/env
  [ -r "$HOME/.rogue-env" ]   && . "$HOME/.rogue-env"
  # Trim a trailing slash so a user-set ROGUE_BASE_URL with one doesn't yield
  # "//" in the composed URL (mirrors hook.ps1's .TrimEnd('/')). Guarded for
  # unset since this script runs under `set -u`.
  ROGUE_BASE_URL="${ROGUE_BASE_URL:-}"
  ROGUE_BASE_URL="${ROGUE_BASE_URL%/}"
  return 0
}

# Not configured → no-op (mirrors hook.sh fail-open on missing key).
require_api_key() {
  [ -n "${ROGUE_API_KEY:-}" ] || exit 0
}

load_actor() {
  [ -r "${PLUGIN_ROOT}/scripts/actor.sh" ] && . "${PLUGIN_ROOT}/scripts/actor.sh"
  return 0
}

# Host + plugin version, shared with hook.sh so its per-event headers and this
# body describe the same install (same fingerprint, one roster row).
# See install-id.sh.
resolve_version() {
  [ -r "${PLUGIN_ROOT}/scripts/install-id.sh" ] && . "${PLUGIN_ROOT}/scripts/install-id.sh"
  VER="${ROGUE_INSTALL_VERSION:-unknown}"
  HOST="${ROGUE_INSTALL_HOST:-unknown}"
  return 0
}

# Surface: $1 when the caller knows it. hook.sh reads it off the event's
# transcriptPath, which is the only reliable source — three products (the 2.0
# app, the IDE, the `agy` CLI) share one install, so the filesystem
# fallback below cannot tell which one is running and picks the CLI whenever it
# is installed alongside another. Validated, not trusted verbatim: the value ends
# up in a roster row.
resolve_surface() {
  AGENT="${1:-}"
  case "$AGENT" in
    antigravity|antigravity_ide|antigravity_cli) return 0 ;;
  esac
  # No surface passed (a manual run, or an older hook.sh): fall back to the
  # environment. Default to the 2.0 app — the current flagship; flip to the CLI
  # surface if the `agy` binary is on PATH or the CLI's config dir exists.
  AGENT="antigravity"
  if command -v agy >/dev/null 2>&1 || [ -d "$HOME/.gemini/antigravity-cli" ]; then
    AGENT="antigravity_cli"
  fi
}

esc() { printf '%s' "$1" | sed -e 's/\\/\\\\/g' -e 's/"/\\"/g'; }

# Family is the fixed enum "antigravity"; surface rides the agent field.
post_heartbeat() {
  _body=$(printf '{"agent_family":"antigravity","agent":"%s","version":"%s","host":"%s","actor_email":"%s","actor_name":"%s"}' \
    "$(esc "$AGENT")" "$(esc "$VER")" "$(esc "$HOST")" \
    "$(esc "${ROGUE_ACTOR_EMAIL:-}")" "$(esc "${ROGUE_ACTOR_NAME:-}")")

  curl -sS --max-time 10 -X POST \
    "${ROGUE_BASE_URL:-https://api.rogue.security}/api/v1/hooks/status" \
    -H "x-rogue-api-key: $ROGUE_API_KEY" \
    -H "Content-Type: application/json" \
    -d "$_body" \
    >/dev/null 2>&1 || true
}

main() {
  locate_plugin_root
  load_env          # sources the env files, then normalises the base URL
  require_api_key   # exits 0 when this install is not configured
  load_actor
  resolve_version
  resolve_surface "${1:-}"
  post_heartbeat
  exit 0
}

main "$@"
