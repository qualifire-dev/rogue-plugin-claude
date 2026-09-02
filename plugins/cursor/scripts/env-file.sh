#!/usr/bin/env sh
# Rogue Security - shared credential-file writer. SOURCED, never executed.
#
# SOURCE OF TRUTH: run scripts/sync-shared-scripts.sh after editing.
#
# The write MERGES: ~/.rogue-env is shared by six plugins and holds settings no
# setup flow asks about (ROGUE_BASE_URL, ROGUE_LOG_DIR). POSIX clean - dash has
# no printf %q.

rogue_env_quote() {
  printf "'%s'" "$(printf '%s' "$1" | sed "s/'/'\\\\''/g")"
}

# Lines we do not own; our header goes too, or it piles up per write. grep exits
# 1 when nothing is left to keep, which is not a failure - but a read or write
# error (2) must propagate, or a truncated temp file replaces a good one.
rogue_env_preserved() { # <env-file> <key1|key2|...>
  grep -Ev "^[[:space:]]*(export[[:space:]]+)?(${2})[[:space:]]*=" "$1" \
    | grep -Ev '^[[:space:]]*# (Managed by the [Rr]ogue|Delete this file to revoke credentials)'
  case "$?" in 0 | 1) return 0 ;; *) return 1 ;; esac
}

# rogue_write_env_file <env-file> <key> <value> [<key> <value> ...]
rogue_write_env_file() {
  _env_file="$1"; shift
  [ "$#" -ge 2 ] || return 2

  _env_dir="$(dirname "$_env_file")"
  [ -d "$_env_dir" ] || mkdir -p "$_env_dir" || return 1

  _env_keys=""
  _env_managed=""
  while [ "$#" -ge 2 ]; do
    _env_keys="${_env_keys}${_env_keys:+|}$1"
    _env_managed="${_env_managed}export $1=$(rogue_env_quote "$2")
"
    shift 2
  done

  # Temp file: a full disk must not leave a truncated credential file. Every
  # emit is && chained, so a partial write fails the group instead of being
  # swallowed and mv'd over the file it was meant to update.
  _env_tmp="${_env_file}.rogue-tmp.$$"
  (
    umask 077
    {
      printf '# Managed by the Rogue plugins. Read by hook subprocesses at runtime.\n' &&
      printf '# Delete this file to revoke credentials.\n' &&
      printf '%s' "$_env_managed" &&
      { [ ! -f "$_env_file" ] || rogue_env_preserved "$_env_file" "$_env_keys"; }
    } > "$_env_tmp"
  ) || { rm -f "$_env_tmp"; return 1; }

  mv -f "$_env_tmp" "$_env_file" || { rm -f "$_env_tmp"; return 1; }
  chmod 600 "$_env_file" 2>/dev/null || :
}
