# Helper for tests/test_hook_logs.ps1 — NOT a test on its own.
#
# Dot-sources ONE dispatcher through its ROGUE_PS_LIB_ONLY seam (which loads the
# logging helpers without running the hook), optionally pre-seeds the log file to
# force a rotation, calls Log once, and prints KEY=value facts for the parent to
# assert on. Run in a child pwsh per case so the five dispatchers' identically
# named functions ($logFile, Log, Rotate-Log) can never collide in one session.
param(
    [Parameter(Mandatory)][string]$Dispatcher,   # path to a hook.ps1
    [string]$EventName = 'PreToolUse',
    [switch]$NeedsInit,                          # antigravity: log vars live in Initialize-Logging
    [int]$SeedBytes = 0                          # >0: pre-fill the log to trigger rotation
)

$env:ROGUE_PS_LIB_ONLY = '1'
. $Dispatcher $EventName
if ($NeedsInit) { Initialize-Logging }

"LOGFILE=$logFile"
"CAP=$logMaxBytes"
if (-not $logFile) { return }

New-Item -ItemType Directory -Path (Split-Path $logFile) -Force | Out-Null
if ($SeedBytes -gt 0) {
    # -NoNewline so the byte count is exact; rotation compares against Length.
    Set-Content -LiteralPath $logFile -Value ('s' * $SeedBytes) -NoNewline
}
Log 'outcome=probe'

$lines = @(Get-Content -LiteralPath $logFile -ErrorAction SilentlyContinue)
"LINES=$($lines.Count)"
"LAST=$($lines[-1])"
"ROTATED=$(Test-Path -LiteralPath ($logFile + '.1'))"
