---
description: Check Rogue Security AIDR connection status, active rulesets, and configuration
---

# Rogue Security Status (Codex)

Check the current status of the Rogue Security AIDR integration. The plugin hooks
source credentials from three locations in order (later wins): the plugin's bundled
`env` (managed installs), `/etc/rogue/env` (MDM-provisioned), and `~/.rogue-env`
(per-user setup).

The commands below are bash (macOS/Linux). **On Windows**, run the PowerShell
equivalents: read the key from `%USERPROFILE%\.rogue-env` (and
`C:\ProgramData\rogue\env` for MDM), then hit the same endpoints with
`Invoke-WebRequest` — e.g.
`Invoke-WebRequest "$($env:ROGUE_BASE_URL ?? 'https://api.rogue.security')/api/v1/hooks/config" -Headers @{ 'x-rogue-api-key' = $ROGUE_API_KEY } -UseBasicParsing`
(use an `if`/`else` for the base-URL default on PowerShell 5.1, which lacks `??`).

## Step 1: Source credentials and report what's found

```bash
cat > /tmp/rogue-source-env.sh <<'EOF'
PLUGIN_ENV=$(find "$HOME/.codex/plugins" -name env -type f -path '*rogue*' 2>/dev/null | head -1)
[ -n "$PLUGIN_ENV" ] && [ -r "$PLUGIN_ENV" ] && . "$PLUGIN_ENV"
[ -r /etc/rogue/env ]              && . /etc/rogue/env
[ -r "$HOME/.rogue-env" ]          && . "$HOME/.rogue-env"
EOF
chmod +x /tmp/rogue-source-env.sh

. /tmp/rogue-source-env.sh
echo "Credential sources detected:"
PLUGIN_ENV=$(find "$HOME/.codex/plugins" -name env -type f -path '*rogue*' 2>/dev/null | head -1)
[ -n "$PLUGIN_ENV" ] && echo "  $PLUGIN_ENV  (plugin bundle)"
[ -r /etc/rogue/env ]     && echo "  /etc/rogue/env  (MDM)"
[ -r "$HOME/.rogue-env" ] && echo "  $HOME/.rogue-env  (per-user)"
[ -z "$PLUGIN_ENV" ] && [ ! -r /etc/rogue/env ] && [ ! -r "$HOME/.rogue-env" ] && echo "  (none)"
[ -n "$ROGUE_API_KEY" ] && echo "API key resolved: ...${ROGUE_API_KEY: -4}" || echo "API key: not resolved"
```

If no sources are found OR `ROGUE_API_KEY` is empty: individual users run
`/rogue:setup`; managed users contact their security admin. Stop here in that case.

## Step 2: Test connection + register heartbeat

```bash
. /tmp/rogue-source-env.sh
PJ=$(find "$HOME/.codex/plugins" -path '*rogue*/.codex-plugin/plugin.json' 2>/dev/null | head -1)
VER=$(grep -oE '"version"[[:space:]]*:[[:space:]]*"[0-9][^"]*"' "$PJ" 2>/dev/null | head -1 | grep -oE '[0-9]+\.[0-9]+\.[0-9]+')
SURFACE="${ROGUE_CODEX_SURFACE:-codex_cli}"
# Escape backslash + double-quote so an actor name/email with a " or \ (from git
# config) can't produce invalid JSON — mirrors scripts/heartbeat.sh.
esc() { printf '%s' "$1" | sed -e 's/\\/\\\\/g' -e 's/"/\\"/g'; }
curl -s -w "\n%{http_code}" -X POST \
  "${ROGUE_BASE_URL:-https://api.rogue.security}/api/v1/hooks/status" \
  -H "x-rogue-api-key: $ROGUE_API_KEY" \
  -H "Content-Type: application/json" \
  -d "{\"agent_family\":\"openai\",\"agent\":\"$SURFACE\",\"version\":\"${VER:-unknown}\",\"host\":\"$(esc "$(hostname)")\",\"actor_email\":\"$(esc "${ROGUE_ACTOR_EMAIL:-}")\",\"actor_name\":\"$(esc "${ROGUE_ACTOR_NAME:-}")\"}"
```

Report from the JSON response (HTTP 200 = connected): organization name, running
vs latest version, and whether `update_available` is `true`. On HTTP 401 the key
is invalid; no response → check network reachability to `api.rogue.security`.

## Step 3: Fetch configuration

```bash
. /tmp/rogue-source-env.sh
curl -s -H "x-rogue-api-key: $ROGUE_API_KEY" \
  "${ROGUE_BASE_URL:-https://api.rogue.security}/api/v1/hooks/config"
```

Parse and display: **Mode** (`settings.mode`), **Fail-open** (`settings.failOpen`),
and each **ruleset** in `rulesets` (name, category, mode, severity).

## Step 4: Show the recent hook log

Each Rogue plugin logs to its **own** file under `~/.rogue/logs/`, so this reads
`codex.log` only — a sibling agent's activity lives in `claude.log`, `cursor.log`,
and so on. `<file>.1` is the previous rotation, if any.

```bash
# Same precedence as the dispatcher: the env files first (system, then per-user),
# with the process environment winning over both. Read with sed, never by
# sourcing - a status command must not execute an env file. Reading only
# $ROGUE_LOG_* would report "no activity" on exactly the machines that relocate
# their logs by policy, which are the ones support is called about.
rogue_log_var() {
  v=$(sed -n "s/^[[:space:]]*\(export[[:space:]][[:space:]]*\)\{0,1\}$1=//p" \
        /etc/rogue/env "$HOME/.rogue-env" 2>/dev/null | tail -1 | sed "s/^['\"]//;s/['\"]$//")
  eval "p=\${$1:-}"
  [ -n "$p" ] && v=$p
  printf '%s' "$v"
}
log=$(rogue_log_var ROGUE_LOG_FILE)
if [ -z "$log" ]; then
  dir=$(rogue_log_var ROGUE_LOG_DIR)
  [ -n "$dir" ] || dir="$HOME/.rogue/logs"
  log="$dir/codex.log"
fi
echo "Log: $log"
tail -n 20 "$log" 2>/dev/null || echo "(no hook log yet)"
```

On Windows, resolve the same precedence before reading:

```powershell
$logCfg = @{}
# Mirror the dispatcher's chain: C:\ProgramData\rogue\env (MDM) then
# %USERPROFILE%\.rogue-env, with the process environment winning over both.
# Parsed with a regex, never executed - a status command must not run an env
# file. Reading only $env: would report "no activity" on exactly the machines
# that relocate their logs by policy, which are the ones support is called about.
foreach ($f in @('C:\ProgramData\rogue\env', (Join-Path $env:USERPROFILE '.rogue-env'))) {
  if (-not (Test-Path -LiteralPath $f)) { continue }
  foreach ($line in (Get-Content -LiteralPath $f)) {
    if ($line -match '^\s*(?:export\s+)?(ROGUE_LOG_FILE|ROGUE_LOG_DIR)=(.+)$') {
      $logCfg[$Matches[1]] = $Matches[2].Trim() -replace "^'(.*)'$",'$1' -replace '^"(.*)"$','$1'
    }
  }
}
foreach ($v in 'ROGUE_LOG_FILE','ROGUE_LOG_DIR') {
  $pv = [Environment]::GetEnvironmentVariable($v)
  if ($pv) { $logCfg[$v] = $pv }
}
$logPath = $logCfg['ROGUE_LOG_FILE']
if (-not $logPath) {
  $logDir = $logCfg['ROGUE_LOG_DIR']
  if (-not $logDir) { $logDir = Join-Path (Join-Path $env:USERPROFILE '.rogue') 'logs' }
  $logPath = Join-Path $logDir 'codex.log'
}
"Log: $logPath"
Get-Content -Tail 20 $logPath -ErrorAction SilentlyContinue
```

A `ROGUE_LOG_DIR` set in `~/.rogue-env` or `C:\ProgramData\rogue\env` also wins over
the default — check those files if this shows no activity on a healthy connection.

## Step 5: Confirm hooks are trusted

Remind the user that Codex skips untrusted command hooks. If no events are showing
up in the dashboard, open `/hooks` in Codex and trust the Rogue entries.

## Step 6: Summary

Present a clean summary: credential sources, connection status, mode + ruleset
count, actor identity (`${ROGUE_ACTOR_EMAIL}` / `${ROGUE_ACTOR_NAME}`).

## Step 7: False-positive escape hatch

> **Was a prompt blocked by mistake?** Prepend `rgx!` to your next prompt and
> resubmit. Rogue allows that one prompt and marks the previous detection as a
> false positive. The override is per-prompt only.
