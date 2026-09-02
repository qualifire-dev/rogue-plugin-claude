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

# An explicit --base-url outranks the one already on disk. Set before sourcing,
# the way the real `ROGUE_BASE_URL=... install.sh` invocation reaches it.
flag_env="$SANDBOX/base-url-flag.env"
seed "$flag_env"
ROGUE_INSTALL_LIB_ONLY=1 ROGUE_BASE_URL="https://staging.example.com" bash -c '
  . "$1"
  ENV_FILE="$2"
  NON_INTERACTIVE=1
  ROGUE_API_KEY="k"
  configure_credentials >/dev/null 2>&1
' _ "$REPO/install.sh" "$flag_env"
check "explicit base url wins" "https://staging.example.com" "$(sourced "$flag_env" ROGUE_BASE_URL)"

# ...and an explicit SaaS URL must be able to clear a stale custom one. The
# default is never written, so "cleared" means the key is gone entirely.
back_env="$SANDBOX/base-url-back-to-saas.env"
seed "$back_env"
ROGUE_INSTALL_LIB_ONLY=1 ROGUE_BASE_URL="https://api.rogue.security" bash -c '
  . "$1"
  ENV_FILE="$2"
  NON_INTERACTIVE=1
  ROGUE_API_KEY="k"
  configure_credentials >/dev/null 2>&1
' _ "$REPO/install.sh" "$back_env"
check "explicit default clears stale custom url" "0" "$(count_lines "$back_env" '^export ROGUE_BASE_URL=')"
check "explicit default keeps other settings"    "/var/log/rogue" "$(sourced "$back_env" ROGUE_LOG_DIR)"

# The --base-url flag is the same signal as the env var.
argv_env="$SANDBOX/base-url-argv.env"
seed "$argv_env"
ROGUE_INSTALL_LIB_ONLY=1 bash -c '
  . "$1"
  ENV_FILE="$2"
  NON_INTERACTIVE=1
  ROGUE_API_KEY="k"
  parse_args --base-url https://api.rogue.security
  configure_credentials >/dev/null 2>&1
' _ "$REPO/install.sh" "$argv_env"
check "--base-url default clears stale custom url" "0" "$(count_lines "$argv_env" '^export ROGUE_BASE_URL=')"

# With no base URL named at all, the on-disk one stays put.
keep_env="$SANDBOX/base-url-untouched.env"
seed "$keep_env"
ROGUE_INSTALL_LIB_ONLY=1 bash -c '
  . "$1"
  ENV_FILE="$2"
  NON_INTERACTIVE=1
  ROGUE_API_KEY="k"
  configure_credentials >/dev/null 2>&1
' _ "$REPO/install.sh" "$keep_env"
check "silent run keeps on-disk base url" "http://localhost:8007" "$(sourced "$keep_env" ROGUE_BASE_URL)"

# ── Nothing left to preserve is not a failure ────────────────────────────────
# The filter greps everything away and exits 1; under `set -e` in a sourcing
# script that must not abort the write.
only_env="$SANDBOX/only-managed.env"
cat > "$only_env" <<'ONLY'
# Managed by the Rogue plugins. Read by hook subprocesses at runtime.
# Delete this file to revoke credentials.
export ROGUE_API_KEY='stale-key'
export ROGUE_ACTOR_EMAIL='stale@example.com'
export ROGUE_ACTOR_NAME='Stale'
ONLY
set +e
"$SH" -ec '. "$1"; rogue_write_env_file "$2" ROGUE_API_KEY "k" ROGUE_ACTOR_EMAIL "e@x.io" ROGUE_ACTOR_NAME "N"' \
  _ "$REPO/scripts/shared/env-file.sh" "$only_env"
only_rc=$?
set -e
check "empty preserve set succeeds"  "0" "$only_rc"
check "empty preserve set rewrites"  "k" "$(sourced "$only_env" ROGUE_API_KEY)"
check "empty preserve set one header" "1" "$(count_lines "$only_env" 'Read by hook subprocesses')"

# ── A failed write must leave the old file alone ─────────────────────────────
# The temp file lands beside the target, so a read-only directory is what a full
# disk looks like from here: the writer must fail rather than mv a partial file
# over a credential file that was fine.
ro_dir="$SANDBOX/readonly"
mkdir -p "$ro_dir"
ro_env="$ro_dir/rogue.env"
seed "$ro_env"
before="$(cat "$ro_env")"
chmod 500 "$ro_dir"
if : 2>/dev/null > "$ro_dir/.probe"; then
  # root ignores the mode bits, so there is no failure to observe.
  rm -f "$ro_dir/.probe"
  chmod 700 "$ro_dir"
  echo "  skip: directory is writable anyway (running as root?)"
else
set +e
"$SH" -c '. "$1"; rogue_write_env_file "$2" ROGUE_API_KEY "should-not-land" ROGUE_ACTOR_EMAIL "x@y.z" ROGUE_ACTOR_NAME "X"' \
  _ "$REPO/scripts/shared/env-file.sh" "$ro_env" >/dev/null 2>&1
ro_rc=$?
set -e
chmod 700 "$ro_dir"
check "failed write reports failure"   "1"        "$ro_rc"
check "failed write keeps the old file" "$before" "$(cat "$ro_env")"
check "failed write leaves no temp"     "0"       "$(find "$ro_dir" -name '*.rogue-tmp.*' | wc -l | tr -d ' ')"
fi

# ── Non-ASCII survives a merge ──────────────────────────────────────────────
# sh has no character encoding to get wrong - it moves bytes - so this is the
# byte-level reference the PowerShell twin is checked against, where the same
# case is a real hazard (5.1 decodes a BOM-less file as the ANSI code page).
u8_env="$SANDBOX/nonascii.env"
cat > "$u8_env" <<'U8'
export ROGUE_API_KEY='stale-key'
export ROGUE_LOG_DIR='/var/log/café'
U8
for pass in 1 2; do
  "$SH" -c '. "$1"; rogue_write_env_file "$2" ROGUE_API_KEY "new-key" ROGUE_ACTOR_EMAIL "e@x.io" ROGUE_ACTOR_NAME "José Müller"' \
    _ "$REPO/scripts/shared/env-file.sh" "$u8_env"
  check "non-ASCII actor name round-trips (pass $pass)" "José Müller" "$(sourced "$u8_env" ROGUE_ACTOR_NAME)"
  check "non-ASCII preserved line intact (pass $pass)"  "/var/log/café"   "$(sourced "$u8_env" ROGUE_LOG_DIR)"
done

# ── An UNREADABLE existing file must fail the write, not silently drop it ────
# The preserve filter used to be `grep | grep`, and a pipeline reports only its
# LAST status: the first grep died with "Permission denied", the second saw empty
# input and exited 1, and the writer read that as "nothing left to keep" and
# replaced the file with the managed keys alone. Both grep patterns are one
# invocation now, so the read error (2) is the status the writer sees.
unread_probe="$SANDBOX/unreadable-probe"
: > "$unread_probe"
chmod 000 "$unread_probe"
if cat "$unread_probe" >/dev/null 2>&1; then
  # root reads it regardless of the mode bits, so there is no failure to observe.
  echo "  skip: mode 000 is readable anyway (running as root?)"
else
  for impl in shared install; do
    unread_env="$SANDBOX/unreadable-$impl.env"
    seed "$unread_env"
    before="$(cat "$unread_env")"
    chmod 000 "$unread_env"
    set +e
    if [ "$impl" = shared ]; then
      "$SH" -c '. "$1"; rogue_write_env_file "$2" ROGUE_API_KEY "should-not-land" ROGUE_ACTOR_EMAIL "x@y.z" ROGUE_ACTOR_NAME "X"' \
        _ "$REPO/scripts/shared/env-file.sh" "$unread_env" >/dev/null 2>&1
    else
      ROGUE_INSTALL_LIB_ONLY=1 bash -c '
        . "$1"
        ENV_FILE="$2"
        ROGUE_API_KEY="should-not-land"; ROGUE_ACTOR_EMAIL="x@y.z"; ROGUE_ACTOR_NAME="X"
        write_env_file
      ' _ "$REPO/install.sh" "$unread_env" >/dev/null 2>&1
    fi
    unread_rc=$?
    set -e
    chmod 600 "$unread_env"
    check "$impl: unreadable file fails the write"  "1"       "$([ "$unread_rc" = 0 ] && echo 0 || echo 1)"
    check "$impl: unreadable file left intact"      "$before" "$(cat "$unread_env")"
    check "$impl: unreadable file leaves no temp"   "0"       "$(find "$SANDBOX" -name "*unreadable-$impl*.rogue-tmp.*" | wc -l | tr -d ' ')"
  done
fi
chmod 600 "$unread_probe"

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
