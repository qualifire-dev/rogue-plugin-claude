#!/usr/bin/env bash
set -euo pipefail

# Rogue Security — credential storage helper (GitHub Copilot CLI plugin).
# Called by the /rogue:setup command and the installer.
# Writes ~/.rogue-env (mode 600) which every plugin hook reads at runtime. The
# file is shared with the Claude/Codex/Cursor/Gemini plugins (same format).
#
# Usage: setup.sh <api-key> <email> <name>
#
# Hooks read credentials from (in order, later wins):
#   1) ${PLUGIN_ROOT}/env   (bundled defaults, for compiled customer plugins)
#   2) /etc/rogue/env       (system-wide, for MDM deployments)
#   3) ~/.rogue-env         (per-user, written by this script)

API_KEY="${1:?Usage: setup.sh <api-key> <email> <name>}"
ACTOR_EMAIL="${2:-}"
ACTOR_NAME="${3:-}"

ENV_FILE="${ROGUE_ENV_FILE:-$HOME/.rogue-env}"

umask 077
: > "$ENV_FILE"
{
  printf '# Managed by the rogue GitHub Copilot CLI plugin. Read by hook subprocesses at runtime.\n'
  printf '# Delete this file to revoke credentials.\n'
  printf 'export ROGUE_API_KEY=%q\n' "$API_KEY"
  printf 'export ROGUE_ACTOR_EMAIL=%q\n' "$ACTOR_EMAIL"
  printf 'export ROGUE_ACTOR_NAME=%q\n' "$ACTOR_NAME"
} >> "$ENV_FILE"
chmod 600 "$ENV_FILE"

echo "OK"
echo "ENV_FILE=$ENV_FILE"
