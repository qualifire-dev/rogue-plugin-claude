# Contract test for THE BEACON THROTTLE in plugins/rogue/scripts/heartbeat.ps1.
#
# The PowerShell twin of tests/test_heartbeat_sh.sh. Both halves must agree case
# for case: a machine's beacon cadence must not depend on its operating system,
# and the two implementations share nothing but this contract.
#
# Runs anywhere pwsh runs, including Linux CI, by dot-sourcing through the
# ROGUE_PS_LIB_ONLY seam - so the credential loading and the real POST below it
# never execute. Windows PowerShell 5.1 must also pass; keep the syntax 5.1-clean.
#
#   pwsh -File tests/test_heartbeat_ps1.ps1

$ErrorActionPreference = 'Stop'
$repo = Split-Path -Parent (Split-Path -Parent $PSCommandPath)
$script:fails = 0

function Check {
    param([string]$Label, $Expected, $Actual)
    if ($Expected -eq $Actual) { Write-Host "  ok: $Label" }
    else { Write-Host "FAIL: $Label (expected [$Expected], got [$Actual])"; $script:fails++ }
}

$sandbox = Join-Path ([System.IO.Path]::GetTempPath()) ("rogue-hbps-" + [guid]::NewGuid().ToString('N'))
$stamp = Join-Path (Join-Path (Join-Path $sandbox '.rogue') 'beacon') '.last-claude'
New-Item -ItemType Directory -Path (Split-Path -Parent $stamp) -Force | Out-Null

$saveProfile = $env:USERPROFILE
$saveInterval = $env:ROGUE_HEARTBEAT_MIN_INTERVAL
$saveLibOnly = $env:ROGUE_PS_LIB_ONLY
$env:USERPROFILE = $sandbox
$env:ROGUE_PS_LIB_ONLY = '1'

function Get-NowSeconds {
    return [int64][Math]::Floor((Get-Date).ToUniversalTime().Subtract(
        [datetime]'1970-01-01T00:00:00Z').TotalSeconds)
}

# WriteAllText, not Set-Content, and Remove-Item -Force: the stamp's name begins
# with a dot, which PowerShell's provider treats as HIDDEN on Linux and macOS -
# Remove-Item without -Force silently refuses, which made a "no stamp" case read a
# leftover file and pass for the wrong reason while this suite was written.
function Set-Stamp { param($Value)
    if ($null -eq $Value) { Remove-Item -LiteralPath $stamp -Force -ErrorAction SilentlyContinue }
    else { [System.IO.File]::WriteAllText($stamp, "$Value`n") }
}

# Each case re-dot-sources, because the interval is read once at load time.
#
# The parameter is deliberately NOT called $Trigger. heartbeat.ps1 declares
# `param([string]$Trigger = 'SessionStart')`, and dot-sourcing runs that param
# block in THIS function's scope - so a parameter of the same name is overwritten
# with 'SessionStart' before the call below ever reads it, and every throttled case
# silently tests the never-throttled trigger instead. PowerShell variable names are
# case-insensitive, so no spelling of it would have been safe. Same trap
# tests/log_probe.ps1 documents; it cost this suite four false passes.
function Throttled { param([string]$Which, [string]$Interval)
    $env:ROGUE_HEARTBEAT_MIN_INTERVAL = $Interval
    $wanted = $Which   # snapshot BEFORE the dot-source, for the reason above
    . (Join-Path $repo 'plugins/rogue/scripts/heartbeat.ps1')
    return [bool](Test-BeaconThrottled -TriggerName $wanted)
}

try {
    Write-Host "-- SessionStart is NEVER throttled ----------------------------------"
    Set-Stamp (Get-NowSeconds)
    Check "fires even with a fresh stamp" $false (Throttled 'SessionStart' '')

    Write-Host "-- Stop IS throttled ------------------------------------------------"
    Set-Stamp (Get-NowSeconds)
    Check "skipped inside the window" $true (Throttled 'Stop' '')
    Set-Stamp 0
    Check "fires once the window has elapsed" $false (Throttled 'Stop' '')
    Set-Stamp $null
    Check "fires when no stamp exists yet" $false (Throttled 'Stop' '')

    Write-Host "-- the interval knob ------------------------------------------------"
    Set-Stamp (Get-NowSeconds)
    Check "zero disables the throttle" $false (Throttled 'Stop' '0')
    Set-Stamp (Get-NowSeconds)
    Check "a non-numeric value falls back to the default" $true (Throttled 'Stop' 'abc')
    Set-Stamp (Get-NowSeconds)
    # TryParse rather than a plain [int64] cast: the cast throws here, and although
    # SilentlyContinue would swallow it and leave the default standing, that is the
    # right answer reached by accident rather than by design.
    Check "a value too wide for int64 falls back to the default" $true `
        (Throttled 'Stop' '99999999999999999999999')
    Set-Stamp (Get-NowSeconds)
    Check "a small interval still throttles inside its window" $true (Throttled 'Stop' '3600')

    Write-Host "-- a stamp we cannot trust never silences the beacon ------------------"
    Set-Stamp 'not-a-number'
    Check "a corrupt stamp does not throttle" $false (Throttled 'Stop' '')
    Set-Stamp 99999999999
    Check "a stamp in the FUTURE does not throttle" $false (Throttled 'Stop' '')
    Set-Stamp ''
    Check "an empty stamp does not throttle" $false (Throttled 'Stop' '')

    Write-Host "-- the two halves agree on where the stamp lives ---------------------"
    # A path mismatch would not fail any assertion above - each half would throttle
    # correctly against its own file - but a machine that ran both dispatchers would
    # beacon twice per window. The sh half builds ~/.rogue/beacon/.last-claude.
    . (Join-Path $repo 'plugins/rogue/scripts/heartbeat.ps1')
    $expected = Join-Path (Join-Path (Join-Path $sandbox '.rogue') 'beacon') '.last-claude'
    Check "the stamp path matches heartbeat.sh's" $expected $script:beaconStamp
    $shSource = Get-Content -Raw (Join-Path $repo 'plugins/rogue/scripts/heartbeat.sh')
    Check "heartbeat.sh builds the same path" $true `
        ($shSource -match '\.rogue/beacon/\.last-claude')
    Check "and defaults to the same interval" $true ($shSource -match 'ROGUE_HEARTBEAT_MIN_INTERVAL:-900')
    Check "the ps default is 900 too" 900 $script:beaconMinInterval

    Write-Host "-- the seam and the trigger default ---------------------------------"
    # The param default is what keeps an OLDER hooks.json - one that passes no
    # argument - behaving exactly as it does today rather than throttling silently.
    $psSource = Get-Content -Raw (Join-Path $repo 'plugins/rogue/scripts/heartbeat.ps1')
    Check "the trigger defaults to SessionStart" $true `
        ($psSource -match "param\(\[string\]\`$Trigger = 'SessionStart'\)")
    Check "the lib-only seam exists" $true ($psSource -match 'ROGUE_PS_LIB_ONLY')
    # The stamp is written with a BOM-less UTF-8 writer. Add-Content -Encoding UTF8
    # emits a BOM on Windows PowerShell 5.1 when it creates a file, and those three
    # leading bytes would fail every TryParse that reads the stamp back - turning
    # the throttle off permanently and silently.
    Check "the stamp is written without a BOM" $true `
        ($psSource -match 'UTF8Encoding \$false')
}
finally {
    $env:USERPROFILE = $saveProfile
    $env:ROGUE_HEARTBEAT_MIN_INTERVAL = $saveInterval
    $env:ROGUE_PS_LIB_ONLY = $saveLibOnly
    Remove-Item -Recurse -Force $sandbox -ErrorAction SilentlyContinue
}

Write-Host ""
if ($script:fails -eq 0) { Write-Host "ALL HEARTBEAT PS1 TESTS PASSED" }
else { Write-Host "$script:fails failure(s)" }
exit $script:fails
