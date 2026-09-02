# Rogue Security - shared credential-file writer (Windows / PowerShell).
# DOT-SOURCED, never executed on its own.
#
# SOURCE OF TRUTH: run scripts/sync-shared-scripts.sh after editing. Must produce
# the same bytes as the sh twin, scripts/shared/env-file.sh, which says why the
# write MERGES. Keep Windows PowerShell 5.1 clean.

# The PS literal "'\''" is exactly the 4 chars ' \ ' '; "'\\''" would be an
# unterminated quote that breaks both parsers.
function Format-RogueEnvValue {
    param([string]$Value)
    return "'" + $Value.Replace("'", "'\''") + "'"
}

# The Windows chmod 600; the failure reason is left in the script-scope var
# because some plugins treat it as fatal.
function Protect-RogueEnvFile {
    param([string]$Path)
    $script:RogueEnvProtectError = ''
    try {
        $acl = Get-Acl $Path
        $acl.SetAccessRuleProtection($true, $false)
        $rule = New-Object System.Security.AccessControl.FileSystemAccessRule(
            [System.Security.Principal.WindowsIdentity]::GetCurrent().Name,
            'FullControl', 'Allow')
        $acl.SetAccessRule($rule)
        Set-Acl $Path $acl
        return $true
    } catch {
        $script:RogueEnvProtectError = $_.Exception.Message
        return $false
    }
}

# $Values: an [ordered] hashtable of the keys this caller owns.
# -RequireProtection: leave the file on disk untouched when the ACL cannot be
# applied, rather than replacing it with one whose API key is readable. Callers
# that treat protection as fatal pass it - they used to delete the file after
# the fact, which took the settings the other five plugins pin in it as well.
function Write-RogueEnvFile {
    param(
        [Parameter(Mandatory = $true)][string]$Path,
        [Parameter(Mandatory = $true)]$Values,
        [switch]$RequireProtection
    )

    $managed = @($Values.Keys)
    $lines = New-Object System.Collections.Generic.List[string]
    $lines.Add('# Managed by the Rogue plugins. Read by hook subprocesses at runtime.')
    $lines.Add('# Delete this file to revoke credentials.')
    foreach ($key in $managed) {
        $lines.Add("export $key=$(Format-RogueEnvValue ([string]$Values[$key]))")
    }

    if (Test-Path -LiteralPath $Path) {
        $owned = '^\s*(?:export\s+)?(?:' +
            (($managed | ForEach-Object { [regex]::Escape($_) }) -join '|') + ')\s*='
        $header = '^\s*# (Managed by the [Rr]ogue|Delete this file to revoke credentials)'
        foreach ($line in (Get-Content -LiteralPath $Path -ErrorAction SilentlyContinue)) {
            if ($line -match $owned)  { continue }
            if ($line -match $header) { continue }
            $lines.Add($line)
        }
    }

    $dir = Split-Path -Parent $Path
    if ($dir -and -not (Test-Path -LiteralPath $dir)) {
        New-Item -ItemType Directory -Path $dir -Force | Out-Null
    }

    # Temp then rename, like the sh twin: a failed or interrupted write must not
    # truncate a file five other plugins read. The ACL lands on the temp, so the
    # key is never briefly readable at the real path and the rename carries the
    # restricted descriptor with it.
    #
    # Set-Content -Encoding UTF8 writes a BOM on 5.1, plus CRLF, and a CR rides
    # into every value a POSIX shell sources.
    $tmp = "$Path.rogue-tmp.$PID"
    $utf8 = New-Object System.Text.UTF8Encoding($false)
    try {
        [System.IO.File]::WriteAllText($tmp, (($lines -join "`n") + "`n"), $utf8)
        $protected = Protect-RogueEnvFile $tmp
        if ($RequireProtection -and -not $protected) {
            Remove-Item -LiteralPath $tmp -Force -ErrorAction SilentlyContinue
            return $false
        }
        Move-Item -LiteralPath $tmp -Destination $Path -Force
    } catch {
        Remove-Item -LiteralPath $tmp -Force -ErrorAction SilentlyContinue
        throw
    }

    return $protected
}
