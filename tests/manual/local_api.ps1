# Point a NATIVE WINDOWS Claude Code at the plugin WORKING TREE and a LOCAL Rogue
# API, so you can exercise uncommitted plugin changes against a backend you control.
#
#   pwsh -File tests\manual\local_api.ps1 up [-Url URL] [-Key KEY] [-Ship] [-BeaconInterval N]
#   pwsh -File tests\manual\local_api.ps1 sync      # re-push working-tree edits, no reinstall
#   pwsh -File tests\manual\local_api.ps1 status    # what is installed, where it points
#   pwsh -File tests\manual\local_api.ps1 check     # assert the log looks like this branch
#   pwsh -File tests\manual\local_api.ps1 ship [-Reset]   # force a log upload NOW
#   pwsh -File tests\manual\local_api.ps1 probe     # one headless session, no restart
#   pwsh -File tests\manual\local_api.ps1 down      # undo everything `up` did
#
# Every command also runs under Windows PowerShell 5.1 (`powershell -File ...`); this
# file is kept 5.1-clean, so a box without pwsh 7 needs nothing extra installed.
#
# WHY THIS FILE EXISTS AT ALL, given tests/manual/local_api.sh already does this.
# Two reasons, and neither is cosmetic:
#
#   1. It is the ONLY way to exercise hook.ps1 / heartbeat.ps1 / ship-logs.ps1 through
#      real Claude Code. tests/e2e_ship_logs.ps1 covers the shipper on a windows-latest
#      runner, but nothing anywhere drives the PowerShell DISPATCHER from a real
#      session, real hooks.json and a real API. On a Mac that code never runs.
#   2. The sh harness cannot be run here even under Git Bash. `install_path` reads a
#      Windows path out of installed_plugins.json, and `cp -R "$IP/"` on a
#      `C:\Users\...` string eats the backslashes as escapes. It would appear to work
#      and silently sync nothing.
#
# WHICH DISPATCHER YOU ARE ACTUALLY TESTING. Per the exactly-one-runs table, on
# native Windows WITH Git Bash installed the sh entry stands down (hook.sh sees
# uname=MINGW and emits nothing) and Git Bash finds powershell.exe on PATH, so the
# PowerShell entry does the work. WITHOUT Git Bash, `sh` is not recognized and the
# PowerShell entry runs directly. Either way hook.ps1 owns every event here - which
# is the point. `status` prints which of the two shapes you are in.
#
# REACHING AN API THAT RUNS ON ANOTHER MACHINE. The localhost-only guard below is
# deliberate and stays: this file rewrites the credentials of EVERY Rogue plugin on
# the box, so a typo in a URL would ship your prompts somewhere unintended. If the
# API runs on your Mac, do not widen the guard - forward the port instead, so the
# URL really is local:
#
#   ssh -N -L 8007:localhost:8007 you@your-mac
#
# Windows 10+ ships the OpenSSH client; the Mac needs Remote Login on. Then
# http://localhost:8007 on this box is your Mac's API and the guard stays honest.
#
# WHAT `up` CHANGES ON THIS MACHINE (all of it undone by `down`)
#
#   * Adds a marketplace `rogue-localdev` sourced from a copy of your working tree,
#     and installs `rogue@rogue-localdev` at user scope.
#   * DISABLES `rogue@rogue-marketplace` if present, so exactly one plugin answers
#     each event. Two enabled copies double every POST and write two log lines per
#     event, which ruins the log for the thing you are trying to observe.
#   * Replaces %USERPROFILE%\.rogue-env, keeping the original at
#     .rogue-env.localdev-backup. THAT FILE IS SHARED BY ALL SIX PLUGINS: while this
#     is up, any Codex, Cursor, Gemini, Copilot or Antigravity install here also talks
#     to your local API with the local key. Usually what you want for a backend test;
#     never what you want left running.
#   * Nothing else. The log stays at its real path so /rogue:status reads the same
#     file you are watching.

param(
    [Parameter(Position = 0)][string]$Command = 'help',
    [string]$Url = 'http://localhost:8000',
    [string]$Key = 'localdev-key',
    [switch]$Ship,
    # The Stop-triggered beacon is throttled to 900s by default, so a test session
    # shorter than 15 minutes sees exactly ONE beacon - indistinguishable from the old
    # SessionStart-only behaviour, which makes the feature unobservable. 0 means a
    # beacon on every turn. Written to the env FILE, which heartbeat.ps1 honors only
    # because it now resolves the knob from the credential map; reading $env: at file
    # scope, as it once did, ignored every env file on Windows.
    [string]$BeaconInterval = '',
    # `ship -Reset`: clear the offset state so the whole log re-ships from byte 0.
    [switch]$Reset
)

$ErrorActionPreference = 'Stop'

$repo = Split-Path -Parent (Split-Path -Parent $PSScriptRoot)
$marketName = 'rogue-localdev'

$userHome = $env:USERPROFILE
if (-not $userHome) { $userHome = $HOME }
if (-not $userHome) { Write-Host 'cannot resolve a home directory'; exit 1 }

$stageRoot  = Join-Path $userHome '.rogue-localdev'
$marketDir  = Join-Path $stageRoot 'market'
$stateFile  = Join-Path $stageRoot 'state'
$envFile    = Join-Path $userHome '.rogue-env'
$envBackup  = Join-Path $userHome '.rogue-env.localdev-backup'
$beaconStamp = Join-Path (Join-Path (Join-Path $userHome '.rogue') 'beacon') '.last-claude'
$shipDir    = Join-Path (Join-Path $userHome '.rogue') 'ship'

$logFile = $env:ROGUE_LOG_FILE
if (-not $logFile) {
    $logFile = Join-Path (Join-Path (Join-Path $userHome '.rogue') 'logs') 'claude.log'
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
    $c = Get-Command claude -ErrorAction SilentlyContinue
    return [bool]$c
}

# BOM-less UTF-8, always. Set-Content -Encoding UTF8 writes a BOM on Windows
# PowerShell 5.1 when it creates a file, and hook.ps1 parses the env file line by
# line with `^\s*(?:export\s+)?([A-Z_][A-Z0-9_]*)=` - three leading bytes would make
# the FIRST assignment in the file unmatchable. In practice that is the API key, so
# the whole install would read as unconfigured with no error anywhere.
function Write-TextNoBom {
    param([string]$Path, [string]$Text)
    [System.IO.File]::WriteAllText($Path, $Text, (New-Object System.Text.UTF8Encoding $false))
}

# The version the marketplace advertises, read the same way build-release.sh does.
function Get-PluginVersion {
    $pj = Join-Path $repo 'plugins\rogue\.claude-plugin\plugin.json'
    $m = [regex]::Match((Get-Content -Raw -LiteralPath $pj), '"version"\s*:\s*"([^"]+)"')
    if ($m.Success) { return $m.Groups[1].Value }
    return 'unknown'
}

# ConvertFrom-Json rather than shelling out to node: the sh sibling needs node only
# because sh cannot parse JSON, and requiring it here would be a gratuitous
# prerequisite on a Windows box.
function Get-InstallPath {
    $f = Join-Path (Join-Path (Join-Path $userHome '.claude') 'plugins') 'installed_plugins.json'
    if (-not (Test-Path -LiteralPath $f)) { return '' }
    try {
        $j = (Get-Content -Raw -LiteralPath $f) | ConvertFrom-Json
        # The key contains an @, so it cannot be reached with dot notation.
        $prop = $j.plugins.PSObject.Properties["rogue@$marketName"]
        if (-not $prop) { return '' }
        $entries = @($prop.Value)
        if ($entries.Count -eq 0) { return '' }
        return [string]$entries[$entries.Count - 1].installPath
    } catch { return '' }
}

# Copy the working tree into the marketplace: only the two paths a Claude
# marketplace install reads. Copying the whole repo would drag .git along for nothing.
function Set-StagedTree {
    if (Test-Path -LiteralPath $marketDir) { Remove-Item -Recurse -Force -LiteralPath $marketDir }
    $mpDir = Join-Path $marketDir '.claude-plugin'
    New-Item -ItemType Directory -Path $mpDir -Force | Out-Null
    New-Item -ItemType Directory -Path (Join-Path $marketDir 'plugins') -Force | Out-Null
    # Rename the marketplace so it cannot collide with a real `rogue-marketplace`
    # entry. The plugin inside is still called `rogue`, hence every claude command
    # below is marketplace-qualified.
    $mp = Get-Content -Raw -LiteralPath (Join-Path $repo '.claude-plugin\marketplace.json')
    $mp = $mp -replace '"name"\s*:\s*"rogue-marketplace"', ('"name": "' + $marketName + '"')
    Write-TextNoBom (Join-Path $mpDir 'marketplace.json') $mp
    Copy-Item -Recurse -Force -LiteralPath (Join-Path $repo 'plugins\rogue') `
        -Destination (Join-Path $marketDir 'plugins\rogue')
}

function Invoke-Up {
    if (-not (Test-HaveClaude)) { Fail 'need the `claude` CLI on PATH' }

    # The guard. Escaped brackets for the IPv6 literal, and anchored at the start so a
    # URL like http://localhost.evil.example cannot slip past on a prefix match.
    if ($Url -notmatch '^http://(localhost|127\.0\.0\.1|\[::1\]):[0-9]+') {
        Fail @"
refusing to point at a non-local URL ($Url). This rewrites %USERPROFILE%\.rogue-env
for EVERY Rogue plugin on the machine; a typo here sends your sessions' prompts and
tool calls somewhere you did not intend.
If the API runs on another machine, forward its port instead:
   ssh -N -L 8007:localhost:8007 you@that-machine
"@
    }
    if ($BeaconInterval -ne '' -and $BeaconInterval -notmatch '^[0-9]+$') {
        Fail "-BeaconInterval takes seconds, got: $BeaconInterval"
    }

    Rule 'the local API'
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

    Rule 'install the working tree'
    Set-StagedTree
    Say ("  staged " + (Get-PluginVersion) + " from $repo -> $marketDir")
    & claude plugin marketplace add $marketDir --scope user 2>&1 | ForEach-Object { Say "  $_" }
    & claude plugin install "rogue@$marketName" --scope user 2>&1 | ForEach-Object { Say "  $_" }
    $ip = Get-InstallPath
    if (-not $ip) { Fail '  the install produced no record - check the output above' }
    Say "  installed to $ip"

    # Exactly one plugin per event. Recorded so `down` re-enables only what it
    # actually disabled.
    New-Item -ItemType Directory -Path $stageRoot -Force | Out-Null
    Write-TextNoBom $stateFile ''
    $listed = (& claude plugin list 2>&1 | Out-String)
    if ($listed -match 'rogue@rogue-marketplace') {
        & claude plugin disable rogue@rogue-marketplace --scope user 2>&1 | Out-Null
        if ($LASTEXITCODE -eq 0) {
            Say '  disabled rogue@rogue-marketplace (it would double every event)'
            Add-Content -LiteralPath $stateFile -Value 'disabled_prod=1'
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

    # The same `export KEY=value` shape setup.ps1 writes, because hook.ps1 and
    # ship-logs.ps1 parse it with the same regex and hook.sh may `source` it if this
    # box also runs Git Bash for something else.
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
    if ($BeaconInterval -ne '') {
        Say "  beacon throttle ${BeaconInterval}s (0 = a beacon on every Stop)"
    }

    Rule 'next'
    Say "  1. Start your local API on $Url"
    Say '  2. RESTART Claude Code - a plugin is loaded at session start, so this'
    Say '     session is still running the old copy.'
    Say '  3. Use it normally, then:  local_api.ps1 check'
    Say ''
    Say '  Edited a script since? Re-push it without a reinstall:'
    Say '     local_api.ps1 sync'
}

# `sync` exists because the install COPIES the tree - editing plugins\rogue in the
# repo does nothing until the copy is refreshed. Refreshing in place beats
# uninstall/reinstall: the install record, the version and the enabled state all stay
# put, and a running session picks it up on the next hook invocation (each event
# spawns a fresh powershell, nothing is cached in-process).
function Invoke-Sync {
    $ip = Get-InstallPath
    if (-not $ip) { Fail "rogue@$marketName is not installed - run ``up`` first" }
    if (-not (Test-Path -LiteralPath $ip)) { Fail "the install record points at $ip, which does not exist" }
    Set-StagedTree
    # Copy CONTENTS, so files deleted in the working tree since the install still
    # linger - acceptable, and far safer than a recursive delete of a path read out of
    # a JSON file.
    Copy-Item -Path (Join-Path (Join-Path $marketDir 'plugins\rogue') '*') `
        -Destination $ip -Recurse -Force
    Say "synced $repo\plugins\rogue -> $ip"
    Say 'Takes effect on the next hook invocation. No restart needed for script edits.'
    Say 'hooks.json changes DO need a restart (the event registration is read once).'
}

function Invoke-Status {
    Rule 'plugins'
    if (Test-HaveClaude) {
        $listed = @(& claude plugin list 2>&1 | Where-Object { $_ -match 'rogue' })
        if ($listed.Count) { Indent $listed } else { Say '  (none)' }
    } else { Say '  no `claude` CLI on PATH' }
    $ip = Get-InstallPath
    if ($ip) {
        Say "  localdev install path: $ip"
        if (Test-Path -LiteralPath (Join-Path $ip 'scripts\surface.ps1')) {
            Say '  the installed copy HAS scripts\surface.ps1 (this branch)'
        } else {
            Say '  the installed copy has NO scripts\surface.ps1 - it predates this branch,'
            Say '  or `sync` has not run since you switched branches'
        }
    }

    # Which of the two hooks.json entries is doing the work here. Not cosmetic: if you
    # believe you are testing hook.ps1 and Git Bash is absent in a way that also hides
    # powershell, you are testing nothing at all.
    Rule 'which dispatcher owns events'
    $haveSh = [bool](Get-Command sh -ErrorAction SilentlyContinue)
    $havePs = [bool](Get-Command powershell -ErrorAction SilentlyContinue)
    Say ("  sh on PATH:         $haveSh")
    Say ("  powershell on PATH: $havePs")
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
    if (-not (Test-Path -LiteralPath $logFile)) { Fail "no $logFile yet - run a session first" }

    Rule 'lines this run wrote'
    Indent (Get-Content -LiteralPath $logFile -Tail 12)

    Rule 'verdict'
    function Ok  { param([string]$T) Write-Host "  ok: $T" }
    # $script: so the counter survives the function scope.
    $script:checkFails = 0
    function Bad { param([string]$T) Write-Host "  FAIL: $T"; $script:checkFails++ }

    $tail = @(Get-Content -LiteralPath $logFile -Tail 40)
    # DISPATCHER lines only. `event=ShipLogs` lines come from ship-logs.ps1, the
    # byte-identical shared script: it takes the slug as an argument and has no
    # surface signal at all, so an absent surface= is correct there per the spec
    # ("absent when the surface cannot be determined"). Counting them as dispatcher
    # lines fails every assertion below as soon as one lands in the tail - which is
    # exactly when -Ship is on and the thing under test is working.
    $recent = @($tail | Where-Object { $_ -notmatch 'event=ShipLogs' })
    $total  = @($recent | Where-Object { $_ -match 'provider=claude' }).Count
    $tagged = @($recent | Where-Object { $_ -match 'provider=claude surface=' }).Count

    if ($total -gt 0) { Ok "the hooks are firing ($total recent lines)" }
    else { Bad 'no provider=claude lines at all - the plugin is not loaded' }

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
        Where-Object { $_ -notmatch 'provider=claude surface=[a-z_]+ event=' }).Count
    if ($misplaced -eq 0) { Ok 'surface= sits between provider= and event= on every tagged line' }
    else { Bad "$misplaced tagged line(s) do not have surface= between provider= and event=" }

    # The closed list for claude. Anything else means something leaked into the token.
    $stray = 0
    foreach ($l in $recent) {
        $m = [regex]::Match($l, 'surface=([^ ]*)')
        if ($m.Success -and $m.Groups[1].Value -notmatch '^(cli|desktop|cowork)$') { $stray++ }
    }
    if ($stray -eq 0) { Ok "every slug is from claude's closed list" }
    else { Bad "$stray line(s) carry a slug outside cli/desktop/cowork" }

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

    # ---- the Stop-triggered beacon -----------------------------------------
    Rule 'the Stop beacon'
    if (Test-Path -LiteralPath $beaconStamp) {
        $stampBytes = [System.IO.File]::ReadAllBytes($beaconStamp)
        if ($stampBytes.Length -ge 3 -and $stampBytes[0] -eq 0xEF -and
            $stampBytes[1] -eq 0xBB -and $stampBytes[2] -eq 0xBF) {
            Bad 'the beacon stamp has a BOM - TryParse fails on it, so the throttle is off'
        } else { Ok 'the beacon stamp has no BOM' }
        # Parsed exactly as Test-BeaconThrottled parses it. An unparseable stamp reads
        # as "not throttled", so the failure is a silent beacon on every single turn.
        $raw = (Get-Content -LiteralPath $beaconStamp -TotalCount 1) -replace '\s', ''
        $last = [int64]0
        if ([int64]::TryParse($raw, [ref]$last)) {
            $now = [int64][Math]::Floor((Get-Date).ToUniversalTime().Subtract(
                [datetime]'1970-01-01T00:00:00Z').TotalSeconds)
            Ok "the stamp parses as epoch seconds (last beacon $($now - $last)s ago)"
        } else {
            Bad "the stamp does not parse as an integer ([$raw]) - the throttle is disabled"
        }
    } else {
        Say "  no beacon stamp yet at $beaconStamp"
        Say '  Expected after a SessionStart. If it is still missing after a turn, the'
        Say '  Stop hook group is not registered - restart Claude Code after a sync.'
    }

    # ---- shipping ----------------------------------------------------------
    # A SUCCESSFUL SHIP WRITES NOTHING. ship-logs.* logs only notable outcomes - a
    # fail, a skip, a stall - and deliberately never the happy path, because a line
    # per run would mean every run has new bytes to ship and would destroy the "an
    # idle machine makes no HTTP request at all" property the throttle depends on.
    # So `event=ShipLogs` lines are a FAILURE feed, not a progress feed: the count you
    # want here is ZERO, and the durable evidence of success is the offset below.
    Rule 'shipping'
    # Reuses the text decoded above rather than re-reading the file.
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
        foreach ($st in $states) {
            $body = (Get-Content -Raw -LiteralPath $st.FullName) -replace '\r?\n', ' '
            Say "  $($st.Name): $body"
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

# Force one shipper run NOW, instead of waiting for the next Stop and guessing.
# `-Reset` first deletes the offset state, so the whole log re-ships from byte 0 - the
# only way to get a repeatable, observable POST at your API on demand.
#
# A CHILD PROCESS, never in-process. ship-logs.ps1 ends in `exit 0`, which dot-sourced
# or invoked as a scriptblock here would terminate THIS script, and its `$script:`
# writes would land on this file's variables. Same -EncodedCommand shape heartbeat.ps1
# uses to spawn it: every value travels as an environment variable and the command
# itself is a constant, so a plugin path containing a quote cannot alter it, and there
# is no -ArgumentList quoting to get wrong on Windows PowerShell 5.1.
function Invoke-Ship {
    $ip = Get-InstallPath
    if (-not $ip) { Fail "rogue@$marketName is not installed - run ``up`` first" }
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

    Rule 'force a ship'
    if ($Reset) {
        if (Test-Path -LiteralPath $shipDir) {
            Remove-Item -Force -Path (Join-Path $shipDir '*.state') -ErrorAction SilentlyContinue
            Say '  cleared the offset state - the whole log will re-ship from byte 0'
        }
    }
    $before = 0
    $stateFileForLog = Join-Path $shipDir 'claude.state'
    if (Test-Path -LiteralPath $stateFileForLog) {
        $m = [regex]::Match((Get-Content -Raw -LiteralPath $stateFileForLog), 'offset=([0-9]+)')
        if ($m.Success) { $before = [int64]$m.Groups[1].Value }
    }

    $version = 'unknown'
    $pj = Join-Path $ip '.claude-plugin\plugin.json'
    if (Test-Path -LiteralPath $pj) {
        $m = [regex]::Match((Get-Content -Raw -LiteralPath $pj), '"version"\s*:\s*"([^"]+)"')
        if ($m.Success) { $version = $m.Groups[1].Value }
    }

    # The actor is PASSED IN, exactly as heartbeat.ps1 passes it: the shipper must
    # never run a cascade of its own, or the uploaded logs key to a second identity for
    # this machine and join to nothing on the backend.
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
    $env:ROGUE_SHIPPER_SLUG    = 'claude'
    $env:ROGUE_SHIPPER_VERSION = $version
    $env:ROGUE_SHIPPER_FAMILY  = 'claude'
    # ROGUE_DEBUG on, so every outcome also goes to stderr. Without it a successful run
    # prints nothing at all and looks identical to a run that did nothing.
    $env:ROGUE_DEBUG = '1'
    $inner = '& ([scriptblock]::Create((Get-Content -Raw -LiteralPath $env:ROGUE_SHIPPER_SCRIPT)))' +
             ' $env:ROGUE_SHIPPER_ROOT $env:ROGUE_SHIPPER_SLUG' +
             ' $env:ROGUE_SHIPPER_VERSION $env:ROGUE_SHIPPER_FAMILY'
    $encoded = [Convert]::ToBase64String([System.Text.Encoding]::Unicode.GetBytes($inner))
    $psExe = 'powershell'
    try { if ((Get-Process -Id $PID).Path) { $psExe = (Get-Process -Id $PID).Path } } catch {}
    Say "  running $shipScript (slug=claude version=$version family=claude)"
    # -Wait and inherited streams, unlike the heartbeat's detached spawn: here you want
    # to see the outcome, not fire and forget.
    & $psExe -NoProfile -NonInteractive -EncodedCommand $encoded 2>&1 |
        ForEach-Object { Say "  ship: $_" }

    $after = 0
    if (Test-Path -LiteralPath $stateFileForLog) {
        $m = [regex]::Match((Get-Content -Raw -LiteralPath $stateFileForLog), 'offset=([0-9]+)')
        if ($m.Success) { $after = [int64]$m.Groups[1].Value }
    }
    Say ''
    if ($after -gt $before) {
        Say "  OFFSET ADVANCED $before -> $after ($($after - $before) bytes accepted with a 2xx)"
        Say '  That is the durable proof your API accepted them - the offset moves on 2xx only.'
    } elseif ($after -eq $before -and $before -gt 0) {
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
    if (-not (Test-HaveClaude)) { Fail 'need the `claude` CLI on PATH' }
    $ip = Get-InstallPath
    if (-not $ip) { Fail "rogue@$marketName is not installed - run ``up`` first" }
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
    Rule 'undo'
    if (Test-HaveClaude) {
        & claude plugin uninstall "rogue@$marketName" --scope user 2>&1 | Out-Null
        if ($LASTEXITCODE -eq 0) { Say "  uninstalled rogue@$marketName" }
        & claude plugin marketplace remove $marketName 2>&1 | Out-Null
        if ($LASTEXITCODE -eq 0) { Say "  removed the $marketName marketplace" }
    }
    # Uninstalling leaves the extracted tree in the cache, and that leftover is not
    # inert: it is a NEWER copy than your real install, so anything resolving the
    # plugin root by "newest under the cache" - the last-resort layer of the
    # /rogue:status support snippet - would pick this one.
    $cache = Join-Path (Join-Path (Join-Path (Join-Path $userHome '.claude') 'plugins') 'cache') $marketName
    if (Test-Path -LiteralPath $cache) {
        Remove-Item -Recurse -Force -LiteralPath $cache
        Say '  removed its plugin cache'
    }
    if ((Test-Path -LiteralPath $stateFile) -and
        ((Get-Content -Raw -LiteralPath $stateFile) -match 'disabled_prod=1')) {
        if (Test-HaveClaude) {
            & claude plugin enable rogue@rogue-marketplace --scope user 2>&1 | Out-Null
            if ($LASTEXITCODE -eq 0) { Say '  re-enabled rogue@rogue-marketplace' }
        }
    }
    if (Test-Path -LiteralPath $envBackup) {
        Move-Item -LiteralPath $envBackup -Destination $envFile -Force
        Say "  restored $envFile from the backup"
    } else {
        Say "  no backup to restore - $envFile still points at the local API."
        Say '  Run /rogue:setup to write your real credentials back.'
    }
    if (Test-Path -LiteralPath $stageRoot) {
        Remove-Item -Recurse -Force -LiteralPath $stageRoot
        Say '  removed the staging directory'
    }
    Say ''
    Say '  RESTART Claude Code to unload the plugin.'
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
        foreach ($l in (Get-Content -LiteralPath $PSCommandPath -TotalCount 13)) {
            Write-Host ($l -replace '^# ?', '')
        }
        exit 1
    }
}
