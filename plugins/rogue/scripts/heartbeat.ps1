# Rogue presence heartbeat (Windows / PowerShell).
#
# Native-Windows analogue of heartbeat.sh. Fired (detached) from SessionStart.
# POSTs /api/v1/hooks/status so this install shows up in the dashboard's Coding
# Agents roster and so the org learns which plugin version is running. Pure
# side-effect: fire-and-forget, never blocks Claude Code, always exits 0.
#
# Credential resolution mirrors hook.ps1 (later file wins; process env over all):
#   1. ${CLAUDE_PLUGIN_ROOT}\env   2. C:\ProgramData\rogue\env   3. %USERPROFILE%\.rogue-env

$ErrorActionPreference = 'SilentlyContinue'
$ProgressPreference = 'SilentlyContinue'

function Dbg { param([string]$Msg) if ($env:ROGUE_DEBUG) { [Console]::Error.WriteLine("[rogue-heartbeat] $Msg") } }

function ConvertFrom-ShellQuoted {
    param([string]$Val)
    if ($null -eq $Val) { return $Val }
    $sb = [System.Text.StringBuilder]::new()
    $i = 0; $n = $Val.Length; $state = 'normal'
    while ($i -lt $n) {
        $c = $Val[$i]
        switch ($state) {
            'single' { if ($c -eq "'") { $state = 'normal' } else { [void]$sb.Append($c) } }
            'double' {
                if ($c -eq '"') { $state = 'normal' }
                elseif ($c -eq '\' -and ($i + 1) -lt $n -and ('"\$`'.IndexOf($Val[$i+1]) -ge 0)) { [void]$sb.Append($Val[$i+1]); $i++ }
                else { [void]$sb.Append($c) }
            }
            default {
                if ($c -eq "'") { $state = 'single' }
                elseif ($c -eq '"') { $state = 'double' }
                elseif ($c -eq '\' -and ($i + 1) -lt $n) { [void]$sb.Append($Val[$i+1]); $i++ }
                else { [void]$sb.Append($c) }
            }
        }
        $i++
    }
    return $sb.ToString()
}

function Test-SyntheticActor {
    # Duplicated from hook.ps1 (heartbeat.ps1 is standalone, like its copy of
    # ConvertFrom-ShellQuoted). Keep in lockstep with actor.sh's
    # _rogue_is_synthetic: empty/whitespace, "claude", "claude code" and
    # "noreply@anthropic.com" are the sandbox identity, never a human.
    param([string]$Value)
    if ($null -eq $Value) { return $true }
    $v = ($Value -replace '\s+', ' ').Trim().ToLowerInvariant()
    return ($v -eq '' -or $v -eq 'claude' -or $v -eq 'claude code' -or $v -eq 'noreply@anthropic.com')
}

function Select-ActorValue {
    param([string[]]$Candidates)
    if ($null -eq $Candidates) { return '' }
    foreach ($c in $Candidates) { if (-not (Test-SyntheticActor $c)) { return $c } }
    return ''
}

try {
    [Net.ServicePointManager]::SecurityProtocol = `
        [Net.ServicePointManager]::SecurityProtocol -bor [Net.SecurityProtocolType]::Tls12
} catch {}

# Stand down on non-Windows (pwsh on macOS/Linux runs heartbeat.sh instead).
if ($PSVersionTable.PSVersion.Major -ge 6 -and -not $IsWindows) { exit 0 }
# Only when Claude Code is invoking.
if (-not $env:CLAUDE_CODE_ENTRYPOINT) { exit 0 }

$pluginRoot = $env:CLAUDE_PLUGIN_ROOT
if (-not $pluginRoot) { try { $pluginRoot = (Get-Location).Path } catch { $pluginRoot = '.' } }

# -- credential resolution --------------------------------------------------
$creds = @{}
foreach ($f in @((Join-Path $pluginRoot 'env'), 'C:\ProgramData\rogue\env', (Join-Path $env:USERPROFILE '.rogue-env'))) {
    if (-not $f -or -not (Test-Path -LiteralPath $f)) { continue }
    foreach ($line in (Get-Content -LiteralPath $f)) {
        if ($line -match '^\s*(?:export\s+)?([A-Z_][A-Z0-9_]*)=(.+)$') {
            $creds[$Matches[1]] = ConvertFrom-ShellQuoted ($Matches[2].Trim())
        }
    }
}
foreach ($k in 'ROGUE_API_KEY','ROGUE_ACTOR_EMAIL','ROGUE_ACTOR_NAME','ROGUE_BASE_URL') {
    $val = [Environment]::GetEnvironmentVariable($k); if ($val) { $creds[$k] = $val }
}

$apiKey = $creds['ROGUE_API_KEY']
if (-not $apiKey) { Dbg 'not configured -> no-op'; exit 0 }

$baseUrl = $creds['ROGUE_BASE_URL']; if (-not $baseUrl) { $baseUrl = 'https://api.rogue.security' }
$baseUrl = $baseUrl.TrimEnd('/')

# -- actor resolution (mirrors actor.sh / hook.ps1: first non-synthetic wins) -
# Screen the WHOLE address before splitting it. Taking the local-part first
# smuggles the sandbox identity past the screen: noreply@anthropic.com is
# rejected as an email, but its local-part "noreply" is not on the list.
$hostMail = Select-ActorValue @($env:CLAUDE_CODE_USER_EMAIL)
$actorName = Select-ActorValue @(
    $creds['ROGUE_ACTOR_NAME'],
    (($hostMail -split '@')[0])
)
if (-not $actorName) {
    $gitName = ''
    try { $gitName = (& git config --global user.name 2>$null | Out-String).Trim() } catch {}
    # POSIX ends this cascade at `whoami`. Windows deliberately does NOT shell out
    # to whoami.exe: its output is DOMAIN\user, a different identity string that
    # would re-fingerprint every existing roster row, and it costs a process per
    # hook. [Environment]::UserName is the true twin — it reads the process token,
    # so it still answers in the service contexts where USERNAME is unset.
    $actorName = Select-ActorValue @($gitName, $env:USERNAME, [Environment]::UserName)
}
if (-not $actorName) { $actorName = 'unknown' }

$actorEmail = Select-ActorValue @($creds['ROGUE_ACTOR_EMAIL'], $env:CLAUDE_CODE_USER_EMAIL)
if (-not $actorEmail) {
    $gitEmail = ''
    try { $gitEmail = (& git config --global user.email 2>$null | Out-String).Trim() } catch {}
    $actorEmail = Select-ActorValue @($gitEmail)
}
if (-not $actorEmail) {
    # Same fallback the roster host below already uses: COMPUTERNAME can be unset
    # in service contexts, where the sh twin's `hostname` still answers.
    $dnsHost = ''
    try { $dnsHost = [System.Net.Dns]::GetHostName() } catch {}
    $hostForActor = Select-ActorValue @($env:COMPUTERNAME, $dnsHost)
    if ($hostForActor) { $actorEmail = "unknown@$hostForActor" } else { $actorEmail = 'unknown' }
}

# -- plugin version (regex from manifest, no python) ------------------------
$ver = 'unknown'
$pj = Join-Path $pluginRoot '.claude-plugin\plugin.json'
if (Test-Path -LiteralPath $pj) {
    $m = [regex]::Match((Get-Content -Raw -LiteralPath $pj), '"version"\s*:\s*"([0-9]+\.[0-9]+\.[0-9]+)')
    if ($m.Success) { $ver = $m.Groups[1].Value }
}

# -- agent display label from entrypoint (family is the fixed enum "claude") -
# Surface id, not a display label: it doubles as the backend's latest-version
# key (see install-id.sh), which a label never matched.
# CLAUDE_CODE_IS_COWORK is checked FIRST (mirrors install-id.sh): Cowork now
# spawns Claude Code with CLAUDE_CODE_ENTRYPOINT=local-agent, so entrypoint
# matching alone reported every Cowork install as "Claude Code - CLI".
$ep = ([string]$env:CLAUDE_CODE_ENTRYPOINT).ToLower()
if ($env:CLAUDE_CODE_IS_COWORK)     { $agent = 'claude_cowork' }
elseif ($ep -like '*cowork*')       { $agent = 'claude_cowork' }
elseif ($ep -like '*desktop*')      { $agent = 'claude_code_desktop' }
else                                { $agent = 'claude_code' }

$host_ = $env:COMPUTERNAME; if (-not $host_) { try { $host_ = [System.Net.Dns]::GetHostName() } catch { $host_ = 'unknown' } }

$body = @{
    agent_family = 'claude'
    agent        = $agent
    version      = $ver
    host         = $host_
    actor_email  = [string]$actorEmail
    actor_name   = [string]$actorName
} | ConvertTo-Json -Compress

try {
    $bytes = [System.Text.Encoding]::UTF8.GetBytes($body)
    Invoke-WebRequest -Uri "$baseUrl/api/v1/hooks/status" -Method Post `
        -Headers @{ 'x-rogue-api-key' = $apiKey } -ContentType 'application/json' `
        -Body $bytes -UseBasicParsing -TimeoutSec 10 -ErrorAction Stop | Out-Null
    Dbg 'heartbeat sent'
} catch { Dbg "heartbeat failed: $($_.Exception.Message)" }

exit 0
