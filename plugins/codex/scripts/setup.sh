#!/usr/bin/env bash
set -euo pipefail

# Rogue Security — credential storage helper (Codex plugin)
# Called by /rogue:setup command and the installer.
# Writes ~/.rogue-env (mode 600) which is sourced by every plugin hook at runtime.
#
# Usage: setup.sh <api-key> <email> <name> [surface]
#   surface: codex_app | codex_cli (default codex_cli) — persisted as
#            ROGUE_CODEX_SURFACE so the bridge sends the right x-rogue-agent.
#
# Hooks read credentials from (in order, later wins):
#   1) /etc/rogue/env       (system-wide, for MDM deployments)
#   2) ~/.rogue-env         (per-user, written by this script)

API_KEY="${1:?Usage: setup.sh <api-key> <email> <name> [surface]}"
ACTOR_EMAIL="${2:-}"
ACTOR_NAME="${3:-}"
SURFACE="${4:-codex_cli}"

ENV_FILE="${ROGUE_ENV_FILE:-$HOME/.rogue-env}"

# Merges: replaces these keys, keeps a pinned ROGUE_BASE_URL and friends.
. "$(dirname "$0")/env-file.sh"
rogue_write_env_file "$ENV_FILE" \
  ROGUE_API_KEY "$API_KEY" \
  ROGUE_ACTOR_EMAIL "$ACTOR_EMAIL" \
  ROGUE_ACTOR_NAME "$ACTOR_NAME" \
  ROGUE_CODEX_SURFACE "$SURFACE"

echo "OK"
echo "ENV_FILE=$ENV_FILE"
