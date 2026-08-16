#!/usr/bin/env bash
# Sourceable. Resolves the three values that identify THIS install to the fleet
# roster, alongside the actor from actor.sh:
#
#   ROGUE_INSTALL_HOST     hostname
#   ROGUE_INSTALL_VERSION  plugin version from the manifest ("unknown" if unreadable)
#   ROGUE_INSTALL_AGENT    surface, stored as the roster's `agent`
#
# heartbeat.sh sends them in its /hooks/status body; hook.sh sends the same three
# as x-rogue-host / x-rogue-version / x-rogue-agent on EVERY event. That second
# path is what keeps the roster row fresh between session starts, which is the
# only time the heartbeat fires. Resolved in ONE place because the backend keys
# the row on host + actor + family + agent: any disagreement between the two
# senders is a duplicate row for one install.
#
# Deliberately NOT named ROGUE_PLUGIN_VERSION: install.sh already uses that for
# the release tag to download.

ROGUE_INSTALL_HOST="$(hostname 2>/dev/null)"
[ -n "$ROGUE_INSTALL_HOST" ] || ROGUE_INSTALL_HOST="unknown"

# Version from the manifest WITHOUT python3 (the /usr/bin/python3 stub fails
# silently on a fresh macOS). grep/sed are always present.
ROGUE_INSTALL_VERSION="unknown"
_rogue_pj="${PLUGIN_ROOT:-}/.codex-plugin/plugin.json"
if [ -r "$_rogue_pj" ]; then
  _rogue_v=$(grep -oE '"version"[[:space:]]*:[[:space:]]*"[0-9][^"]*"' "$_rogue_pj" 2>/dev/null \
               | head -1 | grep -oE '[0-9]+\.[0-9]+\.[0-9]+')
  [ -n "$_rogue_v" ] && ROGUE_INSTALL_VERSION="$_rogue_v"
fi
unset _rogue_pj _rogue_v

# Family is the fixed enum "openai"; the surface (codex_app|codex_cli) is the
# agent. Installer pins ROGUE_CODEX_SURFACE; default codex_cli.
ROGUE_INSTALL_AGENT="${ROGUE_CODEX_SURFACE:-codex_cli}"

export ROGUE_INSTALL_HOST ROGUE_INSTALL_VERSION ROGUE_INSTALL_AGENT
