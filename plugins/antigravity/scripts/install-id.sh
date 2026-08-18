#!/usr/bin/env bash
# Sourceable. Resolves the host and plugin version that identify THIS install to
# the fleet roster, alongside the actor from actor.sh:
#
#   ROGUE_INSTALL_HOST     hostname
#   ROGUE_INSTALL_VERSION  bundled VERSION file ("unknown" if unreadable)
#
# heartbeat.sh sends them in its /hooks/status body; hook.sh sends the same two
# as x-rogue-host / x-rogue-version on EVERY event. That second path is what
# keeps the roster row fresh between session starts, which is the only time the
# heartbeat fires. Resolved in ONE place because the backend keys the row on
# host + actor + family + agent: any disagreement between the two senders is a
# duplicate row for one install.
#
# The third key part, the surface (`agent`), is deliberately NOT resolved here:
# three products share this one install and only the event's transcriptPath says
# which one is running, so each caller passes its own (see surface_from_transcript
# in hook.sh, resolve_surface in heartbeat.sh).
#
# Deliberately NOT named ROGUE_PLUGIN_VERSION: install.sh already uses that for
# the release tag to download.

# Whatever could NOT be resolved is recorded here, empty when everything was
# (`host-unresolved`, `version-file-unreadable:<path>`). Deliberately a variable
# rather than a log call: this file is sourced by both hook.sh and heartbeat.sh,
# and a sourced lib must not assume its caller has a logger. hook.sh logs it per
# event; the heartbeat discards all output anyway.
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

# Version from the bundled VERSION file (NOT plugin.json — the Antigravity
# manifest schema is additionalProperties:false with no version field, so the
# version lives in its own file at the plugin root).
ROGUE_INSTALL_VERSION="$(head -n1 "${PLUGIN_ROOT:-}/VERSION" 2>/dev/null | tr -d ' \r\n')"
if [ -z "$ROGUE_INSTALL_VERSION" ]; then
  ROGUE_INSTALL_VERSION="unknown"
  rogue_install_id_warn "version-file-unreadable:${PLUGIN_ROOT:-}/VERSION"
fi

export ROGUE_INSTALL_HOST ROGUE_INSTALL_VERSION ROGUE_INSTALL_ID_WARN
