#!/usr/bin/env bash
# Rogue Security desktop alert.
# Shows a modal alert that bypasses Do Not Disturb / Focus modes.
#
# Usage:
#   security-alert.sh "Title" "Message body" [severity]
#   echo "Message body" | security-alert.sh "Title" - [severity]
#
# Severity:
#   critical (default) — red stop icon, critical-style alert, Sosumi sound
#   warning            — yellow caution icon, Funk sound
#   info               — note icon, Tink sound
#
# Env overrides:
#   ROGUE_ALERT_ICON   — path to a custom .icns/.png to use as the dialog icon
#   ROGUE_ALERT_SOUND  — set to 1 to enable default sound, or path to an audio file
#                       (silent by default)

set -u

TITLE="${1:-Rogue Security}"
MSG_ARG="${2:-}"
SEVERITY="${3:-critical}"

if [ "$MSG_ARG" = "-" ] || [ -z "$MSG_ARG" ]; then
  MSG="$(cat)"
else
  MSG="$MSG_ARG"
fi

# API-relayed block reasons carry literal "\n" (backslash + n, straight out of
# the JSON string) rather than real newlines. Convert them so the modal shows
# line breaks instead of printing "\n\n". Script runs under bash, so this
# parameter expansion is safe.
MSG="${MSG//\\n/$'\n'}"

# Pick icon + sound by severity.
case "$SEVERITY" in
  warning)
    AS_ICON="caution"
    AS_KIND="as warning"
    DEFAULT_SOUND="/System/Library/Sounds/Funk.aiff"
    ;;
  info)
    AS_ICON="note"
    AS_KIND=""
    DEFAULT_SOUND="/System/Library/Sounds/Tink.aiff"
    ;;
  *)
    AS_ICON="stop"
    AS_KIND="as critical"
    DEFAULT_SOUND="/System/Library/Sounds/Sosumi.aiff"
    ;;
esac

# Silent by default. Set ROGUE_ALERT_SOUND=1 for the severity default sound,
# or ROGUE_ALERT_SOUND=/path/to/file.aiff for a custom one.
case "${ROGUE_ALERT_SOUND:-}" in
  ""|"0") SOUND="" ;;
  "1")    SOUND="$DEFAULT_SOUND" ;;
  *)      SOUND="$ROGUE_ALERT_SOUND" ;;
esac

# Custom icon overrides the built-in stop/caution/note.
ICON_CLAUSE=""
ICON_PATH="${ROGUE_ALERT_ICON:-}"
if [ -z "$ICON_PATH" ]; then
  # Auto-detect bundled icon if present.
  SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
  for candidate in \
    "$SCRIPT_DIR/../assets/rogue.icns" \
    "$SCRIPT_DIR/../assets/rogue.png"; do
    if [ -r "$candidate" ]; then
      ICON_PATH="$candidate"
      break
    fi
  done
fi

# AppleScript escape: backslashes and double quotes.
esc() {
  printf '%s' "$1" | sed -e 's/\\/\\\\/g' -e 's/"/\\"/g'
}

T_ESC="$(esc "$TITLE")"
M_ESC="$(esc "$MSG")"

if command -v osascript >/dev/null 2>&1; then
  # Play sound in background so the dialog isn't blocked (only if opted in).
  if [ -n "$SOUND" ] && [ -r "$SOUND" ] && command -v afplay >/dev/null 2>&1; then
    ( afplay "$SOUND" >/dev/null 2>&1 & )
  fi

  if [ -n "$ICON_PATH" ] && [ -r "$ICON_PATH" ]; then
    I_ESC="$(esc "$ICON_PATH")"
    # `display dialog` supports custom icon files via POSIX file path.
    osascript <<EOF >/dev/null 2>&1 || true
tell application "System Events"
  activate
  display dialog "$M_ESC" with title "$T_ESC" buttons {"Dismiss"} default button "Dismiss" with icon (POSIX file "$I_ESC") giving up after 30
end tell
EOF
  else
    # `display alert ... as critical` is the most attention-grabbing built-in.
    osascript <<EOF >/dev/null 2>&1 || true
tell application "System Events"
  activate
  display alert "$T_ESC" message "$M_ESC" $AS_KIND buttons {"Dismiss"} default button "Dismiss" giving up after 30
end tell
EOF
  fi
  exit 0
fi

# Linux fallback.
if command -v notify-send >/dev/null 2>&1; then
  URGENCY="critical"
  [ "$SEVERITY" = "warning" ] && URGENCY="normal"
  [ "$SEVERITY" = "info" ] && URGENCY="low"
  notify-send -u "$URGENCY" "$TITLE" "$MSG" >/dev/null 2>&1 || true
  exit 0
fi

# Last-resort: stderr.
printf '[%s] %s: %s\n' "$SEVERITY" "$TITLE" "$MSG" >&2
