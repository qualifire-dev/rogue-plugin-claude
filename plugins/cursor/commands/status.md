---
name: status
description: Check Rogue Security AIDR connection, active rulesets, and configuration
---

# Rogue Security Status

Verify the current Rogue Security integration. Sources credentials in order: `/etc/rogue/env` (MDM), `~/.rogue-env` (per-user).

## Step 1: Source credentials and report what was found

```bash
[ -r /etc/rogue/env ]     && . /etc/rogue/env     && echo "  /etc/rogue/env  (MDM)"
[ -r "$HOME/.rogue-env" ] && . "$HOME/.rogue-env" && echo "  $HOME/.rogue-env  (per-user)"
[ -n "$ROGUE_API_KEY" ] && echo "API key resolved: ...${ROGUE_API_KEY: -4}" || { echo "API key: not resolved"; }
```

If `ROGUE_API_KEY` is empty, stop and tell the user to run `/rogue:setup`.

## Step 2: Ping the API

```bash
. "$HOME/.rogue-env" 2>/dev/null; [ -r /etc/rogue/env ] && . /etc/rogue/env
curl -s -w "\n%{http_code}" -H "x-rogue-api-key: $ROGUE_API_KEY" \
  "${ROGUE_BASE_URL:-https://api.rogue.security}/api/v1/hooks/ping"
```

## Step 3: Fetch active config

```bash
. "$HOME/.rogue-env" 2>/dev/null; [ -r /etc/rogue/env ] && . /etc/rogue/env
curl -s -H "x-rogue-api-key: $ROGUE_API_KEY" \
  "${ROGUE_BASE_URL:-https://api.rogue.security}/api/v1/hooks/config"
```

Parse the JSON and show: mode (enforce/monitor), fail-open setting, active rulesets.

## Step 4: Show identity + recent hook activity

```bash
. "$HOME/.rogue-env" 2>/dev/null
echo "Actor email: ${ROGUE_ACTOR_EMAIL:-(unset)}"
echo "Actor name:  ${ROGUE_ACTOR_NAME:-(unset)}"
echo "--- recent hook activity ---"
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
  log="$dir/cursor.log"
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
  $logPath = Join-Path $logDir 'cursor.log'
}
"Log: $logPath"
Get-Content -Tail 20 $logPath -ErrorAction SilentlyContinue
```

A `ROGUE_LOG_DIR` set in `~/.rogue-env` or `C:\ProgramData\rogue\env` also wins over
the default — check those files if this shows no activity on a healthy connection.

Each Rogue plugin logs to its **own** file under `~/.rogue/logs/`, so this reads
`cursor.log` only — a sibling agent's activity lives in `claude.log`,
`codex.log`, and so on. `<file>.1` is the previous rotation, if any. An empty or
missing file with a healthy connection just means no events have fired yet.

## Step 5: Summary

Combine credential sources, connection status, and identity into one clean summary. If everything looks good, confirm the integration is active. Block/allow/ask policy is managed server-side — direct the user to the dashboard to view or change it.

## Step 6: False-positive escape hatch

Tell the user: prepend `rgx!` to a prompt to allow it through and mark the previous detection as a false positive in the dashboard.
