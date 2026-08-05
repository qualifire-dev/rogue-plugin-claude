# Rogue Security — credential storage helper (Windows / PowerShell).
# Mirrors setup.sh: writes %USERPROFILE%\.rogue-env, restricted to the current
# user, in the same `export KEY=value` shell-quoted format both dispatchers read.
#
# Usage: powershell -NoProfile -File setup.ps1 <api-key> <email> <name>
param(
    [Parameter(Mandatory = $true)][string]$ApiKey,
    [string]$Email = '',
    [string]$Name  = ''
)

$ErrorActionPreference = 'Stop'

$EnvFile = if ($env:ROGUE_ENV_FILE) { $env:ROGUE_ENV_FILE } else { Join-Path $env:USERPROFILE '.rogue-env' }

# Always POSIX single-quote so the value is safe whether the file is sourced by
# hook.sh or decoded by hook.ps1's ConvertFrom-ShellQuoted. Each ' becomes '\''
# (close, escaped ', reopen); the PS literal "'\''" is exactly the 4 chars ' \ ' '.
# Emitting "'\\''" here would be an unterminated quote that breaks both.
function Format-EnvVal {
    param([string]$Val)
    return "'" + $Val.Replace("'", "'\''") + "'"
}

$envLines = @(
    '# Managed by the rogue Claude plugin. Read by hook subprocesses at runtime.',
    '# Delete this file to revoke credentials.',
    "export ROGUE_API_KEY=$(Format-EnvVal $ApiKey)",
    "export ROGUE_ACTOR_EMAIL=$(Format-EnvVal $Email)",
    "export ROGUE_ACTOR_NAME=$(Format-EnvVal $Name)"
)

$envDir = Split-Path $EnvFile
if ($envDir -and -not (Test-Path $envDir)) {
    New-Item -ItemType Directory -Path $envDir -Force | Out-Null
}
Set-Content -Path $EnvFile -Value $envLines -Encoding UTF8

# Restrict the file to the current user only (best-effort, mirrors chmod 600).
try {
    $acl = Get-Acl $EnvFile
    $acl.SetAccessRuleProtection($true, $false)
    $rule = New-Object System.Security.AccessControl.FileSystemAccessRule(
        [System.Security.Principal.WindowsIdentity]::GetCurrent().Name,
        'FullControl', 'Allow')
    $acl.SetAccessRule($rule)
    Set-Acl $EnvFile $acl
} catch {}

Write-Output "OK"
Write-Output "ENV_FILE=$EnvFile"
