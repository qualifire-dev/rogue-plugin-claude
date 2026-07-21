#!/usr/bin/env bash
# Rogue presence heartbeat (Google Antigravity plugin). Fired detached from
# the first PreInvocation. POSTs /api/v1/hooks/status so this install shows up
# in the dashboard's Coding Agents roster and the org learns which plugin
# version runs (drives the "outdated" badge). Fire-and-forget: never blocks
# Antigravity, always exits 0.
set -u

# Self-locate the plugin root from $0 (<root>/scripts/heartbeat.sh).
PLUGIN_ROOT="$(CDPATH= cd -- "$(dirname -- "$0")/.." 2>/dev/null && pwd)"
[ -n "$PLUGIN_ROOT" ] || PLUGIN_ROOT="."

# Same env precedence as hook.sh (later wins): bundled → MDM → per-user.
[ -r "${PLUGIN_ROOT}/env" ] && . "${PLUGIN_ROOT}/env"
[ -r /etc/rogue/env ]       && . /etc/rogue/env
[ -r "$HOME/.rogue-env" ]   && . "$HOME/.rogue-env"

# Not configured → no-op (mirrors hook.sh fail-open on missing key).
[ -n "${ROGUE_API_KEY:-}" ] || exit 0

[ -r "${PLUGIN_ROOT}/scripts/actor.sh" ] && . "${PLUGIN_ROOT}/scripts/actor.sh"

# Plugin version from the bundled VERSION file (NOT plugin.json — the
# Antigravity manifest schema is additionalProperties:false with no version
# field, so the version lives in its own file at the plugin root).
VER="unknown"
v="$(head -n1 "${PLUGIN_ROOT}/VERSION" 2>/dev/null | tr -d ' \r\n')"
[ -n "$v" ] && VER="$v"

# Surface inference: heartbeat has no transcriptPath to key off, so infer from
# the environment. Default to the IDE surface; flip to the CLI surface if the
# `agy` binary is on PATH or the CLI's config dir exists.
AGENT="antigravity_ide"
if command -v agy >/dev/null 2>&1 || [ -d "$HOME/.gemini/antigravity-cli" ]; then
  AGENT="antigravity_cli"
fi

# Family is the fixed enum "antigravity"; surface rides the agent field.
HOST=$(hostname 2>/dev/null || echo unknown)
esc() { printf '%s' "$1" | sed -e 's/\\/\\\\/g' -e 's/"/\\"/g'; }
BODY=$(printf '{"agent_family":"antigravity","agent":"%s","version":"%s","host":"%s","actor_email":"%s","actor_name":"%s"}' \
  "$(esc "$AGENT")" "$(esc "$VER")" "$(esc "$HOST")" \
  "$(esc "${ROGUE_ACTOR_EMAIL:-}")" "$(esc "${ROGUE_ACTOR_NAME:-}")")

# Trim a trailing slash so a user-set ROGUE_BASE_URL with one doesn't yield
# "//" in the composed URL (mirrors hook.ps1's .TrimEnd('/')). Guarded for
# unset since this script runs under `set -u`.
ROGUE_BASE_URL="${ROGUE_BASE_URL:-}"
ROGUE_BASE_URL="${ROGUE_BASE_URL%/}"

curl -sS --max-time 10 -X POST \
  "${ROGUE_BASE_URL:-https://api.rogue.security}/api/v1/hooks/status" \
  -H "x-rogue-api-key: $ROGUE_API_KEY" \
  -H "Content-Type: application/json" \
  -d "$BODY" \
  >/dev/null 2>&1 || true

exit 0
