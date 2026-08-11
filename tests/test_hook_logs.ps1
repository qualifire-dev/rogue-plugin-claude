#!/usr/bin/env pwsh
# PowerShell half of the hook-log contract test (see CLAUDE.md § "The hook log").
# The sh/mjs half is tests/test_hook_logs.sh — same assertions, other dispatchers.
#
# One file per agent under %USERPROFILE%\.rogue\logs\, one shared line format, one
# rotation policy — across all five PowerShell dispatchers. The contract is
# duplicated five times (the repo has no shared library), so a copy/paste drift in
# any one of them is invisible until a Windows customer's log is read.
#
# Runs on macOS/Linux too: each dispatcher exposes its logging helpers above a
# ROGUE_PS_LIB_ONLY seam, and each falls back from USERPROFILE to $HOME. That is
# what lets .github/workflows/validate.yml cover the Windows-only code paths on a
# Linux runner. USERPROFILE is set explicitly per case so the assertions hold on
# every platform.
#
#   pwsh -NoProfile -File tests/test_hook_logs.ps1

$ErrorActionPreference = 'Stop'
$repo = Split-Path -Parent (Split-Path -Parent $PSCommandPath)
$probe = Join-Path $repo 'tests/log_probe.ps1'
$failures = 0

$cases = @(
    @{ slug = 'claude';      path = 'plugins/rogue/scripts/hook.ps1';       event = 'PreToolUse'; init = $false }
    @{ slug = 'codex';       path = 'plugins/codex/scripts/hook.ps1';       event = 'PreToolUse'; init = $false }
    @{ slug = 'cursor';      path = 'plugins/cursor/scripts/hook.ps1';      event = 'preToolUse'; init = $false }
    @{ slug = 'copilot';     path = 'plugins/copilot/scripts/hook.ps1';     event = 'preToolUse'; init = $false }
    # antigravity is main-and-functions: its log vars are assigned inside
    # Initialize-Logging, so the probe has to call that before Log.
    @{ slug = 'antigravity'; path = 'plugins/antigravity/scripts/hook.ps1'; event = 'PreToolUse'; init = $true }
)

function Pass { param([string]$M) Write-Host "  ok: $M" }
function Fail { param([string]$M) Write-Host "FAIL: $M"; $script:failures++ }
function Check {
    param([string]$Label, [string]$Expected, [string]$Actual)
    if ($Expected -eq $Actual) { Pass $Label } else { Fail "$Label (expected [$Expected], got [$Actual])" }
}

# Run the probe for one case in a child pwsh and return its KEY=value output as a
# hashtable. `env` overrides are applied to the CHILD only, so the developer's own
# exported ROGUE_LOG_* can never leak in and mask a default-path regression —
# every knob is blanked unless the case sets it.
function Invoke-Probe {
    param([hashtable]$Case, [string]$CaseHome, [hashtable]$Env = @{}, [int]$SeedBytes = 0)

    $defaults = @{
        USERPROFILE          = $CaseHome
        HOME                 = $CaseHome
        ROGUE_LOG_FILE       = ''
        ROGUE_LOG_DIR        = ''
        ROGUE_LOG_MAX_BYTES  = ''
    }
    foreach ($k in $Env.Keys) { $defaults[$k] = $Env[$k] }

    $saved = @{}
    foreach ($k in $defaults.Keys) {
        $saved[$k] = [Environment]::GetEnvironmentVariable($k)
        [Environment]::SetEnvironmentVariable($k, $defaults[$k])
    }
    try {
        $argv = @('-NoProfile', '-File', $probe,
                  '-Dispatcher', (Join-Path $repo $Case.path),
                  '-EventName', $Case.event,
                  '-SeedBytes', $SeedBytes)
        if ($Case.init) { $argv += '-NeedsInit' }
        $out = & (Get-Process -Id $PID).Path @argv 2>$null
    } finally {
        foreach ($k in $saved.Keys) { [Environment]::SetEnvironmentVariable($k, $saved[$k]) }
    }

    $facts = @{}
    foreach ($line in @($out)) {
        if ($line -match '^([A-Z]+)=(.*)$') { $facts[$Matches[1]] = $Matches[2] }
    }
    return $facts
}

function New-CaseHome {
    param([string]$Name)
    $d = Join-Path ([System.IO.Path]::GetTempPath()) ("rogue-logtest-" + $Name + "-" + [System.IO.Path]::GetRandomFileName())
    New-Item -ItemType Directory -Path $d -Force | Out-Null
    return $d
}

$homes = @()
try {

Write-Host "== default path: one file per agent under <home>/.rogue/logs/"
foreach ($c in $cases) {
    $h = New-CaseHome "default-$($c.slug)"; $homes += $h
    $f = Invoke-Probe -Case $c -CaseHome $h
    $expected = Join-Path (Join-Path (Join-Path $h '.rogue') 'logs') "$($c.slug).log"
    Check "$($c.slug) resolves <home>/.rogue/logs/$($c.slug).log" $expected $f['LOGFILE']
}

Write-Host ""
Write-Host "== default cap is 2 MiB"
foreach ($c in $cases) {
    $h = New-CaseHome "cap-$($c.slug)"; $homes += $h
    $f = Invoke-Probe -Case $c -CaseHome $h
    Check "$($c.slug) default ROGUE_LOG_MAX_BYTES" '2097152' $f['CAP']
}

Write-Host ""
Write-Host "== line format: '<ts> provider=<slug> event=<Event> …'"
foreach ($c in $cases) {
    $h = New-CaseHome "fmt-$($c.slug)"; $homes += $h
    $f = Invoke-Probe -Case $c -CaseHome $h
    # A UTC ISO-8601 second-precision stamp with no fractional part: the shipper's
    # line splitter and the backend's parser both key off it.
    $want = "^\d{4}-\d{2}-\d{2}T\d{2}:\d{2}:\d{2}Z provider=$($c.slug) event=$($c.event) outcome=probe$"
    if ($f['LAST'] -match $want) { Pass "$($c.slug) line is '<ts> provider=$($c.slug) event=$($c.event) …'" }
    else { Fail "$($c.slug) line shape [$($f['LAST'])]" }
}

Write-Host ""
Write-Host "== ROGUE_LOG_DIR relocates, keeping the per-agent basename"
foreach ($c in $cases) {
    $h = New-CaseHome "dir-$($c.slug)"; $homes += $h
    $custom = Join-Path $h 'custom'
    $f = Invoke-Probe -Case $c -CaseHome $h -Env @{ ROGUE_LOG_DIR = $custom }
    Check "$($c.slug) honors ROGUE_LOG_DIR" (Join-Path $custom "$($c.slug).log") $f['LOGFILE']
}

Write-Host ""
Write-Host "== ROGUE_LOG_FILE (exact path) beats ROGUE_LOG_DIR"
foreach ($c in $cases) {
    $h = New-CaseHome "file-$($c.slug)"; $homes += $h
    $exact = Join-Path $h 'exact.log'
    $f = Invoke-Probe -Case $c -CaseHome $h -Env @{ ROGUE_LOG_FILE = $exact; ROGUE_LOG_DIR = (Join-Path $h 'custom') }
    Check "$($c.slug) honors ROGUE_LOG_FILE over ROGUE_LOG_DIR" $exact $f['LOGFILE']
}

Write-Host ""
Write-Host "== rotation at ROGUE_LOG_MAX_BYTES"
foreach ($c in $cases) {
    $h = New-CaseHome "rot-$($c.slug)"; $homes += $h
    # Seed 300B against a 100B cap. The comparison is `>=`, so keep the seed
    # clearly above the cap rather than on the boundary.
    $f = Invoke-Probe -Case $c -CaseHome $h -Env @{ ROGUE_LOG_MAX_BYTES = '100' } -SeedBytes 300
    Check "$($c.slug) rotated the old log to $($c.slug).log.1" 'True' $f['ROTATED']
    Check "$($c.slug) started a fresh log (1 line)" '1' $f['LINES']
}

Write-Host ""
Write-Host "== ROGUE_LOG_MAX_BYTES=0 disables rotation"
foreach ($c in $cases) {
    $h = New-CaseHome "norot-$($c.slug)"; $homes += $h
    $f = Invoke-Probe -Case $c -CaseHome $h -Env @{ ROGUE_LOG_MAX_BYTES = '0' } -SeedBytes 300
    Check "$($c.slug) created no .log.1" 'False' $f['ROTATED']
    # The 300B seed has no trailing newline, so Add-Content's line lands on the
    # same physical line: 1 line total, but the seed text is still there.
    Check "$($c.slug) kept the over-cap content" 'True' ([string]($f['LAST'] -like 'sss*'))
}

Write-Host ""
Write-Host "== no dispatcher resolves the legacy shared hook.log"
foreach ($c in $cases) {
    $h = New-CaseHome "legacy-$($c.slug)"; $homes += $h
    $f = Invoke-Probe -Case $c -CaseHome $h
    if ($f['LOGFILE'] -like '*hook.log') { Fail "$($c.slug) still points at hook.log [$($f['LOGFILE'])]" }
    else { Pass "$($c.slug) no longer points at hook.log" }
}

} finally {
    foreach ($h in $homes) { Remove-Item -Recurse -Force $h -ErrorAction SilentlyContinue }
}

Write-Host ""
if ($failures -eq 0) {
    Write-Host "All hook-log contract tests passed (PowerShell)."
    exit 0
}
Write-Host "$failures failure(s)."
exit 1
