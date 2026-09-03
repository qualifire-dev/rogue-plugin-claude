#!/usr/bin/env pwsh
# tests/test_status_kiro_ps1.ps1 - plugins/kiro/scripts/status.ps1 under a temp
# USERPROFILE, in lockstep with tests/test_status_kiro_sh.sh.
#
# Kiro has no slash-command surface for a /rogue:status skill, so the status
# command IS this script, and on Windows it is the one diagnostic path support
# has. It POSTs /hooks/status, which upserts a roster row fingerprinted on
# host|actor|family|agent - so the body it sends has to be the heartbeat's, or
# the status run registers a second row for the install it is checking. The
# last case here replays heartbeat.ps1 against the same home and compares the
# two bodies byte for byte.
#
# Loaded through the ROGUE_PS_LIB_ONLY seam and driven by calling Invoke-Status,
# with Invoke-WebRequest shadowed by a function that records the request and
# answers a canned response; a fake kiro-cli on PATH answers the two subcommands
# the script uses and records every call; the IDE install is a fixture reached
# through ROGUE_KIRO_APP. Runs on any platform with PowerShell; validate.yml
# also runs it under Windows PowerShell 5.1.

$here = Split-Path -Parent $MyInvocation.MyCommand.Path
$repo = Split-Path -Parent $here
$work = Join-Path ([System.IO.Path]::GetTempPath()) ("rogue-kiro-status-" + [System.IO.Path]::GetRandomFileName())
$bin  = Join-Path $work 'bin'
New-Item -ItemType Directory -Path $bin -Force | Out-Null

# The developer's own shell very likely exports a real key and knobs; only the
# temp home's env file may configure the script under test.
$saved = @{}
foreach ($k in 'USERPROFILE','PATH','ROGUE_PS_LIB_ONLY','ROGUE_API_KEY','ROGUE_BASE_URL','ROGUE_ACTOR_EMAIL',
               'ROGUE_ACTOR_NAME','ROGUE_LOG_FILE','ROGUE_LOG_DIR','ROGUE_HEARTBEAT_MIN_INTERVAL',
               'KIRO_PLUGIN_ROOT','ROGUE_KIRO_APP','KIRO_FAKE_DEFAULT','KIRO_CLI_LOG') {
    $saved[$k] = [Environment]::GetEnvironmentVariable($k)
    if ($k -ne 'USERPROFILE' -and $k -ne 'PATH') { [Environment]::SetEnvironmentVariable($k, $null) }
}
$prevPath = $saved['PATH']

# -- the fake toolchain --------------------------------------------------------
# `--version` prints what kiro-cli 2.21.0 prints; `settings chat.defaultAgent`
# prints the value quoted (as the real CLI does) or errors out when none is set.
# Every call is appended to KIRO_CLI_LOG. A .ps1 resolves by bare name from PATH
# on Windows; on Linux/macOS a sh shim beside it does.
$fakeCli = Join-Path $bin 'kiro-cli.ps1'
@'
param([Parameter(ValueFromRemainingArguments = $true)][string[]]$Argv)
if ($env:KIRO_CLI_LOG) { Add-Content -LiteralPath $env:KIRO_CLI_LOG -Value ($Argv -join ' ') }
if ($Argv[0] -eq '--version') { Write-Output 'kiro-cli 2.21.0'; exit 0 }
if ("$($Argv[0]) $($Argv[1])" -eq 'settings chat.defaultAgent') {
    if ($env:KIRO_FAKE_DEFAULT) { Write-Output ('"' + $env:KIRO_FAKE_DEFAULT + '"'); exit 0 }
    [Console]::Error.WriteLine('error: No value associated with chat.defaultAgent')
    exit 1
}
exit 0
'@ | Set-Content -LiteralPath $fakeCli -Encoding UTF8
if ($env:OS -ne 'Windows_NT') {
    $shim = Join-Path $bin 'kiro-cli'
    [System.IO.File]::WriteAllText($shim, "#!/bin/sh`nexec pwsh -NoProfile -File `"$fakeCli`" `"`$@`"`n")
    & chmod +x $shim
}
$withCli = $bin + [System.IO.Path]::PathSeparator + $prevPath
# The inherited PATH minus every directory holding a kiro-cli, so "absent" is a
# real case on a developer machine that has the CLI installed.
$sep = [System.IO.Path]::PathSeparator
$noCli = (($prevPath -split [regex]::Escape($sep)) | Where-Object {
    $_ -and -not (Test-Path -LiteralPath (Join-Path $_ 'kiro-cli')) -and
    -not (Test-Path -LiteralPath (Join-Path $_ 'kiro-cli.exe')) -and
    -not (Test-Path -LiteralPath (Join-Path $_ 'kiro-cli.cmd'))
}) -join $sep

# The IDE install as heartbeat.ps1 reads it: <root>\resources\app\package.json.
$ideRoot = Join-Path $work 'Kiro'
New-Item -ItemType Directory -Path (Join-Path (Join-Path $ideRoot 'resources') 'app') -Force | Out-Null
[System.IO.File]::WriteAllText((Join-Path (Join-Path (Join-Path $ideRoot 'resources') 'app') 'package.json'),
    "{`n  `"name`": `"kiro`",`n  `"version`": `"1.0.437`"`n}`n")
$noIde = Join-Path $work 'no-app'

# Invoke-WebRequest, shadowed: functions win over cmdlets, so the script under
# test calls this. Records the request; answers from $script:fakeCode/$fakeBody
# the way the real cmdlet does - a 2xx as a response object, anything else as a
# throw whose .Response carries the status, a transport failure as a bare throw.
$script:fakeCode = 200
$script:fakeBody = ''
$script:sentUri = ''; $script:sentKey = ''; $script:sentBody = ''
function Invoke-WebRequest {
    [CmdletBinding()]
    param($Uri, $Method, $Headers, $ContentType, $Body, [switch]$UseBasicParsing, $TimeoutSec)
    $script:sentUri = [string]$Uri
    $script:sentKey = [string]$Headers['x-rogue-api-key']
    $script:sentBody = [System.Text.Encoding]::UTF8.GetString($Body)
    if ($script:fakeCode -eq 200) {
        return [pscustomobject]@{ StatusCode = 200; Content = $script:fakeBody }
    }
    $e = New-Object System.Exception 'canned failure'
    if ($script:fakeCode -ne 0) {
        $e | Add-Member -NotePropertyName Response -NotePropertyValue ([pscustomobject]@{ StatusCode = $script:fakeCode }) -Force
    }
    throw $e
}

$fails = 0
$count = 0
function Assert-Has {
    param([string]$Needle, [string]$Hay, [string]$Label)
    $script:count++
    if ($Hay.Contains($Needle)) { Write-Host "  ok: $Label" }
    else { Write-Host "FAIL [$Label]: expected <$Needle> in output"; $script:fails++ }
}
function Assert-Lacks {
    param([string]$Needle, [string]$Hay, [string]$Label)
    $script:count++
    if (-not $Hay.Contains($Needle)) { Write-Host "  ok: $Label" }
    else { Write-Host "FAIL [$Label]: found <$Needle>, which must not appear"; $script:fails++ }
}
function Assert-Eq {
    param($Got, $Expected, [string]$Label)
    $script:count++
    if ([string]$Got -ceq [string]$Expected) { Write-Host "  ok: $Label" }
    else { Write-Host "FAIL [$Label]: got <$Got>, expected <$Expected>"; $script:fails++ }
}

# -- a home with the plugin installed the way install.ps1 -Kiro leaves it ------
function New-Home {  # sets $script:H and $script:PLUGIN; plugin staged, no Kiro wiring yet
    param([string]$Name)
    $script:H = Join-Path $work $Name
    $script:PLUGIN = [System.IO.Path]::Combine($script:H, '.rogue', 'plugins', 'kiro')
    New-Item -ItemType Directory -Path $script:PLUGIN -Force | Out-Null
    New-Item -ItemType Directory -Path (Join-Path $script:H 'ws') -Force | Out-Null
    Copy-Item -Path ([System.IO.Path]::Combine($repo, 'plugins', 'kiro', '*')) -Destination $script:PLUGIN -Recurse -Force
    [System.IO.File]::WriteAllText((Join-Path $script:PLUGIN 'plugin.json'), "{`"name`":`"rogue`",`"version`":`"1.0.0`"}`n")
    [System.IO.File]::WriteAllText((Join-Path $script:H '.rogue-env'), "export ROGUE_API_KEY=rsk_test1234`n")
    $env:USERPROFILE = $script:H
    $env:KIRO_CLI_LOG = Join-Path $script:H 'kiro-cli.log'
}
function Add-KiroWiring {  # the hook file, a rogue agent carrying the hooks, a log
    $hooks  = [System.IO.Path]::Combine($script:H, '.kiro', 'hooks')
    $agents = [System.IO.Path]::Combine($script:H, '.kiro', 'agents')
    $wsAgents = [System.IO.Path]::Combine($script:H, 'ws', '.kiro', 'agents')
    $logs = [System.IO.Path]::Combine($script:H, '.rogue', 'logs')
    foreach ($d in @($hooks, $agents, $wsAgents, $logs)) { New-Item -ItemType Directory -Path $d -Force | Out-Null }
    $bridge = [System.IO.Path]::Combine($script:PLUGIN, 'scripts', 'hook.ps1')
    $cmd = "powershell -NoProfile -ExecutionPolicy Bypass -File \`"$($bridge -replace '\\', '\\')\`""
    [System.IO.File]::WriteAllText((Join-Path $hooks 'rogue.json'), @"
{
  "version": "v1",
  "hooks": [
    {"name": "rogue-SessionStart", "trigger": "SessionStart", "action": {"type": "command", "command": "$cmd SessionStart kiro_ide"}, "timeout": 10},
    {"name": "rogue-PreToolUse", "trigger": "PreToolUse", "action": {"type": "command", "command": "$cmd PreToolUse kiro_ide"}, "timeout": 10}
  ]
}
"@)
    [System.IO.File]::WriteAllText((Join-Path $agents 'rogue.json'), '{"name":"rogue","hooks":[{"name":"rogue-preToolUse","trigger":"preToolUse"}]}')
    [System.IO.File]::WriteAllText((Join-Path $agents 'custom.json'), '{"name":"custom","hooks":[]}')
    [System.IO.File]::WriteAllText((Join-Path $wsAgents 'ws.json'), '{"name":"ws","hooks":[{"name":"rogue-preToolUse","trigger":"preToolUse"}]}')
    [System.IO.File]::WriteAllText((Join-Path $logs 'kiro.log'),
        "2026-09-03T10:00:00Z provider=kiro surface=kiro_cli event=PreToolUse outcome=allow http=200`n")
}

# Loads THIS home's copy of status.ps1 through the seam (top-level, so its
# $script: state is this file's) and runs it from the workspace directory - the
# plugin root must come from the script's own path, not from where it was run.
# Sets $out and $rc; resets the recorded request first.
$env:ROGUE_PS_LIB_ONLY = '1'
function Reset-Request { $script:sentUri = ''; $script:sentKey = ''; $script:sentBody = '' }
$ErrorActionPreference = 'Stop'

Write-Host "kiro status.ps1"

# ============================================================================
Write-Host "-- a fully wired CLI + IDE machine, default agent rogue ----------------"
New-Home 'full'; Add-KiroWiring
$env:PATH = $withCli; $env:ROGUE_KIRO_APP = $ideRoot; $env:KIRO_FAKE_DEFAULT = 'rogue'
$script:fakeCode = 200
$script:fakeBody = '{"ok":true,"connected":true,"organization":{"id":"org_123"},"agent":{"family":"kiro","agent":"kiro_cli","version":"1.0.0","latest_version":"1.2.0","update_available":true}}'
Reset-Request
Set-Location (Join-Path $H 'ws')
. ([System.IO.Path]::Combine($PLUGIN, 'scripts', 'status.ps1'))
$out = (Invoke-Status | Out-String); $rc = $script:statusExit
Assert-Eq $rc 0 'exits 0'
Assert-Has (Join-Path $H '.rogue-env') $out 'lists the per-user credential file'
Assert-Has 'API key resolved: ...1234' $out "shows the key's last four characters only"
Assert-Lacks 'rsk_test1234' $out 'never prints the whole key'
Assert-Has 'kiro_cli' $out 'reports the CLI surface'
Assert-Has 'kiro-cli 2.21.0' $out 'with the version kiro-cli --version prints'
Assert-Has 'kiro_ide' $out 'reports the IDE surface'
Assert-Has 'Kiro 1.0.437' $out "with the version from the install's package.json"
Assert-Has 'rogue.json' $out 'names the hook file'
Assert-Has 'present (2 Rogue hooks, surface kiro_ide)' $out 'counts the Rogue entries in the hook file and names their surface'
Assert-Has 'agent configs with Rogue hooks         2' $out 'counts the agent configs carrying the hooks (home + workspace, not the one without)'
Assert-Has 'default agent (2.x engine)             rogue - covered' $out 'reports the default agent as covered when its config carries the hooks'
Assert-Has 'HTTP 200' $out 'reports the connection status code'
Assert-Has 'organization: org_123' $out 'reports the organization'
Assert-Has 'plugin 1.0.0 (latest 1.2.0, update available)' $out 'reports running vs latest and the update flag'
Assert-Has 'provider=kiro surface=kiro_cli' $out 'tails the hook log'
# The roster row it upserts must be the heartbeat's row.
Assert-Has '/api/v1/hooks/status' $sentUri 'POSTs /hooks/status'
Assert-Eq $sentKey 'rsk_test1234' 'authenticates with the resolved key'
Assert-Has '"agent_family":"kiro"' $sentBody 'body names family kiro'
Assert-Has '"agent":"kiro_cli"' $sentBody 'body keys the CLI surface when kiro-cli is present'
Assert-Has '"version":"1.0.0"' $sentBody "body carries the plugin version from the PLUGIN's plugin.json, not the working directory's"
Assert-Has '"agent_version":"2.21.0"' $sentBody 'body carries the Kiro build'
Assert-Has '"default_agent":"rogue"' $sentBody 'body carries the default agent'
Assert-Has '"host":"' $sentBody 'body carries the host'
$statusBody = $sentBody

Write-Host "-- the body is the heartbeat's, byte for byte ---------------------------"
# heartbeat.ps1 replayed against the same home, the way Invoke-Main runs it
# (minus TLS and the exit), with the surface the status run chose. Any field the
# two disagree on is a second roster row for this install.
Reset-Request
. ([System.IO.Path]::Combine($PLUGIN, 'scripts', 'heartbeat.ps1')) 'kiro_cli' 'SessionStart'
$script:pluginRoot = $PLUGIN
$beaconLib = Get-BeaconLibrary
if ($beaconLib) { . $beaconLib }
Import-Credentials; Initialize-Beacon; Resolve-BaseUrl; Resolve-Actor; Resolve-Version; Resolve-Surface
Send-Heartbeat
Assert-Eq $sentBody $statusBody 'status.ps1 posts exactly the body heartbeat.ps1 posts'

Write-Host "-- the default agent moved away from the hooked one ---------------------"
New-Home 'moved'; Add-KiroWiring
$env:KIRO_FAKE_DEFAULT = 'custom'
Set-Location (Join-Path $H 'ws')
. ([System.IO.Path]::Combine($PLUGIN, 'scripts', 'status.ps1'))
$out = (Invoke-Status | Out-String)
Assert-Has 'default agent (2.x engine)             custom - NOT covered' $out 'flags a default whose config carries no Rogue hooks'
Assert-Has 'kiro-cli agent set-default rogue' $out 'names the fix'

Write-Host "-- no default set, no IDE -----------------------------------------------"
New-Home 'nodefault'; Add-KiroWiring
$env:KIRO_FAKE_DEFAULT = $null; $env:ROGUE_KIRO_APP = $noIde
Reset-Request
Set-Location (Join-Path $H 'ws')
. ([System.IO.Path]::Combine($PLUGIN, 'scripts', 'status.ps1'))
$out = (Invoke-Status | Out-String)
Assert-Has 'default agent (2.x engine)             (none set)' $out 'reports no default'
Assert-Has 'kiro_ide    Kiro IDE not found' $out 'reports the IDE absent'
Assert-Lacks '"default_agent"' $sentBody 'sends no default_agent when none is set'

Write-Host "-- nothing wired: plugin present, Kiro never hooked ---------------------"
New-Home 'bare'
Set-Location (Join-Path $H 'ws')
. ([System.IO.Path]::Combine($PLUGIN, 'scripts', 'status.ps1'))
$out = (Invoke-Status | Out-String)
Assert-Has 'rogue.json' $out 'still names the hook file'
Assert-Has 'MISSING' $out 'reports the hook file missing'
Assert-Has 'agent configs with Rogue hooks         0' $out 'counts zero hooked agent configs'
Assert-Has 'install.ps1 -Kiro' $out 'points at the installer'
Assert-Has '(no hook log yet)' $out 'reports an empty log without failing'

Write-Host "-- unconfigured: no key anywhere ----------------------------------------"
New-Home 'nokey'; Add-KiroWiring
Remove-Item -LiteralPath (Join-Path $H '.rogue-env') -Force
Reset-Request
Set-Location (Join-Path $H 'ws')
. ([System.IO.Path]::Combine($PLUGIN, 'scripts', 'status.ps1'))
$out = (Invoke-Status | Out-String); $rc = $script:statusExit
Assert-Has 'API key: not resolved' $out 'reports the missing key'
Assert-Eq $rc 1 'exits non-zero when unconfigured'
Assert-Eq $sentUri '' 'makes no request without a key'

Write-Host "-- the key is rejected --------------------------------------------------"
New-Home 'badkey'; Add-KiroWiring
$script:fakeCode = 401; $script:fakeBody = '{"error":"Unauthorized"}'
Set-Location (Join-Path $H 'ws')
. ([System.IO.Path]::Combine($PLUGIN, 'scripts', 'status.ps1'))
$out = (Invoke-Status | Out-String); $rc = $script:statusExit
Assert-Has 'HTTP 401' $out 'reports the status code'
Assert-Has 'invalid' $out 'explains a 401 as an invalid key'
Assert-Eq $rc 1 'exits non-zero on a failed check'

Write-Host "-- transport failure ----------------------------------------------------"
New-Home 'offline'; Add-KiroWiring
$script:fakeCode = 0; $script:fakeBody = ''
Set-Location (Join-Path $H 'ws')
. ([System.IO.Path]::Combine($PLUGIN, 'scripts', 'status.ps1'))
$out = (Invoke-Status | Out-String); $rc = $script:statusExit
Assert-Has 'HTTP 000' $out 'reports 000 for a request that never got an answer'
Assert-Has 'network' $out 'explains 000 as a network problem'
Assert-Eq $rc 1 'exits non-zero on a transport failure'

Write-Host "-- kiro-cli absent, IDE present: the row keys on the IDE ----------------"
New-Home 'ideonly'; Add-KiroWiring
$env:PATH = $noCli; $env:ROGUE_KIRO_APP = $ideRoot
$script:fakeCode = 200; $script:fakeBody = '{"ok":true}'
Reset-Request
Set-Location (Join-Path $H 'ws')
if (Get-Command kiro-cli -ErrorAction SilentlyContinue) {
    Write-Host '  skip: kiro-cli absent (a real kiro-cli is on PATH)'
} else {
    . ([System.IO.Path]::Combine($PLUGIN, 'scripts', 'status.ps1'))
    $out = (Invoke-Status | Out-String)
    Assert-Has 'kiro_cli    kiro-cli not found' $out 'reports the CLI absent'
    Assert-Has '"agent":"kiro_ide"' $sentBody 'body keys the IDE surface'
    Assert-Has '"agent_version":"1.0.437"' $sentBody 'body carries the IDE build'
    Assert-Has 'default agent (2.x engine)             (kiro-cli not found)' $out 'no CLI means no default to report'
}

# -- teardown ------------------------------------------------------------------
Set-Location $repo
foreach ($k in $saved.Keys) { [Environment]::SetEnvironmentVariable($k, $saved[$k]) }
Remove-Item -Recurse -Force $work -ErrorAction SilentlyContinue

Write-Host ""
if ($fails -eq 0) { Write-Host "test_status_kiro_ps1: all $count passed"; exit 0 }
Write-Host "test_status_kiro_ps1: $fails of $count failed"
exit 1
