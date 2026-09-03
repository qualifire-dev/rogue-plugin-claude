function Format-RogueEnvValue {
    param([string]$Value)
    return "'" + $Value.Replace("'", "'\''") + "'"
}

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
        $value = [string]$Values[$key]
        if ($value -match "[`r`n]") {
            throw "Refusing to write ${Path}: the value for $key contains a line break"
        }
        $lines.Add("export $key=$(Format-RogueEnvValue $value)")
    }

    if (Test-Path -LiteralPath $Path) {
        $owned = '^\s*(?:export\s+)?(?:' +
            (($managed | ForEach-Object { [regex]::Escape($_) }) -join '|') + ')\s*='
        $header = '^\s*# (Managed by the [Rr]ogue|Delete this file to revoke credentials)'
        foreach ($line in (Get-Content -LiteralPath $Path -Encoding UTF8 -ErrorAction Stop)) {
            if ($line -match $owned)  { continue }
            if ($line -match $header) { continue }
            $lines.Add($line)
        }
    }

    $dir = Split-Path -Parent $Path
    if ($dir -and -not (Test-Path -LiteralPath $dir)) {
        New-Item -ItemType Directory -Path $dir -Force | Out-Null
    }

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
