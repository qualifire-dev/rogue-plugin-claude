# tests/test_antigravity_windows_delivery.ps1
#
# Windows-only. Executes the two plugins/antigravity/hooks.json command
# strings for PreToolUse under BOTH argument-delivery models native-Windows
# Antigravity may use, against the REAL dispatchers:
#
#   blob  : first whitespace token = program, everything after it = ONE
#           argument (what the observed exit-127 failure implies)
#   split : every whitespace token its own argument
#
# Expected behavior on Windows:
#   sh handler  (env -Ssh ...)          -> empty stdout, exit 0
#                                          (hook.sh MSYS stand-down)
#   powershell handler (cmd /d /c ...)  -> {"decision":"allow"}, exit 0
#                                          (hook.ps1 unconfigured fail-open
#                                           default for PreToolUse)
#
# The blob case for the powershell handler is THE load-bearing assertion:
# it is the only place that verifies cmd.exe accepts "/d /c ..." delivered
# inside a leading quote. Off Windows this cannot be tested at all.
$ErrorActionPreference = 'Stop'
if ($env:OS -ne 'Windows_NT') { Write-Host 'skip: Windows-only test'; exit 0 }

$repo = Split-Path -Parent $PSScriptRoot
$pluginRoot = Join-Path $repo 'plugins\antigravity'
$hooksJson = Get-Content -Raw (Join-Path $pluginRoot 'hooks.json') | ConvertFrom-Json
$handlers = $hooksJson.rogue.PreToolUse[0].hooks
$shCmd = ($handlers | Where-Object { $_.command -like 'env *' }).command
$psCmd = ($handlers | Where-Object { $_.command -like 'cmd *' }).command
if (-not $shCmd -or -not $psCmd) { Write-Host 'FAIL: could not read both PreToolUse commands from hooks.json'; exit 1 }

# Git for Windows tools: env.exe and sh.exe live in <git>\usr\bin. GitHub
# runners have it on PATH; make sure locally too.
if (-not (Get-Command env.exe -ErrorAction SilentlyContinue)) {
    $gitExe = (Get-Command git.exe -ErrorAction SilentlyContinue).Source
    if ($gitExe) {
        $usrBin = Join-Path (Split-Path (Split-Path $gitExe)) 'usr\bin'
        if (Test-Path (Join-Path $usrBin 'env.exe')) { $env:Path = "$usrBin;$env:Path" }
    }
}
if (-not (Get-Command env.exe -ErrorAction SilentlyContinue)) { Write-Host 'FAIL: env.exe not found (need Git for Windows)'; exit 1 }

# Isolation: no ROGUE_* config -> hook.ps1 takes the unconfigured path and
# hook.sh stands down before config matters. Keep the log out of the profile.
# hook.ps1 reads credentials from disk each invocation (%USERPROFILE%\.rogue-env,
# falling back to HOME) -- nulling ROGUE_API_KEY alone is not enough isolation
# on a configured machine, so also point USERPROFILE/HOME at a fresh temp dir.
# (C:\ProgramData\rogue\env cannot be redirected this way; a machine with an
# MDM-managed env file is out of scope.)
$env:ROGUE_LOG_DIR = Join-Path $env:TEMP ('rogue-agy-delivery-' + [guid]::NewGuid())
$env:ROGUE_API_KEY = $null
$tempHome = Join-Path $env:TEMP ('rogue-agy-delivery-home-' + [guid]::NewGuid())
New-Item -ItemType Directory -Path $tempHome | Out-Null
$env:USERPROFILE = $tempHome
$env:HOME = $tempHome

Set-Location $pluginRoot
$script:fails = 0
function Assert-Eq {
    param($Actual, $Expected, $Label)
    if ("$Actual" -ne "$Expected") {
        Write-Host "FAIL [$Label]: expected <$Expected> but got <$Actual>"
        $script:fails++
    } else {
        Write-Host "  ok: $Label"
    }
}

$errFile = Join-Path $env:TEMP ('rogue-agy-delivery-err-' + [guid]::NewGuid() + '.txt')

function Invoke-Blob {
    param([string]$CommandString)
    $sp = $CommandString.IndexOf(' ')
    $prog = $CommandString.Substring(0, $sp)
    $rest = $CommandString.Substring($sp + 1)
    $out = '{"toolCall":null}' | & $prog $rest 2>$errFile
    return @(($out -join "`n"), $LASTEXITCODE)
}

function Invoke-Split {
    param([string]$CommandString)
    $parts = $CommandString -split ' '
    $out = '{"toolCall":null}' | & $parts[0] $parts[1..($parts.Length - 1)] 2>$errFile
    return @(($out -join "`n"), $LASTEXITCODE)
}

function Show-StderrOnFail {
    if ((Test-Path $errFile) -and (Get-Item $errFile).Length -gt 0) {
        Write-Host ('  stderr: ' + (Get-Content -Raw $errFile))
    }
}

$r = Invoke-Blob $shCmd
Assert-Eq $r[1] 0 'sh command, blob delivery: exit 0'
Assert-Eq $r[0] '' 'sh command, blob delivery: MSYS stand-down emits nothing'
if ($script:fails) { Show-StderrOnFail }

$r = Invoke-Split $shCmd
Assert-Eq $r[1] 0 'sh command, split delivery: exit 0'
Assert-Eq $r[0] '' 'sh command, split delivery: MSYS stand-down emits nothing'
if ($script:fails) { Show-StderrOnFail }

$r = Invoke-Blob $psCmd
Assert-Eq $r[1] 0 'powershell command, blob delivery: exit 0'
Assert-Eq $r[0] '{"decision":"allow"}' 'powershell command, blob delivery: unconfigured fail-open'
if ($script:fails) { Show-StderrOnFail }

$r = Invoke-Split $psCmd
Assert-Eq $r[1] 0 'powershell command, split delivery: exit 0'
Assert-Eq $r[0] '{"decision":"allow"}' 'powershell command, split delivery: unconfigured fail-open'
if ($script:fails) { Show-StderrOnFail }

Remove-Item -Force -ErrorAction SilentlyContinue $errFile
Remove-Item -Recurse -Force -ErrorAction SilentlyContinue $env:ROGUE_LOG_DIR
Remove-Item -Recurse -Force -ErrorAction SilentlyContinue $tempHome
if ($script:fails) { Write-Host "FAIL: $script:fails assertion(s)"; exit 1 }
Write-Host 'OK: both hooks.json command forms survive blob and split delivery on Windows'
exit 0
