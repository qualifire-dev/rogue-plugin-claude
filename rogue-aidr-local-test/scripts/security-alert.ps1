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
# Severity: critical (default) | warning | info — picks the icon.
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

try {
    Add-Type -AssemblyName System.Windows.Forms -ErrorAction Stop
    Add-Type -AssemblyName System.Drawing -ErrorAction SilentlyContinue

    switch ($Severity) {
        'warning' { $icon = [System.Windows.Forms.MessageBoxIcon]::Warning }
        'info'    { $icon = [System.Windows.Forms.MessageBoxIcon]::Information }
        default   { $icon = [System.Windows.Forms.MessageBoxIcon]::Error }
    }

    # A hidden, topmost owner form forces the message box in front of other windows
    # (a plain MessageBox::Show can open behind the active app).
    $owner = New-Object System.Windows.Forms.Form
    $owner.TopMost = $true
    $owner.ShowInTaskbar = $false
    $owner.WindowState = [System.Windows.Forms.FormWindowState]::Minimized

    [void][System.Windows.Forms.MessageBox]::Show(
        $owner, $Message, $Title,
        [System.Windows.Forms.MessageBoxButtons]::OK,
        $icon,
        [System.Windows.Forms.MessageBoxDefaultButton]::Button1,
        [System.Windows.Forms.MessageBoxOptions]::DefaultDesktopOnly)

    $owner.Dispose()
} catch {
    # Last resort: write to stderr (visible in the hook log under ROGUE_DEBUG).
    [Console]::Error.WriteLine("[$Severity] $Title`: $Message")
}

exit 0
