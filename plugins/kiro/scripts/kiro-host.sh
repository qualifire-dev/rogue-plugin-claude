#!/usr/bin/env bash
# Sourceable. Resolves what the Kiro HOST itself reports about this install,
# beside the plugin's own identity from install-id.sh:
#
#   ROGUE_KIRO_VERSION        the Kiro build the surface runs under ("unknown"
#                             when unreadable). The CLI and Crew (which drives
#                             kiro-cli) from `kiro-cli --version`; the IDE from
#                             the app bundle, since the IDE has no CLI.
#   ROGUE_KIRO_DEFAULT_AGENT  the CLI's `chat.defaultAgent`, empty when none is
#                             set or the surface is not the CLI. On the 2.x
#                             engine only agents carrying the Rogue hooks are
#                             covered (ADR 0001), so a default that moved away
#                             from `rogue` is a machine the roster should show
#                             as uncovered.
#
# The caller sets SURFACE before sourcing, as for install-id.sh. heartbeat.sh
# sends both values in its /hooks/status body and status.sh prints them.
# Resolution never fails the caller: every probe is best-effort and quiet.
#
# ROGUE_KIRO_APP overrides the IDE bundle path (default /Applications/Kiro.app)
# so a test never reads the developer's real install.

_rogue_semver() { grep -oE '[0-9]+\.[0-9]+\.[0-9]+' 2>/dev/null | head -n1; }

rogue_kiro_cli_version() {
  command -v kiro-cli >/dev/null 2>&1 || return 0
  kiro-cli --version 2>/dev/null </dev/null | _rogue_semver
}

# `defaults` reads a binary plist too, which is what a shipped bundle carries;
# the grep is the Linux path and the fallback when `defaults` is absent.
rogue_kiro_ide_version() {
  _plist="${ROGUE_KIRO_APP:-/Applications/Kiro.app}/Contents/Info.plist"
  [ -r "$_plist" ] || return 0
  _v=$(defaults read "${_plist%.plist}" CFBundleShortVersionString 2>/dev/null </dev/null | _rogue_semver)
  [ -n "$_v" ] || _v=$(tr -d '\n' < "$_plist" 2>/dev/null \
    | sed -nE 's/.*<key>CFBundleShortVersionString<\/key>[[:space:]]*<string>([^<]*)<\/string>.*/\1/p' | _rogue_semver)
  printf '%s' "$_v"
}

# The real CLI prints the value quoted ("rogue"); both forms are stripped.
rogue_kiro_default_agent() {
  command -v kiro-cli >/dev/null 2>&1 || return 0
  kiro-cli settings chat.defaultAgent 2>/dev/null </dev/null | head -n1 \
    | tr -d '\r' | sed -e 's/^[[:space:]]*"\{0,1\}//' -e 's/"\{0,1\}[[:space:]]*$//'
}

case "${SURFACE:-kiro_cli}" in
  kiro_ide) ROGUE_KIRO_VERSION=$(rogue_kiro_ide_version); ROGUE_KIRO_DEFAULT_AGENT="" ;;
  kiro_cli) ROGUE_KIRO_VERSION=$(rogue_kiro_cli_version); ROGUE_KIRO_DEFAULT_AGENT=$(rogue_kiro_default_agent) ;;
  *)        ROGUE_KIRO_VERSION=$(rogue_kiro_cli_version); ROGUE_KIRO_DEFAULT_AGENT="" ;;
esac
[ -n "$ROGUE_KIRO_VERSION" ] || ROGUE_KIRO_VERSION="unknown"

export ROGUE_KIRO_VERSION ROGUE_KIRO_DEFAULT_AGENT
