#!/usr/bin/env bash
# Sourceable. Resolves ROGUE_ACTOR_{EMAIL,NAME} from a cascade.
# Cascade: env → git --global → hostname/whoami.

[ -n "${ROGUE_ACTOR_EMAIL:-}" ] || ROGUE_ACTOR_EMAIL="$(git config --global user.email 2>/dev/null)"
[ -n "${ROGUE_ACTOR_NAME:-}" ]  || ROGUE_ACTOR_NAME="$(git config --global user.name 2>/dev/null)"
[ -n "${ROGUE_ACTOR_EMAIL:-}" ] || ROGUE_ACTOR_EMAIL="$(hostname 2>/dev/null)"
[ -n "${ROGUE_ACTOR_NAME:-}" ]  || ROGUE_ACTOR_NAME="$(whoami 2>/dev/null)"

export ROGUE_ACTOR_EMAIL ROGUE_ACTOR_NAME
