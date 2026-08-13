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
tail -n 20 "${ROGUE_LOG_FILE:-${ROGUE_LOG_DIR:-$HOME/.rogue/logs}/antigravity.log}" 2>/dev/null || echo "(no hook log yet)"
```
- Windows (PowerShell):
```powershell
# Mirror the dispatcher's precedence: explicit file -> dir override -> default.
# A value set in ~/.rogue-env or C:\ProgramData\rogue\env wins over the default
# too; read it from there if this shows no activity but the connection is healthy.
$logPath = $env:ROGUE_LOG_FILE
if (-not $logPath) {
  $logDir = $env:ROGUE_LOG_DIR
  if (-not $logDir) { $logDir = Join-Path (Join-Path $env:USERPROFILE '.rogue') 'logs' }
  $logPath = Join-Path $logDir 'antigravity.log'
}
"Log: $logPath"
Get-Content -Tail 20 $logPath -ErrorAction SilentlyContinue
```

### Upload the log to Rogue support

**Only run this if the user asks for it, or asks for help with a problem that
needs the log read.** It uploads this machine's hook log to Rogue, where a
support engineer can read it without an endpoint agent on the box.

This normally needs no action: the log ships by itself in the background on the
first model invocation of a turn, at most once every 15 minutes per file, resuming
from wherever the last upload finished. Run it by hand only to push the newest
lines *now*.

**Uploading is off by default right now.** The receiving route is not deployed yet,
so a background run makes no request at all unless `ROGUE_SHIP_LOGS=1` is set — which
is why every command below sets it explicitly. Once the route is live the default
flips and the paragraph above applies unchanged.

- macOS / Linux:
```bash
ROGUE_SHIP_LOGS=1 ROGUE_SHIP_MIN_INTERVAL=0 ROGUE_DEBUG=1 \
  sh "$HOME/.gemini/config/plugins/rogue/scripts/ship-logs.sh"
```
- Windows (PowerShell):
```powershell
$root = Join-Path $env:USERPROFILE '.gemini\config\plugins\rogue'
$env:ROGUE_SHIP_LOGS = '1'; $env:ROGUE_SHIP_MIN_INTERVAL = '0'; $env:ROGUE_DEBUG = '1'
$env:ROGUE_SHIPPER_SCRIPT = Join-Path $root 'scripts\ship-logs.ps1'
$encoded = [Convert]::ToBase64String([System.Text.Encoding]::Unicode.GetBytes(
  '& ([scriptblock]::Create((Get-Content -Raw -LiteralPath $env:ROGUE_SHIPPER_SCRIPT)))'))
Start-Process -FilePath 'powershell' -NoNewWindow -Wait `
  -ArgumentList '-NoProfile', '-NonInteractive', '-EncodedCommand', $encoded
# One run only. The bash form scopes these to a single command; setting them as
# session variables would leave later runs from this session with the 15-minute
# throttle waived and debug output on.
Remove-Item Env:ROGUE_SHIP_LOGS, Env:ROGUE_SHIP_MIN_INTERVAL, Env:ROGUE_DEBUG, Env:ROGUE_SHIPPER_SCRIPT -ErrorAction SilentlyContinue
```

**A child process, never in-process.** `ship-logs.ps1` ends in `exit 0`, so
loading it into the current session would terminate *that* session rather than
the shipper. The script path travels as an environment variable and the command
itself is a constant, so a path containing a quote cannot alter it;
`-EncodedCommand` because `-ArgumentList` quoting is unreliable on Windows
PowerShell 5.1. Same shape `heartbeat.ps1` uses.

`~/.gemini/config/plugins/rogue` is the directory **both** surfaces read — the IDE
and the `agy` CLI — which is where the installer copies the plugin. Antigravity's
own docs name `~/.gemini/antigravity-cli/plugins/`; if the path above does not
exist, try that one.

Run with **no arguments**, which is the support form: it uploads *every* agent's
log in the log directory, not just `antigravity.log`. Each line is attributed by
its own `provider=` token, so a mixed upload is still filed per agent.

`ROGUE_SHIP_LOGS=1` opts this run in while the default is off;
`ROGUE_SHIP_MIN_INTERVAL=0` waives the 15-minute throttle for this one run;
`ROGUE_DEBUG=1` prints one line per upload. Report what it prints. Expect **no
output at all** when everything already shipped — that is success. Nothing is
re-sent, because the upload resumes from a stored byte offset that only advances
on a confirmed 2xx.

Report failures as-is rather than retrying: `http=401` is a bad API key
(`/setup`), `http=000` is a network or proxy problem, and
`outcome=skip reason=no-actor` means identity is unresolved. `ROGUE_SHIP_LOGS=0`
in any env file keeps uploading off even with the flag above,
and stays off after the default flips.

## Step 5: Summary

Present a clean summary: credential sources, connection status, mode + ruleset count, the Antigravity event sets (IDE and CLI surfaces), and actor identity (`${ROGUE_ACTOR_EMAIL}` / `${ROGUE_ACTOR_NAME}`).

## Step 6: False-positive escape hatch

> **Was a prompt blocked by mistake?** Prepend `rgx!` to your next prompt and resubmit. Rogue allows that one prompt and marks the previous detection as a false positive. The override is per-prompt only.
