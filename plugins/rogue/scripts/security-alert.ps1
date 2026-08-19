# Rogue Security desktop alert (Windows / PowerShell).
#
# Native-Windows analogue of security-alert.sh's osascript/notify-send modal.
# Shows a topmost message box so a block is visible even when Claude Code is in
# the foreground. hook.ps1 launches this DETACHED (Start-Process -WindowStyle
# Hidden) so the hook returns immediately.
#
# Usage:
#   security-alert.ps1 "Title" "Message body" [severity]
# or, when launched detached, via environment variables:
#   ROGUE_ALERT_TITLE / ROGUE_ALERT_MSG / ROGUE_ALERT_SEVERITY
#
# Severity: critical (default) | warning | info - picks the icon.
# Always exits 0; a UI failure must never propagate to the hook.

param(
    [string]$Title    = $env:ROGUE_ALERT_TITLE,
    [string]$Message  = $env:ROGUE_ALERT_MSG,
    [string]$Severity = $env:ROGUE_ALERT_SEVERITY
)

if (-not $Title)    { $Title = 'Rogue Security' }
if (-not $Severity) { $Severity = 'critical' }
if ($null -eq $Message) { $Message = '' }

# API-relayed block reasons can carry literal "\n" (backslash + n, straight out of
# the JSON string) rather than real newlines. Convert them so the modal shows line
# breaks instead of printing "\n" (mirrors security-alert.sh:35).
$Message = $Message -replace '\\n', "`n"

# Severity -> WScript.Shell.Popup type code. The low bits are the button set
# (0 = OK); the icon bits are 16 = Stop (critical), 48 = Exclamation (warning),
# 64 = Information.
switch ($Severity) {
    'warning' { $type = 48 }
    'info'    { $type = 64 }
    default   { $type = 16 }
}

# WScript.Shell.Popup reliably surfaces on the interactive desktop from a detached,
# hidden background process (e.g. Cowork's hook runner) - it needs no assembly load
# (System.Windows.Forms) and isn't subject to the owner-window / DefaultDesktopOnly
# window-station constraints that made MessageBox::Show silently no-op there.
# Second arg 0 = no auto-dismiss timeout. Runs in a detached process, so a lingering
# dialog never blocks the hook.
try {
    $wsh = New-Object -ComObject 'WScript.Shell'
    $null = $wsh.Popup($Message, 0, $Title, $type)
} catch {
    # Last resort: write to stderr (visible in the hook log under ROGUE_DEBUG).
    [Console]::Error.WriteLine("[$Severity] $Title`: $Message")
}

exit 0
