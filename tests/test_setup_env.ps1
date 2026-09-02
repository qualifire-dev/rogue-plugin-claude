# The ~/.rogue-env writers must MERGE, not truncate - the PowerShell half, and
# the twin of tests/test_setup_env.sh, which it must agree with case for case.
#
# Runs anywhere pwsh runs, including Linux CI. Windows PowerShell 5.1 must also
# pass; keep the syntax 5.1-clean.
#
#   pwsh -File tests/test_setup_env.ps1

$ErrorActionPreference = 'Stop'
$repo = Split-Path -Parent (Split-Path -Parent $PSCommandPath)
$script:fails = 0

function Check {
    param([string]$Label, $Expected, $Actual)
    if ($Expected -eq $Actual) { Write-Host "  ok: $Label" }
    else { Write-Host "FAIL: $Label (expected [$Expected], got [$Actual])"; $script:fails++ }
}

$sandbox = Join-Path ([System.IO.Path]::GetTempPath()) ("rogue-envps-" + [guid]::NewGuid().ToString('N'))
New-Item -ItemType Directory -Path $sandbox -Force | Out-Null

# Managed keys stale, plus what a machine might have added itself.
$seed = @(
    '# Managed by the rogue Claude plugin. Read by hook subprocesses at runtime.',
    '# Delete this file to revoke credentials.',
    "export ROGUE_API_KEY='stale-key'",
    "export ROGUE_ACTOR_EMAIL='stale@example.com'",
    "export ROGUE_ACTOR_NAME='Stale'",
    '# our self-hosted API',
    "export ROGUE_BASE_URL='http://localhost:8007'",
    "export ROGUE_LOG_DIR='/var/log/rogue'",
    'export ROGUE_HEARTBEAT_MIN_INTERVAL=60'
) -join "`n"

function New-SeededFile {
    param([string]$Name)
    $path = Join-Path $sandbox $Name
    [System.IO.File]::WriteAllText($path, $seed + "`n",
        (New-Object System.Text.UTF8Encoding($false)))
    return $path
}

function Get-EnvValue {
    param([string]$Path, [string]$Key)
    foreach ($line in (Get-Content -LiteralPath $Path)) {
        if ($line -match ('^\s*export\s+' + [regex]::Escape($Key) + "\s*=\s*'?(.*?)'?\s*$")) {
            return $Matches[1]
        }
    }
    return $null
}

function Count-Matching {
    param([string]$Path, [string]$Pattern)
    return @(Get-Content -LiteralPath $Path | Where-Object { $_ -match $Pattern }).Count
}

# -- The shared library the five setup.ps1 helpers load -----------------------
. ([scriptblock]::Create((Get-Content -Raw -LiteralPath (Join-Path $repo 'scripts/shared/env-file.ps1'))))

$libFile = New-SeededFile 'lib.env'
Write-RogueEnvFile -Path $libFile -Values ([ordered]@{
    ROGUE_API_KEY     = 'new-key'
    ROGUE_ACTOR_EMAIL = 'new@example.com'
    ROGUE_ACTOR_NAME  = 'New Name'
}) | Out-Null

Check 'lib: api key replaced'      'new-key'               (Get-EnvValue $libFile 'ROGUE_API_KEY')
Check 'lib: actor name replaced'   'New Name'              (Get-EnvValue $libFile 'ROGUE_ACTOR_NAME')
Check 'lib: base url kept'         'http://localhost:8007' (Get-EnvValue $libFile 'ROGUE_BASE_URL')
Check 'lib: log dir kept'          '/var/log/rogue'        (Get-EnvValue $libFile 'ROGUE_LOG_DIR')
Check 'lib: beacon interval kept'  '60'                    (Get-EnvValue $libFile 'ROGUE_HEARTBEAT_MIN_INTERVAL')
Check 'lib: user comment kept'     1  (Count-Matching $libFile '^# our self-hosted API$')
Check 'lib: one api key line'      1  (Count-Matching $libFile '^export ROGUE_API_KEY=')
# Re-emitted per write; the old one must not accumulate.
Check 'lib: one header line'       1  (Count-Matching $libFile 'Read by hook subprocesses')

# sh sources this file on the other half of the fleet, where an unescaped quote
# swallows the rest of it.
$quoteFile = New-SeededFile 'quote.env'
Write-RogueEnvFile -Path $quoteFile -Values ([ordered]@{
    ROGUE_API_KEY     = "key'with'quotes"
    ROGUE_ACTOR_EMAIL = 'e@x.io'
    ROGUE_ACTOR_NAME  = "O'Brien"
}) | Out-Null
Check 'lib: quoted value escaped' "export ROGUE_API_KEY='key'\''with'\''quotes'" `
    (@(Get-Content -LiteralPath $quoteFile | Where-Object { $_ -match '^export ROGUE_API_KEY=' })[0])

# `.` in sh chokes on a BOM, and a CR rides into every value it sources.
$bytes = [System.IO.File]::ReadAllBytes($libFile)
Check 'lib: no UTF-8 BOM' $false (($bytes[0] -eq 0xEF) -and ($bytes[1] -eq 0xBB) -and ($bytes[2] -eq 0xBF))
Check 'lib: no CR bytes'  $false ($bytes -contains 13)

# -- The two best-effort setup.ps1 helpers, end to end ------------------------
# Only these two: the other three delete the file and fail when the ACL cannot be
# applied, i.e. every non-Windows run. They are wired-checked below.
$saveEnvFile = $env:ROGUE_ENV_FILE
foreach ($plugin in @('rogue', 'cursor')) {
    $path = New-SeededFile "$plugin.env"
    $env:ROGUE_ENV_FILE = $path
    & (Join-Path $repo "plugins/$plugin/scripts/setup.ps1") 'new-key' 'new@example.com' 'New Name' `
        -WarningAction SilentlyContinue | Out-Null
    Check "${plugin}: api key replaced" 'new-key'               (Get-EnvValue $path 'ROGUE_API_KEY')
    Check "${plugin}: base url kept"    'http://localhost:8007' (Get-EnvValue $path 'ROGUE_BASE_URL')
    Check "${plugin}: log dir kept"     '/var/log/rogue'        (Get-EnvValue $path 'ROGUE_LOG_DIR')
    Check "${plugin}: one header line"  1 (Count-Matching $path 'Read by hook subprocesses')
}
$env:ROGUE_ENV_FILE = $saveEnvFile

# -- Wiring: no writer may go back to truncating -------------------------------
foreach ($plugin in @('rogue', 'codex', 'cursor', 'copilot', 'antigravity')) {
    $text = Get-Content -Raw -LiteralPath (Join-Path $repo "plugins/$plugin/scripts/setup.ps1")
    Check "${plugin}: uses the shared writer" $true ($text -match 'Write-RogueEnvFile')
    Check "${plugin}: does not rewrite the file itself" $false ($text -match 'Set-Content\s+-Path\s+\$EnvFile')
}
$installer = Get-Content -Raw -LiteralPath (Join-Path $repo 'install.ps1')
Check 'install.ps1: merges existing lines' $true ($installer -match 'foreach \(\$line in \(Get-Content -LiteralPath \$EnvFile')
Check 'install.ps1: no truncating write'   $false ($installer -match 'Set-Content\s+-Path\s+\$EnvFile')

# -- The sh and PowerShell writers must produce the SAME file ------------------
$bash = Get-Command bash -ErrorAction SilentlyContinue
if ($bash) {
    $shFile = New-SeededFile 'cmp-sh.env'
    $psFile = New-SeededFile 'cmp-ps.env'
    $env:ROGUE_ENV_FILE = $shFile
    & $bash.Source (Join-Path $repo 'plugins/rogue/scripts/setup.sh') 'new-key' 'new@example.com' 'New Name' | Out-Null
    $env:ROGUE_ENV_FILE = $saveEnvFile
    Write-RogueEnvFile -Path $psFile -Values ([ordered]@{
        ROGUE_API_KEY     = 'new-key'
        ROGUE_ACTOR_EMAIL = 'new@example.com'
        ROGUE_ACTOR_NAME  = 'New Name'
    }) | Out-Null
    $shText = [System.IO.File]::ReadAllText($shFile)
    $psText = [System.IO.File]::ReadAllText($psFile)
    if ($shText -ceq $psText) { Write-Host '  ok: sh and PowerShell writers agree byte for byte' }
    else {
        Write-Host 'FAIL: sh and PowerShell writers disagree'
        Write-Host "--- sh ---`n$shText--- ps ---`n$psText"
        $script:fails++
    }
} else {
    Write-Host '  skip: bash not available (sh/PowerShell comparison)'
}

Remove-Item -Recurse -Force $sandbox -ErrorAction SilentlyContinue
if ($script:fails -gt 0) { Write-Host "$($script:fails) check(s) failed"; exit 1 }
Write-Host 'all env-file writer checks passed'
