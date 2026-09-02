#Requires -Version 5.1
<#
.SYNOPSIS
    Rogue Security - one-line installer for Claude Code (Windows).
.DESCRIPTION
    iwr -useb https://raw.githubusercontent.com/qualifire-dev/rogue-plugins/main/install.ps1 | iex

    With credentials via environment variables (non-interactive):
    $env:ROGUE_API_KEY='rsk_xxx'; $env:ROGUE_ACTOR_EMAIL='you@co.com'; iwr -useb https://raw.githubusercontent.com/qualifire-dev/rogue-plugins/main/install.ps1 | iex

    Direct invocation with flags:
    .\install.ps1 -ApiKey rsk_xxx -Email you@co.com -Name 'Your Name'
    .\install.ps1 -NonInteractive

    Installs the plugin through the official Claude CLI (marketplace add + plugin
    install) - the same mechanism as install.sh - validates and stores your API
    key, and confirms your actor identity.

    Unlike the runtime hooks (which fail OPEN so Claude Code never hangs on Rogue
    infrastructure), this installer fails LOUD: a half-finished install should be
    visible, not silent.
.PARAMETER ApiKey
    Rogue API key (rsk_...).
.PARAMETER Email
    Actor email address.
.PARAMETER Name
    Actor display name.
.PARAMETER BaseUrl
    Override the API base URL (default: https://api.rogue.security).
.PARAMETER PluginRepo
    Marketplace source repo (default: qualifire-dev/rogue-plugins).
.PARAMETER NonInteractive
    Fail / skip prompts rather than ask for missing values.
.PARAMETER Claude
    Install only for Claude Code (combine with -Codex/-Cursor to pick a set).
.PARAMETER Codex
    Install only for OpenAI Codex.
.PARAMETER Cursor
    Install only for Cursor.
.PARAMETER Gemini
    Install only for Gemini CLI.
.PARAMETER Copilot
    Install only for GitHub Copilot CLI.
.PARAMETER Antigravity
    Install only for Google Antigravity. With no agent switch, every detected agent is installed.
#>
[CmdletBinding()]
param(
    [string]$ApiKey,
    [string]$Email,
    [string]$Name,
    [string]$BaseUrl,
    [string]$PluginRepo,
    [switch]$NonInteractive,
    [switch]$Claude,
    [switch]$Codex,
    [switch]$Cursor,
    [switch]$Gemini,
    [switch]$Copilot,
    [switch]$Antigravity
)

$ErrorActionPreference = 'Stop'

$ROGUE_BASE_URL_DEFAULT = 'https://api.rogue.security'
$MarketplaceName = 'rogue-marketplace'
$CopilotMarketplaceName = 'rogue-copilot'
$PluginName      = 'rogue'
$EnvFile = if ($env:ROGUE_ENV_FILE) { $env:ROGUE_ENV_FILE } else { Join-Path $env:USERPROFILE '.rogue-env' }

# Merge env vars -> params (explicit params win).
if (-not $ApiKey)     { $ApiKey     = $env:ROGUE_API_KEY }
if (-not $Email)      { $Email      = $env:ROGUE_ACTOR_EMAIL }
if (-not $Name)       { $Name       = $env:ROGUE_ACTOR_NAME }
if (-not $BaseUrl)    { $BaseUrl    = if ($env:ROGUE_BASE_URL) { $env:ROGUE_BASE_URL } else { $ROGUE_BASE_URL_DEFAULT } }
if (-not $PluginRepo) { $PluginRepo = if ($env:ROGUE_PLUGIN_REPO) { $env:ROGUE_PLUGIN_REPO } else { 'qualifire-dev/rogue-plugins' } }
if ($env:ROGUE_NON_INTERACTIVE) { $NonInteractive = $true }

function Log  { param([string]$M) Write-Host "-> $M" -ForegroundColor Cyan }
function Ok   { param([string]$M) Write-Host "v  $M" -ForegroundColor Green }
function Warn2{ param([string]$M) Write-Host "!  $M" -ForegroundColor Yellow }
function Die  { param([string]$M) Write-Host "x  $M" -ForegroundColor Red; exit 1 }

try {
    [Net.ServicePointManager]::SecurityProtocol = `
        [Net.ServicePointManager]::SecurityProtocol -bor [Net.SecurityProtocolType]::Tls12
} catch {}

Write-Host ""
Write-Host "Rogue Security (Windows)" -ForegroundColor Cyan

# Agent selection. -Claude/-Codex/-Cursor pick an explicit set; with none, auto-detect
# every supported agent. claude/codex ship a CLI on PATH; Cursor's `cursor` command is
# opt-in, so detection also accepts %USERPROFILE%\.cursor. An explicitly selected CLI
# agent still needs its binary; Cursor is a plain file copy, so it installs regardless.
# Antigravity has no `antigravity` binary on PATH — detect the `agy` CLI or its data
# dirs under %USERPROFILE%\.gemini (IDE and/or manual-CLI installs).
$explicit = $Claude -or $Codex -or $Cursor -or $Gemini -or $Copilot -or $Antigravity
if ($explicit) {
    $hasClaude      = [bool]$Claude
    $hasCodex       = [bool]$Codex
    $hasCursor      = [bool]$Cursor
    $hasGemini      = [bool]$Gemini
    $hasCopilot     = [bool]$Copilot
    $hasAntigravity = [bool]$Antigravity
    if ($hasClaude -and -not (Get-Command claude -ErrorAction SilentlyContinue)) {
        Die "-Claude requested but the 'claude' CLI is not on PATH. Install Claude Code (https://claude.com/code) first."
    }
    if ($hasCodex -and -not (Get-Command codex -ErrorAction SilentlyContinue)) {
        Die "-Codex requested but the 'codex' CLI is not on PATH. Install OpenAI Codex first."
    }
    if ($hasGemini -and -not (Get-Command gemini -ErrorAction SilentlyContinue)) {
        Die "-Gemini requested but the 'gemini' CLI is not on PATH. Install Gemini CLI (https://geminicli.com) first."
    }
    if ($hasCopilot -and -not (Get-Command copilot -ErrorAction SilentlyContinue)) {
        Die "-Copilot requested but the 'copilot' CLI is not on PATH. Install GitHub Copilot CLI (https://github.com/github/copilot-cli) first."
    }
    if ($hasAntigravity -and -not ((Get-Command agy -ErrorAction SilentlyContinue) -or (Test-Path (Join-Path $env:USERPROFILE '.gemini\antigravity*')))) {
        Die "-Antigravity requested but no Antigravity install was detected (looked for: agy CLI, %USERPROFILE%\.gemini\antigravity*). Install Google Antigravity first."
    }
} else {
    $hasClaude      = [bool](Get-Command claude -ErrorAction SilentlyContinue)
    $hasCodex       = [bool](Get-Command codex  -ErrorAction SilentlyContinue)
    $hasCursor      = [bool](Get-Command cursor -ErrorAction SilentlyContinue) -or (Test-Path (Join-Path $env:USERPROFILE '.cursor'))
    $hasGemini      = [bool](Get-Command gemini -ErrorAction SilentlyContinue)
    $hasCopilot     = [bool](Get-Command copilot -ErrorAction SilentlyContinue)
    $hasAntigravity = [bool](Get-Command agy -ErrorAction SilentlyContinue) -or (Test-Path (Join-Path $env:USERPROFILE '.gemini\antigravity*'))
    if (-not ($hasClaude -or $hasCodex -or $hasCursor -or $hasGemini -or $hasCopilot -or $hasAntigravity)) {
        Die "No supported coding agent found (looked for: claude, codex, cursor, gemini, copilot, antigravity). Install Claude Code (https://claude.com/code), OpenAI Codex, Cursor (https://cursor.com), Gemini CLI (https://geminicli.com), GitHub Copilot CLI (https://github.com/github/copilot-cli), or Google Antigravity first."
    }
}
# Claude shells out to git to clone the marketplace; git is required only for it.
if ($hasClaude -and -not (Get-Command git -ErrorAction SilentlyContinue)) {
    Die "git not found. Install Git for Windows (https://git-scm.com/download/win) first."
}

# Load existing creds from disk (same priority as the dispatcher: later wins).
function Load-ExistingCreds {
    foreach ($f in @('C:\ProgramData\rogue\env', (Join-Path $env:USERPROFILE '.rogue-env'))) {
        if (-not (Test-Path -LiteralPath $f)) { continue }
        foreach ($line in (Get-Content -LiteralPath $f -ErrorAction SilentlyContinue)) {
            if ($line -match '^\s*(?:export\s+)?([A-Z_][A-Z0-9_]*)=(.+)$') {
                $k = $Matches[1]
                $v = $Matches[2].Trim() -replace "^'(.*)'$", '$1' -replace '^"(.*)"$', '$1'
                switch ($k) {
                    'ROGUE_API_KEY'     { if (-not $script:ApiKey)  { $script:ApiKey  = $v } }
                    'ROGUE_ACTOR_EMAIL' { if (-not $script:Email)   { $script:Email   = $v } }
                    'ROGUE_ACTOR_NAME'  { if (-not $script:Name)    { $script:Name    = $v } }
                    'ROGUE_BASE_URL'    { if ($script:BaseUrl -eq $ROGUE_BASE_URL_DEFAULT) { $script:BaseUrl = $v } }
                }
            }
        }
    }
}
Load-ExistingCreds

if (-not $ApiKey) {
    if ($NonInteractive) {
        Warn2 'No API key set and running non-interactively - skipping key setup.'
        Warn2 'Run /rogue:setup inside Claude Code to connect your key later.'
    } else {
        $secure = Read-Host 'Rogue API key (rsk_...)' -AsSecureString
        $bstr   = [Runtime.InteropServices.Marshal]::SecureStringToBSTR($secure)
        $ApiKey = [Runtime.InteropServices.Marshal]::PtrToStringAuto($bstr)
        [Runtime.InteropServices.Marshal]::ZeroFreeBSTR($bstr)
        if (-not $ApiKey) { Die 'API key cannot be empty.' }
    }
}

# Actor identity: git config -> env fallbacks (mirrors actor.sh).
if (-not $Email) { try { $Email = (& git config --global user.email 2>$null | Out-String).Trim() } catch {} }
if (-not $Name)  { try { $Name  = (& git config --global user.name 2>$null | Out-String).Trim() } catch {} }
if (-not $Email -and $env:CLAUDE_CODE_USER_EMAIL) { $Email = $env:CLAUDE_CODE_USER_EMAIL }
if (-not $Email) { $Email = "$env:USERNAME@$env:COMPUTERNAME" }
if (-not $Name)  { $Name  = $env:USERNAME }
Log "Actor: $Name <$Email>"

# Validate the key AND register this install via /api/v1/hooks/status (the same
# heartbeat the SessionStart hook calls), so the dashboard roster row is deduped.
if ($ApiKey) {
    Log 'Validating API key...'
    try {
        $hostName = $env:COMPUTERNAME; if (-not $hostName) { $hostName = 'unknown' }
        # /api/v1/hooks/status has side effects (it registers/updates the roster
        # row), so register under an agent actually being installed — a Copilot-
        # only or Codex-only install must NOT create a bogus Claude roster row.
        # Prefer claude when it's a target (its heartbeat backs the row,
        # preserving prior behavior); otherwise use the first selected agent.
        # Values mirror each heartbeat.
        $scFamily = 'claude'; $scAgent = 'claude_code'
        if ($hasClaude)      { $scFamily = 'claude';  $scAgent = 'claude_code' }
        elseif ($hasCodex)   { $scFamily = 'openai';  $scAgent = 'codex_cli' }
        elseif ($hasCursor)  { $scFamily = 'cursor';  $scAgent = 'cursor' }
        elseif ($hasGemini)  { $scFamily = 'gemini';  $scAgent = 'gemini_cli' }
        elseif ($hasCopilot) { $scFamily = 'copilot'; $scAgent = 'github_copilot' }
        $body = @{ agent_family = $scFamily; agent = $scAgent; host = $hostName; actor_email = [string]$Email } | ConvertTo-Json -Compress
        $bytes = [System.Text.Encoding]::UTF8.GetBytes($body)
        $resp = Invoke-WebRequest -Uri "$($BaseUrl.TrimEnd('/'))/api/v1/hooks/status" -Method Post `
            -Headers @{ 'x-rogue-api-key' = $ApiKey } -ContentType 'application/json' `
            -Body $bytes -UseBasicParsing -TimeoutSec 10 -ErrorAction Stop
        if ($resp.StatusCode -eq 200) { Ok 'Key validated.' } else { Warn2 "Unexpected response (HTTP $($resp.StatusCode)) - saving without verification." }
    } catch {
        $code = $null
        if ($_.Exception.Response) { try { $code = [int]$_.Exception.Response.StatusCode } catch {} }
        if ($code -eq 401 -or $code -eq 403) {
            if ($NonInteractive) { Die "Invalid API key (HTTP $code)." }
            Warn2 "Invalid key (HTTP $code) - saving anyway. Verify it at https://app.rogue.security/settings/api-keys"
        } else {
            Warn2 "Could not reach $BaseUrl to validate - saving without verification."
        }
    }

    # Write %USERPROFILE%\.rogue-env. Same MERGE semantics as
    # scripts/shared/env-file.ps1, inlined because this script is piped to iex on
    # its own - keep the two in step. Merging matters most here: auto-update
    # re-runs the installer unattended every 24h.
    function Format-EnvVal { param([string]$Val) return "'" + $Val.Replace("'", "'\''") + "'" }
    $managed = @('ROGUE_API_KEY', 'ROGUE_ACTOR_EMAIL', 'ROGUE_ACTOR_NAME', 'ROGUE_BASE_URL')
    $envLines = @(
        '# Managed by the Rogue plugins. Read by hook subprocesses at runtime.',
        '# Delete this file to revoke credentials.',
        "export ROGUE_API_KEY=$(Format-EnvVal $ApiKey)",
        "export ROGUE_ACTOR_EMAIL=$(Format-EnvVal $Email)",
        "export ROGUE_ACTOR_NAME=$(Format-EnvVal $Name)"
    )
    # Writing the default would bake today's hostname into every install.
    if ($BaseUrl -ne $ROGUE_BASE_URL_DEFAULT) { $envLines += "export ROGUE_BASE_URL=$(Format-EnvVal $BaseUrl)" }
    if (Test-Path -LiteralPath $EnvFile) {
        $owned = '^\s*(?:export\s+)?(?:' + ($managed -join '|') + ')\s*='
        $header = '^\s*# (Managed by the [Rr]ogue|Delete this file to revoke credentials)'
        foreach ($line in (Get-Content -LiteralPath $EnvFile -ErrorAction SilentlyContinue)) {
            if ($line -match $owned -or $line -match $header) { continue }
            $envLines += $line
        }
    }
    $envDir = Split-Path $EnvFile
    if ($envDir -and -not (Test-Path $envDir)) { New-Item -ItemType Directory -Path $envDir -Force | Out-Null }
    # BOM-less UTF-8 with LF - the same bytes install.sh writes.
    [System.IO.File]::WriteAllText($EnvFile, (($envLines -join "`n") + "`n"),
        (New-Object System.Text.UTF8Encoding($false)))
    try {
        $acl = Get-Acl $EnvFile
        $acl.SetAccessRuleProtection($true, $false)
        $rule = New-Object System.Security.AccessControl.FileSystemAccessRule(
            [System.Security.Principal.WindowsIdentity]::GetCurrent().Name, 'FullControl', 'Allow')
        $acl.SetAccessRule($rule); Set-Acl $EnvFile $acl
    } catch { Warn2 "Could not restrict permissions on $EnvFile (non-fatal)." }
    Ok "Credentials written to $EnvFile"
}

# Install through each agent's CLI marketplace (cross-platform; same monorepo for
# both — Claude reads .claude-plugin/marketplace.json, Codex reads
# .agents/plugins/marketplace.json; marketplace `rogue-marketplace` + plugin
# `rogue` are identical). `claude`/`codex` are native commands — a non-zero exit
# does NOT throw, so gate on $LASTEXITCODE.
if ($hasClaude) {
    Write-Host ""
    Write-Host "Rogue Security - Claude Code" -ForegroundColor Cyan
    Log "Adding marketplace $PluginRepo"
    $mktOk = $false
    try { & claude plugin marketplace add $PluginRepo 2>&1 | Out-Null; if ($LASTEXITCODE -eq 0) { $mktOk = $true } } catch {}
    if ($mktOk) { Ok 'Marketplace added' }
    else {
        try { & claude plugin marketplace update $MarketplaceName 2>&1 | Out-Null; if ($LASTEXITCODE -eq 0) { $mktOk = $true } } catch {}
        if ($mktOk) { Ok 'Marketplace updated' }
        else { Warn2 'Could not add or update marketplace (continuing - it may already be present).' }
    }
    Log "Installing plugin $PluginName@$MarketplaceName"
    $installed = $false
    try { & claude plugin install "$PluginName@$MarketplaceName" 2>&1 | Out-Null; if ($LASTEXITCODE -eq 0) { $installed = $true } } catch {}
    if (-not $installed) {
        try { & claude plugin update $PluginName 2>&1 | Out-Null; if ($LASTEXITCODE -eq 0) { $installed = $true } } catch {}
    }
    if (-not $installed) { Die "claude plugin install failed. Run 'claude plugin install $PluginName@$MarketplaceName' to see the error." }
    Ok 'Plugin installed'
}

if ($hasCodex) {
    Write-Host ""
    Write-Host "Rogue Security - OpenAI Codex" -ForegroundColor Cyan
    Log "Adding marketplace $PluginRepo"
    $mktOk = $false
    try { & codex plugin marketplace add $PluginRepo 2>&1 | Out-Null; if ($LASTEXITCODE -eq 0) { $mktOk = $true } } catch {}
    if ($mktOk) { Ok 'Marketplace added' }
    else {
        try { & codex plugin marketplace upgrade $MarketplaceName 2>&1 | Out-Null; if ($LASTEXITCODE -eq 0) { $mktOk = $true } } catch {}
        if ($mktOk) { Ok 'Marketplace updated' }
        else { Warn2 'Could not add or update Codex marketplace (continuing - it may already be present).' }
    }
    Log "Installing plugin $PluginName@$MarketplaceName"
    # Codex uses `plugin add` (not `install`); idempotent re-add is fine.
    $installed = $false
    try { & codex plugin add "$PluginName@$MarketplaceName" 2>&1 | Out-Null; if ($LASTEXITCODE -eq 0) { $installed = $true } } catch {}
    if (-not $installed) { Die "codex plugin add failed. Run 'codex plugin add $PluginName@$MarketplaceName' to see the error." }
    Ok 'Plugin installed'
    Warn2 'Codex skips untrusted hooks - open /hooks in Codex and trust the Rogue entries once.'
}

# Cursor has no plugin CLI: install is a file copy into
# %USERPROFILE%\.cursor\plugins\local\rogue. Download the release tarball, extract
# with `tar` (bundled in Windows 10+), and copy plugins\cursor into place. The Team
# Marketplace is the separate, admin-driven managed path; this does not touch it.
if ($hasCursor) {
    Write-Host ""
    Write-Host "Rogue Security - Cursor" -ForegroundColor Cyan
    # Cursor ships dual dispatchers (sh + PowerShell) like Claude/Codex; the runtime
    # is the same shell stack, so no extra prerequisite check beyond tar (below).
    $asset = 'rogue-plugin-cursor.tar.gz'
    if ($env:ROGUE_PLUGIN_VERSION) {
        $url = "https://github.com/$PluginRepo/releases/download/$($env:ROGUE_PLUGIN_VERSION)/$asset"
    } else {
        $url = "https://github.com/$PluginRepo/releases/latest/download/$asset"
    }
    $tmp = Join-Path ([System.IO.Path]::GetTempPath()) ("rogue-cursor-" + [System.IO.Path]::GetRandomFileName())
    New-Item -ItemType Directory -Path $tmp -Force | Out-Null
    # Non-fatal: Cursor is detected from %USERPROFILE%\.cursor (present for nearly
    # every developer), so a missing release asset or download error must NOT abort
    # the run and break the Claude/Codex installs above. Warn and continue.
    try {
        Log "Downloading plugin $asset"
        $tarball = Join-Path $tmp 'p.tar.gz'
        Invoke-WebRequest -Uri $url -OutFile $tarball -UseBasicParsing -TimeoutSec 60 -ErrorAction Stop
        & tar -xzf $tarball -C $tmp
        if ($LASTEXITCODE -ne 0) { throw "Could not extract the Cursor plugin tarball (is 'tar' available?)." }
        $src = Get-ChildItem -Path $tmp -Recurse -Directory -Filter 'cursor' |
            Where-Object { Test-Path (Join-Path $_.FullName '.cursor-plugin\plugin.json') } |
            Select-Object -First 1
        if (-not $src) { throw "Cursor plugin manifest missing in download." }
        $dest = Join-Path $env:USERPROFILE '.cursor\plugins\local\rogue'
        if (Test-Path $dest) { Remove-Item -Recurse -Force $dest }
        New-Item -ItemType Directory -Path $dest -Force | Out-Null
        Copy-Item -Recurse -Force (Join-Path $src.FullName '*') $dest
        Ok "Plugin installed -> $dest"
        Warn2 'Fully quit and reopen Cursor, then run /rogue:status to verify.'
    } catch {
        Warn2 "Cursor plugin not installed ($($_.Exception.Message)). If the asset isn't published yet, re-run the installer once it is."
    } finally {
        Remove-Item -Recurse -Force $tmp -ErrorAction SilentlyContinue
    }
}

# Gemini has a native extension CLI, but `gemini extensions install <github-url>`
# expects the manifest at the source root, which the monorepo root is not. So we
# download the release tarball (whose top dir IS the extension, manifest at root),
# extract it with `tar` (bundled in Windows 10+), and `gemini extensions install
# <dir>`. Gemini makes its own managed copy, so the temp dir is disposable.
# Re-running upgrades (uninstall-then-install). Non-fatal.
if ($hasGemini) {
    Write-Host ""
    Write-Host "Rogue Security - Gemini CLI" -ForegroundColor Cyan
    $asset = 'rogue-plugin-gemini.tar.gz'
    if ($env:ROGUE_PLUGIN_VERSION) {
        $url = "https://github.com/$PluginRepo/releases/download/$($env:ROGUE_PLUGIN_VERSION)/$asset"
    } else {
        $url = "https://github.com/$PluginRepo/releases/latest/download/$asset"
    }
    $tmp = Join-Path ([System.IO.Path]::GetTempPath()) ("rogue-gemini-" + [System.IO.Path]::GetRandomFileName())
    New-Item -ItemType Directory -Path $tmp -Force | Out-Null
    # GEMINI_CLI_TRUST_WORKSPACE=true is Gemini's documented headless bypass for
    # its folder-trust gate (default-ON): without it the install prompts "Do you
    # trust the files in this folder?" for our own just-extracted temp dir, the
    # prompt is invisible here (output piped to Out-Null), the non-interactive
    # default is No, and the install aborts with 'Installation aborted: Folder
    # "..." is not trusted.' Captured/restored so it never leaks into the user's
    # shell session (iwr | iex runs in-session). No persistent trust granted.
    $prevGeminiTrust = $env:GEMINI_CLI_TRUST_WORKSPACE
    try {
        Log "Downloading extension $asset"
        $tarball = Join-Path $tmp 'p.tar.gz'
        Invoke-WebRequest -Uri $url -OutFile $tarball -UseBasicParsing -TimeoutSec 60 -ErrorAction Stop
        & tar -xzf $tarball -C $tmp
        if ($LASTEXITCODE -ne 0) { throw "Could not extract the Gemini extension tarball (is 'tar' available?)." }
        $src = Get-ChildItem -Path $tmp -Recurse -File -Filter 'gemini-extension.json' | Select-Object -First 1
        if (-not $src) { throw "Gemini manifest missing in download." }
        $srcDir = $src.Directory.FullName
        # Reinstall cleanly so a re-run upgrades. Ignore uninstall errors (first run).
        $env:GEMINI_CLI_TRUST_WORKSPACE = 'true'
        try { & gemini extensions uninstall rogue 2>&1 | Out-Null } catch {}
        & gemini extensions install $srcDir --consent 2>&1 | Out-Null
        if ($LASTEXITCODE -ne 0) { throw "gemini extensions install failed." }
        Ok "Extension installed via gemini extensions install"
        Warn2 'Gemini skips untrusted hooks - open /hooks in Gemini CLI and trust the Rogue entries once, then restart Gemini CLI.'
    } catch {
        Warn2 "Gemini extension not installed ($($_.Exception.Message)). If the asset isn't published yet, re-run the installer once it is."
    } finally {
        if ($null -eq $prevGeminiTrust) {
            Remove-Item Env:GEMINI_CLI_TRUST_WORKSPACE -ErrorAction SilentlyContinue
        } else {
            $env:GEMINI_CLI_TRUST_WORKSPACE = $prevGeminiTrust
        }
        Remove-Item -Recurse -Force $tmp -ErrorAction SilentlyContinue
    }
}

# Antigravity has no marketplace-add command. Like Gemini, the release tarball's
# top dir IS the plugin (manifest at its root — see scripts/build-release.sh), so
# download it, extract with `tar` (bundled in Windows 10+), and copy it into the
# IDE's global plugin dir (%USERPROFILE%\.gemini\config\plugins\rogue). If the
# `agy` CLI is present, also register it natively (uninstall-then-install so a
# re-run upgrades); otherwise, if a manual-CLI plugins dir exists, copy there too.
# Non-fatal: a failed Antigravity install must not abort the run.
if ($hasAntigravity) {
    Write-Host ""
    Write-Host "Rogue Security - Google Antigravity" -ForegroundColor Cyan
    $asset = 'rogue-plugin-antigravity.tar.gz'
    if ($env:ROGUE_PLUGIN_VERSION) {
        $url = "https://github.com/$PluginRepo/releases/download/$($env:ROGUE_PLUGIN_VERSION)/$asset"
    } else {
        $url = "https://github.com/$PluginRepo/releases/latest/download/$asset"
    }
    $tmp = Join-Path ([System.IO.Path]::GetTempPath()) ("rogue-antigravity-" + [System.IO.Path]::GetRandomFileName())
    New-Item -ItemType Directory -Path $tmp -Force | Out-Null
    try {
        Log "Downloading plugin $asset"
        $tarball = Join-Path $tmp 'p.tar.gz'
        Invoke-WebRequest -Uri $url -OutFile $tarball -UseBasicParsing -TimeoutSec 60 -ErrorAction Stop
        & tar -xzf $tarball -C $tmp
        if ($LASTEXITCODE -ne 0) { throw "Could not extract the Antigravity plugin tarball (is 'tar' available?)." }
        $src = Get-ChildItem -Path $tmp -Recurse -File -Filter 'plugin.json' |
            Where-Object { Test-Path (Join-Path $_.Directory.FullName 'hooks.json') } |
            Select-Object -First 1
        if (-not $src) { throw "Antigravity plugin manifest missing in download." }
        $srcDir = $src.Directory.FullName

        # IDE global copy.
        $ideDir = Join-Path $env:USERPROFILE '.gemini\config\plugins\rogue'
        if (Test-Path $ideDir) { Remove-Item -Recurse -Force $ideDir }
        New-Item -ItemType Directory -Path $ideDir -Force | Out-Null
        Copy-Item -Recurse -Force (Join-Path $srcDir '*') $ideDir
        Ok "Plugin installed -> $ideDir"

        # CLI: native install if `agy` is present, else manual copy if the CLI dir exists.
        #
        # A failure here is not fatal: the global copy above is the shared plugins dir
        # all three surfaces read, so the CLI keeps loading the plugin from there. What
        # it must not print is a dead recovery command — $srcDir lives under $tmp, which
        # the finally block deletes on the way out. Mirrors install.sh.
        if (Get-Command agy -ErrorAction SilentlyContinue) {
            try { & agy plugin uninstall rogue 2>&1 | Out-Null } catch {}
            $agyErr = (& agy plugin install $srcDir 2>&1 | Out-String).Trim()
            if ($LASTEXITCODE -eq 0) {
                Ok "Plugin installed via agy plugin install"
            } else {
                Warn2 "agy plugin install failed - the CLI still loads the plugin from $ideDir."
                if ($agyErr) { Log $agyErr }
                Log "To retry the native registration: agy plugin install '$ideDir'"
            }
        } else {
            $cliPlugins = Join-Path $env:USERPROFILE '.gemini\antigravity-cli\plugins'
            if (Test-Path $cliPlugins) {
                $cliDir = Join-Path $cliPlugins 'rogue'
                if (Test-Path $cliDir) { Remove-Item -Recurse -Force $cliDir }
                New-Item -ItemType Directory -Path $cliDir -Force | Out-Null
                Copy-Item -Recurse -Force (Join-Path $srcDir '*') $cliDir
                Ok "Plugin installed -> $cliDir"
            }
        }
        Warn2 'Fully quit and reopen Antigravity, then run /rogue:status to verify.'
    } catch {
        Warn2 "Antigravity plugin not installed ($($_.Exception.Message)). If the asset isn't published yet, re-run the installer once it is."
    } finally {
        Remove-Item -Recurse -Force $tmp -ErrorAction SilentlyContinue
    }
}

# Copilot has a native plugin CLI (marketplace add + install NAME@MARKETPLACE),
# same model as Claude/Codex. But Copilot reads BOTH .github/plugin/marketplace.json
# and .claude-plugin/marketplace.json from the monorepo, so its marketplace uses a
# DISTINCT name (rogue-copilot) and we install rogue@rogue-copilot to disambiguate.
# `copilot` is a native command — a non-zero exit does NOT throw, so gate on $LASTEXITCODE.
if ($hasCopilot) {
    Write-Host ""
    Write-Host "Rogue Security - GitHub Copilot CLI" -ForegroundColor Cyan
    Log "Adding marketplace $PluginRepo"
    $mktOk = $false
    try { & copilot plugin marketplace add $PluginRepo 2>&1 | Out-Null; if ($LASTEXITCODE -eq 0) { $mktOk = $true } } catch {}
    if ($mktOk) { Ok 'Marketplace added' }
    else {
        try { & copilot plugin marketplace update $CopilotMarketplaceName 2>&1 | Out-Null; if ($LASTEXITCODE -eq 0) { $mktOk = $true } } catch {}
        if ($mktOk) { Ok 'Marketplace updated' }
        else { Warn2 'Could not add or update Copilot marketplace (continuing - it may already be present).' }
    }
    Log "Installing plugin $PluginName@$CopilotMarketplaceName"
    $installed = $false
    try { & copilot plugin install "$PluginName@$CopilotMarketplaceName" 2>&1 | Out-Null; if ($LASTEXITCODE -eq 0) { $installed = $true } } catch {}
    if (-not $installed) {
        try { & copilot plugin update $PluginName 2>&1 | Out-Null; if ($LASTEXITCODE -eq 0) { $installed = $true } } catch {}
    }
    if (-not $installed) { Die "copilot plugin install failed. Run 'copilot plugin install $PluginName@$CopilotMarketplaceName' to see the error." }
    Ok 'Plugin installed'
    Warn2 'Copilot skips untrusted hooks - open /hooks in Copilot CLI and trust the Rogue entries once.'
    # Mirrors install.sh: Rogue reaches JetBrains only through Copilot's
    # CLI/Agent provider. The IDE's built-in "Local" agent runs its own hook
    # engine that refuses plugin-provided hooks (zero coverage), and no hook ever
    # runs there to warn from - the installer is the only place we can say it.
    if ($env:APPDATA -and (Test-Path -LiteralPath (Join-Path $env:APPDATA 'JetBrains'))) {
        Warn2 "In JetBrains, pick Copilot's CLI/Agent provider - the built-in Local agent ignores installed plugins, so Rogue would see nothing."
    }
}

Write-Host @"

v Rogue Security installed.

  Credentials:  $EnvFile

Next steps:
  1. Fully quit and reopen each agent (hooks load credentials at session start).
  2. Run /rogue:status inside the agent to verify.
  3. AIDR dashboard: https://app.rogue.security/aidr

Re-running this installer upgrades the plugins and is safe.
"@ -ForegroundColor Green
