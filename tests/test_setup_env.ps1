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

# -Encoding UTF8 on every read here too: on Windows PowerShell 5.1 a bare
# Get-Content decodes our BOM-less UTF-8 as the ANSI code page, so a test that
# read back a mangled value would agree with a writer that mangled it.
function Get-EnvValue {
    param([string]$Path, [string]$Key)
    foreach ($line in (Get-Content -LiteralPath $Path -Encoding UTF8)) {
        if ($line -match ('^\s*export\s+' + [regex]::Escape($Key) + "\s*=\s*'?(.*?)'?\s*$")) {
            return $Matches[1]
        }
    }
    return $null
}

function Count-Matching {
    param([string]$Path, [string]$Pattern)
    return @(Get-Content -LiteralPath $Path -Encoding UTF8 | Where-Object { $_ -match $Pattern }).Count
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
    (@(Get-Content -LiteralPath $quoteFile -Encoding UTF8 | Where-Object { $_ -match '^export ROGUE_API_KEY=' })[0])

# Non-ASCII must survive a merge. We write BOM-less UTF-8; Windows PowerShell 5.1
# decodes a BOM-less file as the ANSI code page unless told otherwise, so a bare
# Get-Content in the writer would read the preserved lines back mangled and then
# write the mangled bytes out - corruption that compounds on every later merge.
#
# The literals are built from code points rather than typed in: this .ps1 is
# itself BOM-less UTF-8, so under 5.1 a literal non-ASCII character in the source
# would hit the same decoding trap and the test would be measuring itself.
$eacute = [string][char]0x00E9
$uuml   = [string][char]0x00FC
$actorName = 'Jos' + $eacute + ' M' + $uuml + 'ller'
$keptDir   = '/var/log/caf' + $eacute

$u8File = Join-Path $sandbox 'nonascii.env'
[System.IO.File]::WriteAllText($u8File, (@(
    "export ROGUE_API_KEY='stale-key'",
    "export ROGUE_LOG_DIR='$keptDir'"
) -join "`n") + "`n", (New-Object System.Text.UTF8Encoding($false)))

foreach ($pass in 1, 2) {
    Write-RogueEnvFile -Path $u8File -Values ([ordered]@{
        ROGUE_API_KEY     = 'new-key'
        ROGUE_ACTOR_EMAIL = 'e@x.io'
        ROGUE_ACTOR_NAME  = $actorName
    }) | Out-Null
    Check "lib: non-ASCII actor name round-trips (pass $pass)" $actorName (Get-EnvValue $u8File 'ROGUE_ACTOR_NAME')
    Check "lib: non-ASCII preserved line intact (pass $pass)"  $keptDir   (Get-EnvValue $u8File 'ROGUE_LOG_DIR')
}
# The bytes on disk, independent of any Get-Content: mangling shows up as the
# ANSI round trip of the code point, not as the code point itself.
$u8Bytes = [System.IO.File]::ReadAllBytes($u8File)
$u8Text  = [System.Text.Encoding]::UTF8.GetString($u8Bytes)
Check 'lib: non-ASCII stored as UTF-8 on disk' $true ($u8Text -match ([regex]::Escape($actorName)))
Check 'lib: non-ASCII file has no BOM' $false `
    (($u8Bytes[0] -eq 0xEF) -and ($u8Bytes[1] -eq 0xBB) -and ($u8Bytes[2] -eq 0xBF))

# `.` in sh chokes on a BOM, and a CR rides into every value it sources.
$bytes = [System.IO.File]::ReadAllBytes($libFile)
Check 'lib: no UTF-8 BOM' $false (($bytes[0] -eq 0xEF) -and ($bytes[1] -eq 0xBB) -and ($bytes[2] -eq 0xBF))
Check 'lib: no CR bytes'  $false ($bytes -contains 13)

# -- -RequireProtection: no ACL, no replacement -------------------------------
# The three plugins that treat protection as fatal used to write the file and
# then delete it, which took the settings the other five pin in it as well. Now
# the ACL goes on the temp file and a failure abandons the temp instead. Every
# non-Windows run exercises the failure branch (Get-Acl is unsupported there).
$reqFile = New-SeededFile 'require-protection.env'
$reqBefore = [System.IO.File]::ReadAllText($reqFile)
$reqOk = Write-RogueEnvFile -Path $reqFile -RequireProtection -Values ([ordered]@{
    ROGUE_API_KEY     = 'guarded-key'
    ROGUE_ACTOR_EMAIL = 'e@x.io'
    ROGUE_ACTOR_NAME  = 'N'
})
if ($reqOk) {
    Check 'require-protection: wrote once the ACL applied' 'guarded-key' (Get-EnvValue $reqFile 'ROGUE_API_KEY')
} else {
    Check 'require-protection: existing file left untouched' $reqBefore ([System.IO.File]::ReadAllText($reqFile))
}
Check 'require-protection: no temp left behind' 0 `
    (@(Get-ChildItem -LiteralPath $sandbox -Filter '*.rogue-tmp.*' -Force).Count)

# A failed write must not truncate the file either. A read-only directory is what
# a full disk looks like from here; root ignores the mode bits, hence the probe.
$chmod = Get-Command chmod -ErrorAction SilentlyContinue
if ($chmod) {
    $roDir = Join-Path $sandbox 'readonly'
    New-Item -ItemType Directory -Path $roDir -Force | Out-Null
    $roFile = Join-Path $roDir 'rogue.env'
    [System.IO.File]::WriteAllText($roFile, $seed + "`n", (New-Object System.Text.UTF8Encoding($false)))
    $roBefore = [System.IO.File]::ReadAllText($roFile)
    & $chmod.Source 500 $roDir
    # finally, not a trailing call: $ErrorActionPreference is 'Stop', so a
    # terminating error anywhere below would skip the restore and leave the
    # sandbox undeletable for the run's own cleanup.
    try {
        $probe = Join-Path $roDir '.probe'
        $writable = $true
        try { [System.IO.File]::WriteAllText($probe, 'x'); Remove-Item -LiteralPath $probe -Force } catch { $writable = $false }
        if ($writable) {
            Write-Host '  skip: directory is writable anyway (running as root?)'
        } else {
            $threw = $false
            try {
                Write-RogueEnvFile -Path $roFile -Values ([ordered]@{
                    ROGUE_API_KEY = 'should-not-land'; ROGUE_ACTOR_EMAIL = 'e@x.io'; ROGUE_ACTOR_NAME = 'N'
                }) | Out-Null
            } catch { $threw = $true }
            Check 'failed write: reported, not swallowed' $true $threw
            Check 'failed write: old file intact' $roBefore ([System.IO.File]::ReadAllText($roFile))
        }
    } finally {
        & $chmod.Source 700 $roDir
    }
} else {
    Write-Host '  skip: chmod not available (failed-write case)'
}

# -- The two best-effort setup.ps1 helpers, end to end ------------------------
# Only these two: the other three pass -RequireProtection and fail without
# writing when the ACL cannot be applied, i.e. every non-Windows run. They are
# wired-checked below.
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
    # The file now holds five other plugins' settings: no caller may delete it.
    Check "${plugin}: never deletes the env file" $false ($text -match 'Remove-Item -LiteralPath \$EnvFile')
}
foreach ($plugin in @('codex', 'copilot', 'antigravity')) {
    $text = Get-Content -Raw -LiteralPath (Join-Path $repo "plugins/$plugin/scripts/setup.ps1")
    Check "${plugin}: requires protection before replacing" $true ($text -match '-RequireProtection')
}

# The destination is only ever reached by renaming a fully written temp file.
$libText = Get-Content -Raw -LiteralPath (Join-Path $repo 'scripts/shared/env-file.ps1')
Check 'writer: no in-place write of the destination' $false `
    ($libText -match '\[System\.IO\.File\]::WriteAllText\(\$Path')
Check 'writer: renames a temp into place' $true `
    ($libText -match 'Move-Item -LiteralPath \$tmp -Destination \$Path')

# Structural, because behaviour cannot cover this on Linux: pwsh 7 defaults to
# UTF-8, so the non-ASCII case above passes there with or without the switch.
# Only Windows PowerShell 5.1 mangles, and only the wiring check fails on both.
Check 'writer: reads the env file as UTF-8' $true `
    ($libText -match 'Get-Content -LiteralPath \$Path -Encoding UTF8')

$installer = Get-Content -Raw -LiteralPath (Join-Path $repo 'install.ps1')
Check 'install.ps1: merges existing lines' $true ($installer -match 'foreach \(\$line in \(Get-Content -LiteralPath \$EnvFile')
Check 'install.ps1: reads the merge source as UTF-8' $true `
    ($installer -match 'Get-Content -LiteralPath \$EnvFile -Encoding UTF8')
Check 'install.ps1: reads existing creds as UTF-8' $true `
    ($installer -match 'Get-Content -LiteralPath \$f -Encoding UTF8')

# install.ps1 is piped to iex with no plugin tree beside it, so it inlines the
# dispatcher's shell-word decoder rather than loading it. Stripping the outer
# quotes is not enough - the writers emit 'O'\''Brien' - and a divergent copy
# here means the installer and the hooks disagree about one machine's actor name.
$dispatcher = Get-Content -Raw -LiteralPath (Join-Path $repo 'plugins/rogue/scripts/hook.ps1')
function Get-NormalizedFunction {
    param([string]$Text, [string]$Name)
    $body = [regex]::Match($Text, "(?ms)^function $Name \{.*?^\}").Value
    $body = [regex]::Replace($body, '(?m)^\s*#.*$', '')      # comments differ on purpose
    return ([regex]::Replace($body, '\s+', ' ')).Trim()
}
Check 'install.ps1: decodes shell quoting, not just the outer quotes' $true `
    ($installer -match 'ConvertFrom-ShellQuoted \$Matches')
Check 'install.ps1: shell-word decoder matches the dispatcher' `
    (Get-NormalizedFunction $dispatcher 'ConvertFrom-ShellQuoted') `
    (Get-NormalizedFunction $installer  'ConvertFrom-ShellQuoted')
Check 'install.ps1: no truncating write'   $false ($installer -match 'Set-Content\s+-Path\s+\$EnvFile')
Check 'install.ps1: renames a temp into place' $true `
    ($installer -match 'Move-Item -LiteralPath \$envTmp -Destination \$EnvFile')

# -- install.ps1: an explicit base URL must beat the one already on disk -------
# install.ps1 has no lib-only seam - it is a top-level script that installs on
# sight - so lift out the one function that decides that precedence and run it.
$loadFn = [regex]::Match($installer, '(?ms)^function Load-ExistingCreds \{.*?^\}').Value
Check 'install.ps1: Load-ExistingCreds located' $true ($loadFn.Length -gt 0)
# Load-ExistingCreds calls this, so it has to come along.
$unquoteFn = [regex]::Match($installer, '(?ms)^function ConvertFrom-ShellQuoted \{.*?^\}').Value
Check 'install.ps1: ConvertFrom-ShellQuoted located' $true ($unquoteFn.Length -gt 0)
. ([scriptblock]::Create($unquoteFn))
. ([scriptblock]::Create($loadFn))

$ROGUE_BASE_URL_DEFAULT = 'https://api.rogue.security'
$saveProfile = $env:USERPROFILE
$env:USERPROFILE = $sandbox
[System.IO.File]::WriteAllText((Join-Path $sandbox '.rogue-env'), $seed + "`n",
    (New-Object System.Text.UTF8Encoding($false)))

function Resolve-BaseUrl {
    param([string]$Given, [bool]$Explicit)
    $script:ApiKey = 'k'; $script:Email = 'e@x.io'; $script:Name = 'N'
    $script:BaseUrl = $Given
    $script:BaseUrlExplicit = $Explicit
    Load-ExistingCreds
    return $script:BaseUrl
}
Check 'install.ps1: silent run takes the on-disk url' 'http://localhost:8007' `
    (Resolve-BaseUrl $ROGUE_BASE_URL_DEFAULT $false)
Check 'install.ps1: explicit custom url wins' 'https://staging.example.com' `
    (Resolve-BaseUrl 'https://staging.example.com' $true)
# The regression: an explicit SaaS url used to read as "not given" and lose, so a
# machine pinned to a staging host could never be moved back.
Check 'install.ps1: explicit default clears the stale custom url' $ROGUE_BASE_URL_DEFAULT `
    (Resolve-BaseUrl $ROGUE_BASE_URL_DEFAULT $true)

# -- A value with an apostrophe must survive load -> write -> load -------------
# The writers emit POSIX single-quoted values, so O'Brien is stored as
# 'O'\''Brien'. Load-ExistingCreds used to strip only the outer quotes and hand
# back the literal O'\''Brien, which the next write re-quoted - and auto-update
# re-runs this installer unattended every 24h, so the escaping compounded with no
# user action. An Enter-to-keep flow reaches the same place by hand.
$apos = "O'Brien"
$aposFile = Join-Path $sandbox '.rogue-env'
[System.IO.File]::WriteAllText($aposFile, (@(
    "export ROGUE_API_KEY='k'",
    "export ROGUE_ACTOR_EMAIL='o@example.com'",
    "export ROGUE_ACTOR_NAME='O'\''Brien'"
) -join "`n") + "`n", (New-Object System.Text.UTF8Encoding($false)))

$script:ApiKey = ''; $script:Email = ''; $script:Name = ''
$script:BaseUrl = $ROGUE_BASE_URL_DEFAULT; $script:BaseUrlExplicit = $false
Load-ExistingCreds
Check 'install.ps1: apostrophe decoded on load' $apos $script:Name

# Now write it back the way the installer does, and load it once more: a value
# that survives one cycle but grows on the next is the actual failure mode.
Write-RogueEnvFile -Path $aposFile -Values ([ordered]@{
    ROGUE_API_KEY     = $script:ApiKey
    ROGUE_ACTOR_EMAIL = $script:Email
    ROGUE_ACTOR_NAME  = $script:Name
}) | Out-Null
$script:Name = ''
Load-ExistingCreds
Check 'install.ps1: apostrophe survives a rewrite' $apos $script:Name
Check 'install.ps1: apostrophe not re-escaped on disk' "export ROGUE_ACTOR_NAME='O'\''Brien'" `
    (@(Get-Content -LiteralPath $aposFile -Encoding UTF8 |
       Where-Object { $_ -match '^export ROGUE_ACTOR_NAME=' })[0])
# sh is the other half of the fleet: it must read back the same value. POSIX
# paths only - under Git Bash this sandbox path is C:\Users\..., whose
# backslashes bash eats as escapes, so the source silently reads nothing. The
# path goes through the environment rather than the -c string for the same
# reason. tests/test_setup_env.sh covers the sh side natively on this platform.
$bashForApos = Get-Command bash -ErrorAction SilentlyContinue
if ($bashForApos -and -not $env:OS) {
    $env:ROGUE_APOS_FILE = $aposFile
    $viaSh = & $bashForApos.Source -c '. "$ROGUE_APOS_FILE"; printf %s "$ROGUE_ACTOR_NAME"'
    Remove-Item Env:ROGUE_APOS_FILE -ErrorAction SilentlyContinue
    Check 'install.ps1: apostrophe reads the same under sh' $apos $viaSh
}
$env:USERPROFILE = $saveProfile

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
