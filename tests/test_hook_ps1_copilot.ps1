#!/usr/bin/env pwsh
# tests/test_hook_ps1_copilot.ps1 — unit tests for the Copilot PowerShell
# dispatcher's pure helpers (plugins/copilot/scripts/hook.ps1).
#
# Why a separate file from tests/test_hook_ps1.ps1: that one is explicitly about
# the CLAUDE plugin's shell-quoting decoder (ConvertFrom-ShellQuoted) and the
# cross-bridge round-trip of ~/.rogue-env. This one covers the Copilot-only
# JetBrains silent-block alert — the single out-of-band exception to pure relay —
# and must stay in lockstep with tests/test_hook_sh_copilot.sh cases 4b-4e.
#
# These are the ONLY automated checks that ever execute hook.ps1's alert code:
# a parse or logic error there is not a graceful degradation, because the
# hooks.json loader wraps the call in `try { … } catch { '{}' } ; exit 0` and
# would silently turn every Windows Copilot user's enforcement into a no-op.
#
# Run on any platform with PowerShell:  pwsh tests/test_hook_ps1_copilot.ps1
# hook.ps1 stands down on non-Windows for its MAIN body, but this test loads only
# its functions via the ROGUE_PS_LIB_ONLY seam, so it runs anywhere. Test-JetBrainsIde
# is exercised through its env fallback: the CIM walk throws (Get-CimInstance does
# not exist off Windows) / finds no copilot ancestor, and falls through.

$here = Split-Path -Parent $MyInvocation.MyCommand.Path
# [IO.Path]::Combine takes many segments on Windows PowerShell 5.1; multi-segment
# Join-Path is PowerShell 7+ only.
$hook = [System.IO.Path]::Combine($here, '..', 'plugins', 'copilot', 'scripts', 'hook.ps1')

# Load hook.ps1's functions without executing the dispatcher body.
$env:ROGUE_PS_LIB_ONLY = '1'
. $hook
$env:ROGUE_PS_LIB_ONLY = $null
# hook.ps1 sets SilentlyContinue for its own fail-open behaviour; the test itself
# wants failures to be loud. Every helper under test guards with try/catch, so
# this does not change what they do.
$ErrorActionPreference = 'Stop'

# Single-char building blocks, so the test literals themselves can't be
# mis-escaped (PowerShell's own quoting rules differ from the shell's).
$SQ = [char]39   # '
$BS = [char]92   # \

$fails = 0
$count = 0
function Assert-Eq {
    param($Got, $Expected, [string]$Label)
    $script:count++
    if ([string]$Got -ceq [string]$Expected) {
        Write-Host "  ok: $Label"
    } else {
        Write-Host "FAIL [$Label]: got <$Got>, expected <$Expected>"
        $script:fails++
    }
}
function Assert-True {
    param($Cond, [string]$Label)
    $script:count++
    if ($Cond) { Write-Host "  ok: $Label" }
    else { Write-Host "FAIL [$Label]: expected true, got <$Cond>"; $script:fails++ }
}

# ── log capture ────────────────────────────────────────────────────────────
# hook.ps1 assigns $logFile at dot-source time into THIS script's scope, and Log
# resolves it up the scope chain at call time — so re-pointing it here is enough
# to isolate each case.
function Reset-Log {
    $p = Join-Path ([System.IO.Path]::GetTempPath()) ("rogue-copilot-ps-" + [guid]::NewGuid().ToString('N') + ".log")
    $script:logFile = $p
    return $p
}
function Get-LogText {
    param([string]$Path)
    if (Test-Path -LiteralPath $Path) { return (Get-Content -Raw -LiteralPath $Path) }
    return ''
}
# The alert's DRYRUN=2 seam logs "ide_alert=escaped msg=<composed literal>", with
# real newlines rendered as '|' so the record stays one line.
function Get-EscapedMsg {
    param([string]$Path)
    $txt = Get-LogText $Path
    $m = [regex]::Match($txt, 'ide_alert=escaped msg=(.*)')
    if ($m.Success) { return $m.Groups[1].Value.TrimEnd([char]13) }
    return $null
}
function Clear-AlertEnv {
    $env:ROGUE_IDE_ALERT = $null
    $env:ROGUE_IDE_ALERT_DRYRUN = $null
    $env:COPILOT_CLI_BINARY_VERSION = $null
    $env:PKG_EXECPATH = $null
    $env:GITHUB_COPILOT_RIPGREP_PATH_OVERRIDE = $null
}
Clear-AlertEnv

# ── Sanitize: strip control characters (log-forgery guard) ─────────────────
# The reason text is server-controlled and lands in the hook log; a raw newline
# or CR would let it forge a second log record.
Assert-Eq (Sanitize "a`tb`nc`r`0d") 'abcd'  'Sanitize strips tab/LF/CR/NUL'
Assert-Eq (Sanitize ("x" + [char]0x7f + "y")) 'xy' 'Sanitize strips DEL (0x7f)'
Assert-Eq (Sanitize 'plain text') 'plain text' 'Sanitize leaves printable text alone'
Assert-Eq (Sanitize $null) '' 'Sanitize tolerates null'

# ── Show-BlockNotification: ROGUE_IDE_ALERT=0 is a hard off switch ─────────
$log = Reset-Log
$env:ROGUE_IDE_ALERT = '0'
$env:ROGUE_IDE_ALERT_DRYRUN = '1'
Show-BlockNotification 'should not appear'
Assert-Eq (Get-LogText $log) '' 'ROGUE_IDE_ALERT=0 logs nothing and shows nothing'
Clear-AlertEnv

# ── Show-BlockNotification: DRYRUN=1 logs, never composes or spawns ────────
$log = Reset-Log
$env:ROGUE_IDE_ALERT_DRYRUN = '1'
Show-BlockNotification 'Coding Agent Security: PROMPT_INJECTION'
$txt = Get-LogText $log
Assert-True ($txt -like '*ide_alert=fired*') 'DRYRUN=1 logs ide_alert=fired'
Assert-True (-not ($txt -like '*ide_alert=escaped*')) 'DRYRUN=1 stops before composing the popup'
Clear-AlertEnv

# ── Show-BlockNotification: empty reason falls back to a default ───────────
$log = Reset-Log
$env:ROGUE_IDE_ALERT_DRYRUN = '2'
Show-BlockNotification ''
Assert-Eq (Get-EscapedMsg $log) 'Prompt blocked by Rogue Security.' 'empty reason uses the default text'
Clear-AlertEnv

# ── Show-BlockNotification: literal \n becomes a real newline ──────────────
# API reasons are two paragraphs (findings text + the `rgx!` hint) carrying
# literal "\n" straight out of the JSON string. The call site must NOT collapse
# them to a space or this conversion is dead code. Mirrors hook.sh case 4e.
$log = Reset-Log
$env:ROGUE_IDE_ALERT_DRYRUN = '2'
Show-BlockNotification ('Rogue blocked.' + $BS + 'nUse rgx! to override.')
Assert-Eq (Get-EscapedMsg $log) 'Rogue blocked.|Use rgx! to override.' 'literal \n becomes a real newline'
Clear-AlertEnv

# ── Show-BlockNotification: single quotes are doubled ──────────────────────
# $safe is interpolated into a single-quoted PowerShell literal inside the
# -EncodedCommand payload, where "'" is the only metacharacter.
$log = Reset-Log
$env:ROGUE_IDE_ALERT_DRYRUN = '2'
Show-BlockNotification ("don" + $SQ + "t run this")
Assert-Eq (Get-EscapedMsg $log) ("don" + $SQ + $SQ + "t run this") 'single quote is doubled for the PS literal'
Clear-AlertEnv

# ── Show-BlockNotification: a runaway reason is truncated to 400 ───────────
$log = Reset-Log
$env:ROGUE_IDE_ALERT_DRYRUN = '2'
Show-BlockNotification ('a' * 500)
Assert-Eq (Get-EscapedMsg $log).Length 400 '500-char reason truncated to 400'
Clear-AlertEnv

# ── Test-JetBrainsIde: env-fallback truth table ────────────────────────────
# Both harnesses set COPILOT_CLI=1, so the parent process is the real
# discriminator. When the process walk is unavailable (WMI off, container, or —
# as here — dot-sourced off Windows) the env shape decides: the IDE does NOT
# export COPILOT_CLI_BINARY_VERSION but DOES export PKG_EXECPATH /
# GITHUB_COPILOT_RIPGREP_PATH_OVERRIDE. Mirrors hook.sh in_jetbrains_ide.
Clear-AlertEnv
$env:PKG_EXECPATH = '/x'
Assert-True (Test-JetBrainsIde) 'fallback: version unset + PKG_EXECPATH set => IDE'
Clear-AlertEnv

$env:GITHUB_COPILOT_RIPGREP_PATH_OVERRIDE = '/x/rg'
Assert-True (Test-JetBrainsIde) 'fallback: version unset + ripgrep override set => IDE'
Clear-AlertEnv

Assert-True (-not (Test-JetBrainsIde)) 'fallback: version unset + no IDE markers => not IDE'

$env:COPILOT_CLI_BINARY_VERSION = '1.0.75'
$env:PKG_EXECPATH = '/x'
Assert-True (-not (Test-JetBrainsIde)) 'fallback: version SET (terminal CLI) wins over PKG_EXECPATH'
Clear-AlertEnv

$env:COPILOT_CLI_BINARY_VERSION = '1.0.75'
Assert-True (-not (Test-JetBrainsIde)) 'fallback: version SET + no markers => not IDE'
Clear-AlertEnv

if ($fails -gt 0) {
    Write-Host ""
    Write-Host "$fails of $count Copilot hook.ps1 test(s) FAILED."
    exit 1
}
Write-Host ""
Write-Host "All $count Copilot hook.ps1 tests passed."
