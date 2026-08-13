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
tail -n 20 "${ROGUE_LOG_FILE:-${ROGUE_LOG_DIR:-$HOME/.rogue/logs}/codex.log}" 2>/dev/null || echo "(no hook log yet)"
```

On Windows, resolve the same precedence before reading:

```powershell
$logPath = $env:ROGUE_LOG_FILE
if (-not $logPath) {
  $logDir = $env:ROGUE_LOG_DIR
  if (-not $logDir) { $logDir = Join-Path (Join-Path $env:USERPROFILE '.rogue') 'logs' }
  $logPath = Join-Path $logDir 'codex.log'
}
Get-Content -Tail 20 $logPath -ErrorAction SilentlyContinue
```

A `ROGUE_LOG_DIR` set in `~/.rogue-env` or `C:\ProgramData\rogue\env` also wins over
the default — check those files if this shows no activity on a healthy connection.

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
# PLUGIN_ROOT is exported to HOOK processes, not to this shell, so the script is
# located on disk the same way Step 1 locates the bundled env file.
SHIP="${PLUGIN_ROOT:+$PLUGIN_ROOT/scripts/ship-logs.sh}"
[ -r "$SHIP" ] || SHIP=$(find "$HOME/.codex" -type f -name ship-logs.sh -path '*rogue*' 2>/dev/null | head -1)
if [ -r "$SHIP" ]; then
  ROGUE_SHIP_LOGS=1 ROGUE_SHIP_MIN_INTERVAL=0 ROGUE_DEBUG=1 sh "$SHIP"
else
  echo "ship-logs.sh not found - list ~/.codex/plugins/ and report what is there"
fi
```
- Windows (PowerShell):
```powershell
$ship = $null
if ($env:PLUGIN_ROOT) {
  $candidate = Join-Path $env:PLUGIN_ROOT 'scripts\ship-logs.ps1'
  if (Test-Path -LiteralPath $candidate) { $ship = $candidate }
}
if (-not $ship) {
  $ship = Get-ChildItem (Join-Path $env:USERPROFILE '.codex') -Recurse -Filter ship-logs.ps1 -File -ErrorAction SilentlyContinue |
    Where-Object { $_.FullName -like '*rogue*' } | Sort-Object LastWriteTime -Descending |
    Select-Object -First 1 -ExpandProperty FullName
}
if (-not $ship) { 'ship-logs.ps1 not found - list %USERPROFILE%\.codex\plugins and report what is there' }
else {
  $env:ROGUE_SHIP_LOGS = '1'; $env:ROGUE_SHIP_MIN_INTERVAL = '0'; $env:ROGUE_DEBUG = '1'
  $env:ROGUE_SHIPPER_SCRIPT = $ship
  $encoded = [Convert]::ToBase64String([System.Text.Encoding]::Unicode.GetBytes(
    '& ([scriptblock]::Create((Get-Content -Raw -LiteralPath $env:ROGUE_SHIPPER_SCRIPT)))'))
  Start-Process -FilePath 'powershell' -NoNewWindow -Wait `
    -ArgumentList '-NoProfile', '-NonInteractive', '-EncodedCommand', $encoded
}
```

**Resolve the script, never assume `PLUGIN_ROOT`.** That variable is exported to
hook processes only — in the shell a slash command runs in it is empty, and
`sh "/scripts/ship-logs.sh"` fails silently at exactly the moment support is
trying to collect logs. The fallback is the same `find` under `~/.codex` that
Step 1 uses for the bundled env file. **Which copy runs does not matter**: the
support form takes no arguments, so no plugin root is passed and no per-agent
value is read, and `ship-logs.sh` is byte-identical across all five sh plugins
(enforced by `scripts/sync-shared-scripts.sh --check`).

`PLUGIN_ROOT`, never `CLAUDE_PLUGIN_ROOT` — the Codex plugin uses Codex-native
variables only, even though Codex exposes the Claude names as compat shims.

**A child process, never in-process.** `ship-logs.ps1` ends in `exit 0`, so
loading it into the current session would terminate *that* session rather than
the shipper. The script path travels as an environment variable and the command
itself is a constant, so a path containing a quote cannot alter it;
`-EncodedCommand` because `-ArgumentList` quoting is unreliable on Windows
PowerShell 5.1. Same shape `heartbeat.ps1` uses.

Run with **no arguments**, which is the support form: it uploads *every* agent's
log in the log directory, not just `codex.log`. Each line is attributed by its own
`provider=` token, so a mixed upload is still filed per agent.

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
