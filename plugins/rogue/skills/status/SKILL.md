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
# Resolve the actor through the SAME cascade every hook uses, instead of posting
# whatever the env files happen to hold. A bundle compiled before the cascade fix
# pre-seeds ROGUE_ACTOR_* from `git config` at read time, which in a sandbox is
# Anthropic's synthetic "Claude <noreply@anthropic.com>" — posting that raw would
# register a roster row under the wrong actor, and the fingerprint is
# host|actor|family|agent, so it would be a SECOND row for this install.
PLUGIN_ROOT=$(dirname "$(dirname "$PJ")")
if [ -r "$PLUGIN_ROOT/scripts/actor.sh" ]; then
  . "$PLUGIN_ROOT/scripts/actor.sh"
else
  echo "WARNING: actor.sh not found under $PLUGIN_ROOT — reporting raw env values"
fi
# Surface id, mirroring scripts/install-id.sh: a stable snake_case id, not a
# display label, because the backend resolves the latest release from this exact
# value. CLAUDE_CODE_IS_COWORK is checked first — Cowork spawns Claude Code with
# CLAUDE_CODE_ENTRYPOINT=local-agent, so the entrypoint cases alone would file a
# Cowork install under the CLI surface.
if [ -n "${CLAUDE_CODE_IS_COWORK:-}" ]; then
  AGENT="claude_cowork"
else
  case "$(printf '%s' "${CLAUDE_CODE_ENTRYPOINT:-}" | tr '[:upper:]' '[:lower:]')" in
    *cowork*)  AGENT="claude_cowork" ;;
    *desktop*) AGENT="claude_code_desktop" ;;
    *)         AGENT="claude_code" ;;
  esac
fi
# POST a JSON body, exactly as scripts/heartbeat.sh does: /hooks/status is
# registered POST-only and validates body.agent_family, so the old GET with
# x-rogue-agent-* headers could only ever fail. Escape each value so a name or
# host containing " or \ can't break the JSON.
esc() { printf '%s' "$1" | sed -e 's/\\/\\\\/g' -e 's/"/\\"/g'; }
BODY=$(printf '{"agent_family":"claude","agent":"%s","version":"%s","host":"%s","actor_email":"%s","actor_name":"%s"}' \
  "$(esc "$AGENT")" "$(esc "${VER:-unknown}")" "$(esc "$(hostname 2>/dev/null || echo unknown)")" \
  "$(esc "${ROGUE_ACTOR_EMAIL:-}")" "$(esc "${ROGUE_ACTOR_NAME:-}")")
curl -s -w "\n%{http_code}" -X POST \
  "${ROGUE_BASE_URL:-https://api.rogue.security}/api/v1/hooks/status" \
  -H "x-rogue-api-key: $ROGUE_API_KEY" \
  -H "Content-Type: application/json" \
  -d "$BODY"
```

Report from the JSON response (HTTP 200 = connected):

- **Connected** — `connected: true`
- **Organization** — `organization.name`
- **Version** — `agent.version` (running) vs `agent.latest_version`; if
  `agent.update_available` is `true`, note that auto-update will pick it up.

On failure suggest:

- HTTP 401 → key invalid. Compare the resolved key tail (Step 1) against the
  [API keys dashboard](https://app.rogue.security/settings/api-keys); the
  precedence chain may be picking up a stale source — check Step 1's list.
- HTTP 400 → unexpected (the `x-rogue-agent-family` header above should prevent it).
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

## Step 4: Show identity

```bash
. /tmp/rogue-source-env.sh
echo "Actor email: ${ROGUE_ACTOR_EMAIL:-(unset)}"
echo "Actor name:  ${ROGUE_ACTOR_NAME:-(unset)}"
```

If either is unset:

- **Managed deployment**: the MDM script (`mdm-provision-actor.sh`) hasn't run
  yet or ran with empty placeholders. Events are POSTing with blank actor
  headers until MDM provisioning completes. Force an enforcement run on your
  MDM (Kandji "Run library item now", `sudo jamf policy`).
- **Individual user**: re-run `/rogue:setup` to populate identity.

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
$ep = ([string]$env:CLAUDE_CODE_ENTRYPOINT).ToLower()
if ($env:CLAUDE_CODE_IS_COWORK)     { $agent = 'claude_cowork' }
elseif ($ep -like '*cowork*')       { $agent = 'claude_cowork' }
elseif ($ep -like '*desktop*')      { $agent = 'claude_code_desktop' }
else                                { $agent = 'claude_code' }
$pj = Get-ChildItem "$env:USERPROFILE\.claude\plugins" -Recurse -Filter plugin.json -File -ErrorAction SilentlyContinue |
  Where-Object { $_.FullName -like '*rogue*' } | Select-Object -First 1
$ver = 'unknown'
if ($pj) {
  $m = [regex]::Match((Get-Content -Raw -LiteralPath $pj.FullName), '"version"\s*:\s*"([0-9]+\.[0-9]+\.[0-9]+)')
  if ($m.Success) { $ver = $m.Groups[1].Value }
}
# Resolve the actor through hook.ps1's own screen rather than trusting the env
# files. A bundle compiled before the cascade fix pre-seeds ROGUE_ACTOR_* from
# `git config` at read time, which in a sandbox is Anthropic's synthetic
# "Claude <noreply@anthropic.com>"; posting that raw registers a roster row under
# the wrong actor, and the row is fingerprinted on host|actor|family|agent.
# ROGUE_PS_LIB_ONLY loads hook.ps1's helpers without running its dispatcher.
$hookPs1 = Get-ChildItem "$env:USERPROFILE\.claude\plugins" -Recurse -Filter hook.ps1 -File -ErrorAction SilentlyContinue |
  Where-Object { $_.FullName -like '*rogue*' } | Select-Object -First 1
$actorEmail = [string]$creds['ROGUE_ACTOR_EMAIL']; $actorName = [string]$creds['ROGUE_ACTOR_NAME']
if ($hookPs1) {
  $env:ROGUE_PS_LIB_ONLY = '1'; . $hookPs1.FullName; $env:ROGUE_PS_LIB_ONLY = $null
  # Mirrors the cascade in hook.ps1 / heartbeat.ps1 — keep all three in step.
  $hostMail  = Select-ActorValue @($env:CLAUDE_CODE_USER_EMAIL)
  $actorName = Select-ActorValue @($creds['ROGUE_ACTOR_NAME'], (($hostMail -split '@')[0]))
  if (-not $actorName) {
    $gn = ''; try { $gn = (& git config --global user.name 2>$null | Out-String).Trim() } catch {}
    $actorName = Select-ActorValue @($gn, $env:USERNAME, [Environment]::UserName)
  }
  if (-not $actorName) { $actorName = 'unknown' }
  $actorEmail = Select-ActorValue @($creds['ROGUE_ACTOR_EMAIL'], $env:CLAUDE_CODE_USER_EMAIL)
  if (-not $actorEmail) {
    $ge = ''; try { $ge = (& git config --global user.email 2>$null | Out-String).Trim() } catch {}
    $actorEmail = Select-ActorValue @($ge)
  }
  if (-not $actorEmail) {
    $dns = ''; try { $dns = [System.Net.Dns]::GetHostName() } catch {}
    $h = Select-ActorValue @($env:COMPUTERNAME, $dns)
    if ($h) { $actorEmail = "unknown@$h" } else { $actorEmail = 'unknown' }
  }
} else {
  'WARNING: hook.ps1 not found - reporting raw env values, which may be a sandbox identity'
}
$body = @{ agent_family='claude'; agent=$agent; version=$ver; host=$env:COMPUTERNAME; actor_email=$actorEmail; actor_name=$actorName } | ConvertTo-Json -Compress
try {
  $r = Invoke-WebRequest -Uri "$base/api/v1/hooks/status" -Method Post -Headers @{ 'x-rogue-api-key'=$key } -ContentType 'application/json' -Body ([Text.Encoding]::UTF8.GetBytes($body)) -UseBasicParsing -TimeoutSec 10
  "Connected (HTTP $($r.StatusCode)): $($r.Content)"
} catch { "Status check failed: $($_.Exception.Message)" }
"Actor email: $actorEmail"
"Actor name:  $actorName"
```

Interpret the JSON response and report the same fields as Step 2 (connected,
organization, version/update_available). HTTP 401 → key invalid; no response →
check network reachability to `api.rogue.security`.
