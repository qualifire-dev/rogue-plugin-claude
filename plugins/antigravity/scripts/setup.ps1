# Rogue Security — credential storage helper (Windows / PowerShell) — Google Antigravity plugin.
# Mirrors setup.sh: writes %USERPROFILE%\.rogue-env, restricted to the current
# user, in the same `export KEY=value` shell-quoted format both bridges read. The
# file is shared with the Claude/Codex/Cursor/Gemini/Copilot plugins.
#
# Usage: powershell -NoProfile -File setup.ps1 <api-key> <email> <name>
param(
    [Parameter(Mandatory = $true)][string]$ApiKey,
    [string]$Email = '',
    [string]$Name  = ''
)

$ErrorActionPreference = 'Stop'

$EnvFile = if ($env:ROGUE_ENV_FILE) { $env:ROGUE_ENV_FILE } else { Join-Path $env:USERPROFILE '.rogue-env' }

# Merges: replaces these keys, keeps a pinned ROGUE_BASE_URL and friends. Loaded
# as a scriptblock so ExecutionPolicy never applies.
. ([scriptblock]::Create((Get-Content -Raw -LiteralPath (Join-Path $PSScriptRoot 'env-file.ps1'))))

$restricted = Write-RogueEnvFile -Path $EnvFile -RequireProtection -Values ([ordered]@{
    ROGUE_API_KEY     = $ApiKey
    ROGUE_ACTOR_EMAIL = $Email
    ROGUE_ACTOR_NAME  = $Name
})

# Without the ACL the API key would sit readable with inherited perms, so
# -RequireProtection left the file on disk untouched instead of replacing it
# with an exposed one. Deleting it here - which is what this used to do - would
# take the settings the other five plugins pin in it down with the secret.
if (-not $restricted) {
    Write-Error "Failed to restrict permissions on $EnvFile : $script:RogueEnvProtectError"
    exit 1
}

Write-Output "OK"
Write-Output "ENV_FILE=$EnvFile"
