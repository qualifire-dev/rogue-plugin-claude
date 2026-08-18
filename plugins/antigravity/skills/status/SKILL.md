---
name: status
description: Check Rogue Security AIDR connection status, active rulesets, and configuration for Google Antigravity
---

# Rogue Security Status (Google Antigravity)

Check the current status of the Rogue Security AIDR integration for Google Antigravity (IDE 2.0 and the `agy` CLI). The plugin hooks source credentials from three locations in order (later wins): the plugin's bundled `env` (managed installs), `/etc/rogue/env` (MDM-provisioned), and `~/.rogue-env` (per-user setup). This command checks all three so it works for managed, MDM, and individual deployments.

**Pick the command variant for the user's OS.** Use the **macOS / Linux (bash)** commands by default; use the **Windows (PowerShell)** commands when the user is on native Windows — the credential files there are `C:\ProgramData\rogue\env` (MDM) and `%USERPROFILE%\.rogue-env` (per-user), and the plugin's bundled `env` lives under `%USERPROFILE%\.gemini\config\plugins\rogue`.

## Step 1: Source credentials and report what's found

- macOS / Linux:
```bash
PLUGIN_ENV=$(find "$HOME/.gemini" -maxdepth 5 -type f -name env -path '*rogue*' 2>/dev/null | head -1)
[ -n "$PLUGIN_ENV" ] && [ -r "$PLUGIN_ENV" ] && . "$PLUGIN_ENV"
[ -r /etc/rogue/env ]     && . /etc/rogue/env
[ -r "$HOME/.rogue-env" ] && . "$HOME/.rogue-env"
echo "Credential sources detected:"
[ -n "$PLUGIN_ENV" ] && [ -r "$PLUGIN_ENV" ] && echo "  $PLUGIN_ENV  (plugin bundle)"
[ -r /etc/rogue/env ]     && echo "  /etc/rogue/env  (MDM)"
[ -r "$HOME/.rogue-env" ] && echo "  $HOME/.rogue-env  (per-user)"
[ -n "$ROGUE_API_KEY" ] && echo "API key resolved: ...${ROGUE_API_KEY: -4}" || echo "API key: not resolved"
```
- Windows (PowerShell):
```powershell
$creds = @{}
$pluginEnv = Get-ChildItem "$env:USERPROFILE\.gemini\config\plugins" -Recurse -Filter env -File -ErrorAction SilentlyContinue |
  Where-Object { $_.FullName -like '*rogue*' } | Select-Object -First 1
foreach ($f in @($pluginEnv.FullName, 'C:\ProgramData\rogue\env', "$env:USERPROFILE\.rogue-env")) {
  if (-not $f -or -not (Test-Path -LiteralPath $f)) { continue }
  Write-Host "  $f"
  foreach ($line in (Get-Content -LiteralPath $f)) {
    if ($line -match '^\s*(?:export\s+)?([A-Z_][A-Z0-9_]*)=(.+)$') {
      $creds[$Matches[1]] = $Matches[2].Trim() -replace "^'(.*)'$",'$1' -replace '^"(.*)"$','$1'
    }
  }
}
$key = $creds['ROGUE_API_KEY']
if ($key) { 'API key resolved: ...' + $key.Substring([Math]::Max(0,$key.Length-4)) } else { 'API key: not resolved' }
```

If no sources are found OR `ROGUE_API_KEY` is empty: individual users run `/setup`; managed users contact their security admin. Stop here in that case.

## Step 2: Test connection + register heartbeat

Hit the status endpoint with the resolved key. This validates the key, registers this install in the dashboard's Coding Agents roster, and reports whether a newer plugin version exists. The plugin version is read from the bundled `VERSION` file (Antigravity's `plugin.json` schema has no `version` field):

- macOS / Linux:
```bash
PLUGIN_ENV=$(find "$HOME/.gemini" -maxdepth 5 -type f -name env -path '*rogue*' 2>/dev/null | head -1)
[ -n "$PLUGIN_ENV" ] && [ -r "$PLUGIN_ENV" ] && . "$PLUGIN_ENV"
[ -r /etc/rogue/env ]     && . /etc/rogue/env
[ -r "$HOME/.rogue-env" ] && . "$HOME/.rogue-env"
VF=$(find "$HOME/.gemini" -maxdepth 5 -type f -name VERSION -path '*rogue*' 2>/dev/null | head -1)
VER=$(head -n1 "$VF" 2>/dev/null | tr -d ' \r\n')
AGENT="antigravity_ide"
if command -v agy >/dev/null 2>&1 || [ -d "$HOME/.gemini/antigravity-cli" ]; then
  AGENT="antigravity_cli"
fi
BASE_URL="${ROGUE_BASE_URL%/}"
curl -s -w "\n%{http_code}" -X POST \
  "${BASE_URL:-https://api.rogue.security}/api/v1/hooks/status" \
  -H "x-rogue-api-key: $ROGUE_API_KEY" \
  -H "Content-Type: application/json" \
  -d "{\"agent_family\":\"antigravity\",\"agent\":\"$AGENT\",\"version\":\"${VER:-unknown}\",\"host\":\"$(hostname)\",\"actor_email\":\"${ROGUE_ACTOR_EMAIL:-}\",\"actor_name\":\"${ROGUE_ACTOR_NAME:-}\"}"
```
- Windows (PowerShell):
```powershell
$base = if ($creds['ROGUE_BASE_URL']) { $creds['ROGUE_BASE_URL'].TrimEnd('/') } else { 'https://api.rogue.security' }
$vf = Get-ChildItem "$env:USERPROFILE\.gemini\config\plugins" -Recurse -Filter VERSION -File -ErrorAction SilentlyContinue |
  Where-Object { $_.FullName -like '*rogue*' } | Select-Object -First 1
$ver = if ($vf) { (Get-Content -TotalCount 1 $vf.FullName).Trim() } else { 'unknown' }
$agent = 'antigravity_ide'
$agyCmd = Get-Command agy -ErrorAction SilentlyContinue
$agyCliDir = Join-Path $env:USERPROFILE '.gemini\antigravity-cli'
if ($agyCmd -or (Test-Path -LiteralPath $agyCliDir)) { $agent = 'antigravity_cli' }
$body = @{ agent_family='antigravity'; agent=$agent; version=$ver; host=$env:COMPUTERNAME; actor_email=[string]$creds['ROGUE_ACTOR_EMAIL']; actor_name=[string]$creds['ROGUE_ACTOR_NAME'] } | ConvertTo-Json -Compress
try {
  $r = Invoke-WebRequest -Uri "$base/api/v1/hooks/status" -Method Post -Headers @{ 'x-rogue-api-key'=$key } -ContentType 'application/json' -Body ([Text.Encoding]::UTF8.GetBytes($body)) -UseBasicParsing -TimeoutSec 10
  "Connected (HTTP $($r.StatusCode)): $($r.Content)"
} catch { "Status check failed: $($_.Exception.Message)" }
```

Report from the JSON response (HTTP 200 = connected): organization name, running vs latest version, and whether `update_available` is `true`. On HTTP 401 the key is invalid; no response → check network reachability to `api.rogue.security`.

## Step 3: Fetch configuration

- macOS / Linux:
```bash
PLUGIN_ENV=$(find "$HOME/.gemini" -maxdepth 5 -type f -name env -path '*rogue*' 2>/dev/null | head -1)
[ -n "$PLUGIN_ENV" ] && [ -r "$PLUGIN_ENV" ] && . "$PLUGIN_ENV"
[ -r /etc/rogue/env ]     && . /etc/rogue/env
[ -r "$HOME/.rogue-env" ] && . "$HOME/.rogue-env"
curl -s -H "x-rogue-api-key: $ROGUE_API_KEY" \
  "${ROGUE_BASE_URL:-https://api.rogue.security}/api/v1/hooks/config"
```
- Windows (PowerShell):
```powershell
Invoke-WebRequest -Uri "$base/api/v1/hooks/config" -Headers @{ 'x-rogue-api-key' = $key } -UseBasicParsing | Select-Object -ExpandProperty Content
```

Parse and display: **Mode** (`settings.mode`), **Fail-open** (`settings.failOpen`), each **ruleset** in `rulesets` (name, category, mode, severity), and the Antigravity event sets under `tools.antigravity_ide` and `tools.antigravity_cli` (`monitoredEvents`, `blockingEvents` for each surface).

## Step 4: Show the recent hook log

Each Rogue plugin logs to its **own** file under `~/.rogue/logs/`, so this reads
`antigravity.log` only — a sibling agent's activity lives in `claude.log`,
`cursor.log`, and so on. `<file>.1` is the previous rotation, if any.

- macOS / Linux:
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
  log="$dir/antigravity.log"
fi
echo "Log: $log"
tail -n 20 "$log" 2>/dev/null || echo "(no hook log yet)"
```
- Windows (PowerShell):
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
  $logPath = Join-Path $logDir 'antigravity.log'
}
"Log: $logPath"
Get-Content -Tail 20 $logPath -ErrorAction SilentlyContinue
```

## Step 5: Summary

Present a clean summary: credential sources, connection status, mode + ruleset count, the Antigravity event sets (IDE and CLI surfaces), and actor identity (`${ROGUE_ACTOR_EMAIL}` / `${ROGUE_ACTOR_NAME}`).

## Step 6: False-positive escape hatch

> **Was a prompt blocked by mistake?** Prepend `rgx!` to your next prompt and resubmit. Rogue allows that one prompt and marks the previous detection as a false positive. The override is per-prompt only.
