---
name: status
description: Check Rogue Security AIDR connection status, active rulesets, and configuration for GitHub Copilot CLI
---

# Rogue Security Status (GitHub Copilot CLI)

Check the current status of the Rogue Security AIDR integration. The plugin hooks
source credentials from three locations in order (later wins): the plugin's bundled
`env` (managed installs), `/etc/rogue/env` (MDM-provisioned), and `~/.rogue-env`
(per-user setup).

The commands below are bash (macOS/Linux). **On Windows**, run the PowerShell
equivalents: read the key from `%USERPROFILE%\.rogue-env` (and
`C:\ProgramData\rogue\env` for MDM), then hit the same endpoints with
`Invoke-WebRequest` — e.g.
`Invoke-WebRequest "https://api.rogue.security/api/v1/hooks/config" -Headers @{ 'x-rogue-api-key' = $ROGUE_API_KEY } -UseBasicParsing`.

## Step 1: Source credentials and report what's found

```bash
[ -r /etc/rogue/env ]     && . /etc/rogue/env
[ -r "$HOME/.rogue-env" ] && . "$HOME/.rogue-env"
echo "Credential sources detected:"
[ -r /etc/rogue/env ]     && echo "  /etc/rogue/env  (MDM)"
[ -r "$HOME/.rogue-env" ] && echo "  $HOME/.rogue-env  (per-user)"
[ ! -r /etc/rogue/env ] && [ ! -r "$HOME/.rogue-env" ] && echo "  (none)"
[ -n "$ROGUE_API_KEY" ] && echo "API key resolved: ...${ROGUE_API_KEY: -4}" || echo "API key: not resolved"
[ "${ROGUE_IDE_ALERT:-1}" = "0" ] && echo "ROGUE_IDE_ALERT=0  (JetBrains blocked-prompt alert disabled)"
```

If no sources are found OR `ROGUE_API_KEY` is empty: individual users run
`/rogue:setup`; managed users contact their security admin. Stop here in that case.

If `ROGUE_IDE_ALERT=0` is reported, mention it: in JetBrains a blocked prompt
renders nothing, so with the alert off a block looks like the chat silently dying.
Remove the line from `~/.rogue-env` to get the reason back.

## Step 2: Test connection + register heartbeat

```bash
[ -r /etc/rogue/env ]     && . /etc/rogue/env
[ -r "$HOME/.rogue-env" ] && . "$HOME/.rogue-env"
esc() { printf '%s' "$1" | sed -e 's/\\/\\\\/g' -e 's/"/\\"/g'; }
curl -s -w "\n%{http_code}" -X POST \
  "${ROGUE_BASE_URL:-https://api.rogue.security}/api/v1/hooks/status" \
  -H "x-rogue-api-key: $ROGUE_API_KEY" \
  -H "Content-Type: application/json" \
  -d "{\"agent_family\":\"copilot\",\"agent\":\"github_copilot\",\"host\":\"$(esc "$(hostname)")\",\"actor_email\":\"$(esc "${ROGUE_ACTOR_EMAIL:-}")\",\"actor_name\":\"$(esc "${ROGUE_ACTOR_NAME:-}")\"}"
```

Report from the JSON response (HTTP 200 = connected): organization name, running
vs latest version, and whether `update_available` is `true`. On HTTP 401 the key
is invalid; no response → check network reachability to `api.rogue.security`.

## Step 3: Fetch configuration

```bash
[ -r /etc/rogue/env ]     && . /etc/rogue/env
[ -r "$HOME/.rogue-env" ] && . "$HOME/.rogue-env"
curl -s -H "x-rogue-api-key: $ROGUE_API_KEY" \
  "${ROGUE_BASE_URL:-https://api.rogue.security}/api/v1/hooks/config"
```

Parse and display: **Mode** (`settings.mode`), **Fail-open** (`settings.failOpen`),
each **ruleset** in `rulesets` (name, category, mode, severity), and the Copilot
event set under `tools.github_copilot` (`monitoredEvents`, `blockingEvents`).

## Step 4: Show the recent hook log

Each Rogue plugin logs to its **own** file under `~/.rogue/logs/`, so this reads
`copilot.log` only — a sibling agent's activity lives in `claude.log`,
`cursor.log`, and so on. `<file>.1` is the previous rotation, if any.

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
  log="$dir/copilot.log"
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
  $logPath = Join-Path $logDir 'copilot.log'
}
"Log: $logPath"
Get-Content -Tail 20 $logPath -ErrorAction SilentlyContinue
```

## Step 5: Confirm hooks are trusted

Remind the user that Copilot CLI skips untrusted command hooks. If no events are
showing up in the dashboard, open `/hooks` in Copilot CLI and trust the Rogue
entries.

## Step 6: Summary

Present a clean summary: credential sources, connection status, mode + ruleset
count, the Copilot event set, and actor identity (`${ROGUE_ACTOR_EMAIL}` /
`${ROGUE_ACTOR_NAME}`).

## Step 7: False-positive escape hatch

> **Was a prompt blocked by mistake?** Prepend `rgx!` to your next prompt and
> resubmit. Rogue allows that one prompt and marks the previous detection as a
> false positive. The override is per-prompt only.
