#!/usr/bin/env sh

rogue_env_quote() {
  printf "'%s'" "$(printf '%s' "$1" | sed "s/'/'\\\\''/g")"
}

rogue_env_preserved() {
  _rogue_env_rc=0
  _rogue_env_kept="$(grep -Ev \
    -e "^[[:space:]]*(export[[:space:]]+)?(${2})[[:space:]]*=" \
    -e '^[[:space:]]*# (Managed by the [Rr]ogue|Delete this file to revoke credentials)' \
    "$1")" || _rogue_env_rc=$?
  [ "$_rogue_env_rc" -le 1 ] || return 1

  [ -z "$_rogue_env_kept" ] || printf '%s\n' "$_rogue_env_kept" | tr -d '\r'
}

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
