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
tail -n 20 "${ROGUE_LOG_FILE:-${ROGUE_LOG_DIR:-$HOME/.rogue/logs}/cursor.log}" 2>/dev/null || echo "(no hook log yet)"
```

On Windows, resolve the same precedence before reading:

```powershell
$logPath = $env:ROGUE_LOG_FILE
if (-not $logPath) {
  $logDir = $env:ROGUE_LOG_DIR
  if (-not $logDir) { $logDir = Join-Path (Join-Path $env:USERPROFILE '.rogue') 'logs' }
  $logPath = Join-Path $logDir 'cursor.log'
}
Get-Content -Tail 20 $logPath -ErrorAction SilentlyContinue
```

A `ROGUE_LOG_DIR` set in `~/.rogue-env` or `C:\ProgramData\rogue\env` also wins over
the default — check those files if this shows no activity on a healthy connection.

Each Rogue plugin logs to its **own** file under `~/.rogue/logs/`, so this reads
`cursor.log` only — a sibling agent's activity lives in `claude.log`,
`codex.log`, and so on. `<file>.1` is the previous rotation, if any. An empty or
missing file with a healthy connection just means no events have fired yet.

### Upload the log to Rogue support

**Only run this if the user asks for it, or asks for help with a problem that
needs the log read.** It uploads this machine's hook log to Rogue, where a
support engineer can read it without an endpoint agent on the box.

This normally needs no action: the log ships by itself in the background at
session start, at most once every 15 minutes per file, resuming from wherever the
last upload finished. Run it by hand only to push the newest lines *now*.

**Uploading is off by default right now.** The receiving route is not deployed yet,
so a background run makes no request at all unless `ROGUE_SHIP_LOGS=1` is set — which
is why every command below sets it explicitly. Once the route is live the default
flips and the paragraph above applies unchanged.

- macOS / Linux:
```bash
ROGUE_SHIP_LOGS=1 ROGUE_SHIP_MIN_INTERVAL=0 ROGUE_DEBUG=1 sh "${CURSOR_PLUGIN_ROOT:-$HOME/.cursor/plugins/local/rogue}/scripts/ship-logs.sh"
```
- Windows (PowerShell):
```powershell
$root = $env:CURSOR_PLUGIN_ROOT
if (-not $root) { $root = Join-Path $env:USERPROFILE '.cursor\plugins\local\rogue' }
$env:ROGUE_SHIP_LOGS = '1'; $env:ROGUE_SHIP_MIN_INTERVAL = '0'; $env:ROGUE_DEBUG = '1'
$env:ROGUE_SHIPPER_SCRIPT = Join-Path $root 'scripts\ship-logs.ps1'
$encoded = [Convert]::ToBase64String([System.Text.Encoding]::Unicode.GetBytes(
  '& ([scriptblock]::Create((Get-Content -Raw -LiteralPath $env:ROGUE_SHIPPER_SCRIPT)))'))
Start-Process -FilePath 'powershell' -NoNewWindow -Wait `
  -ArgumentList '-NoProfile', '-NonInteractive', '-EncodedCommand', $encoded
```

**A child process, never in-process.** `ship-logs.ps1` ends in `exit 0`, so
loading it into the current session would terminate *that* session rather than
the shipper. The script path travels as an environment variable and the command
itself is a constant, so a path containing a quote cannot alter it;
`-EncodedCommand` because `-ArgumentList` quoting is unreliable on Windows
PowerShell 5.1. Same shape `hook.ps1` uses to start the shipper.

The explicit fallback path matters here: `CURSOR_PLUGIN_ROOT` is set for hook
subprocesses, but a slash command runs in the agent's own shell, where it may be
absent. `~/.cursor/plugins/local/rogue` is where the one-line installer puts the
plugin; a Team Marketplace install lives elsewhere, so check `~/.cursor/plugins/`
if that path does not exist.

Run with **no arguments**, which is the support form: it uploads *every* agent's
log in the log directory, not just `cursor.log`. Each line is attributed by its
own `provider=` token, so a mixed upload is still filed per agent.

`ROGUE_SHIP_LOGS=1` opts this run in while the default is off;
`ROGUE_SHIP_MIN_INTERVAL=0` waives the 15-minute throttle for this one run;
`ROGUE_DEBUG=1` prints one line per upload. Report what it prints. Expect **no
output at all** when everything already shipped — that is success. Nothing is
re-sent, because the upload resumes from a stored byte offset that only advances
on a confirmed 2xx.

Report failures as-is rather than retrying: `http=401` is a bad API key
(`/rogue:setup`), `http=000` is a network or proxy problem, and
`outcome=skip reason=no-actor` means identity is unresolved. `ROGUE_SHIP_LOGS=0`
in any env file keeps uploading off even with the flag above,
and stays off after the default flips.

## Step 5: Summary

Combine credential sources, connection status, and identity into one clean summary. If everything looks good, confirm the integration is active. Block/allow/ask policy is managed server-side — direct the user to the dashboard to view or change it.

## Step 6: False-positive escape hatch

Tell the user: prepend `rgx!` to a prompt to allow it through and mark the previous detection as a false positive in the dashboard.
