# Point a NATIVE WINDOWS coding agent at a Rogue plugin WORKING TREE and an API you
# control, so you can exercise uncommitted plugin changes end to end.
#
#   local_api.ps1 up   [-Agent claude|cursor] [-Url URL] [-Key KEY] [-Ship]
#                      [-BeaconInterval N] [-AllowRemoteUrl]
#   local_api.ps1 sync   [-Agent ...]   # re-push working-tree edits, no reinstall
#   local_api.ps1 status [-Agent ...]   # what is installed, where it points
#   local_api.ps1 check  [-Agent ...]   # assert the log looks like this branch
#   local_api.ps1 ship   [-Agent ...] [-Reset]   # force a log upload NOW
#   local_api.ps1 probe  [-Agent claude]         # one headless session (claude only)
#   local_api.ps1 down   [-Agent ...]   # undo everything `up` did
#
# Run it with either host: `pwsh -File ...` or `powershell -File ...`. The file is kept
# Windows PowerShell 5.1-clean, so a box without pwsh 7 needs nothing extra.
#
# TWO AGENTS, ONE HARNESS. -Agent selects which plugin is installed and which log is
# asserted. They differ in almost every mechanic, which is why the table below is
# explicit rather than derived:
#
#                        claude                        cursor
#   source tree          plugins\rogue                 plugins\cursor
#   manifest/version     .claude-plugin\plugin.json    .cursor-plugin\plugin.json
#   install              `claude plugin install` from  COPY the directory into
#                        a staged marketplace          %USERPROFILE%\.cursor\plugins\local\rogue
#   log file             ~\.rogue\logs\claude.log      ~\.rogue\logs\cursor.log
#   provider= token      claude                        cursor
#   surface= vocabulary  cli|desktop|cowork            cursor (one, always present)
#   shipper slug/family  claude / claude               cursor / cursor
#   beacon               heartbeat.ps1, DETACHED,      INLINE in hook.ps1, a SYNC
#                        SessionStart AND Stop         POST, sessionStart AND stop
#   beacon throttle      yes, stamped                  yes, stamped (same library)
#   beacon in the log    no (detached: unobservable)   yes - heartbeat=<status>|throttled
#   headless probe       yes (`claude -p`)             no such CLI
#
# Cursor has NO plugin CLI at all - that asymmetry is load-bearing in install.ps1 and
# is reproduced here. Its install target is the SAME path the one-line installer uses,
# so `up` moves any existing copy aside to <dest>.localdev-backup and `down` puts it
# back; without that, testing would silently destroy a real install.
#
# WHY THIS FILE EXISTS, given tests/manual/local_api.sh does this on macOS/Linux.
# Two reasons, and neither is cosmetic:
#
#   1. It is the ONLY way to exercise the PowerShell dispatchers (hook.ps1,
#      heartbeat.ps1, ship-logs.ps1) through a real agent, real hooks.json and a real
#      API. tests/e2e_ship_logs.ps1 covers the shipper on a windows-latest runner, but
#      nothing anywhere drives the dispatcher. On a Mac that code never runs at all.
#   2. The sh harness cannot be run here even under Git Bash: it reads a `C:\Users\...`
#      path out of installed_plugins.json and `cp -R "$IP/"` eats the backslashes as
#      escapes, so a sync would appear to succeed and copy nothing.
#
# THE URL. Any URL is allowed, but a non-local one needs -AllowRemoteUrl. That is not
# a restriction on where you may point it - it is a guard against a TYPO, because `up`
# rewrites ~\.rogue-env, which ALL SIX plugins read: a wrong host there sends your
# sessions' prompts and tool calls somewhere you did not intend, from every agent on
# the box at once. Pass the flag and paste whatever you like.
#
# If the API runs on another machine and you would rather keep the URL local, forward
# the port instead:  ssh -N -L 8007:localhost:8007 you@that-machine
#
# WHAT `up` CHANGES (all of it undone by `down`)
#
#   * claude: adds a `rogue-localdev` marketplace sourced from a copy of your working
#     tree and installs `rogue@rogue-localdev` at user scope; DISABLES
#     `rogue@rogue-marketplace` if present, so exactly one plugin answers each event
#     (two enabled copies double every POST and write two log lines per event).
#   * cursor: copies plugins\cursor into %USERPROFILE%\.cursor\plugins\local\rogue,
#     moving any existing copy to <dest>.localdev-backup first.
#   * Replaces %USERPROFILE%\.rogue-env, keeping the original at
#     .rogue-env.localdev-backup. THAT FILE IS SHARED BY ALL SIX PLUGINS: while this is
#     up, any other Rogue install on the box also talks to your API with your key.
#     Usually what you want for a backend test; never what you want left running.
#   * Nothing else. The log stays at its real path so /rogue:status reads the same file.

param(
    [Parameter(Position = 0)][string]$Command = 'help',
    [ValidateSet('claude', 'cursor')][string]$Agent = 'claude',
    [string]$Url = 'http://localhost:8000',
    [string]$Key = 'localdev-key',
    [switch]$Ship,
    # The Stop-triggered beacon is throttled to 900s by default, so a claude session
    # shorter than 15 minutes sees exactly ONE beacon - indistinguishable from the old
    # SessionStart-only behaviour, which makes the feature unobservable. 0 means a
    # beacon on every turn. Written to the env FILE, which heartbeat.ps1 honors only
    # because it resolves the knob from the credential map; reading $env: at file
    # scope, as it once did, ignored every env file on Windows.
    #
    # Meaningless for cursor, whose beacon fires once per session and has no throttle.
    [string]$BeaconInterval = '',
    # Required for any URL that is not loopback. See THE URL above.
    [switch]$AllowRemoteUrl,
    # `ship -Reset`: clear the offset state so the whole log re-ships from byte 0.
    [switch]$Reset
)

$ErrorActionPreference = 'Stop'

$repo = Split-Path -Parent (Split-Path -Parent $PSScriptRoot)

$userHome = $env:USERPROFILE
if (-not $userHome) { $userHome = $HOME }
if (-not $userHome) { Write-Host 'cannot resolve a home directory'; exit 1 }

# ── the per-agent table ────────────────────────────────────────────────────
# Everything that differs between the two agents lives HERE and is read from $cfg
# below. Nothing is derived from the slug: the log's provider= token happens to equal
# the slug for these two, but the shipper's FAMILY is a separate field on purpose -
# codex ships codex.log under family `openai`, so a harness that inferred one from the
# other could never grow a third agent correctly.
$agents = @{
    claude = @{
        Slug        = 'claude'
        Family      = 'claude'
        Source      = 'plugins\rogue'
        Manifest    = '.claude-plugin\plugin.json'
        LogName     = 'claude.log'
        Provider    = 'claude'
        # Regex alternation of the closed surface vocabulary for this agent.
        Surfaces    = 'cli|desktop|cowork'
        InstallMode = 'marketplace'
        MarketName  = 'rogue-localdev'
        HasBeacon   = $true      # heartbeat.ps1, detached, with a throttle stamp
        InlineBeacon = $false    # so its outcome never reaches the hook log
        HasProbe    = $true      # `claude -p`
        Restart     = 'Claude Code'
    }
    cursor = @{
        Slug        = 'cursor'
        Family      = 'cursor'
        Source      = 'plugins\cursor'
        Manifest    = '.cursor-plugin\plugin.json'
        LogName     = 'cursor.log'
        Provider    = 'cursor'
        # One surface, and hook.ps1 emits it as a constant, so it is ALWAYS present.
        Surfaces    = 'cursor'
        InstallMode = 'copy'
        # The same path install.ps1 writes, which is why `up` backs up what is there.
        Dest        = (Join-Path $userHome '.cursor\plugins\local\rogue')
        # Both triggers (sessionStart + stop) since cursor 1.1.2, so it stamps and
        # honours -BeaconInterval exactly as claude does.
        HasBeacon   = $true
        # ...but the POST is SYNCHRONOUS, inside the dispatcher, so unlike every other
        # plugin its outcome lands in the hook log (`heartbeat=<status>|throttled`).
        # That is the only reason this flag exists.
        InlineBeacon = $true
        HasProbe    = $false
        Restart     = 'Cursor'
    }
}
$cfg = $agents[$Agent]

$stageRoot = Join-Path $userHome '.rogue-localdev'
$marketDir = Join-Path $stageRoot 'market'
# Per agent, so `up -Agent cursor` cannot clobber the claude run's record.
$stateFile = Join-Path $stageRoot ("state-" + $cfg.Slug)
$envFile   = Join-Path $userHome '.rogue-env'
$envBackup = Join-Path $userHome '.rogue-env.localdev-backup'
$shipDir   = Join-Path (Join-Path $userHome '.rogue') 'ship'
$beaconStamp = Join-Path (Join-Path (Join-Path $userHome '.rogue') 'beacon') (".last-" + $cfg.Slug)

# ROGUE_LOG_FILE is an EXACT path shared by every plugin, so honoring it here would
# make both agents assert the same file. Only ROGUE_LOG_DIR relocates per agent.
$logFile = $env:ROGUE_LOG_FILE
if (-not $logFile) {
    $logDir = $env:ROGUE_LOG_DIR
    if (-not $logDir) { $logDir = Join-Path (Join-Path $userHome '.rogue') 'logs' }
    $logFile = Join-Path $logDir $cfg.LogName
}

# Derived from the LOG FILE'S BASENAME, exactly as Get-StateKeyForPath in ship-logs.ps1
# does - never from the slug. They coincide only because the log is named <slug>.log,
# so a ROGUE_LOG_FILE pointing somewhere else would send `ship` looking for a state
# file that never exists, and it would then report a successful upload as "no offset
# recorded".
function Get-ShipStatePath {
    $base = Split-Path $logFile -Leaf
    if ($base -match '\.log$') { $base = $base.Substring(0, $base.Length - 4) }
    return (Join-Path $shipDir ($base + '.state'))
}

function Say { param([string]$Text = '') Write-Host $Text }
function Fail { param([string]$Text) Write-Host $Text; exit 1 }
function Rule {
    param([string]$Title)
    $pad = 70 - $Title.Length
    if ($pad -lt 1) { $pad = 1 }
    Write-Host ''
    Write-Host ("-- $Title " + ('-' * $pad))
}
function Indent { param([string[]]$Lines, [string]$Prefix = '  ')
    foreach ($l in $Lines) { Write-Host ($Prefix + $l) }
}
function Test-HaveClaude {
    return [bool](Get-Command claude -ErrorAction SilentlyContinue)
}

# BOM-less UTF-8, always. Set-Content -Encoding UTF8 writes a BOM on Windows
# PowerShell 5.1 when it creates a file, and every dispatcher parses the env file line
# by line with `^\s*(?:export\s+)?([A-Z_][A-Z0-9_]*)=` - three leading bytes would make
# the FIRST assignment unmatchable. In practice that is the API key, so the whole
# install would read as unconfigured with no error anywhere.
function Write-TextNoBom {
    param([string]$Path, [string]$Text)
    [System.IO.File]::WriteAllText($Path, $Text, (New-Object System.Text.UTF8Encoding $false))
}

# Read from this agent's own manifest, the same way build-release.sh does.
function Get-PluginVersion {
    param([string]$Root = (Join-Path $repo $cfg.Source))
    $pj = Join-Path $Root $cfg.Manifest
    if (-not (Test-Path -LiteralPath $pj)) { return 'unknown' }
    $m = [regex]::Match((Get-Content -Raw -LiteralPath $pj), '"version"\s*:\s*"([^"]+)"')
    if ($m.Success) { return $m.Groups[1].Value }
    return 'unknown'
}

# claude resolves through its install record; cursor's install IS a known directory.
# ConvertFrom-Json rather than shelling out to node: the sh sibling needs node only
# because sh cannot parse JSON, and requiring it here would be a gratuitous
# prerequisite on a Windows box.
function Get-InstallPath {
    if ($cfg.InstallMode -eq 'copy') {
        if (Test-Path -LiteralPath $cfg.Dest) { return [string]$cfg.Dest }
        return ''
    }
    $f = Join-Path (Join-Path (Join-Path $userHome '.claude') 'plugins') 'installed_plugins.json'
    if (-not (Test-Path -LiteralPath $f)) { return '' }
    try {
        $j = (Get-Content -Raw -LiteralPath $f) | ConvertFrom-Json
        # The key contains an @, so it cannot be reached with dot notation.
        $prop = $j.plugins.PSObject.Properties["rogue@$($cfg.MarketName)"]
        if (-not $prop) { return '' }
        $entries = @($prop.Value)
        if ($entries.Count -eq 0) { return '' }
        return [string]$entries[$entries.Count - 1].installPath
    } catch { return '' }
}

# Stage the working tree into a marketplace layout. claude only - cursor installs by
# copying the plugin directory straight to its destination, with no manifest around it.
function Set-StagedTree {
    if (Test-Path -LiteralPath $marketDir) { Remove-Item -Recurse -Force -LiteralPath $marketDir }
    $mpDir = Join-Path $marketDir '.claude-plugin'
    New-Item -ItemType Directory -Path $mpDir -Force | Out-Null
    New-Item -ItemType Directory -Path (Join-Path $marketDir 'plugins') -Force | Out-Null
    # Rename the marketplace so it cannot collide with a real `rogue-marketplace`
    # entry. The plugin inside is still called `rogue`, hence every claude command is
    # marketplace-qualified.
    $mp = Get-Content -Raw -LiteralPath (Join-Path $repo '.claude-plugin\marketplace.json')
    $mp = $mp -replace '"name"\s*:\s*"rogue-marketplace"', ('"name": "' + $cfg.MarketName + '"')
    Write-TextNoBom (Join-Path $mpDir 'marketplace.json') $mp
    Copy-Item -Recurse -Force -LiteralPath (Join-Path $repo $cfg.Source) `
        -Destination (Join-Path $marketDir 'plugins\rogue')
}

function Test-UrlAllowed {
    if ($Url -match '^https?://(localhost|127\.0\.0\.1|\[::1\])(:[0-9]+)?(/|$)') { return }
    if ($AllowRemoteUrl) {
        Say "  NOTE: $Url is not loopback, allowed by -AllowRemoteUrl."
        Say '  Every Rogue plugin on this machine will send there until you run `down`.'
        return
    }
    Fail @"
$Url is not a loopback URL, so -AllowRemoteUrl is required.

This is a typo guard, not a restriction: ``up`` rewrites $envFile, which ALL SIX Rogue
plugins read, so a wrong host there sends your sessions' prompts and tool calls
somewhere you did not intend - from every agent on this box at once.

Re-run with -AllowRemoteUrl to use it, or forward the port and keep the URL local:
   ssh -N -L 8007:localhost:8007 you@that-machine
"@
}

function Invoke-Up {
    Test-UrlAllowed
    if ($BeaconInterval -ne '' -and $BeaconInterval -notmatch '^[0-9]+$') {
        Fail "-BeaconInterval takes seconds, got: $BeaconInterval"
    }
    if ($BeaconInterval -ne '' -and -not $cfg.HasBeacon) {
        Say "  NOTE: -BeaconInterval is ignored for $Agent - it has no throttled beacon."
        Say '  The knob is written anyway, harmlessly, since the env file is shared.'
    }

    Rule 'the API'
    $reached = $false
    try {
        Invoke-WebRequest -Uri $Url -TimeoutSec 3 -UseBasicParsing | Out-Null
        $reached = $true
    } catch {
        # A 4xx still proves something is listening, which is all this probe asks.
        if ($_.Exception.Response) { $reached = $true }
    }
    if ($reached) {
        Say "  something is listening on $Url"
    } else {
        Say "  WARNING: nothing answered at $Url yet."
        Say '  Continuing anyway - every hook fails open, so an unreachable API costs'
        Say '  you nothing but an outcome=fail line.'
    }

    New-Item -ItemType Directory -Path $stageRoot -Force | Out-Null
    Write-TextNoBom $stateFile ''

    Rule "install the working tree ($Agent)"
    if ($cfg.InstallMode -eq 'copy') {
        # Cursor has no plugin CLI. Its install target is the SAME path the one-line
        # installer uses, so anything already there is a real install and must be moved
        # aside rather than overwritten.
        $dest = [string]$cfg.Dest
        $destBackup = "$dest.localdev-backup"
        if (Test-Path -LiteralPath $dest) {
            if (Test-Path -LiteralPath $destBackup) {
                Say "  $destBackup already exists - keeping it, not re-backing-up"
                Remove-Item -Recurse -Force -LiteralPath $dest
            } else {
                Move-Item -LiteralPath $dest -Destination $destBackup
                Say "  moved the existing install aside -> $destBackup"
                Add-Content -LiteralPath $stateFile -Value 'moved_dest=1'
            }
        }
        New-Item -ItemType Directory -Path $dest -Force | Out-Null
        Copy-Item -Path (Join-Path (Join-Path $repo $cfg.Source) '*') `
            -Destination $dest -Recurse -Force
        Say ("  copied " + (Get-PluginVersion) + " from $repo\$($cfg.Source) -> $dest")
        Add-Content -LiteralPath $stateFile -Value 'installed_copy=1'
    } else {
        if (-not (Test-HaveClaude)) { Fail 'need the `claude` CLI on PATH' }
        Set-StagedTree
        Say ("  staged " + (Get-PluginVersion) + " from $repo -> $marketDir")
        & claude plugin marketplace add $marketDir --scope user 2>&1 | ForEach-Object { Say "  $_" }
        & claude plugin install "rogue@$($cfg.MarketName)" --scope user 2>&1 | ForEach-Object { Say "  $_" }
        $ip = Get-InstallPath
        if (-not $ip) { Fail '  the install produced no record - check the output above' }
        Say "  installed to $ip"
        # Exactly one plugin per event. Recorded so `down` re-enables only what it
        # actually disabled.
        $listed = (& claude plugin list 2>&1 | Out-String)
        if ($listed -match 'rogue@rogue-marketplace') {
            & claude plugin disable rogue@rogue-marketplace --scope user 2>&1 | Out-Null
            if ($LASTEXITCODE -eq 0) {
                Say '  disabled rogue@rogue-marketplace (it would double every event)'
                Add-Content -LiteralPath $stateFile -Value 'disabled_prod=1'
            }
        }
    }

    Rule 'credentials'
    if (Test-Path -LiteralPath $envFile) {
        # Never clobber a real backup: a second `up` without a `down` would otherwise
        # overwrite the saved original with the localdev one and lose it for good.
        if (Test-Path -LiteralPath $envBackup) {
            Say "  $envBackup already exists - keeping it, not re-backing-up"
        } else {
            Copy-Item -LiteralPath $envFile -Destination $envBackup -Force
            Say "  backed up $envFile -> $envBackup"
            Add-Content -LiteralPath $stateFile -Value 'backed_up=1'
        }
    }

    $actorEmail = $env:ROGUE_ACTOR_EMAIL
    if (-not $actorEmail) { $actorEmail = 'localdev@rogue.security' }
    $actorName = $env:ROGUE_ACTOR_NAME
    if (-not $actorName) { $actorName = 'Local Dev' }

    # The same `export KEY=value` shape setup.ps1 writes, because every dispatcher
    # parses it with the same regex and hook.sh may `source` it if this box also runs
    # Git Bash for something else.
    $lines = New-Object System.Collections.Generic.List[string]
    $lines.Add('# Written by tests/manual/local_api.ps1 - LOCAL DEVELOPMENT ONLY.')
    $lines.Add('# Restore the original with: local_api.ps1 down')
    $lines.Add("export ROGUE_API_KEY=$Key")
    $lines.Add("export ROGUE_BASE_URL=$Url")
    $lines.Add("export ROGUE_ACTOR_EMAIL=$actorEmail")
    $lines.Add("export ROGUE_ACTOR_NAME=$actorName")
    if ($Ship) {
        $lines.Add('export ROGUE_SHIP_LOGS=1')
        $lines.Add('export ROGUE_SHIP_MIN_INTERVAL=0')
    }
    if ($BeaconInterval -ne '') {
        $lines.Add("export ROGUE_HEARTBEAT_MIN_INTERVAL=$BeaconInterval")
    }
    Write-TextNoBom $envFile (($lines -join "`n") + "`n")

    # Restrict to the current user, mirroring setup.ps1's chmod 600 equivalent.
    try {
        $acl = Get-Acl $envFile
        $acl.SetAccessRuleProtection($true, $false)
        $rule = New-Object System.Security.AccessControl.FileSystemAccessRule(
            [System.Security.Principal.WindowsIdentity]::GetCurrent().Name, 'FullControl', 'Allow')
        $acl.SetAccessRule($rule)
        Set-Acl $envFile $acl
    } catch {}

    Say "  wrote $envFile (owner-only) -> $Url"
    if ($Ship) { Say '  log shipping ON (your API must serve POST /api/v1/hooks/logs)' }
    if ($BeaconInterval -ne '' -and $cfg.HasBeacon) {
        Say "  beacon throttle ${BeaconInterval}s (0 = a beacon on every Stop)"
    }

    Rule 'next'
    Say "  1. Start your API on $Url"
    Say "  2. RESTART $($cfg.Restart) - a plugin is loaded at session start, so a"
    Say '     running instance is still on the old copy.'
    Say "  3. Use it normally, then:  local_api.ps1 check -Agent $Agent"
    Say ''
    Say '  Edited a script since? Re-push it without a reinstall:'
    Say "     local_api.ps1 sync -Agent $Agent"
}

# `sync` exists because BOTH installs COPY the tree - editing the repo does nothing
# until the copy is refreshed. Refreshing in place beats reinstalling: the install
# record, the version and the enabled state all stay put, and a running session picks
# it up on the next hook invocation (each event spawns a fresh powershell, nothing is
# cached in-process).
function Invoke-Sync {
    $ip = Get-InstallPath
    if (-not $ip) { Fail "$Agent is not installed - run ``up -Agent $Agent`` first" }
    if (-not (Test-Path -LiteralPath $ip)) { Fail "the install record points at $ip, which does not exist" }
    if ($cfg.InstallMode -eq 'copy') {
        $src = Join-Path (Join-Path $repo $cfg.Source) '*'
    } else {
        Set-StagedTree
        $src = Join-Path (Join-Path $marketDir 'plugins\rogue') '*'
    }
    # Copy CONTENTS, so files deleted in the working tree since the install still
    # linger - acceptable, and far safer than a recursive delete of a path read out of
    # a JSON file.
    Copy-Item -Path $src -Destination $ip -Recurse -Force
    Say "synced $repo\$($cfg.Source) -> $ip"
    Say 'Takes effect on the next hook invocation. No restart needed for script edits.'
    Say 'hooks.json changes DO need a restart (the event registration is read once).'
}

function Invoke-Status {
    Rule "installed ($Agent)"
    if ($cfg.InstallMode -eq 'marketplace') {
        if (Test-HaveClaude) {
            $listed = @(& claude plugin list 2>&1 | Where-Object { $_ -match 'rogue' })
            if ($listed.Count) { Indent $listed } else { Say '  (none)' }
        } else { Say '  no `claude` CLI on PATH' }
    }
    $ip = Get-InstallPath
    if ($ip) {
        Say "  install path: $ip"
        Say ("  installed version: " + (Get-PluginVersion $ip) +
             "   working tree: " + (Get-PluginVersion))
        foreach ($f in @('scripts\hook.ps1', 'scripts\ship-logs.ps1')) {
            $mark = if (Test-Path -LiteralPath (Join-Path $ip $f)) { 'yes' } else { 'NO' }
            Say "  has $f : $mark"
        }
    } else { Say "  not installed" }
    if ($cfg.InstallMode -eq 'copy') {
        $destBackup = "$($cfg.Dest).localdev-backup"
        if (Test-Path -LiteralPath $destBackup) { Say "  real install saved at $destBackup" }
    }

    # Which of the two hooks.json entries is doing the work here. Not cosmetic: if you
    # believe you are testing hook.ps1 and Git Bash is absent in a way that also hides
    # powershell, you are testing nothing at all.
    Rule 'which dispatcher owns events'
    $haveSh = [bool](Get-Command sh -ErrorAction SilentlyContinue)
    $havePs = [bool](Get-Command powershell -ErrorAction SilentlyContinue)
    Say "  sh on PATH:         $haveSh"
    Say "  powershell on PATH: $havePs"
    if ($haveSh) {
        Say '  Git Bash present -> hook.sh sees uname=MINGW and stands down (no output,'
        Say '  no log line); Git Bash finds powershell.exe, so hook.ps1 does the work.'
    } else {
        Say '  no Git Bash -> the sh entry is not recognized and exits 0 silently;'
        Say '  hook.ps1 runs directly. Either way hook.ps1 owns every event.'
    }

    Rule 'credentials'
    if (Test-Path -LiteralPath $envFile) {
        $redacted = Get-Content -LiteralPath $envFile |
            ForEach-Object { $_ -replace '^export ROGUE_API_KEY=.*', 'export ROGUE_API_KEY=<redacted>' }
        Indent $redacted
    } else { Say "  no $envFile" }
    if (Test-Path -LiteralPath $envBackup) { Say "  original saved at $envBackup" }

    Rule 'the log'
    Say "  $logFile"
    if (Test-Path -LiteralPath $logFile) {
        Indent (Get-Content -LiteralPath $logFile -Tail 8)
    } else { Say '  (nothing yet)' }
}

# What this branch is supposed to have changed, asserted against real lines a real
# session wrote. Reads local state only - it says nothing about what the API did with
# the requests, which is your backend's to check.
function Invoke-Check {
    if (-not (Test-Path -LiteralPath $logFile)) {
        Fail "no $logFile yet - run a $($cfg.Restart) session first"
    }
    $provider = [string]$cfg.Provider
    $surfaces = [string]$cfg.Surfaces

    Rule 'lines this run wrote'
    Indent (Get-Content -LiteralPath $logFile -Tail 12)

    Rule 'verdict'
    function Ok  { param([string]$T) Write-Host "  ok: $T" }
    # $script: so the counter survives the function scope.
    $script:checkFails = 0
    function Bad { param([string]$T) Write-Host "  FAIL: $T"; $script:checkFails++ }

    $tail = @(Get-Content -LiteralPath $logFile -Tail 40)
    # DISPATCHER lines only. `event=ShipLogs` lines come from ship-logs.ps1, the
    # byte-identical shared script: it takes the slug as an argument and has no surface
    # signal at all, so an absent surface= is correct there per the spec ("absent when
    # the surface cannot be determined"). Counting them as dispatcher lines fails every
    # assertion below as soon as one lands in the tail - which is exactly when -Ship is
    # on and the thing under test is working.
    $recent = @($tail | Where-Object { $_ -notmatch 'event=ShipLogs' })
    $total  = @($recent | Where-Object { $_ -match "provider=$provider" }).Count
    $tagged = @($recent | Where-Object { $_ -match "provider=$provider surface=" }).Count

    if ($total -gt 0) { Ok "the hooks are firing ($total recent lines)" }
    else { Bad "no provider=$provider lines at all - the plugin is not loaded" }

    if ($total -gt 0 -and $tagged -eq $total) {
        Ok "every recent line carries surface= ($tagged/$total)"
    } else {
        Bad "only $tagged of $total recent lines carry surface= - a stale install, or ``sync`` has not run"
    }

    # Position is part of the contract the backend parses on: provider, then surface,
    # then event. A token in the wrong place is worse than a missing one. EVERY tagged
    # line, not any: an assertion that passes as soon as ONE line is right reported ok
    # on a run where most lines were wrong.
    $misplaced = @($recent | Where-Object { $_ -match 'surface=' } |
        Where-Object { $_ -notmatch "provider=$provider surface=[a-z_]+ event=" }).Count
    if ($misplaced -eq 0) { Ok 'surface= sits between provider= and event= on every tagged line' }
    else { Bad "$misplaced tagged line(s) do not have surface= between provider= and event=" }

    # The closed list for THIS agent. Anything else means something leaked in.
    $stray = 0
    foreach ($l in $recent) {
        $m = [regex]::Match($l, 'surface=([^ ]*)')
        if ($m.Success -and $m.Groups[1].Value -notmatch "^($surfaces)$") { $stray++ }
    }
    if ($stray -eq 0) { Ok "every slug is from $provider's closed list ($surfaces)" }
    else { Bad "$stray line(s) carry a slug outside $surfaces" }

    if (@($recent | Where-Object { $_ -match 'surface=unknown' }).Count -eq 0) {
        Ok 'no surface=unknown'
    } else { Bad 'a line says surface=unknown' }
    if (@($recent | Where-Object { $_ -match 'surface=( |$)' }).Count -eq 0) {
        Ok 'no empty surface='
    } else { Bad 'a line has an empty surface=' }

    # ---- the Windows-only byte-level assertions -----------------------------
    # These are the whole reason this file exists. Nothing on a Mac can produce or
    # detect either failure, and both are silent: a parser anchored on the timestamp
    # simply stops matching.
    Rule 'bytes on disk (Windows-only failure modes)'
    $bytes = [System.IO.File]::ReadAllBytes($logFile)
    if ($bytes.Length -ge 3 -and $bytes[0] -eq 0xEF -and $bytes[1] -eq 0xBB -and $bytes[2] -eq 0xBF) {
        Bad 'the log starts with a UTF-8 BOM - a writer used Add-Content -Encoding UTF8'
    } else { Ok 'no UTF-8 BOM at the head of the log' }

    # Sanitize strips \x00-\x1f from every server-controlled string before it is
    # logged, so a CR cannot arrive via raw= or reason=. Any CR here means a writer
    # used Add-Content / Out-File instead of AppendAllText with an explicit "`n".
    #
    # Counted over the decoded STRING, not by piping the byte array through
    # Where-Object: the log is capped at 10 MiB by default, and piping ten million
    # objects to run one comparison each takes minutes.
    $logText = [System.Text.Encoding]::UTF8.GetString($bytes)
    $crCount = $logText.Length - ($logText -replace "`r", '').Length
    if ($crCount -eq 0) { Ok 'LF line endings throughout, matching the sh dispatchers' }
    else { Bad "$crCount CR byte(s) in the log - something wrote CRLF" }

    # ---- the beacon --------------------------------------------------------
    Rule 'the beacon'
    if ($cfg.InlineBeacon) {
        # Cursor's beacon is SYNCHRONOUS inside the dispatcher, so unlike every other
        # plugin it logs its own outcome - `heartbeat=<status>` when it went out,
        # `heartbeat=throttled` when the window swallowed it. Both are evidence the
        # per-turn trigger is wired, and the throttled line is the only place in the
        # whole fleet where a throttle decision is directly observable.
        $hb = @($logText -split "`n" | Where-Object { $_ -match 'heartbeat=' })
        if ($hb.Count) {
            Say "  $($hb.Count) heartbeat line(s); last few:"
            Indent ($hb | Select-Object -Last 3) '    '
            $thr = @($hb | Where-Object { $_ -match 'heartbeat=throttled' }).Count
            if ($thr) { Ok "$thr throttled beacon(s) - the per-turn throttle is live" }
        } else {
            Say '  no heartbeat= lines yet. Cursor beacons at sessionStart and on every'
            Say '  stop - start a session and send one prompt if you expected one.'
        }
    }
    if (-not $cfg.HasBeacon) {
        Say "  (no throttle stamp for $Agent - it has no throttled beacon)"
    } elseif (Test-Path -LiteralPath $beaconStamp) {
        $stampBytes = [System.IO.File]::ReadAllBytes($beaconStamp)
        if ($stampBytes.Length -ge 3 -and $stampBytes[0] -eq 0xEF -and
            $stampBytes[1] -eq 0xBB -and $stampBytes[2] -eq 0xBF) {
            Bad 'the beacon stamp has a BOM - TryParse fails on it, so the throttle is off'
        } else { Ok 'the beacon stamp has no BOM' }
        # Parsed exactly as Request-RogueBeaconSlot parses it. An unparseable stamp reads
        # as "not throttled", so the failure is a silent beacon on every single turn.
        $raw = (Get-Content -LiteralPath $beaconStamp -TotalCount 1) -replace '\s', ''
        $last = [int64]0
        if ([int64]::TryParse($raw, [ref]$last)) {
            # Constructed Utc, never parsed from a Z string: a `Z` literal parses as
            # Local, and subtracting Local from Utc silently yields epoch minus the
            # machine's UTC offset - the exact bug heartbeat.ps1 shipped with.
            $epoch = New-Object DateTime(1970, 1, 1, 0, 0, 0, [DateTimeKind]::Utc)
            $now = [int64][Math]::Floor(((Get-Date).ToUniversalTime() - $epoch).TotalSeconds)
            Ok "the stamp parses as epoch seconds (last beacon $($now - $last)s ago)"
        } else {
            Bad "the stamp does not parse as an integer ([$raw]) - the throttle is disabled"
        }
    } else {
        Say "  no beacon stamp yet at $beaconStamp"
        Say '  Expected after a SessionStart. If it is still missing after a turn, the'
        Say '  Stop hook group is not registered - restart after a sync.'
    }

    # ---- shipping ----------------------------------------------------------
    # A SUCCESSFUL SHIP WRITES NOTHING. ship-logs.* logs only notable outcomes - a
    # fail, a skip, a stall - and deliberately never the happy path, because a line per
    # run would mean every run has new bytes to ship and would destroy the "an idle
    # machine makes no HTTP request at all" property the throttle depends on. So
    # `event=ShipLogs` lines are a FAILURE feed, not a progress feed: the count you
    # want here is ZERO, and the durable evidence of success is the offset below.
    Rule 'shipping'
    $ships = @($logText -split "`n" | Where-Object { $_ -match 'event=ShipLogs' })
    if ($ships.Count -eq 0) {
        Say '  no ShipLogs lines - nothing has FAILED to ship (success is silent)'
    } else {
        Say "  $($ships.Count) ShipLogs line(s) - these are failures/skips, not progress:"
        Indent ($ships | Select-Object -Last 3) '    '
    }
    if (Test-Path -LiteralPath $shipDir) {
        $states = @(Get-ChildItem -LiteralPath $shipDir -Filter '*.state' -ErrorAction SilentlyContinue)
        if ($states.Count -eq 0) { Say "  no .state files yet in $shipDir" }
        $mine = Split-Path (Get-ShipStatePath) -Leaf
        foreach ($st in $states) {
            $body = (Get-Content -Raw -LiteralPath $st.FullName) -replace '\r?\n', ' '
            Say "  $($st.Name): $body"
            # Only the state tracking THIS agent's log may be compared against it - the
            # others track a different file and a different size entirely. Matched on
            # the state FILE NAME, the same key the shipper derives, rather than by
            # searching the body for a log name: `path=` is an absolute path, and a
            # directory that happened to contain the string would match by accident.
            if ($st.Name -ne $mine) { continue }
            # The offset IS the success signal: it advances ONLY on a 2xx, so a value
            # equal to the log size means every byte on disk has been accepted by your
            # API. It must also never EXCEED the file - past the end, every later read
            # is a fragment and the log silently stops shipping.
            $m = [regex]::Match($body, 'offset=([0-9]+)')
            if ($m.Success) {
                $off = [int64]$m.Groups[1].Value
                if ($off -gt $bytes.Length) {
                    Bad "offset $off is PAST the end of the $($bytes.Length)-byte log"
                } elseif ($off -eq $bytes.Length) {
                    Ok "offset $off == log size: every byte has been accepted (2xx)"
                } else {
                    Ok ("offset $off of $($bytes.Length) bytes accepted; " +
                        "$($bytes.Length - $off) still pending - run ``ship`` to flush now")
                }
            }
        }
    } else { Say "  no state directory yet at $shipDir" }

    Say ''
    if ($script:checkFails -eq 0) { Say 'LOCAL API CHECK PASSED' } else { Say "$($script:checkFails) failure(s)" }
    return $script:checkFails
}

# Force one shipper run NOW, instead of waiting for the next session and guessing.
# `-Reset` first deletes the offset state, so the whole log re-ships from byte 0 - the
# only way to get a repeatable, observable POST at your API on demand.
#
# A CHILD PROCESS, never in-process. ship-logs.ps1 ends in `exit 0`, which dot-sourced
# or invoked as a scriptblock here would terminate THIS script, and its `$script:`
# writes would land on this file's variables. Same -EncodedCommand shape the
# dispatchers use to spawn it: every value travels as an environment variable and the
# command itself is a constant, so a plugin path containing a quote cannot alter it,
# and there is no -ArgumentList quoting to get wrong on Windows PowerShell 5.1.
function Invoke-Ship {
    $ip = Get-InstallPath
    if (-not $ip) { Fail "$Agent is not installed - run ``up -Agent $Agent`` first" }
    $shipScript = Join-Path $ip 'scripts\ship-logs.ps1'
    if (-not (Test-Path -LiteralPath $shipScript)) { Fail "no shipper at $shipScript" }

    # ship-logs.ps1 stands down on non-Windows (ship-logs.sh owns macOS/Linux/WSL, so
    # exactly one of the pair ever runs). Without this the child would exit silently
    # having done nothing, and the "offset unchanged" branch below would report it as
    # "nothing new on disk" - a wrong diagnosis of a correct stand-down.
    if ($PSVersionTable.PSVersion.Major -ge 6 -and -not $IsWindows) {
        Fail @'
ship-logs.ps1 stands down on non-Windows, so this subcommand is a no-op here.
Use the sh sibling instead:  bash tests/manual/local_api.sh ship
'@
    }

    Rule "force a ship ($Agent)"
    $stateForLog = Get-ShipStatePath
    if ($Reset) {
        if (Test-Path -LiteralPath $stateForLog) {
            Remove-Item -Force -LiteralPath $stateForLog -ErrorAction SilentlyContinue
            Say "  cleared $stateForLog - the whole log will re-ship from byte 0"
        }
    }
    $before = 0
    if (Test-Path -LiteralPath $stateForLog) {
        $m = [regex]::Match((Get-Content -Raw -LiteralPath $stateForLog), 'offset=([0-9]+)')
        if ($m.Success) { $before = [int64]$m.Groups[1].Value }
    }
    $version = Get-PluginVersion $ip

    # The actor is PASSED IN, exactly as the dispatchers pass it: the shipper must never
    # run a cascade of its own, or the uploaded logs key to a second identity for this
    # machine and join to nothing on the backend.
    $actorEmail = $env:ROGUE_ACTOR_EMAIL
    $actorName  = $env:ROGUE_ACTOR_NAME
    if (-not $actorEmail -or -not $actorName) {
        foreach ($line in (Get-Content -LiteralPath $envFile -ErrorAction SilentlyContinue)) {
            if ($line -match '^\s*(?:export\s+)?ROGUE_ACTOR_EMAIL=(.+)$' -and -not $actorEmail) {
                $actorEmail = $Matches[1].Trim().Trim("'").Trim('"')
            }
            if ($line -match '^\s*(?:export\s+)?ROGUE_ACTOR_NAME=(.+)$' -and -not $actorName) {
                $actorName = $Matches[1].Trim().Trim("'").Trim('"')
            }
        }
    }
    if (-not $actorEmail) { Fail 'no ROGUE_ACTOR_EMAIL to inherit - the shipper would skip with reason=no-actor' }

    $env:ROGUE_ACTOR_EMAIL     = $actorEmail
    $env:ROGUE_ACTOR_NAME      = $actorName
    $env:ROGUE_SHIPPER_SCRIPT  = $shipScript
    $env:ROGUE_SHIPPER_ROOT    = $ip
    $env:ROGUE_SHIPPER_SLUG    = [string]$cfg.Slug
    $env:ROGUE_SHIPPER_VERSION = [string]$version
    $env:ROGUE_SHIPPER_FAMILY  = [string]$cfg.Family
    # ROGUE_DEBUG on, so every outcome also goes to stderr. Without it a successful run
    # prints nothing at all and looks identical to a run that did nothing.
    $env:ROGUE_DEBUG = '1'
    $inner = '& ([scriptblock]::Create((Get-Content -Raw -LiteralPath $env:ROGUE_SHIPPER_SCRIPT)))' +
             ' $env:ROGUE_SHIPPER_ROOT $env:ROGUE_SHIPPER_SLUG' +
             ' $env:ROGUE_SHIPPER_VERSION $env:ROGUE_SHIPPER_FAMILY'
    $encoded = [Convert]::ToBase64String([System.Text.Encoding]::Unicode.GetBytes($inner))
    $psExe = 'powershell'
    try { if ((Get-Process -Id $PID).Path) { $psExe = (Get-Process -Id $PID).Path } } catch {}
    Say "  running $shipScript (slug=$($cfg.Slug) version=$version family=$($cfg.Family))"
    & $psExe -NoProfile -NonInteractive -EncodedCommand $encoded 2>&1 |
        ForEach-Object { Say "  ship: $_" }

    $after = 0
    if (Test-Path -LiteralPath $stateForLog) {
        $m = [regex]::Match((Get-Content -Raw -LiteralPath $stateForLog), 'offset=([0-9]+)')
        if ($m.Success) { $after = [int64]$m.Groups[1].Value }
    }
    Say ''
    if ($after -gt $before) {
        Say "  OFFSET ADVANCED $before -> $after ($($after - $before) bytes accepted with a 2xx)"
        Say '  That is durable proof your API accepted them - the offset moves on 2xx only.'
    } elseif ($before -gt 0) {
        Say "  offset unchanged at $before. Tell the two cases apart by the ship: lines:"
        Say '    no POST line at all -> nothing new on disk (an idle run makes no request)'
        Say '    a POST line then outcome=fail http=NNN -> your API rejected the bytes'
    } else {
        Say '  no offset recorded. Most likely ROGUE_SHIP_LOGS is not enabled (shipping is'
        Say '  OPT-IN), or an env file carries the ROGUE_SHIP_LOGS=0 kill switch, which'
        Say '  process env deliberately cannot override. Re-run `up` with -Ship.'
    }
}

# A headless probe, for when you do not want to restart your editor to see whether the
# API is wired up. Claude Code did NOT run plugin-provided hooks in a `claude -p` run
# on 2.1.223, so this registers the INSTALLED plugin's own hooks.json through
# --settings - the same trick, and the same caveat, as live_session.sh.
function Invoke-Probe {
    if (-not $cfg.HasProbe) {
        Fail "there is no headless CLI for $Agent, so `probe` does not apply. Start $($cfg.Restart), use it, then run ``check -Agent $Agent``."
    }
    if (-not (Test-HaveClaude)) { Fail 'need the `claude` CLI on PATH' }
    $ip = Get-InstallPath
    if (-not $ip) { Fail "$Agent is not installed - run ``up -Agent $Agent`` first" }
    $settings = Join-Path $stageRoot 'hooks-settings.json'
    New-Item -ItemType Directory -Path $stageRoot -Force | Out-Null

    $hooksRaw = Get-Content -Raw -LiteralPath (Join-Path $ip 'hooks\hooks.json')
    # The only edit: expand ${CLAUDE_PLUGIN_ROOT}, which Claude Code substitutes for a
    # plugin hook but not for a settings hook. Substituted on the RAW TEXT, so the
    # backslashes in the Windows path must be JSON-escaped by hand before they go in -
    # the round-trip through ConvertFrom-Json/ConvertTo-Json below then re-escapes the
    # polyglot's nested quoting correctly, exactly as the sh sibling's JSON.parse /
    # JSON.stringify pair does.
    $expanded = $hooksRaw.Replace('${CLAUDE_PLUGIN_ROOT}', $ip.Replace('\', '\\'))
    $hooks = ($expanded | ConvertFrom-Json).hooks
    Write-TextNoBom $settings (@{ hooks = $hooks } | ConvertTo-Json -Depth 100)
    Say ("  registered " + @($hooks.PSObject.Properties).Count + " events from $ip")

    Rule 'one headless session'
    Push-Location $stageRoot
    try {
        $env:CLAUDE_PLUGIN_ROOT = $ip
        & claude --settings $settings --output-format text `
            -p 'Run the shell command `echo rogue-localdev-probe` and then reply with just the word done.' 2>&1 |
            ForEach-Object { Say "  claude: $_" }
    } finally { Pop-Location }
    return (Invoke-Check)
}

function Invoke-Down {
    Rule "undo ($Agent)"
    $state = ''
    if (Test-Path -LiteralPath $stateFile) { $state = (Get-Content -Raw -LiteralPath $stateFile) }

    if ($cfg.InstallMode -eq 'copy') {
        $dest = [string]$cfg.Dest
        $destBackup = "$dest.localdev-backup"
        if (Test-Path -LiteralPath $dest) {
            Remove-Item -Recurse -Force -LiteralPath $dest
            Say "  removed $dest"
        }
        if (Test-Path -LiteralPath $destBackup) {
            Move-Item -LiteralPath $destBackup -Destination $dest
            Say "  restored the real install from $destBackup"
        }
    } else {
        if (Test-HaveClaude) {
            & claude plugin uninstall "rogue@$($cfg.MarketName)" --scope user 2>&1 | Out-Null
            if ($LASTEXITCODE -eq 0) { Say "  uninstalled rogue@$($cfg.MarketName)" }
            & claude plugin marketplace remove $cfg.MarketName 2>&1 | Out-Null
            if ($LASTEXITCODE -eq 0) { Say "  removed the $($cfg.MarketName) marketplace" }
        }
        # Uninstalling leaves the extracted tree in the cache, and that leftover is not
        # inert: it is a NEWER copy than your real install, so anything resolving the
        # plugin root by "newest under the cache" - the last-resort layer of the
        # /rogue:status support snippet - would pick this one.
        $cache = Join-Path (Join-Path (Join-Path (Join-Path $userHome '.claude') 'plugins') 'cache') $cfg.MarketName
        if (Test-Path -LiteralPath $cache) {
            Remove-Item -Recurse -Force -LiteralPath $cache
            Say '  removed its plugin cache'
        }
        if ($state -match 'disabled_prod=1' -and (Test-HaveClaude)) {
            & claude plugin enable rogue@rogue-marketplace --scope user 2>&1 | Out-Null
            if ($LASTEXITCODE -eq 0) { Say '  re-enabled rogue@rogue-marketplace' }
        }
    }

    # The env file is SHARED, so restore it only when no other agent is still up.
    $otherUp = @(Get-ChildItem -LiteralPath $stageRoot -Filter 'state-*' -ErrorAction SilentlyContinue |
        Where-Object { $_.Name -ne (Split-Path -Leaf $stateFile) }).Count
    if (Test-Path -LiteralPath $stateFile) { Remove-Item -Force -LiteralPath $stateFile }
    if ($otherUp -gt 0) {
        Say "  $otherUp other agent(s) still up - leaving $envFile pointing at the local API"
    } elseif (Test-Path -LiteralPath $envBackup) {
        Move-Item -LiteralPath $envBackup -Destination $envFile -Force
        Say "  restored $envFile from the backup"
        if (Test-Path -LiteralPath $stageRoot) {
            Remove-Item -Recurse -Force -LiteralPath $stageRoot
            Say '  removed the staging directory'
        }
    } else {
        Say "  no backup to restore - $envFile still points at the local API."
        Say '  Run /rogue:setup to write your real credentials back.'
    }
    Say ''
    Say "  RESTART $($cfg.Restart) to unload the plugin."
}

switch ($Command) {
    'up'     { Invoke-Up; exit 0 }
    'sync'   { Invoke-Sync; exit 0 }
    'status' { Invoke-Status; exit 0 }
    'check'  { exit (Invoke-Check) }
    'ship'   { Invoke-Ship; exit 0 }
    'probe'  { exit (Invoke-Probe) }
    'down'   { Invoke-Down; exit 0 }
    default  {
        # The usage block at the top of this file, so there is one copy of it. Keep the
        # count in step with that block - a stale one silently truncates the help.
        foreach ($l in (Get-Content -LiteralPath $PSCommandPath -TotalCount 15)) {
            Write-Host ($l -replace '^# ?', '')
        }
        exit 1
    }
}
