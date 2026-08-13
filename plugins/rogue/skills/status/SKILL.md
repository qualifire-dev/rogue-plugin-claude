---
description: Check Rogue Security AIDR connection status, active rulesets, and configuration
---

# Rogue Security Status

Check the current status of the Rogue Security AIDR integration. The plugin hooks
source credentials from three locations in order (later wins): the plugin's bundled
`env` (managed installs), `/etc/rogue/env` (MDM-provisioned), and `~/.rogue-env`
(per-user setup). This command checks all three so it works for managed, MDM, and
individual deployments.

**Pick the command variant for the user's OS.** The steps below use **macOS / Linux (bash)** commands. On **native Windows (no WSL)**, use the PowerShell equivalents in the "Windows (PowerShell)" block at the end of this command instead — the credential files there are `C:\ProgramData\rogue\env` (MDM) and `%USERPROFILE%\.rogue-env` (per-user), and the plugin bundle `env` lives under `$env:USERPROFILE\.claude\plugins`.

## Step 1: Write a credential-source helper and report what's found

Each Bash invocation runs in its own subshell, so steps re-source the chain via a
helper written to `/tmp/`:

```bash
cat > /tmp/rogue-source-env.sh <<'EOF'
PLUGIN_ENV=$(find "$HOME/.claude/plugins" -name env -type f -path '*rogue*' 2>/dev/null | head -1)
[ -n "$PLUGIN_ENV" ] && [ -r "$PLUGIN_ENV" ] && . "$PLUGIN_ENV"
[ -r /etc/rogue/env ]              && . /etc/rogue/env
[ -r "$HOME/.rogue-env" ]          && . "$HOME/.rogue-env"
EOF
chmod +x /tmp/rogue-source-env.sh

# Report which sources contributed
. /tmp/rogue-source-env.sh
echo "Credential sources detected:"
PLUGIN_ENV=$(find "$HOME/.claude/plugins" -name env -type f -path '*rogue*' 2>/dev/null | head -1)
[ -n "$PLUGIN_ENV" ] && echo "  $PLUGIN_ENV  (plugin bundle)"
[ -r /etc/rogue/env ]     && echo "  /etc/rogue/env  (MDM)"
[ -r "$HOME/.rogue-env" ] && echo "  $HOME/.rogue-env  (per-user)"
[ -z "$PLUGIN_ENV" ] && [ ! -r /etc/rogue/env ] && [ ! -r "$HOME/.rogue-env" ] && echo "  (none)"

# Sanity check the resolved key
[ -n "$ROGUE_API_KEY" ] && echo "API key resolved: ...${ROGUE_API_KEY: -4}" || echo "API key: not resolved"
```

If no sources are found OR `ROGUE_API_KEY` is empty after sourcing:

- **Managed deployment users**: contact your security admin — either the plugin
  didn't deploy (Claude management UI) or the MDM script didn't run.
- **Individual users**: run `/rogue:setup` to configure `~/.rogue-env`.

Stop and don't proceed past this step in either of those cases.

## Step 2: Test connection + register heartbeat

Hit the status endpoint with the resolved key. This validates the key, registers
this install in the dashboard's Coding Agents roster, and reports whether a newer
plugin version exists. The plugin version is read from the manifest without
`python3` (absent on a fresh macOS):

```bash
. /tmp/rogue-source-env.sh
PJ=$(find "$HOME/.claude/plugins" -path '*rogue*/.claude-plugin/plugin.json' 2>/dev/null | head -1)
VER=$(grep -oE '"version"[[:space:]]*:[[:space:]]*"[0-9][^"]*"' "$PJ" 2>/dev/null | head -1 | grep -oE '[0-9]+\.[0-9]+\.[0-9]+')
case "$(printf '%s' "${CLAUDE_CODE_ENTRYPOINT:-}" | tr '[:upper:]' '[:lower:]')" in
  *cowork*)  AGENT="Claude Cowork" ;;
  *desktop*) AGENT="Claude Code - Desktop" ;;
  *)         AGENT="Claude Code - CLI" ;;
esac
esc() { printf '%s' "$1" | sed -e 's/\\/\\\\/g' -e 's/"/\\"/g'; }
curl -s -w "\n%{http_code}" -X POST \
  "${ROGUE_BASE_URL:-https://api.rogue.security}/api/v1/hooks/status" \
  -H "x-rogue-api-key: $ROGUE_API_KEY" \
  -H "Content-Type: application/json" \
  -d "{\"agent_family\":\"claude\",\"agent\":\"$(esc "$AGENT")\",\"version\":\"${VER:-unknown}\",\"host\":\"$(esc "$(hostname)")\",\"actor_email\":\"$(esc "${ROGUE_ACTOR_EMAIL:-}")\",\"actor_name\":\"$(esc "${ROGUE_ACTOR_NAME:-}")\"}"
```

**A POST with a JSON body, not a GET with `x-rogue-agent-*` headers.** The route is
`POST /hooks/status` and it validates `agent_family` from the body; the header form
this command used to send was the pre-`/hooks/status` contract, so it reported a
failure on a perfectly valid key. `heartbeat.sh` has always sent the body form — this
is now the same shape, values escaped the same way, so a `/rogue:status` result and
the background heartbeat can no longer disagree.

Report from the JSON response (HTTP 200 = connected):

- **Connected** — `connected: true`
- **Organization** — `organization.name`
- **Version** — `agent.version` (running) vs `agent.latest_version`; if
  `agent.update_available` is `true`, note that auto-update will pick it up.

On failure suggest:

- HTTP 401 → key invalid. Compare the resolved key tail (Step 1) against the
  [API keys dashboard](https://app.rogue.security/settings/api-keys); the
  precedence chain may be picking up a stale source — check Step 1's list.
- HTTP 400 → the JSON body was malformed or `agent_family` was missing; print the
  body the command sent and compare it with `scripts/heartbeat.sh`.
- HTTP 404 → the URL is wrong (a stale `ROGUE_BASE_URL`, or a path other than
  `/api/v1/hooks/status`), not a credential problem.
- No response → confirm network reachability to `api.rogue.security` (or `${ROGUE_BASE_URL}`).

## Step 3: Fetch configuration

If the connection succeeded, fetch the active config:

```bash
. /tmp/rogue-source-env.sh
curl -s -H "x-rogue-api-key: $ROGUE_API_KEY" \
  "${ROGUE_BASE_URL:-https://api.rogue.security}/api/v1/hooks/config"
```

Parse the JSON response and display in a clear format:

- **Mode**: `settings.mode` (enforce or monitor)
- **Fail-open**: `settings.failOpen`
- **Active rulesets**: For each ruleset in `rulesets`, show name, category, mode
  (block/monitor), and severity

## Step 4: Show identity + recent hook activity

```bash
. /tmp/rogue-source-env.sh
echo "Actor email: ${ROGUE_ACTOR_EMAIL:-(unset)}"
echo "Actor name:  ${ROGUE_ACTOR_NAME:-(unset)}"
echo "--- recent hook activity ---"
tail -n 20 "${ROGUE_LOG_FILE:-${ROGUE_LOG_DIR:-$HOME/.rogue/logs}/claude.log}" 2>/dev/null || echo "(no hook log yet)"
```

Each Rogue plugin logs to its **own** file under `~/.rogue/logs/`, so this reads
`claude.log` only — a sibling agent's activity lives in `codex.log`,
`cursor.log`, and so on. `<file>.1` is the previous rotation, if any. An empty or
missing file with a healthy connection just means no events have fired yet.

If either is unset:

- **Managed deployment**: the MDM script (`mdm-provision-actor.sh`) hasn't run
  yet or ran with empty placeholders. Events are POSTing with blank actor
  headers until MDM provisioning completes. Force an enforcement run on your
  MDM (Kandji "Run library item now", `sudo jamf policy`).
- **Individual user**: re-run `/rogue:setup` to populate identity.

### Upload the log to Rogue support

**Only run this if the user asks for it, or asks for help with a problem that
needs the log read.** It uploads this machine's hook log to Rogue, where a
support engineer can read it without an endpoint agent on the box.

This normally needs no action at all: the log ships by itself in the background
at session start, at most once every 15 minutes per file, resuming from wherever
the last upload finished. Run it by hand only to push the newest lines *now*.

**Uploading is off by default right now.** The receiving route is not deployed yet,
so a background run makes no request at all unless `ROGUE_SHIP_LOGS=1` is set — which
is why every command below sets it explicitly. Once the route is live the default
flips and the paragraph above applies unchanged.

- macOS / Linux:
```bash
# CLAUDE_PLUGIN_ROOT is exported to HOOK processes, not to this shell, so the
# script is located on disk the same way Step 1 locates the bundled env file.
SHIP="${CLAUDE_PLUGIN_ROOT:+$CLAUDE_PLUGIN_ROOT/scripts/ship-logs.sh}"
if [ ! -r "$SHIP" ]; then
  ROOT=$(grep -o '"installPath": *"[^"]*"' "$HOME/.claude/plugins/installed_plugins.json" 2>/dev/null \
           | sed 's/.*"\(\/[^"]*\)"$/\1/' | grep '/rogue/' | tail -1)
  SHIP="${ROOT:+$ROOT/scripts/ship-logs.sh}"
fi
[ -r "$SHIP" ] || SHIP=$(ls -t "$HOME"/.claude/plugins/cache/*/rogue*/*/scripts/ship-logs.sh 2>/dev/null | head -1)
if [ -r "$SHIP" ]; then
  ROGUE_SHIP_LOGS=1 ROGUE_SHIP_MIN_INTERVAL=0 ROGUE_DEBUG=1 sh "$SHIP"
else
  echo "ship-logs.sh not found - list ~/.claude/plugins/cache/*/rogue*/ and report what is there"
fi
```
- Windows (PowerShell):
```powershell
$ship = $null
if ($env:CLAUDE_PLUGIN_ROOT) {
  $candidate = Join-Path $env:CLAUDE_PLUGIN_ROOT 'scripts\ship-logs.ps1'
  if (Test-Path -LiteralPath $candidate) { $ship = $candidate }
}
if (-not $ship) {
  $ship = Get-ChildItem (Join-Path $env:USERPROFILE '.claude\plugins') -Recurse -Filter ship-logs.ps1 -File -ErrorAction SilentlyContinue |
    Where-Object { $_.FullName -like '*rogue*' } | Sort-Object LastWriteTime -Descending |
    Select-Object -First 1 -ExpandProperty FullName
}
if (-not $ship) { 'ship-logs.ps1 not found - list %USERPROFILE%\.claude\plugins and report what is there' }
else {
  $env:ROGUE_SHIP_LOGS = '1'; $env:ROGUE_SHIP_MIN_INTERVAL = '0'; $env:ROGUE_DEBUG = '1'
  $env:ROGUE_SHIPPER_SCRIPT = $ship
  $encoded = [Convert]::ToBase64String([System.Text.Encoding]::Unicode.GetBytes(
    '& ([scriptblock]::Create((Get-Content -Raw -LiteralPath $env:ROGUE_SHIPPER_SCRIPT)))'))
  Start-Process -FilePath 'powershell' -NoNewWindow -Wait `
    -ArgumentList '-NoProfile', '-NonInteractive', '-EncodedCommand', $encoded
}
```

**Resolve the script, never assume `CLAUDE_PLUGIN_ROOT`.** That variable is
exported to hook processes only — in the shell this command runs in it is empty,
and `sh "/scripts/ship-logs.sh"` fails silently at exactly the moment support is
trying to collect logs. Three layers, in order: the variable if something did set
it, then the `installPath` recorded in `installed_plugins.json` (authoritative —
it names the version actually installed, and ignores stale cache directories left
by an uninstalled marketplace), then the newest copy under
`~/.claude/plugins/cache/`. **Which copy runs does not matter much**: the support
form takes no arguments, so no plugin root is passed and no per-agent value is
read, and `ship-logs.sh` is byte-identical across all five sh plugins (enforced by
`scripts/sync-shared-scripts.sh --check`). The last layer therefore exists to
survive a change in Claude Code's own bookkeeping file, not to pick a "right" copy.

**A child process, never in-process.** `ship-logs.ps1` ends in `exit 0`, so
loading it into the current session would terminate *that* session — the one
running this command — rather than the shipper. The script path travels as an
environment variable and the command itself is a constant, so a plugin path
containing a quote cannot alter it; `-EncodedCommand` because `-ArgumentList`
quoting is unreliable on Windows PowerShell 5.1. This is the same shape
`heartbeat.ps1` uses to start the shipper in the background.

Run with **no arguments**, which is the support form: it uploads *every* agent's
log found in the log directory, not just this one, which is usually what a
support request needs on a machine with several coding agents. Each line is
attributed by its own `provider=` token, so a mixed upload is still filed per
agent.

`ROGUE_SHIP_LOGS=1` opts this run in while the default is off;
`ROGUE_SHIP_MIN_INTERVAL=0` waives the 15-minute throttle for this one run;
`ROGUE_DEBUG=1` prints one line per upload so there is something to report back.
Report what it prints. Expect **no output at all** when everything already
shipped — that is success, not failure. Nothing is re-sent, because the upload
resumes from a stored byte offset that only advances on a confirmed 2xx.

Report failures as-is rather than retrying: `outcome=fail … http=401` is a bad
API key (`/rogue:setup`), `http=000` is a network or proxy problem, and
`outcome=skip reason=no-actor` means identity is unresolved (see the actor
section above). `ROGUE_SHIP_LOGS=0` in any env file keeps uploading off even
with the flag above, and stays off after the default flips.


## Step 5: Summary

Present a clean summary combining everything:

- Credential sources found (from Step 1)
- Connection status (Step 2)
- Mode + ruleset count (Step 3)
- Identity (Step 4)

If everything looks good, confirm the integration is active.

## Step 6: False-positive escape hatch

After the summary, tell the user:

> **Was a prompt blocked by mistake?** Prepend `rgx!` to your next prompt and
> resubmit. Rogue will allow that one prompt and mark the previous detection as
> a false positive in your dashboard. The override is per-prompt only —
> subsequent prompts go through normal evaluation.

## Windows (PowerShell)

On native Windows (no WSL), run this single block instead of Steps 1–4. It
resolves credentials (later source wins), reports what was found, registers the
heartbeat, and prints the resolved identity:

```powershell
$creds = @{}
$pluginEnv = Get-ChildItem "$env:USERPROFILE\.claude\plugins" -Recurse -Filter env -File -ErrorAction SilentlyContinue |
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
if (-not $key) { 'API key: not resolved — run /rogue:setup'; return }
'API key resolved: ...' + $key.Substring([Math]::Max(0,$key.Length-4))
$base = if ($creds['ROGUE_BASE_URL']) { $creds['ROGUE_BASE_URL'].TrimEnd('/') } else { 'https://api.rogue.security' }
$body = @{ agent_family='claude'; agent='Claude Code - CLI'; host=$env:COMPUTERNAME; actor_email=[string]$creds['ROGUE_ACTOR_EMAIL'] } | ConvertTo-Json -Compress
try {
  $r = Invoke-WebRequest -Uri "$base/api/v1/hooks/status" -Method Post -Headers @{ 'x-rogue-api-key'=$key } -ContentType 'application/json' -Body ([Text.Encoding]::UTF8.GetBytes($body)) -UseBasicParsing -TimeoutSec 10
  "Connected (HTTP $($r.StatusCode)): $($r.Content)"
} catch { "Status check failed: $($_.Exception.Message)" }
"Actor email: $($creds['ROGUE_ACTOR_EMAIL'])"
"Actor name:  $($creds['ROGUE_ACTOR_NAME'])"
'--- recent hook activity ---'
$logPath = $creds['ROGUE_LOG_FILE']
if (-not $logPath) {
  $logDir = $creds['ROGUE_LOG_DIR']
  if (-not $logDir) { $logDir = Join-Path (Join-Path $env:USERPROFILE '.rogue') 'logs' }
  $logPath = Join-Path $logDir 'claude.log'
}
"Log: $logPath"
Get-Content -Tail 20 $logPath -ErrorAction SilentlyContinue
```

Interpret the JSON response and report the same fields as Step 2 (connected,
organization, version/update_available). HTTP 401 → key invalid; no response →
check network reachability to `api.rogue.security`.
