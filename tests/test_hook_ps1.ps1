#!/usr/bin/env pwsh
# tests/test_hook_ps1.ps1 — unit tests for hook.ps1's shell-quoting decoder
# (ConvertFrom-ShellQuoted).
#
# Why this matters: on Windows ONLY hook.ps1 reads the credential files, but one
# of those files — the compiled plugin `env` — is a cross-platform artifact that
# hook.sh `source`s on macOS/Linux. So the value MUST come out identical whether
# the shell parses it or hook.ps1 decodes it. These files are shell-quoted two
# different ways in the wild:
#   • POSIX single-quoting with `'\''` escapes ............ install.ps1 / setup.ps1
#   • bash `printf %q` (backslash + double-quote escapes) .. install.sh / setup.sh
# A naive outer-quote strip mangles both. This decoder must match what a POSIX
# shell would do when evaluating a single word.
#
# Run on any platform with PowerShell:  pwsh tests/test_hook_ps1.ps1
# (hook.ps1 stands down on non-Windows for its MAIN body, but the test only loads
#  its functions via the ROGUE_PS_LIB_ONLY seam, so this runs anywhere.)

$ErrorActionPreference = 'Stop'
$here = Split-Path -Parent $MyInvocation.MyCommand.Path
# [IO.Path]::Combine takes many segments on Windows PowerShell 5.1; multi-segment
# Join-Path is PowerShell 7+ only.
$hook = [System.IO.Path]::Combine($here, '..', 'plugins', 'rogue', 'scripts', 'hook.ps1')

# Load hook.ps1's functions without executing the dispatcher body.
$env:ROGUE_PS_LIB_ONLY = '1'
. $hook
$env:ROGUE_PS_LIB_ONLY = $null

# Single-char building blocks, so the test literals themselves can't be
# mis-escaped (PowerShell's own quoting rules differ from the shell's).
$SQ  = [char]39   # '
$DQ  = [char]34   # "
$BS  = [char]92   # \
$DOL = [char]36   # $
$BT  = [char]96   # `

$fails = 0
$count = 0
function Assert-Decode {
    param([string]$Raw, [string]$Expected, [string]$Label)
    $script:count++
    $got = ConvertFrom-ShellQuoted $Raw
    if ($got -ceq $Expected) {
        Write-Host "  ok: $Label"
    } else {
        Write-Host "FAIL [$Label]: ConvertFrom-ShellQuoted <$Raw> = <$got>, expected <$Expected>"
        $script:fails++
    }
}

# ── barewords: nothing for the shell to interpret, returned as-is ──────────
Assert-Decode 'rsk_abc123'        'rsk_abc123'        'plain API-key-style value'
Assert-Decode 'user@example.com'  'user@example.com'  'plain email'
Assert-Decode 'café'              'café'              'non-ASCII passes through'
Assert-Decode ''                  ''                  'empty string'

# ── POSIX single-quoting (install.ps1 / setup.ps1 Format-EnvVal) ───────────
Assert-Decode "'Test User'"           'Test User'            'single-quoted value with space'
Assert-Decode "''"                    ''                     'empty single-quoted value'
Assert-Decode "' '"                   ' '                    'single-quoted lone space'
Assert-Decode ("'O'" + $BS + $SQ + $SQ + "Brien'")  ("O" + $SQ + "Brien")  "POSIX escaped single quote"
Assert-Decode ("'Mary O'" + $BS + $SQ + $SQ + "Brien-Smith'") ("Mary O" + $SQ + "Brien-Smith") "POSIX escaped quote mid-name"
Assert-Decode "'a'b'c'"               'abc'                  'adjacent single-quoted segments concatenate'
Assert-Decode "''''"                  ''                     'four single quotes cancel to empty'
Assert-Decode ("'it'" + $BS + $SQ + $SQ + "s'") ("it" + $SQ + "s") "mixed bareword + escaped quote (it's)"
Assert-Decode "'a;b|c&d'"             'a;b|c&d'              'shell metacharacters literal inside single quotes'
Assert-Decode ($SQ + 'a' + $DOL + 'HOME' + $SQ) ('a' + $DOL + 'HOME') 'dollar literal inside single quotes'

# ── bash printf %q output (install.sh / setup.sh) ──────────────────────────
Assert-Decode 'Your\ Name'            'Your Name'            'printf %q escaped space'
Assert-Decode ("O" + $BS + $SQ + "Brien")  ("O" + $SQ + "Brien")  'printf %q escaped single quote'
Assert-Decode ("Mary" + $BS + " O" + $BS + $SQ + "Brien") ("Mary O" + $SQ + "Brien") 'printf %q escaped space + quote'
Assert-Decode 'C:\\path\\to'          'C:\path\to'           'printf %q escaped backslashes'
Assert-Decode 'a\\b'                  'a\b'                  'printf %q single escaped backslash'
Assert-Decode ('a' + $BS + $DQ + 'b') ('a' + $DQ + 'b')      'printf %q escaped double quote (bareword)'
Assert-Decode ($BS + $DOL + 'HOME')   ($DOL + 'HOME')        'printf %q escaped dollar (bareword)'

# ── double-quoted forms (a writer or hand-edit may use them) ───────────────
Assert-Decode '"a b"'                 'a b'                  'double-quoted value with space'
Assert-Decode '"a;b|c"'               'a;b|c'                'metacharacters literal inside double quotes'
Assert-Decode ('"a' + $BS + $DQ + 'b"') ('a' + $DQ + 'b')   'double-quoted escaped double quote'
Assert-Decode '"a\\b"'                'a\b'                  'double-quoted escaped backslash'
Assert-Decode ($DQ + 'a' + $BS + $DOL + 'b' + $DQ) ('a' + $DOL + 'b') 'double-quoted escaped dollar stays literal'
Assert-Decode ($DQ + 'a' + $BS + $BT + 'b' + $DQ) ('a' + $BT + 'b')   'double-quoted escaped backtick stays literal'
Assert-Decode ($DQ + 'O' + $SQ + 'Brien' + $DQ) ('O' + $SQ + 'Brien') 'single quote literal inside double quotes'

# ── trailing backslash: no following char to escape, kept literal ──────────
Assert-Decode ('a' + $BS)             ('a' + $BS)            'trailing lone backslash kept literal'

# ── actor identity screening (Test-SyntheticActor / Select-ActorValue) ─────
# In Claude Cowork the hook runs in a sandbox as unix user `claude` whose git
# identity is Anthropic's synthetic "Claude <noreply@anthropic.com>", so those
# values must never be reported as the acting human — from ANY source, including
# an explicit ROGUE_ACTOR_* baked into a compiled bundle's env file. The sh twin
# of this screen is actor.sh's _rogue_is_synthetic (see tests/test_actor_sh.sh).
function Assert-Synthetic {
    param([string]$Value, [bool]$Expected, [string]$Label)
    $script:count++
    $got = [bool](Test-SyntheticActor $Value)
    if ($got -eq $Expected) {
        Write-Host "  ok: $Label"
    } else {
        Write-Host "FAIL [$Label]: Test-SyntheticActor <$Value> = $got, expected $Expected"
        $script:fails++
    }
}
function Assert-Selected {
    param([string[]]$Candidates, [string]$Expected, [string]$Label)
    $script:count++
    $got = Select-ActorValue $Candidates
    if ($got -ceq $Expected) {
        Write-Host "  ok: $Label"
    } else {
        Write-Host "FAIL [$Label]: Select-ActorValue = <$got>, expected <$Expected>"
        $script:fails++
    }
}

Assert-Synthetic ''                      $true  'empty value is synthetic'
Assert-Synthetic '   '                   $true  'whitespace-only value is synthetic'
Assert-Synthetic 'Claude'                $true  'Claude is synthetic'
Assert-Synthetic 'claude'                $true  'claude (lowercase) is synthetic'
Assert-Synthetic 'Claude Code'           $true  'Claude Code is synthetic'
Assert-Synthetic '  CLAUDE   code  '     $true  'case + repeated whitespace still matches'
Assert-Synthetic 'noreply@anthropic.com' $true  'sandbox git email is synthetic'
Assert-Synthetic 'NoReply@Anthropic.COM' $true  'sandbox git email match is case-insensitive'
Assert-Synthetic 'Jane Dev'              $false 'a real name is not synthetic'
Assert-Synthetic 'Claudia Claude-Smith'  $false 'a name merely containing claude is not synthetic'
Assert-Synthetic 'claude.dubois@corp.com' $false 'a real email at a real domain is not synthetic'

Assert-Selected @('noreply@anthropic.com', 'real.user@corp.com') 'real.user@corp.com' 'poisoned first candidate skipped'
Assert-Selected @('Claude', '', 'Jane Dev')                      'Jane Dev'           'synthetic + empty candidates skipped'
Assert-Selected @('mdm@corp.com', 'real.user@corp.com')          'mdm@corp.com'       'first legitimate candidate wins'
Assert-Selected @('Claude', 'claude code', '  ')                 ''                   'all-synthetic yields empty (caller emits the unknown marker)'

if ($fails -gt 0) {
    Write-Host ""
    Write-Host "$fails of $count PowerShell unit test(s) FAILED."
    exit 1
}
Write-Host ""
Write-Host "All $count hook.ps1 unit tests passed."
