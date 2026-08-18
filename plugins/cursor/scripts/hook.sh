#!/usr/bin/env sh
# Rogue Security hook dispatcher for Cursor — POSIX sh + curl implementation.
#
# Cross-platform sibling of hook.ps1. hooks.json fires BOTH an `sh` and a
# PowerShell entry for every event; exactly one does real work per machine:
#
#   • macOS / Linux / WSL         → this script runs (curl POST).
#   • native Windows + Git Bash   → this script STANDS DOWN (uname is MINGW/
#                                   MSYS/CYGWIN) so hook.ps1 owns Windows.
#   • native Windows, no Git Bash → `sh` is not found → the entry fails to
#                                   spawn (clean fail-open, no output); ps1 runs.
#
# Invoked via `sh`, NOT `bash`, on purpose: on Windows `bash` resolves to the
# WSL launcher stub (System32\bash.exe), which prints a UTF-16 "no installed
# distributions" notice that breaks Cursor's JSON parse of the hook output.
# There is no `sh.exe` stub, so `sh` cleanly "command not found"s on a bash-less
# Windows box. This script is kept POSIX-clean (tested under dash) as a result.
#
# The Git Bash stand-down matters because Git Bash's `~` maps to the Windows
# user profile — the SAME dir hook.ps1 reads — so without it both would POST.
#
# Pass-through: read the Cursor event payload from stdin, POST it to the Rogue
# AIDR backend, relay the server's response bytes verbatim. No client policy.
# The ONE exception is the file pre-image (see `augment_with_pre_image`), which
# adds a field the payload cannot express and never removes or rewrites one.
#
# Fail-open everywhere: missing API key, missing curl, network error, non-200,
# empty body all yield `{}` on stdout, exit 0. Cursor
# must never block because Rogue infrastructure is unavailable.
#
# Credential resolution (later file wins; process env wins over all):
#   1. ${CURSOR_PLUGIN_ROOT}/env   (baked into a compiled customer plugin)
#   2. /etc/rogue/env              (MDM-provisioned)
#   3. ~/.rogue-env                (user / installer-written)

event="${1:-}"

emit() {
  # Relay the server response to Cursor verbatim. We deliberately do NOT validate
  # the JSON: a 200 from the Rogue API is always valid JSON, and if a malformed
  # body ever slips through, Cursor ignores it AND logs the raw output — which is
  # exactly what we want for debugging. Validating here would only let us swallow
  # that signal (turning it into `{}`) for no gain. Empty body -> `{}`.
  data="$1"
  trimmed="${data#"${data%%[![:space:]]*}"}"   # strip leading whitespace
  [ -z "$trimmed" ] && { printf '{}'; return; }
  printf '%s' "$data"
}

# Diagnostics to stderr when ROGUE_DEBUG is set (Cursor logs stderr separately).
dbg() { [ -n "${ROGUE_DEBUG:-}" ] && printf '[rogue] %s\n' "$*" >&2; return 0; }

# Abnormal-but-survivable conditions, NOT gated on ROGUE_DEBUG: this dispatcher
# keeps no log file (unlike the claude/codex/copilot/antigravity ones), so a
# debug-gated message would mean nobody ever learns the install is reporting
# itself imprecisely. stderr only — stdout is the hook's JSON channel, and Cursor
# captures stderr separately.
warn() { printf '[rogue] warn: %s\n' "$*" >&2; return 0; }

# ── Git Bash stand-down: let hook.ps1 own native Windows ───────────────────
case "$(uname -s 2>/dev/null)" in
  MINGW*|MSYS*|CYGWIN*) dbg "Git Bash (uname) -> stand down"; printf '{}'; exit 0 ;;
esac

[ -n "$event" ] || { printf '{}'; exit 0; }
dbg "event=$event"

# ── credential resolution (later file wins; process env wins over all) ─────
_penv_ROGUE_API_KEY="${ROGUE_API_KEY:-}"
_penv_ROGUE_ACTOR_EMAIL="${ROGUE_ACTOR_EMAIL:-}"
_penv_ROGUE_ACTOR_NAME="${ROGUE_ACTOR_NAME:-}"
_penv_ROGUE_BASE_URL="${ROGUE_BASE_URL:-}"

PLUGIN_ROOT="${CURSOR_PLUGIN_ROOT:-}"
if [ -z "$PLUGIN_ROOT" ]; then
  PLUGIN_ROOT="$(cd "$(dirname "$0")/.." 2>/dev/null && pwd)" || PLUGIN_ROOT=""
fi

# Env files are bash-quoted (`export KEY=value`, written via printf %q), so
# sourcing them is correct.
for _f in "$PLUGIN_ROOT/env" /etc/rogue/env "$HOME/.rogue-env"; do
  if [ -n "$_f" ] && [ -r "$_f" ]; then dbg "cred file found: $_f"; . "$_f" 2>/dev/null
  else dbg "cred file absent: $_f"; fi
done

# process env wins over file values
[ -n "$_penv_ROGUE_API_KEY" ]     && ROGUE_API_KEY="$_penv_ROGUE_API_KEY"
[ -n "$_penv_ROGUE_ACTOR_EMAIL" ] && ROGUE_ACTOR_EMAIL="$_penv_ROGUE_ACTOR_EMAIL"
[ -n "$_penv_ROGUE_ACTOR_NAME" ]  && ROGUE_ACTOR_NAME="$_penv_ROGUE_ACTOR_NAME"
[ -n "$_penv_ROGUE_BASE_URL" ]    && ROGUE_BASE_URL="$_penv_ROGUE_BASE_URL"

API_KEY="${ROGUE_API_KEY:-}"
if [ -z "$API_KEY" ]; then
  dbg "no API key after cred resolution -> fail-open"
  if [ "$event" = "sessionStart" ]; then
    printf '%s' '{"additional_context": "Rogue Security plugin is installed but not configured. Run /rogue:setup to connect your API key."}'
  else
    printf '{}'
  fi
  exit 0
fi

BASE_URL="${ROGUE_BASE_URL:-https://api.rogue.security}"
BASE_URL="${BASE_URL%/}"
dbg "apiKey present (tail $(printf '%s' "$API_KEY" | tail -c 4 2>/dev/null)) baseUrl=$BASE_URL"

# ── actor resolution: explicit creds → git config → whoami/hostname ────────
_git_cfg() { git config --global "$1" 2>/dev/null; }

actor_name="${ROGUE_ACTOR_NAME:-}"
[ -n "$actor_name" ] || actor_name="$(_git_cfg user.name)"
[ -n "$actor_name" ] || actor_name="${USER:-${USERNAME:-$(whoami 2>/dev/null)}}"

actor_email="${ROGUE_ACTOR_EMAIL:-}"
[ -n "$actor_email" ] || actor_email="$(_git_cfg user.email)"
if [ -z "$actor_email" ]; then
  _u="${USER:-${USERNAME:-$(whoami 2>/dev/null)}}"
  _h="$(hostname 2>/dev/null)"
  if [ -n "$_u" ] && [ -n "$_h" ]; then actor_email="$_u@$_h"
  else actor_email="${_u:-$_h}"; fi
fi

# ── install identity: host + plugin version ────────────────────────────────
# The fleet roster keys an install on host + actor + family + agent, and until
# now only the heartbeat below ever sent those — once, at session start. A
# session still working a day later therefore aged out as disconnected. Sending
# the same values as headers on EVERY event lets the backend refresh this exact
# row from ordinary hook traffic. They must match the heartbeat body's values
# byte for byte, or the two writers create two rows for one install.
#
# Neither lookup can fail the hook: a degraded value still identifies the install
# well enough to keep the roster fresh, and no liveness bookkeeping is worth
# breaking a session over. Both warn, because "unknown" in the roster is a real
# symptom worth chasing.
host="$(hostname 2>/dev/null)" || host=unknown
if [ -z "$host" ]; then
  host=unknown
  warn "hostname unresolved; reporting host=unknown to the fleet roster"
fi

# Plugin version from the manifest, without python/jq.
plugin_version="unknown"
_pj="$PLUGIN_ROOT/.cursor-plugin/plugin.json"
if [ -r "$_pj" ]; then
  _v=$(grep -oE '"version"[[:space:]]*:[[:space:]]*"[0-9][^"]*"' "$_pj" 2>/dev/null \
        | head -1 | grep -oE '[0-9]+\.[0-9]+\.[0-9]+')
  if [ -n "$_v" ]; then
    plugin_version="$_v"
  else
    # Manifest is there but carries no semver: schema drift, not a bad install.
    warn "no version in $_pj; reporting version=unknown to the fleet roster"
  fi
else
  warn "plugin manifest not readable at $_pj; reporting version=unknown"
fi

# ── payload from stdin ─────────────────────────────────────────────────────
PAYLOAD="$(cat 2>/dev/null)"
[ -n "$PAYLOAD" ] || PAYLOAD='{}'
# Strip a leading UTF-8 BOM if present. Cursor on Windows prepends one to the
# hook payload (hook.ps1 handles it on the native path); a BOM-prefixed body is
# invalid JSON and the API rejects it with HTTP 400. No-op when absent.
_bom="$(printf '\357\273\277')"
PAYLOAD="${PAYLOAD#"$_bom"}"

# ── File pre-image (preToolUse only) ───────────────────────────────────────
# Cursor's preToolUse carries the FULL post-edit file and NO baseline, so the
# payload alone cannot say which part of the file this edit is responsible for.
# The file on disk still holds the PRE-edit content at this point, so we attach
# it as `rogueFilePreImageB64` and the API can compare the two.
#
# A NON-EXISTENT FILE YIELDS AN EMPTY PRE-IMAGE, AND THAT IS THE CREATE SIGNAL.
# No Cursor payload field distinguishes a create from an overwrite (`old_string`
# is "" for both an insertion into an existing file and a create), so this is the
# only mechanism that gets creates right. Do not add a separate `rogueFileExists`
# flag: two mechanisms for one fact, at double the lockstep cost.
#
# MULTI-HUNK EDITS NEED NO SPECIAL HANDLING, and this is load-bearing: Cursor
# emits one full preToolUse/afterFileEdit/postToolUse cycle PER HUNK, so by hunk
# 2 the file on disk already contains hunk 1 and the pre-image IS the correct
# per-hunk baseline. Never "fix" this into reading the whole turn's pre-state.
#
# Fail-open in every branch — a missing path, an unreadable file, a read error or
# an over-cap file leaves the relayed body byte-identical. Note that an over-cap
# file sends NO pre-image rather than a truncated one: a partial pre-image is
# WORSE than none, because it misrepresents the file's pre-edit state instead of
# admitting we don't know it.
PRE_IMAGE_MAX_BYTES=262144

# Every file the agent writes gets a pre-image, subject to the size cap above.
# The extension list below is the one exclusion: base64 of a PNG or a zip is
# pure payload with no text in it to compare, and binaries are also the files
# most likely to be large. An UNKNOWN extension is treated as text — the cost of
# shipping a binary we failed to recognize is bytes, while the cost of skipping
# a text file is losing the comparison entirely.
#
# COST: for a file write this roughly doubles the request body, since the event
# payload already carries the post-edit content. The size cap bounds the worst
# case; nothing is sent for a file above it.
_is_binary_path() {
  _base=$(printf '%s' "${1##*/}" | tr '[:upper:]' '[:lower:]')
  case "$_base" in
    # images
    *.png|*.jpg|*.jpeg|*.gif|*.bmp|*.tif|*.tiff|*.ico|*.icns|*.webp|*.avif|*.heic|*.psd) return 0 ;;
    # fonts
    *.ttf|*.otf|*.woff|*.woff2|*.eot) return 0 ;;
    # archives and packages
    *.zip|*.tar|*.gz|*.tgz|*.bz2|*.xz|*.zst|*.7z|*.rar|*.jar|*.war|*.ear) return 0 ;;
    *.whl|*.egg|*.nupkg|*.dmg|*.iso|*.pkg|*.deb|*.rpm) return 0 ;;
    # audio and video
    *.mp3|*.wav|*.flac|*.ogg|*.m4a|*.mp4|*.mov|*.avi|*.mkv|*.webm) return 0 ;;
    # compiled artifacts
    *.exe|*.dll|*.so|*.dylib|*.o|*.a|*.lib|*.obj|*.pdb|*.class|*.pyc|*.pyo|*.wasm|*.node|*.bin) return 0 ;;
    # documents and databases
    *.pdf|*.doc|*.docx|*.xls|*.xlsx|*.ppt|*.pptx|*.db|*.sqlite|*.sqlite3|*.mdb) return 0 ;;
  esac
  return 1
}

# One JSON string field: jq when it is on PATH, the text scan only when it is
# not. jq is preferred because it understands nesting and unescaping, both of
# which the scan gets only by luck — `file_path` sits under `tool_input` on a
# tool event, and the scan takes whichever copy appears first. The scan stays
# safe for this narrow use because a `"` inside a JSON string value is always
# backslash-escaped, so `"file_path":"…"` cannot match text that merely appears
# inside the file CONTENT the same payload carries.
#
# $1 body, $2 jq filter, $3 key for the fallback scan.
_json_string_field() {
  _jsf_key="$3"
  if command -v jq >/dev/null 2>&1; then
    if _jsf_val=$(printf '%s' "$1" | jq -r "$2 // empty" 2>/dev/null); then
      printf '%s' "$_jsf_val"
      return
    fi
  fi
  printf '%s' "$1" \
    | grep -o "\"$_jsf_key\"[[:space:]]*:[[:space:]]*\"[^\"]*\"" 2>/dev/null \
    | head -1 \
    | sed -e "s/^\"$_jsf_key\"[[:space:]]*:[[:space:]]*\"//" -e 's/"$//'
}

augment_with_pre_image() {
  _body="$1"
  # Only the file-writing tools have a file to pre-image. A preToolUse for
  # Shell, Read, Grep or an MCP call carries no relevant path, and reading one
  # off such a payload would be a wasted stat at best. `Edit` is listed
  # defensively — Cursor has only ever been observed sending `Write`.
  _tool="$(_json_string_field "$_body" '.tool_name' tool_name)"
  case "$_tool" in Write|Edit) : ;; *) printf '%s' "$_body"; return ;; esac
  _fp="$(_json_string_field "$_body" '.tool_input.file_path // .file_path' file_path)"
  # Absolute paths only. A relative path would resolve against the hook's cwd,
  # and a wrongly-"missing" file reads as a CREATE — the one wrong answer that
  # is worse than no answer, since it claims the whole file is new.
  case "$_fp" in /*) : ;; *) printf '%s' "$_body"; return ;; esac
  # A backslash means the JSON value carried an escape the fallback scan did not
  # unescape. Deliberate divergence from hook.ps1, which DOES unescape `\\` and
  # `\/`: this script only ever runs on POSIX, where a path needing either is
  # pathological, while on Windows every path arrives escaped.
  case "$_fp" in *\\*) printf '%s' "$_body"; return ;; esac
  if _is_binary_path "$_fp"; then printf '%s' "$_body"; return; fi

  if [ -e "$_fp" ]; then
    { [ -f "$_fp" ] && [ -r "$_fp" ]; } || { printf '%s' "$_body"; return; }
    _sz=$(wc -c < "$_fp" 2>/dev/null | tr -d ' ')
    case "$_sz" in ''|*[!0-9]*) printf '%s' "$_body"; return ;; esac
    if [ "$_sz" -gt "$PRE_IMAGE_MAX_BYTES" ]; then
      dbg "pre-image $_sz B over cap -> sending none"
      printf '%s' "$_body"; return
    fi
    if [ "$_sz" -eq 0 ]; then
      _b64=""
    else
      _b64=$(base64 < "$_fp" 2>/dev/null | tr -d '\r\n')
      [ -n "$_b64" ] || { printf '%s' "$_body"; return; }
    fi
  else
    _b64=""   # create
  fi
  dbg "pre-image attached for $_fp (${#_b64} b64 chars)"

  # Same jq-or-string-concat duality as the Copilot dispatcher: jq when it is on
  # PATH, otherwise strip the trailing `}`, append, re-close. base64 contains no
  # JSON-special characters, so the concat is safe.
  if command -v jq >/dev/null 2>&1; then
    _out=$(printf '%s' "$_body" | jq -c --arg b64 "$_b64" \
      '. + {rogueFilePreImageB64:$b64}' 2>/dev/null)
    # Only trust a complete object back; anything else falls through to concat.
    case "$_out" in '{'*'}') printf '%s' "$_out"; return ;; esac
  fi
  # Trim trailing whitespace so the single-'}' strip lands on the real closing
  # brace (mirrors the Copilot dispatcher and hook.ps1's TrimEnd()).
  _trimmed="${_body%"${_body##*[![:space:]]}"}"
  case "$_trimmed" in *'}') : ;; *) printf '%s' "$_body"; return ;; esac
  _pre="${_trimmed%\}}"
  # An empty object needs no separator ({} -> {"rogueFilePreImageB64":…}).
  if [ "$_pre" = "{" ]; then _sep=""; else _sep=","; fi
  printf '%s%s"rogueFilePreImageB64":"%s"}' "$_pre" "$_sep" "$_b64"
}

if [ "$event" = "preToolUse" ]; then
  PAYLOAD="$(augment_with_pre_image "$PAYLOAD")"
fi

# ── POST (fail-open) ───────────────────────────────────────────────────────
command -v curl >/dev/null 2>&1 || { dbg "curl not found -> {}"; printf '{}'; exit 0; }

URL="$BASE_URL/api/v1/hooks/cursor"
dbg "POST $URL actor=$actor_email"
# -f makes curl emit nothing and exit non-zero on HTTP >= 400, giving us
# fail-open on non-200 for free.
RESP="$(printf '%s' "$PAYLOAD" | curl -fsS --max-time 10 -X POST \
  -H 'Content-Type: application/json' \
  -H "x-rogue-api-key: $API_KEY" \
  -H "x-rogue-event: $event" \
  -H "x-rogue-actor-email: $actor_email" \
  -H "x-rogue-actor-name: $actor_name" \
  -H 'x-rogue-source: cursor' \
  -H "x-rogue-host: $host" \
  -H "x-rogue-version: $plugin_version" \
  -H 'x-rogue-agent: cursor' \
  --data-binary @- "$URL" 2>/dev/null)"; _rc=$?
dbg "curl rc=$_rc resp_len=${#RESP}"
[ "$_rc" -eq 0 ] || RESP=""

# ── presence heartbeat (sessionStart only, fire-and-forget) ────────────────
# POSTs /api/v1/hooks/status so this install shows in the dashboard's Coding
# Agents roster (Connected / version / host / user). Pure side-effect: the POST
# runs in a detached double-fork with all fds redirected, so neither the relayed
# response below nor session start ever waits on it, and the response is
# ignored. Creds/actor were already resolved above.
if [ "$event" = "sessionStart" ]; then
  # `agent` is "cursor" (not a display label): the server keys its latest-version
  # lookup (PLUGIN_REPOS) on this value, so the roster can flag outdated installs.
  # host/version come from the shared block above so this body and the per-event
  # headers describe the same install (same fingerprint, one row).
  hb_esc() { printf '%s' "$1" | sed -e 's/\\/\\\\/g' -e 's/"/\\"/g'; }
  HB_BODY=$(printf '{"agent_family":"cursor","agent":"cursor","version":"%s","host":"%s","actor_email":"%s","actor_name":"%s"}' \
    "$(hb_esc "$plugin_version")" "$(hb_esc "$host")" "$(hb_esc "$actor_email")" "$(hb_esc "$actor_name")")
  dbg "heartbeat POST $BASE_URL/api/v1/hooks/status ver=$plugin_version host=$host"
  ( curl -fsS --max-time 10 -X POST \
      -H 'Content-Type: application/json' \
      -H "x-rogue-api-key: $API_KEY" \
      -H 'x-rogue-source: cursor' \
      -d "$HB_BODY" \
      "$BASE_URL/api/v1/hooks/status" \
      </dev/null >/dev/null 2>&1 & )
fi

emit "$RESP"
exit 0
