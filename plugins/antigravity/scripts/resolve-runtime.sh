#!/bin/sh
# Find a JavaScript runtime that can read Antigravity's conversation store, and
# cache the answer. Echoes an absolute path on success, nothing on failure.
#
# Usage: resolve-runtime.sh <transcriptPathOrStateDir>   (both optional)
#
# WHY A PROBE AND NOT A VERSION CHECK. The reader needs `node:sqlite`, which
# arrived in Node 22.5 and stopped needing a flag in 22.13. Measured on a real
# machine: the developer's own `node` (v20.19.4) does NOT have it, while the
# runtime the IDE itself ships (Electron 39 -> node 22.21.1) does. So a candidate
# is accepted only if it can actually load the module.
#
# WHY NO DOWNLOAD. The `antigravity_ide` surface exists only where the IDE is
# installed, and the IDE bundles a qualifying runtime — so provisioning one would
# duplicate bytes already on disk. Nothing here fetches anything; when no
# candidate passes we cache a sentinel and the prompt gate simply stays inactive.
#
# Cache: ~/.rogue/antigravity-runtime, one line "<kind>\t<path>", or "none".
CACHE="${ROGUE_ANTIGRAVITY_RUNTIME_CACHE:-$HOME/.rogue/antigravity-runtime}"

# Does this candidate actually expose node:sqlite? --experimental-sqlite is a
# harmless no-op on versions that no longer need it, so passing it always keeps
# compatibility back to Node 22.5.
probe() {
  [ -x "$1" ] || return 1
  ELECTRON_RUN_AS_NODE=1 "$1" --no-warnings --experimental-sqlite \
    -e 'require("node:sqlite").DatabaseSync;process.stdout.write("OK")' 2>/dev/null \
    | grep -q '^OK$'
}

emit() {  # $1 = kind, $2 = path
  mkdir -p "$(dirname "$CACHE")" 2>/dev/null
  printf '%s\t%s\n' "$1" "$2" > "$CACHE" 2>/dev/null
  printf '%s' "$2"
}

# The IDE's own Electron, located from state the IDE itself writes rather than a
# hardcoded /Applications path: <stateDir>/bin/agentapi execs the language server
# inside the app bundle, so the bundle root is that path truncated at `.app/`.
# Verified on macOS; the Linux/Windows arms are untested.
ide_runtime_candidates() {
  _sd="$1"
  [ -n "$_sd" ] || return 0
  _shim="$_sd/bin/agentapi"
  [ -r "$_shim" ] || return 0
  _ls=$(sed -n 's|.*exec "\([^"]*\)".*|\1|p' "$_shim" | head -1)
  [ -n "$_ls" ] || return 0
  case "$_ls" in
    */Contents/*)                                    # macOS bundle
      _bundle=${_ls%%.app/Contents/*}.app
      _name=$(basename "$_bundle" .app)
      printf '%s\n' "$_bundle/Contents/Frameworks/$_name Helper.app/Contents/MacOS/$_name Helper"
      printf '%s\n' "$_bundle/Contents/MacOS/Electron"
      ;;
    *)                                               # Linux: walk up to the app root
      _root=${_ls%%/resources/app/*}
      [ "$_root" != "$_ls" ] || return 0
      printf '%s\n' "$_root/antigravity-ide"
      printf '%s\n' "$_root/antigravity"
      printf '%s\n' "$_root/electron"
      ;;
  esac
}

# $1 may be a transcriptPath or a state dir; reduce it to the state dir.
state_dir_from() {
  case "$1" in
    */brain/*) printf '%s' "${1%%/brain/*}" ;;
    ?*)        printf '%s' "$1" ;;
  esac
}

# The resolution chain, in preference order. Echoes the runtime path (or nothing)
# and is the only thing that decides — main just prints what it returns.
resolve_runtime() {
  _state_dir=$(state_dir_from "$1")

  # 1. Explicit override wins — the MDM / air-gapped / test answer. It is an
  #    answer either way: a bad override resolves to nothing rather than falling
  #    through to a runtime the operator did not choose.
  if [ -n "${ROGUE_ANTIGRAVITY_NODE:-}" ]; then
    probe "$ROGUE_ANTIGRAVITY_NODE" && printf '%s' "$ROGUE_ANTIGRAVITY_NODE"
    return 0
  fi

  # 2. Cache. A stale entry (IDE upgraded/moved) falls through to a fresh resolve.
  if [ -r "$CACHE" ]; then
    _cached=$(cut -f2 -d'	' < "$CACHE" 2>/dev/null | head -1)
    _kind=$(cut -f1 -d'	' < "$CACHE" 2>/dev/null | head -1)
    [ "$_kind" = "none" ] && return 0
    if [ -n "$_cached" ] && [ -x "$_cached" ]; then printf '%s' "$_cached"; return 0; fi
  fi

  # 3. The IDE's bundled Electron — the only candidate guaranteed present on the
  #    surface that needs it. The loop runs in a subshell (it is the right-hand
  #    side of a pipe), so it cannot return from here: it PRINTS the winner and
  #    `grep .` reports whether there was one.
  _ide=$(ide_runtime_candidates "$_state_dir" | while IFS= read -r _c; do
    [ -n "$_c" ] || continue
    probe "$_c" && { emit ide-electron "$_c"; exit 0; }
  done | grep .)
  if [ -n "$_ide" ]; then printf '%s' "$_ide"; return 0; fi

  # 4. Antigravity 2.0's shim, present when 2.0 is co-installed (node 24.x).
  for _c in "$HOME/Library/Application Support/Antigravity/bin/agy-node" \
            "$HOME/.gemini/antigravity/bin/agy-node"; do
    probe "$_c" && { emit app-electron "$_c"; return 0; }
  done

  # 5. System node, accepted only if it passes the probe (often it will not).
  _sys=$(command -v node 2>/dev/null)
  if [ -n "$_sys" ] && probe "$_sys"; then emit system-node "$_sys"; return 0; fi

  # 6. Nothing qualifies: remember that, so later events cost one file read.
  mkdir -p "$(dirname "$CACHE")" 2>/dev/null
  printf 'none\t\n' > "$CACHE" 2>/dev/null
  return 0
}

main() {
  resolve_runtime "${1:-}"
  exit 0
}

main "$@"
