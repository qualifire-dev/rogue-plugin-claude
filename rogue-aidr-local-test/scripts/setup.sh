#!/usr/bin/env bash
set -euo pipefail

# Rogue Security — credential storage helper
# Called by /rogue:setup command.
# Writes ~/.rogue-env (mode 600) which is sourced by every plugin hook at runtime.
#
# Usage: setup.sh <api-key> <email> <name>
#
# Hooks read credentials from (in order):
#   1) /etc/rogue/env       (system-wide, for MDM deployments)
#   2) ~/.rogue-env         (per-user, written by this script)

API_KEY="${1:?Usage: setup.sh <api-key> <email> <name>}"
ACTOR_EMAIL="${2:-}"
ACTOR_NAME="${3:-}"

ENV_FILE="${ROGUE_ENV_FILE:-$HOME/.rogue-env}"

umask 077
: > "$ENV_FILE"
{
  printf '# Managed by the rogue Claude plugin. Read by hook subprocesses at runtime.\n'
  printf '# Delete this file to revoke credentials.\n'
  printf 'export ROGUE_API_KEY=%q\n' "$API_KEY"
  printf 'export ROGUE_ACTOR_EMAIL=%q\n' "$ACTOR_EMAIL"
  printf 'export ROGUE_ACTOR_NAME=%q\n' "$ACTOR_NAME"
} >> "$ENV_FILE"
chmod 600 "$ENV_FILE"

echo "OK"
echo "ENV_FILE=$ENV_FILE"
