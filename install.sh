#!/usr/bin/env bash
#
# Rogue Security — one-line installer for Claude Code.
#
#   curl -fsSL https://raw.githubusercontent.com/qualifire-dev/rogue-plugins/main/install.sh | bash
#
# Installs the Rogue Security AIDR plugin through the official Claude CLI
# (marketplace add + plugin install), validates and stores your API key,
# confirms your actor identity, and configures a status badge below the prompt.
#
# Unlike the runtime hooks (which fail OPEN so Claude Code never hangs on Rogue
# infrastructure), this installer fails LOUD: it is a deliberate user action and
# a half-finished install should be visible, not silent.
#
# Env knobs:
#   ROGUE_NON_INTERACTIVE=1   no prompts (used by auto-update.sh re-invocation)
#   ROGUE_API_KEY=...         pre-seed the API key (skips the prompt)
#   ROGUE_ACTOR_EMAIL=...     pre-seed actor identity
#   ROGUE_ACTOR_NAME=...
#   ROGUE_PLUGIN_REPO=...     marketplace source (default below)
#   ROGUE_BASE_URL=...        API base for key validation (default below)
#   ROGUE_NO_STATUSLINE=1     skip the status-badge setup
#   NO_COLOR=1                disable ANSI color
#
# CLI flags (equivalent to the env knobs; pass after `bash -s --`):
#   curl -fsSL .../install.sh | bash -s -- --api-key="rg_xxx" --non-interactive
#
#   --claude               install only for Claude Code (repeatable with the others)
#   --codex                install only for OpenAI Codex
#   --cursor               install only for Cursor
#   --gemini               install only for Gemini CLI
#   --copilot              install only for GitHub Copilot CLI
#   --antigravity          install only for Google Antigravity
#                          (no agent flag = auto-detect and install for every agent found)
#   --api-key=KEY          same as ROGUE_API_KEY
#   --actor-email=EMAIL    same as ROGUE_ACTOR_EMAIL
#   --actor-name=NAME      same as ROGUE_ACTOR_NAME
#   --non-interactive      same as ROGUE_NON_INTERACTIVE=1
#   --no-statusline        same as ROGUE_NO_STATUSLINE=1
#   --plugin-repo=OWNER/R  same as ROGUE_PLUGIN_REPO
#   --base-url=URL         same as ROGUE_BASE_URL
#   -h | --help            print this and exit
#
# Note: a key on the command line is visible in `ps` and shell history. For
# unattended/MDM installs the env-var form (ROGUE_API_KEY=...) is preferable.
#
set -u

# ── Config ──────────────────────────────────────────────────────────────────
ROGUE_PLUGIN_REPO="${ROGUE_PLUGIN_REPO:-qualifire-dev/rogue-plugins}"
ROGUE_BASE_URL_DEFAULT="https://api.rogue.security"
BASE_URL_EXPLICIT=0
[ -z "${ROGUE_BASE_URL:-}" ] || BASE_URL_EXPLICIT=1
ROGUE_BASE_URL="${ROGUE_BASE_URL:-$ROGUE_BASE_URL_DEFAULT}"
MARKETPLACE_NAME="rogue-marketplace"
PLUGIN_NAME="rogue"
CONFIG_DIR="${CLAUDE_CONFIG_DIR:-$HOME/.claude}"
STATUSLINE_PATH="$CONFIG_DIR/hooks/rogue-statusline.sh"
SETTINGS_PATH="$CONFIG_DIR/settings.json"
ENV_FILE="${ROGUE_ENV_FILE:-$HOME/.rogue-env}"

NON_INTERACTIVE="${ROGUE_NON_INTERACTIVE:-0}"
# Explicit agent selection via --claude/--codex/--cursor. Empty = auto-detect all.
WANT=""
# Bind the controlling terminal to fd 3 once, so prompts work even under
# `curl | bash` (where stdin is the script, not the keyboard). If /dev/tty
# can't be opened (no terminal, or a sandbox that reports "Device not
# configured"), fall back to non-interactive instead of crashing.
if { exec 3</dev/tty; } 2>/dev/null; then
  HAVE_TTY=1
else
  HAVE_TTY=0
  NON_INTERACTIVE=1
fi

# ── Colors / log helpers ──────────────────────────────────────────────────────
if [ -n "${NO_COLOR:-}" ] || [ ! -t 2 ]; then
  C_RESET=''; C_TEAL=''; C_GREEN=''; C_YELLOW=''; C_RED=''; C_DIM=''
else
  C_RESET=$'\033[0m'; C_TEAL=$'\033[38;2;74;176;227m'; C_GREEN=$'\033[38;5;40m'
  C_YELLOW=$'\033[38;5;220m'; C_RED=$'\033[38;5;196m'; C_DIM=$'\033[2m'
fi

ok()   { printf '%s✓%s %s\n'  "$C_GREEN"  "$C_RESET" "$*" >&2; }
note() { printf '%s•%s %s\n'  "$C_DIM"    "$C_RESET" "$*" >&2; }
warn() { printf '%s!%s %s\n'  "$C_YELLOW" "$C_RESET" "$*" >&2; }
die()  { printf '%s✗ %s%s\n'  "$C_RED"    "$*" "$C_RESET" >&2; exit 1; }

# Prompt on the terminal (fd 3) and read one line. We print the prompt ourselves
# to stderr (NOT via `read -p`, whose prompt would be swallowed by stderr
# redirection) so it's always visible. Returns non-zero when there's no terminal
# (HAVE_TTY=0) or on EOF — callers must fall back rather than loop.
ask() { # ask <varname> <prompt> [-s]
  local __var="$1" __prompt="$2" __silent="${3:-}"
  [ "$HAVE_TTY" = "1" ] || return 1
  printf '%s' "$__prompt" >&2
  if [ "$__silent" = "-s" ]; then
    read -r -s "$__var" <&3 || return 1
    printf '\n' >&2
  else
    read -r "$__var" <&3 || return 1
  fi
}

have_cmd() { command -v "$1" >/dev/null 2>&1; }

# ── Agent detection (extensible probe) ────────────────────────────────────────
# main() detects each agent via `have_cmd <bin>` and runs its installer. Add an
# agent = one detect line in main() + one `<id>_install_plugin` function.
#
#   id           label                detect                              installer
#   ───────────  ───────────────────  ──────────────────────────────────  ───────────────────
#   claude       Claude Code          command:claude                      install_claude      ← implemented
#   codex        Codex CLI            command:codex                       install_codex       ← implemented
#   cursor       Cursor               command:cursor|~/.cursor            install_cursor      ← implemented
#   gemini       Gemini CLI           command:gemini                      install_gemini      ← implemented
#   copilot      Copilot CLI          command:copilot                     install_copilot     ← implemented
#   antigravity  Google Antigravity   command:agy|~/.gemini/antigravity*  install_antigravity ← implemented
#
# Claude, Codex, and Copilot install via their native plugin CLIs (which git-clone
# the marketplace). Cursor has NO plugin CLI — install is a file copy into
# ~/.cursor/plugins/local/rogue. So install_cursor downloads the release tarball
# and copies the plugin tree (see cursor_install_plugin). Gemini HAS a native
# extension CLI but expects the manifest at a source root — so gemini_install_extension
# downloads the release tarball (whose top dir IS the extension) and runs
# `gemini extensions install <dir>` (see gemini_install_extension). Copilot reads
# BOTH .github/plugin/marketplace.json AND .claude-plugin/marketplace.json from the
# monorepo, so its marketplace uses a DISTINCT name (rogue-copilot) and the install
# targets rogue@rogue-copilot to avoid resolving to the Claude plugin. Antigravity is
# a copy-a-directory install (into ~/.gemini/config/plugins/rogue) PLUS the native
# `agy plugin install` when the `agy` CLI is present (see antigravity_install_plugin).

# ── Marketplace + plugin install (Claude) ─────────────────────────────────────
claude_install_plugin() {
  note "Adding marketplace ${C_DIM}$ROGUE_PLUGIN_REPO${C_RESET}"
  # Capture stderr so a real failure (e.g. missing git, clone error) is surfaced
  # instead of swallowed — otherwise it resurfaces later as a misleading
  # "plugin not found" from the install step.
  local add_err
  if add_err="$(claude plugin marketplace add "$ROGUE_PLUGIN_REPO" 2>&1)"; then
    ok "Marketplace added"
  else
    # Already present (or transient) — refresh from source instead.
    if claude plugin marketplace update "$MARKETPLACE_NAME" >/dev/null 2>&1; then
      ok "Marketplace updated"
    else
      warn "Could not add or update marketplace (continuing — it may already be present)"
      [ -n "$add_err" ] && note "${C_DIM}${add_err}${C_RESET}"
    fi
  fi

  note "Installing plugin ${C_DIM}${PLUGIN_NAME}@${MARKETPLACE_NAME}${C_RESET}"
  if claude plugin install "${PLUGIN_NAME}@${MARKETPLACE_NAME}" >/dev/null 2>&1; then
    ok "Plugin installed"
  elif claude plugin update "$PLUGIN_NAME" >/dev/null 2>&1; then
    ok "Plugin updated"
  else
    die "claude plugin install failed. Run 'claude plugin install ${PLUGIN_NAME}@${MARKETPLACE_NAME}' to see the error."
  fi
}

# ── Marketplace + plugin install (Codex) ──────────────────────────────────────
# Same monorepo: Codex reads .agents/plugins/marketplace.json, Claude reads
# .claude-plugin/marketplace.json — both name the marketplace `rogue-marketplace`
# and the plugin `rogue`, so the slug and `${PLUGIN_NAME}@${MARKETPLACE_NAME}` match.
codex_install_plugin() {
  note "Adding marketplace ${C_DIM}$ROGUE_PLUGIN_REPO${C_RESET}"
  local add_err
  if add_err="$(codex plugin marketplace add "$ROGUE_PLUGIN_REPO" 2>&1)"; then
    ok "Marketplace added"
  else
    if codex plugin marketplace upgrade "$MARKETPLACE_NAME" >/dev/null 2>&1; then
      ok "Marketplace updated"
    else
      warn "Could not add or update Codex marketplace (continuing — it may already be present)"
      [ -n "$add_err" ] && note "${C_DIM}${add_err}${C_RESET}"
    fi
  fi

  note "Installing plugin ${C_DIM}${PLUGIN_NAME}@${MARKETPLACE_NAME}${C_RESET}"
  # Codex uses `plugin add` (not `install`); idempotent re-add is fine.
  if codex plugin add "${PLUGIN_NAME}@${MARKETPLACE_NAME}" >/dev/null 2>&1; then
    ok "Plugin installed"
  else
    die "codex plugin add failed. Run 'codex plugin add ${PLUGIN_NAME}@${MARKETPLACE_NAME}' to see the error."
  fi
}

# ── Marketplace + plugin install (GitHub Copilot CLI) ─────────────────────────
# Copilot has a native plugin CLI (`copilot plugin marketplace add` +
# `copilot plugin install NAME@MARKETPLACE`) that git-clones the marketplace —
# same model as Claude/Codex. But Copilot reads BOTH .github/plugin/marketplace.json
# (native) and .claude-plugin/marketplace.json (which points at the Claude plugin),
# so the Copilot marketplace uses a DISTINCT name (rogue-copilot) and we install
# rogue@rogue-copilot to disambiguate.
COPILOT_MARKETPLACE_NAME="rogue-copilot"
copilot_install_plugin() {
  note "Adding marketplace ${C_DIM}$ROGUE_PLUGIN_REPO${C_RESET}"
  local add_err
  if add_err="$(copilot plugin marketplace add "$ROGUE_PLUGIN_REPO" 2>&1)"; then
    ok "Marketplace added"
  else
    if copilot plugin marketplace update "$COPILOT_MARKETPLACE_NAME" >/dev/null 2>&1; then
      ok "Marketplace updated"
    else
      warn "Could not add or update Copilot marketplace (continuing — it may already be present)"
      [ -n "$add_err" ] && note "${C_DIM}${add_err}${C_RESET}"
    fi
  fi

  note "Installing plugin ${C_DIM}${PLUGIN_NAME}@${COPILOT_MARKETPLACE_NAME}${C_RESET}"
  if copilot plugin install "${PLUGIN_NAME}@${COPILOT_MARKETPLACE_NAME}" >/dev/null 2>&1; then
    ok "Plugin installed"
  elif copilot plugin update "$PLUGIN_NAME" >/dev/null 2>&1; then
    ok "Plugin updated"
  else
    die "copilot plugin install failed. Run 'copilot plugin install ${PLUGIN_NAME}@${COPILOT_MARKETPLACE_NAME}' to see the error."
  fi
}

# ── File-copy install (Cursor) ────────────────────────────────────────────────
# Cursor has no plugin CLI and no marketplace-add command — the only programmatic
# install is dropping the plugin tree into ~/.cursor/plugins/local/<name>. So we
# download the release tarball, extract it, and copy plugins/cursor/ into place
# (mirrors rogue-plugin-cursor/install.sh). Re-running overwrites — safe upgrade.
# The Team Marketplace (.cursor-plugin/marketplace.json) is the separate, admin-
# driven managed/auto-update path; this one-liner does not touch it.
CURSOR_INSTALL_DIR="$HOME/.cursor/plugins/local/${PLUGIN_NAME}"
# Returns non-zero (never `die`s) so a missing release asset or transient download
# failure can't abort the whole installer — Cursor is auto-detected from ~/.cursor,
# which is present for almost every developer, so a hard failure here would break
# the Claude/Codex installs that ran first. install_cursor() warns on a non-zero
# return and the run continues.
cursor_install_plugin() {
  local tmp asset url src
  asset="rogue-plugin-cursor.tar.gz"
  if [ -n "${ROGUE_PLUGIN_VERSION:-}" ]; then
    url="https://github.com/${ROGUE_PLUGIN_REPO}/releases/download/${ROGUE_PLUGIN_VERSION}/${asset}"
  else
    url="https://github.com/${ROGUE_PLUGIN_REPO}/releases/latest/download/${asset}"
  fi

  tmp="$(mktemp -d)" || { warn "Could not create a temp dir for the Cursor download."; return 1; }
  # shellcheck disable=SC2064
  trap "rm -rf '$tmp'" RETURN

  note "Downloading plugin ${C_DIM}${asset}${C_RESET}"
  if ! curl -fsSL --max-time 60 -o "$tmp/p.tar.gz" "$url"; then
    warn "Cursor plugin asset not available yet ($url) — skipping Cursor. Re-run the installer once it's published."
    return 1
  fi
  mkdir -p "$tmp/extract"
  tar -xzf "$tmp/p.tar.gz" -C "$tmp/extract" \
    || { warn "Could not extract the Cursor plugin tarball — skipping Cursor."; return 1; }

  # The tarball stages a top dir (rogue-plugin-cursor/) containing plugins/cursor/.
  src="$(find "$tmp/extract" -type d -path '*/plugins/cursor' | head -1)"
  [ -n "$src" ] && [ -f "$src/.cursor-plugin/plugin.json" ] \
    || { warn "Cursor plugin manifest missing in download — skipping Cursor."; return 1; }

  mkdir -p "$(dirname "$CURSOR_INSTALL_DIR")"
  rm -rf "$CURSOR_INSTALL_DIR"
  mkdir -p "$CURSOR_INSTALL_DIR"
  cp -R "$src/." "$CURSOR_INSTALL_DIR/"
  ok "Plugin installed → ${C_DIM}$CURSOR_INSTALL_DIR${C_RESET}"
}

# ── Native-extension install (Gemini CLI) ─────────────────────────────────────
# Gemini has a native extension CLI, but `gemini extensions install <github-url>`
# expects gemini-extension.json at the SOURCE ROOT — which the monorepo root is
# not. So we download the release tarball (whose top dir IS the extension, with
# the manifest at its root — see scripts/build-release.sh), extract it, and run
# `gemini extensions install <extracted-dir>`. Gemini makes its own managed copy
# under ~/.gemini/extensions/rogue, so the temp dir is disposable. Re-running
# upgrades (uninstall-then-install). Returns non-zero (never `die`s) so a missing
# asset can't abort a run that already installed the other agents.
gemini_install_extension() {
  local tmp asset url src
  asset="rogue-plugin-gemini.tar.gz"
  if [ -n "${ROGUE_PLUGIN_VERSION:-}" ]; then
    url="https://github.com/${ROGUE_PLUGIN_REPO}/releases/download/${ROGUE_PLUGIN_VERSION}/${asset}"
  else
    url="https://github.com/${ROGUE_PLUGIN_REPO}/releases/latest/download/${asset}"
  fi

  tmp="$(mktemp -d)" || { warn "Could not create a temp dir for the Gemini download."; return 1; }
  # shellcheck disable=SC2064
  trap "rm -rf '$tmp'" RETURN

  note "Downloading extension ${C_DIM}${asset}${C_RESET}"
  if ! curl -fsSL --max-time 60 -o "$tmp/p.tar.gz" "$url"; then
    warn "Gemini extension asset not available yet ($url) — skipping Gemini. Re-run the installer once it's published."
    return 1
  fi
  mkdir -p "$tmp/extract"
  tar -xzf "$tmp/p.tar.gz" -C "$tmp/extract" \
    || { warn "Could not extract the Gemini extension tarball — skipping Gemini."; return 1; }

  # The tarball stages a top dir (rogue-plugin-gemini/) whose ROOT is the extension.
  src="$(find "$tmp/extract" -type f -name gemini-extension.json | head -1)"
  [ -n "$src" ] || { warn "Gemini manifest missing in download — skipping Gemini."; return 1; }
  src="$(dirname "$src")"

  # Reinstall cleanly so a re-run upgrades. Ignore uninstall errors (first run).
  # GEMINI_CLI_TRUST_WORKSPACE=true is Gemini's documented headless bypass for
  # its folder-trust gate (default-ON): without it the install prompts "Do you
  # trust the files in this folder?" for our own just-extracted temp dir, the
  # prompt is invisible here (output swallowed), non-interactive default is No,
  # and the install aborts with 'Installation aborted: Folder "..." is not
  # trusted.' Scoped to these two commands only — no persistent trust granted.
  GEMINI_CLI_TRUST_WORKSPACE=true gemini extensions uninstall rogue >/dev/null 2>&1 || true
  if GEMINI_CLI_TRUST_WORKSPACE=true gemini extensions install "$src" --consent >/dev/null 2>&1; then
    ok "Extension installed via ${C_DIM}gemini extensions install${C_RESET}"
  else
    # No recovery command in the message: $src lives under $tmp, which the RETURN
    # trap deletes on the way out of this function (same rule as install_antigravity).
    warn "gemini extensions install failed — re-run the installer, or install manually: extract ${asset} from the GitHub release and run 'GEMINI_CLI_TRUST_WORKSPACE=true gemini extensions install <extracted-dir> --consent'."
    return 1
  fi
}

# ── Copy-a-directory install (Google Antigravity) ─────────────────────────────
# Antigravity has no marketplace-add command. Like Gemini, the release tarball's
# top dir IS the plugin (manifest at its root — see scripts/build-release.sh), so
# we download it, extract it, and copy it into the IDE's global plugin dir
# (~/.gemini/config/plugins/rogue). If the `agy` CLI is present we additionally
# register it natively (uninstall-then-install so a re-run upgrades); otherwise,
# if a manual-CLI plugins dir exists, copy there too. Returns non-zero (never
# `die`s) so a missing asset can't abort a run that already installed other agents.
antigravity_install_plugin() {
  local tmp asset url src ide_dir cli_dir
  asset="rogue-plugin-antigravity.tar.gz"
  if [ -n "${ROGUE_PLUGIN_VERSION:-}" ]; then
    url="https://github.com/${ROGUE_PLUGIN_REPO}/releases/download/${ROGUE_PLUGIN_VERSION}/${asset}"
  else
    url="https://github.com/${ROGUE_PLUGIN_REPO}/releases/latest/download/${asset}"
  fi

  tmp="$(mktemp -d)" || { warn "Could not create a temp dir for the Antigravity download."; return 1; }
  # shellcheck disable=SC2064
  trap "rm -rf '$tmp'" RETURN

  note "Downloading plugin ${C_DIM}${asset}${C_RESET}"
  if ! curl -fsSL --max-time 60 -o "$tmp/p.tar.gz" "$url"; then
    warn "Antigravity plugin asset not available yet ($url) — skipping Antigravity. Re-run the installer once it's published."
    return 1
  fi
  mkdir -p "$tmp/extract"
  tar -xzf "$tmp/p.tar.gz" -C "$tmp/extract" \
    || { warn "Could not extract the Antigravity plugin tarball — skipping Antigravity."; return 1; }

  # The tarball stages a top dir (rogue-plugin-antigravity/) whose ROOT is the plugin.
  src="$(find "$tmp/extract" -maxdepth 2 -type f -name plugin.json -exec dirname {} \; | head -1)"
  [ -n "$src" ] && [ -f "$src/hooks.json" ] \
    || { warn "Antigravity plugin manifest missing in download — skipping Antigravity."; return 1; }

  # IDE global copy.
  ide_dir="$HOME/.gemini/config/plugins/${PLUGIN_NAME}"
  mkdir -p "$(dirname "$ide_dir")"
  rm -rf "$ide_dir"
  mkdir -p "$ide_dir"
  cp -R "$src/." "$ide_dir/"
  ok "Plugin installed → ${C_DIM}$ide_dir${C_RESET}"

  # CLI: native install if `agy` is present, else manual copy if the CLI dir exists.
  #
  # A failure here is NOT fatal and must not be reported as one: the global copy
  # above is the shared plugins dir all three surfaces read (`agy plugin list`
  # reports it as source "antigravity"), so the CLI keeps loading the plugin from
  # there. What it must not do is print a dead recovery command — `$src` lives in
  # `$tmp`, which the RETURN trap deletes on the way out of this function, so the
  # durable path ($ide_dir) is the only one worth suggesting.
  if have_cmd agy; then
    agy plugin uninstall "$PLUGIN_NAME" >/dev/null 2>&1 || true
    local agy_err
    if agy_err="$(agy plugin install "$src" 2>&1)"; then
      ok "Plugin installed via ${C_DIM}agy plugin install${C_RESET}"
    else
      warn "agy plugin install failed — the CLI still loads the plugin from $ide_dir."
      [ -n "$agy_err" ] && note "${C_DIM}${agy_err}${C_RESET}"
      note "To retry the native registration: ${C_DIM}agy plugin install '$ide_dir'${C_RESET}"
    fi
  elif [ -d "$HOME/.gemini/antigravity-cli/plugins" ]; then
    cli_dir="$HOME/.gemini/antigravity-cli/plugins/${PLUGIN_NAME}"
    rm -rf "$cli_dir"
    mkdir -p "$cli_dir"
    cp -R "$src/." "$cli_dir/"
    ok "Plugin installed → ${C_DIM}$cli_dir${C_RESET}"
  fi
}

# ── Credentials ───────────────────────────────────────────────────────────────
# Validate the key AND register this install via /api/v1/hooks/status (the same
# heartbeat the SessionStart hook calls). Echoes the HTTP status code (empty on
# transport failure). On 200, also populates STATUS_ORG for the caller to
# surface. Sending a stable host + actor-email keeps the dashboard roster row
# deduped with the later heartbeats.
STATUS_ORG=""
# /api/v1/hooks/status has side effects (it registers/updates the roster row), so
# the key-validation POST must register under an agent that is actually being
# installed — a Copilot-only or Codex-only install must NOT create a bogus Claude
# roster row. Resolve the family/agent from the selected `agents`: prefer claude
# when it's a target (its heartbeat backs the row, preserving today's behavior);
# otherwise use the first selected agent so the row matches a plugin whose
# heartbeat will run. Values mirror each plugin's heartbeat body.
status_agent_ctx() { # sets SC_FAMILY / SC_AGENT from $agents
  local a
  for a in ${agents:-}; do
    [ "$a" = claude ] && { SC_FAMILY="claude"; SC_AGENT="claude_code"; return; }
  done
  set -- ${agents:-claude}
  case "${1:-claude}" in
    codex)   SC_FAMILY="openai";  SC_AGENT="codex_cli" ;;
    cursor)  SC_FAMILY="cursor";  SC_AGENT="cursor" ;;
    gemini)  SC_FAMILY="gemini";  SC_AGENT="gemini_cli" ;;
    copilot) SC_FAMILY="copilot"; SC_AGENT="github_copilot" ;;
    *)       SC_FAMILY="claude";  SC_AGENT="claude_code" ;;
  esac
}
status_check() { # status_check <api-key> <actor-email>
  have_cmd curl || { printf ''; return; }
  local resp code body host json
  host="$(hostname 2>/dev/null || echo unknown)"
  status_agent_ctx
  # POST /api/v1/hooks/status with a JSON body — the GET route was removed
  # (see plugins/rogue/scripts/heartbeat.sh). The former x-rogue-agent-*
  # headers now ride the body; x-rogue-api-key stays a header. esc() so a host
  # or email with a " or \ can't break the JSON.
  esc() { printf '%s' "$1" | sed -e 's/\\/\\\\/g' -e 's/"/\\"/g'; }
  json=$(printf '{"agent_family":"%s","agent":"%s","host":"%s","actor_email":"%s"}' \
    "$SC_FAMILY" "$SC_AGENT" "$(esc "$host")" "$(esc "${2:-}")")
  resp=$(curl -s -w $'\n%{http_code}' --max-time 10 -X POST \
    "$ROGUE_BASE_URL/api/v1/hooks/status" \
    -H "x-rogue-api-key: $1" \
    -H "Content-Type: application/json" \
    -d "$json" 2>/dev/null) || { printf ''; return; }
  code="${resp##*$'\n'}"
  body="${resp%$'\n'*}"
  if [ "$code" = "200" ]; then
    STATUS_ORG=$(printf '%s' "$body" | sed -E -n 's/.*"name"[[:space:]]*:[[:space:]]*"([^"]*)".*/\1/p' | head -1)
  fi
  printf '%s' "$code"
}

# Mask an API key for display: show the first 8 chars, hide the rest.
key_hint() { # key_hint <key>
  local k="$1"
  if [ "${#k}" -le 8 ]; then printf '%s' "$k"; else printf '%s…' "${k:0:8}"; fi
}

configure_credentials() {
  # Capture explicit input (CLI flags / env vars) BEFORE sourcing the on-disk
  # files — otherwise a stored key would clobber a key the caller passed to
  # rotate it. Explicit user intent wins; on-disk is the fallback.
  local flag_key="${ROGUE_API_KEY:-}"
  local flag_email="${ROGUE_ACTOR_EMAIL:-}"
  local flag_name="${ROGUE_ACTOR_NAME:-}"
  local flag_base_url="$ROGUE_BASE_URL"

  # Pull anything already on disk / in env into scope.
  [ -r /etc/rogue/env ] && . /etc/rogue/env
  [ -r "$ENV_FILE" ]    && . "$ENV_FILE"

  [ "$BASE_URL_EXPLICIT" = "1" ] && ROGUE_BASE_URL="$flag_base_url"

  local cur_key="${flag_key:-${ROGUE_API_KEY:-}}"

  # Resolve actor defaults up front (same cascade as plugins/rogue/scripts/actor.sh)
  # so key validation can register the roster row under the real email, deduped
  # with the later SessionStart heartbeats. Explicit flag/env beats on-disk.
  local def_email def_name
  def_email="${flag_email:-${ROGUE_ACTOR_EMAIL:-$(git config --global user.email 2>/dev/null)}}"
  def_name="${flag_name:-${ROGUE_ACTOR_NAME:-$(git config --global user.name 2>/dev/null)}}"
  [ -n "$def_email" ] || def_email="${CLAUDE_CODE_USER_EMAIL:-}"
  [ -n "$def_name" ]  || { def_name="${CLAUDE_CODE_USER_EMAIL:-}"; def_name="${def_name%@*}"; }
  [ -n "$def_email" ] || def_email="$(hostname 2>/dev/null)"
  [ -n "$def_name" ]  || def_name="$(whoami 2>/dev/null)"

  # Non-interactive: persist whatever key is in scope (env-passed or on-disk),
  # filling actor identity from the resolved cascade. A key passed only via the
  # ROGUE_API_KEY env var is otherwise lost — it never reaches ~/.rogue-env, so
  # runtime hooks (which source the file, not the installer's env) fail-open.
  if [ "$NON_INTERACTIVE" = "1" ]; then
    if [ -n "$cur_key" ]; then
      ROGUE_API_KEY="$cur_key"
      ROGUE_ACTOR_EMAIL="$def_email"
      ROGUE_ACTOR_NAME="$def_name"
      write_env_file
      note "API key configured (${C_DIM}$(key_hint "$cur_key")${C_RESET})"
    else
      note "No API key set and running non-interactively — skipping."
      note "Run ${C_DIM}/rogue:setup${C_RESET} inside Claude Code to connect your key."
    fi
    return
  fi

  # --- API key (interactive). Show a hint of the current key; Enter keeps it. ---
  local key code tries=0 prompt
  if [ -n "$cur_key" ]; then
    prompt="Rogue API key [current: $(key_hint "$cur_key"), Enter to keep]: "
  else
    prompt="Rogue API key: "
  fi
  while :; do
    if ! ask key "$prompt" -s; then
      # No usable terminal — fall back instead of looping.
      if [ -n "$cur_key" ]; then key="$cur_key"; note "No TTY — keeping existing key"; break; fi
      note "No TTY for input — skipping. Run ${C_DIM}/rogue:setup${C_RESET} later."; return
    fi
    if [ -z "$key" ]; then
      [ -n "$cur_key" ] && { key="$cur_key"; note "Keeping existing key"; break; }
      warn "Empty — paste your key from https://app.rogue.security/settings/api-keys"; continue
    fi
    code="$(status_check "$key" "$def_email")"
    case "$code" in
      200)        ok "Key validated${STATUS_ORG:+ — org: $STATUS_ORG}"
                  break ;;
      401|403)    tries=$((tries+1)); warn "Invalid key (HTTP $code)."
                  if [ "$tries" -ge 3 ]; then
                    local yn=""; ask yn "Save it anyway? [y/N]: " || yn=""
                    case "$yn" in [Yy]*) warn "Saving unvalidated key"; break ;; *) die "Aborted." ;; esac
                  fi ;;
      '')         warn "Could not reach $ROGUE_BASE_URL to validate — saving without verification."; break ;;
      *)          warn "Unexpected response (HTTP $code) — saving without verification."; break ;;
    esac
  done
  ROGUE_API_KEY="$key"

  # --- Actor identity (gh-CLI style: show full current/detected, Enter to keep) ---
  # Defaults (def_email/def_name) were resolved above, before key validation.
  local in_email="" in_name=""
  ask in_email "Actor email [${def_email:-none}, Enter to keep]: " || in_email=""
  ask in_name  "Actor name  [${def_name:-none}, Enter to keep]: "  || in_name=""
  ROGUE_ACTOR_EMAIL="${in_email:-$def_email}"
  ROGUE_ACTOR_NAME="${in_name:-$def_name}"

  write_env_file
}

env_quote() { printf "'%s'" "$(printf '%s' "$1" | sed "s/'/'\\\\''/g")"; }

env_preserved() {
  local rc=0
  local kept
  kept="$(grep -Ev \
    -e "^[[:space:]]*(export[[:space:]]+)?($1)[[:space:]]*=" \
    -e '^[[:space:]]*# (Managed by the [Rr]ogue|Delete this file to revoke credentials)' \
    "$ENV_FILE")" || rc=$?
  [ "$rc" -le 1 ] || return 1
  [ -z "$kept" ] || printf '%s\n' "$kept" | tr -d '\r'
}

env_has_break() {
  local nl='
'
  local cr
  cr="$(printf '\r')"
  case "$1" in
    *"$nl"*|*"$cr"*) return 0 ;;
  esac
  return 1
}

write_env_file() {
  local keys="ROGUE_API_KEY|ROGUE_ACTOR_EMAIL|ROGUE_ACTOR_NAME"
  [ "$BASE_URL_EXPLICIT" != "1" ] || keys="$keys|ROGUE_BASE_URL"
  local k v
  for k in ROGUE_API_KEY ROGUE_ACTOR_EMAIL ROGUE_ACTOR_NAME ROGUE_BASE_URL; do
    eval "v=\${$k:-}"
    ! env_has_break "$v" || die "Refusing to write $ENV_FILE: the value for $k contains a line break"
  done
  local tmp="$ENV_FILE.rogue-tmp.$$"
  (
    umask 077
    {
      printf '# Managed by the Rogue plugins. Read by hook subprocesses at runtime.\n' &&
      printf '# Delete this file to revoke credentials.\n' &&
      printf 'export ROGUE_API_KEY=%s\n' "$(env_quote "$ROGUE_API_KEY")" &&
      printf 'export ROGUE_ACTOR_EMAIL=%s\n' "$(env_quote "$ROGUE_ACTOR_EMAIL")" &&
      printf 'export ROGUE_ACTOR_NAME=%s\n' "$(env_quote "$ROGUE_ACTOR_NAME")" &&
      { [ "$BASE_URL_EXPLICIT" != "1" ] || [ "$ROGUE_BASE_URL" = "$ROGUE_BASE_URL_DEFAULT" ] ||
        printf 'export ROGUE_BASE_URL=%s\n' "$(env_quote "$ROGUE_BASE_URL")"; } &&
      { [ ! -f "$ENV_FILE" ] || env_preserved "$keys"; }
    } > "$tmp"
  ) || { rm -f "$tmp"; die "Could not write $ENV_FILE"; }
  mv -f "$tmp" "$ENV_FILE" || { rm -f "$tmp"; die "Could not write $ENV_FILE"; }
  chmod 600 "$ENV_FILE"
  ok "Credentials written to ${C_DIM}$ENV_FILE${C_RESET} (mode 600)"
}

# ── Status badge ──────────────────────────────────────────────────────────────
write_statusline_script() {
  mkdir -p "$(dirname "$STATUSLINE_PATH")" 2>/dev/null
  # Body kept byte-identical with plugins/rogue/scripts/statusline.sh.
  cat > "$STATUSLINE_PATH" <<'BADGE'
#!/usr/bin/env bash
# Rogue Security status badge (installed by install.sh). Status circle then
# teal bracketed label: 🟢 [Rogue Security] configured, 🔴 [Rogue Security] not.
set -u
for f in /etc/rogue/env "$HOME/.rogue-env"; do
  [ -r "$f" ] && . "$f"
done
if [ -n "${ROGUE_API_KEY:-}" ]; then
  dot='🟢'
else
  dot='🔴'
fi
printf '%s \033[38;2;74;176;227m[Rogue Security]\033[0m' "$dot"
BADGE
  chmod 755 "$STATUSLINE_PATH"
}

# Merge the statusLine into settings.json without clobbering other keys.
# Uses node (Claude Code ships it) — avoids jq/python3 which may be absent.
# Exit codes: 0 set, 10 already ours, 20 foreign statusLine exists.
apply_statusline_setting() {
  local sl_cmd="bash \"$STATUSLINE_PATH\""
  node - "$SETTINGS_PATH" "$sl_cmd" "$STATUSLINE_PATH" "$1" <<'NODE'
const fs = require('fs');
const [file, slCmd, slPath, overwrite] = process.argv.slice(2);
let s = {};
try { s = JSON.parse(fs.readFileSync(file, 'utf8') || '{}'); } catch (_) {}
const cur = s.statusLine;
const isOurs = cur && typeof cur.command === 'string' && cur.command.includes(slPath);
if (cur && !isOurs && overwrite !== 'yes') process.exit(20);  // foreign — let caller decide
s.statusLine = { type: 'command', command: slCmd };
fs.mkdirSync(require('path').dirname(file), { recursive: true });
fs.writeFileSync(file, JSON.stringify(s, null, 2) + '\n');
process.exit(isOurs ? 10 : 0);
NODE
}

configure_statusline() {
  if [ "${ROGUE_NO_STATUSLINE:-0}" = "1" ]; then
    note "ROGUE_NO_STATUSLINE=1 — skipping status badge"
    return
  fi
  have_cmd node || { warn "node not found — skipping status badge"; return; }

  write_statusline_script

  apply_statusline_setting "no"
  case "$?" in
    0)  ok "Status badge enabled" ;;
    10) ok "Status badge already configured" ;;
    20)
      if [ "$NON_INTERACTIVE" = "1" ]; then
        warn "An existing statusLine is configured — leaving it untouched."
        note "To use the Rogue badge, set settings.json statusLine.command to: bash \"$STATUSLINE_PATH\""
      else
        local yn; ask yn "A statusLine is already configured. Overwrite it with the Rogue badge? [y/N]: "
        case "$yn" in
          [Yy]*) apply_statusline_setting "yes" && ok "Status badge enabled (replaced existing)" ;;
          *)     note "Kept your existing statusLine. Badge script left at $STATUSLINE_PATH" ;;
        esac
      fi
      ;;
    *)  warn "Could not update settings.json — skipping status badge" ;;
  esac
}

# ── Per-agent installers ──────────────────────────────────────────────────────
# Credentials are written once (shared ~/.rogue-env) by main(); these only do the
# agent-specific marketplace/plugin install.
install_claude() {
  printf '\n%sRogue Security%s — Claude Code\n' "$C_TEAL" "$C_RESET" >&2
  # Claude Code shells out to system git to clone the marketplace. A fresh
  # machine without git makes the clone fail — name it here instead of letting
  # it surface later as a misleading "plugin not found". Hint per-OS.
  if ! have_cmd git; then
    case "$(uname -s 2>/dev/null)" in
      Darwin) die "git not found. Install the Command Line Tools first: xcode-select --install" ;;
      *)      die "git not found. Install it via your package manager (e.g. apt install git, or dnf install git)." ;;
    esac
  fi
  claude_install_plugin
  configure_statusline
}

install_codex() {
  printf '\n%sRogue Security%s — OpenAI Codex\n' "$C_TEAL" "$C_RESET" >&2
  codex_install_plugin
  note "Codex skips untrusted hooks — open ${C_DIM}/hooks${C_RESET} in Codex and trust the Rogue entries once."
}

install_cursor() {
  printf '\n%sRogue Security%s — Cursor\n' "$C_TEAL" "$C_RESET" >&2
  # The Cursor plugin ships dual dispatchers (sh + PowerShell) like Claude/Codex —
  # the matching runtime is the same shell running this installer, so no extra
  # prerequisite check. tar/curl (used in cursor_install_plugin) are assumed present.
  # Non-fatal: a failed Cursor install must not abort the run (see cursor_install_plugin).
  if cursor_install_plugin; then
    note "Fully quit and reopen Cursor, then run ${C_DIM}/rogue:status${C_RESET} to verify."
  fi
}

install_gemini() {
  printf '\n%sRogue Security%s — Gemini CLI\n' "$C_TEAL" "$C_RESET" >&2
  # Non-fatal: a failed Gemini install must not abort the run (see gemini_install_extension).
  if gemini_install_extension; then
    note "Gemini skips untrusted hooks — open ${C_DIM}/hooks${C_RESET} in Gemini CLI and trust the Rogue entries once."
    note "Then restart Gemini CLI and run ${C_DIM}/setup${C_RESET} (if needed) and ${C_DIM}/status${C_RESET} to verify."
  fi
}

install_antigravity() {
  printf '\n%sRogue Security%s — Google Antigravity\n' "$C_TEAL" "$C_RESET" >&2
  # Non-fatal: a failed Antigravity install must not abort the run (see antigravity_install_plugin).
  if antigravity_install_plugin; then
    note "Fully quit and reopen Antigravity, then run ${C_DIM}/rogue:status${C_RESET} to verify."
  fi
}

install_copilot() {
  printf '\n%sRogue Security%s — GitHub Copilot CLI\n' "$C_TEAL" "$C_RESET" >&2
  copilot_install_plugin
  note "Copilot skips untrusted hooks — open ${C_DIM}/hooks${C_RESET} in Copilot CLI and trust the Rogue entries once."
  # Rogue reaches JetBrains only through Copilot's CLI/Agent provider. The IDE's
  # built-in "Local" agent runs its OWN hook engine, which reads only
  # <git-root>/.github/hooks/**/*.json and refuses plugin-provided hooks — zero
  # coverage. No hook ever runs there, so nothing inside the IDE can warn about
  # it; the installer is the only place we still have a voice.
  if [ -d "$HOME/Library/Application Support/JetBrains" ] || [ -d "$HOME/.config/JetBrains" ]; then
    note "In JetBrains, pick Copilot's ${C_DIM}CLI/Agent${C_RESET} provider — the built-in ${C_DIM}Local${C_RESET} agent ignores installed plugins, so Rogue would see nothing."
  fi
  note "Then restart Copilot CLI and run ${C_DIM}/rogue:status${C_RESET} to verify."
}

# ── CLI flags ─────────────────────────────────────────────────────────────────
# Accepts `--flag=value` and `--flag value`. Sets the same globals the env knobs
# do, so the rest of the script is flag-agnostic. CLI flags override env vars.
usage() { sed -n '2,42p' "$0" 2>/dev/null | sed 's/^# \{0,1\}//'; }

parse_args() {
  while [ "$#" -gt 0 ]; do
    local arg="$1" val=""
    case "$arg" in
      --*=*) val="${arg#*=}"; arg="${arg%%=*}" ;;
    esac
    case "$arg" in
      --api-key)         [ -n "$val" ] || { val="$2"; shift; }; ROGUE_API_KEY="$val" ;;
      --actor-email)     [ -n "$val" ] || { val="$2"; shift; }; ROGUE_ACTOR_EMAIL="$val" ;;
      --actor-name)      [ -n "$val" ] || { val="$2"; shift; }; ROGUE_ACTOR_NAME="$val" ;;
      --plugin-repo)     [ -n "$val" ] || { val="$2"; shift; }; ROGUE_PLUGIN_REPO="$val" ;;
      --base-url)        [ -n "$val" ] || { val="$2"; shift; }; ROGUE_BASE_URL="$val"; BASE_URL_EXPLICIT=1 ;;
      --claude)          WANT="$WANT claude" ;;
      --codex)           WANT="$WANT codex" ;;
      --cursor)          WANT="$WANT cursor" ;;
      --gemini)          WANT="$WANT gemini" ;;
      --copilot)         WANT="$WANT copilot" ;;
      --antigravity)     WANT="$WANT antigravity" ;;
      --non-interactive) NON_INTERACTIVE=1 ;;
      --no-statusline)   ROGUE_NO_STATUSLINE=1 ;;
      -h|--help)         usage; exit 0 ;;
      *)                 die "Unknown argument: $arg (try --help)" ;;
    esac
    shift
  done
}

# ── Dispatch: detect installed agents, install for each ───────────────────────
main() {
  parse_args "$@"

  if [ -n "$WANT" ]; then
    # Explicit selection (--claude/--codex/--cursor): install exactly these. A CLI
    # agent still needs its binary (can't add a marketplace without it); Cursor is a
    # plain file copy, so it installs regardless of detection.
    agents="$WANT"
    for a in $agents; do
      case "$a" in
        claude) have_cmd claude || die "--claude requested but the 'claude' CLI is not on PATH. Install Claude Code (https://claude.com/code) first." ;;
        codex)  have_cmd codex  || die "--codex requested but the 'codex' CLI is not on PATH. Install OpenAI Codex first." ;;
        cursor) : ;;
        gemini) have_cmd gemini || die "--gemini requested but the 'gemini' CLI is not on PATH. Install Gemini CLI (https://geminicli.com) first." ;;
        copilot) have_cmd copilot || die "--copilot requested but the 'copilot' CLI is not on PATH. Install GitHub Copilot CLI (https://github.com/github/copilot-cli) first." ;;
        antigravity)
          { have_cmd agy || [ -d "$HOME/.gemini/antigravity" ] || [ -d "$HOME/.gemini/antigravity-ide" ] || [ -d "$HOME/.gemini/antigravity-cli" ]; } \
            || die "--antigravity requested but no Antigravity install was detected (looked for: agy CLI, ~/.gemini/antigravity*). Install Google Antigravity first." ;;
      esac
    done
  else
    # Auto-detect every supported agent. claude/codex ship a CLI on PATH; Cursor's
    # `cursor` shell command is opt-in, so also accept the presence of ~/.cursor.
    # Antigravity has no `antigravity` binary on PATH — detect the `agy` CLI or its
    # data dirs under ~/.gemini (IDE and/or manual-CLI installs).
    agents=""
    have_cmd claude && agents="$agents claude"
    have_cmd codex  && agents="$agents codex"
    { have_cmd cursor || [ -d "$HOME/.cursor" ]; } && agents="$agents cursor"
    have_cmd gemini && agents="$agents gemini"
    have_cmd copilot && agents="$agents copilot"
    { have_cmd agy || [ -d "$HOME/.gemini/antigravity" ] || [ -d "$HOME/.gemini/antigravity-ide" ] || [ -d "$HOME/.gemini/antigravity-cli" ]; } && agents="$agents antigravity"
    [ -n "$agents" ] || die "No supported coding agent found (looked for: claude, codex, cursor, gemini, copilot, antigravity). Install Claude Code (https://claude.com/code), OpenAI Codex, Cursor (https://cursor.com), Gemini CLI (https://geminicli.com), GitHub Copilot CLI (https://github.com/github/copilot-cli), or Google Antigravity first."
  fi

  # Credentials once — every plugin reads the shared ~/.rogue-env.
  configure_credentials

  for a in $agents; do
    case "$a" in
      claude)      install_claude ;;
      codex)       install_codex ;;
      cursor)      install_cursor ;;
      gemini)      install_gemini ;;
      copilot)     install_copilot ;;
      antigravity) install_antigravity ;;
    esac
  done

  printf '\n' >&2
  ok "Done. ${C_TEAL}Rogue Security${C_RESET} 🟢 (${agents# })"
  note "Open a new session in each agent, then run ${C_DIM}/rogue:status${C_RESET} to verify."
}

[ -n "${ROGUE_INSTALL_LIB_ONLY:-}" ] || main "$@"
