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

# Whatever could NOT be resolved is recorded here, empty when everything was
# (`host-unresolved`, `manifest-missing:<path>`, `version-unparsed:<path>`).
# Deliberately a variable rather than a log call: this file is sourced by both
# hook.sh and heartbeat.sh, and a sourced lib must not assume its caller has a
# logger. hook.sh logs it per event; the heartbeat discards all output anyway.
#
# Resolution NEVER fails the hook. A degraded value still identifies the install
# well enough to keep the roster fresh, and no liveness bookkeeping is worth
# breaking a developer's session over.
ROGUE_INSTALL_ID_WARN=""

rogue_install_id_warn() {
  ROGUE_INSTALL_ID_WARN="${ROGUE_INSTALL_ID_WARN:+$ROGUE_INSTALL_ID_WARN,}$1"
}

ROGUE_INSTALL_HOST="$(hostname 2>/dev/null)"
if [ -z "$ROGUE_INSTALL_HOST" ]; then
  ROGUE_INSTALL_HOST="unknown"
  rogue_install_id_warn "host-unresolved"
fi

# Version from the manifest WITHOUT python3 (the /usr/bin/python3 stub fails
# silently on a fresh macOS). grep/sed are always present.
ROGUE_INSTALL_VERSION="unknown"
_rogue_pj="${PLUGIN_ROOT:-}/.codex-plugin/plugin.json"
if [ -r "$_rogue_pj" ]; then
  _rogue_v=$(grep -oE '"version"[[:space:]]*:[[:space:]]*"[0-9][^"]*"' "$_rogue_pj" 2>/dev/null \
               | head -1 | grep -oE '[0-9]+\.[0-9]+\.[0-9]+')
  if [ -n "$_rogue_v" ]; then
    ROGUE_INSTALL_VERSION="$_rogue_v"
  else
    # Manifest is there but carries no semver: schema drift, not a bad install.
    rogue_install_id_warn "version-unparsed:$_rogue_pj"
  fi
else
  rogue_install_id_warn "manifest-missing:$_rogue_pj"
fi
unset _rogue_pj _rogue_v

# Family is the fixed enum "openai"; the surface (codex_app|codex_cli) is the
# agent. Installer pins ROGUE_CODEX_SURFACE; default codex_cli.
ROGUE_INSTALL_AGENT="${ROGUE_CODEX_SURFACE:-codex_cli}"

export ROGUE_INSTALL_HOST ROGUE_INSTALL_VERSION ROGUE_INSTALL_AGENT ROGUE_INSTALL_ID_WARN
