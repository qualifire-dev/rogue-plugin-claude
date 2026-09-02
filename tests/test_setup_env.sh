#!/usr/bin/env bash
# tests/test_setup_env.sh — the ~/.rogue-env writers must MERGE, not truncate.
#
# They used to `: > "$ENV_FILE"` and put back only the credential keys, deleting a
# machine's pinned ROGUE_BASE_URL on any /rogue:setup — or unprompted, when
# auto-update re-ran install.sh 24h later. All seven writers, since one machine's
# file is written by whichever agent was set up last.
set -euo pipefail

REPO="$(cd "$(dirname "$0")/.." && pwd)"
SH="${TEST_SH:-sh}"
SANDBOX="$(mktemp -d)"
trap 'rm -rf "$SANDBOX"' EXIT
fails=0

check() { # <label> <expected> <actual>
  if [ "$2" = "$3" ]; then echo "  ok: $1"
  else echo "FAIL: $1 (expected [$2], got [$3])"; fails=$((fails + 1)); fi
}

# Managed keys stale, plus what a machine might have added itself.
seed() { # <env-file>
  cat > "$1" <<'SEED'
# Managed by the rogue Claude plugin. Read by hook subprocesses at runtime.
# Delete this file to revoke credentials.
export ROGUE_API_KEY='stale-key'
export ROGUE_ACTOR_EMAIL='stale@example.com'
export ROGUE_ACTOR_NAME='Stale'
# our self-hosted API
export ROGUE_BASE_URL='http://localhost:8007'
export ROGUE_LOG_DIR='/var/log/rogue'
export ROGUE_HEARTBEAT_MIN_INTERVAL=60
SEED
}

# Read a variable back the way a hook does.
sourced() { # <env-file> <var>
  "$SH" -c '. "$1"; eval "printf %s \"\$$2\""' _ "$1" "$2"
}

count_lines() { grep -c "$2" "$1" || :; }

# ── The shared library under strict POSIX ────────────────────────────────────
# A setup doc may invoke its helper through `sh`, i.e. dash, where the old
# printf %q wrote a corrupt file.
posix_env="$SANDBOX/posix.env"
seed "$posix_env"
"$SH" -c '. "$1"; rogue_write_env_file "$2" ROGUE_API_KEY "posix-key" ROGUE_ACTOR_EMAIL "p@x.io" ROGUE_ACTOR_NAME "P"' \
  _ "$REPO/scripts/shared/env-file.sh" "$posix_env"
check "posix: key replaced"   "posix-key"             "$(sourced "$posix_env" ROGUE_API_KEY)"
check "posix: base url kept"  "http://localhost:8007" "$(sourced "$posix_env" ROGUE_BASE_URL)"

# ── The five setup.sh helpers ────────────────────────────────────────────────
for plugin in rogue codex cursor copilot antigravity; do
  script="$REPO/plugins/$plugin/scripts/setup.sh"
  env_file="$SANDBOX/$plugin.env"
  seed "$env_file"
  ROGUE_ENV_FILE="$env_file" bash "$script" "new-key" "new@example.com" "New Name" >/dev/null

  check "$plugin: api key replaced"       "new-key"                 "$(sourced "$env_file" ROGUE_API_KEY)"
  check "$plugin: actor email replaced"   "new@example.com"         "$(sourced "$env_file" ROGUE_ACTOR_EMAIL)"
  check "$plugin: actor name replaced"    "New Name"                "$(sourced "$env_file" ROGUE_ACTOR_NAME)"
  check "$plugin: base url kept"          "http://localhost:8007"   "$(sourced "$env_file" ROGUE_BASE_URL)"
  check "$plugin: log dir kept"           "/var/log/rogue"          "$(sourced "$env_file" ROGUE_LOG_DIR)"
  check "$plugin: beacon interval kept"   "60"                      "$(sourced "$env_file" ROGUE_HEARTBEAT_MIN_INTERVAL)"
  check "$plugin: user comment kept"      "1"                       "$(count_lines "$env_file" '^# our self-hosted API$')"
  check "$plugin: one api key line"       "1"                       "$(count_lines "$env_file" '^export ROGUE_API_KEY=')"
  # Re-emitted per write; the old one must not accumulate.
  check "$plugin: one header line"        "1"                       "$(count_lines "$env_file" 'Read by hook subprocesses')"
  check "$plugin: mode 600"               "600"                     "$(perl -e 'printf "%o", (stat($ARGV[0]))[2] & 07777' "$env_file")"
done

# Codex also owns the surface key.
codex_env="$SANDBOX/codex-surface.env"
seed "$codex_env"
printf "export ROGUE_CODEX_SURFACE='codex_cli'\n" >> "$codex_env"
ROGUE_ENV_FILE="$codex_env" bash "$REPO/plugins/codex/scripts/setup.sh" \
  "k" "e@x.io" "N" "codex_app" >/dev/null
check "codex: surface replaced"     "codex_app" "$(sourced "$codex_env" ROGUE_CODEX_SURFACE)"
check "codex: one surface line"     "1"         "$(count_lines "$codex_env" '^export ROGUE_CODEX_SURFACE=')"
check "codex: base url kept"        "http://localhost:8007" "$(sourced "$codex_env" ROGUE_BASE_URL)"

# ── Gemini's Node writer ─────────────────────────────────────────────────────
if command -v node >/dev/null 2>&1; then
  gem_env="$SANDBOX/gemini.env"
  seed "$gem_env"
  ROGUE_ENV_FILE="$gem_env" node "$REPO/plugins/gemini/scripts/setup.mjs" \
    "new-key" "new@example.com" "New Name" >/dev/null
  check "gemini: api key replaced"  "new-key"               "$(sourced "$gem_env" ROGUE_API_KEY)"
  check "gemini: base url kept"     "http://localhost:8007" "$(sourced "$gem_env" ROGUE_BASE_URL)"
  check "gemini: one header line"   "1"                     "$(count_lines "$gem_env" 'Read by hook subprocesses')"

  # The writers share one file, so their output must be interchangeable.
  sh_env="$SANDBOX/rogue-compare.env"
  seed "$sh_env"
  ROGUE_ENV_FILE="$sh_env" bash "$REPO/plugins/rogue/scripts/setup.sh" \
    "new-key" "new@example.com" "New Name" >/dev/null
  if cmp -s "$sh_env" "$gem_env"; then echo "  ok: sh and node writers agree byte for byte"
  else echo "FAIL: sh and node writers disagree"; diff "$sh_env" "$gem_env" || :; fails=$((fails + 1)); fi
else
  echo "  skip: node not installed (gemini writer)"
fi

# ── A value with a quote in it must survive the round trip ───────────────────
odd_env="$SANDBOX/odd.env"
seed "$odd_env"
ROGUE_ENV_FILE="$odd_env" bash "$REPO/plugins/rogue/scripts/setup.sh" \
  "key'with'quotes" "o'brien@example.com" "O'Brien" >/dev/null
check "quoted key round-trips"   "key'with'quotes"     "$(sourced "$odd_env" ROGUE_API_KEY)"
check "quoted name round-trips"  "O'Brien"             "$(sourced "$odd_env" ROGUE_ACTOR_NAME)"
check "quoted seed still kept"   "http://localhost:8007" "$(sourced "$odd_env" ROGUE_BASE_URL)"

# ── A first run with no file at all ──────────────────────────────────────────
fresh_env="$SANDBOX/fresh/nested.env"
ROGUE_ENV_FILE="$fresh_env" bash "$REPO/plugins/rogue/scripts/setup.sh" \
  "k" "e@x.io" "N" >/dev/null
check "fresh file written"   "k"   "$(sourced "$fresh_env" ROGUE_API_KEY)"
check "fresh file mode 600"  "600" "$(perl -e 'printf "%o", (stat($ARGV[0]))[2] & 07777' "$fresh_env")"

# ── install.sh ───────────────────────────────────────────────────────────────
# Sourced through its ROGUE_INSTALL_LIB_ONLY seam: no install, just the writer.
inst_env="$SANDBOX/install.env"
seed "$inst_env"
ROGUE_INSTALL_LIB_ONLY=1 ENV_FILE="$inst_env" bash -c '
  . "$1"
  ENV_FILE="$2"
  ROGUE_API_KEY="installer-key"
  ROGUE_ACTOR_EMAIL="i@example.com"
  ROGUE_ACTOR_NAME="Installer"
  ROGUE_BASE_URL="http://localhost:8007"
  write_env_file >/dev/null 2>&1
' _ "$REPO/install.sh" "$inst_env"
check "install.sh: key replaced"      "installer-key"         "$(sourced "$inst_env" ROGUE_API_KEY)"
check "install.sh: base url kept"     "http://localhost:8007" "$(sourced "$inst_env" ROGUE_BASE_URL)"
check "install.sh: one base url line" "1"                     "$(count_lines "$inst_env" '^export ROGUE_BASE_URL=')"
check "install.sh: log dir kept"      "/var/log/rogue"        "$(sourced "$inst_env" ROGUE_LOG_DIR)"
check "install.sh: one header line"   "1"                     "$(count_lines "$inst_env" 'Read by hook subprocesses')"

# The installer inlines its own quoting, so it needs its own case.
quo_env="$SANDBOX/install-quote.env"
seed "$quo_env"
q_key="key'quote"
q_name="O'Brien"
ROGUE_INSTALL_LIB_ONLY=1 Q_KEY="$q_key" Q_NAME="$q_name" bash -c '
  . "$1"
  ENV_FILE="$2"
  ROGUE_API_KEY="$Q_KEY"
  ROGUE_ACTOR_EMAIL="e@x.io"
  ROGUE_ACTOR_NAME="$Q_NAME"
  write_env_file >/dev/null 2>&1
' _ "$REPO/install.sh" "$quo_env"
check "install.sh: quoted key round-trips"  "$q_key"  "$(sourced "$quo_env" ROGUE_API_KEY)"
check "install.sh: quoted name round-trips" "$q_name" "$(sourced "$quo_env" ROGUE_ACTOR_NAME)"

# The reported bug end to end: what auto-update runs 24h after anyone looked.
auto_env="$SANDBOX/auto-update.env"
seed "$auto_env"
ROGUE_INSTALL_LIB_ONLY=1 bash -c '
  . "$1"
  ENV_FILE="$2"
  NON_INTERACTIVE=1
  ROGUE_API_KEY="rotated-key"
  configure_credentials >/dev/null 2>&1
' _ "$REPO/install.sh" "$auto_env"
check "auto-update path: key rotated"  "rotated-key"           "$(sourced "$auto_env" ROGUE_API_KEY)"
check "auto-update path: base url kept" "http://localhost:8007" "$(sourced "$auto_env" ROGUE_BASE_URL)"
check "auto-update path: log dir kept"  "/var/log/rogue"        "$(sourced "$auto_env" ROGUE_LOG_DIR)"

# An explicit --base-url outranks the one already on disk.
flag_env="$SANDBOX/base-url-flag.env"
seed "$flag_env"
ROGUE_INSTALL_LIB_ONLY=1 bash -c '
  . "$1"
  ENV_FILE="$2"
  NON_INTERACTIVE=1
  ROGUE_API_KEY="k"
  ROGUE_BASE_URL="https://staging.example.com"
  configure_credentials >/dev/null 2>&1
' _ "$REPO/install.sh" "$flag_env"
check "explicit base url wins" "https://staging.example.com" "$(sourced "$flag_env" ROGUE_BASE_URL)"

# Writing the default would bake today's hostname in.
def_env="$SANDBOX/install-default.env"
ROGUE_INSTALL_LIB_ONLY=1 bash -c '
  . "$1"
  ENV_FILE="$2"
  ROGUE_API_KEY="k"; ROGUE_ACTOR_EMAIL="e@x.io"; ROGUE_ACTOR_NAME="N"
  write_env_file >/dev/null 2>&1
' _ "$REPO/install.sh" "$def_env"
check "install.sh: default base url not written" "0" "$(count_lines "$def_env" '^export ROGUE_BASE_URL=')"

[ "$fails" = 0 ] || { echo "$fails check(s) failed"; exit 1; }
echo "all env-file writer checks passed"
