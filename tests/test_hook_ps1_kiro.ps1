#!/usr/bin/env pwsh
# tests/test_hook_ps1_kiro.ps1 - unit tests for the Kiro PowerShell bridge's
# pure helpers (plugins/kiro/scripts/hook.ps1), in lockstep with
# tests/test_hook_sh_kiro.sh.
#
# Kiro's decision travels in the EXIT CODE (PreToolUse block = exit 2 with the
# reason on stderr), in a JSON decision on stdout (UserPromptSubmit), or nowhere
# at all (Stop never blocks). hook.ps1 computes that whole table in one pure
# function, Resolve-KiroOutcome, so it can be held to the contract here without
# a network: the main body stands down off-Windows, and these are the ONLY
# automated checks that ever execute the Windows half of the enforcement.
#
# Run on any platform with PowerShell:  pwsh tests/test_hook_ps1_kiro.ps1
# Loads only the functions via the ROGUE_PS_LIB_ONLY seam.

$here = Split-Path -Parent $MyInvocation.MyCommand.Path
# [IO.Path]::Combine takes many segments on Windows PowerShell 5.1; multi-segment
# Join-Path is PowerShell 7+ only.
$hook = [System.IO.Path]::Combine($here, '..', 'plugins', 'kiro', 'scripts', 'hook.ps1')
$fixtures = [System.IO.Path]::Combine($here, 'fixtures', 'kiro')

$env:ROGUE_PS_LIB_ONLY = '1'
. $hook
$env:ROGUE_PS_LIB_ONLY = $null
$ErrorActionPreference = 'Stop'

$BS = [char]92   # \
$fails = 0
$count = 0
function Assert-Eq {
    param($Got, $Expected, [string]$Label)
    $script:count++
    if ([string]$Got -ceq [string]$Expected) {
        Write-Host "  ok: $Label"
    } else {
        Write-Host "FAIL [$Label]: got <$Got>, expected <$Expected>"
        $script:fails++
    }
}
function Read-Fixture { param([string]$Name) return (Get-Content -Raw -LiteralPath (Join-Path $fixtures $Name)) }

$BLOCK = '{"decision":"block","reason":"Coding Agent Security: DESTRUCTIVE_COMMAND"}'

# -- ConvertTo-KiroEvent: the 2.x camelCase names map to the canonical event --
Assert-Eq (ConvertTo-KiroEvent 'preToolUse')       'PreToolUse'       '2.x preToolUse -> PreToolUse'
Assert-Eq (ConvertTo-KiroEvent 'agentSpawn')       'SessionStart'     '2.x agentSpawn -> SessionStart'
Assert-Eq (ConvertTo-KiroEvent 'userPromptSubmit') 'UserPromptSubmit' '2.x userPromptSubmit -> UserPromptSubmit'
Assert-Eq (ConvertTo-KiroEvent 'postToolUse')      'PostToolUse'      '2.x postToolUse -> PostToolUse'
Assert-Eq (ConvertTo-KiroEvent 'stop')             'Stop'             '2.x stop -> Stop'
Assert-Eq (ConvertTo-KiroEvent 'PreToolUse')       'PreToolUse'       'canonical names pass through'
Assert-Eq (ConvertTo-KiroEvent 'PostFileSave')     'PostFileSave'     'IDE file triggers pass through'
Assert-Eq (ConvertTo-KiroEvent 'SomethingNew')     'SomethingNew'     'an unknown event is passed verbatim, not dropped'

# -- Get-KiroSurface: closed vocabulary ---------------------------------------
Assert-Eq (Get-KiroSurface 'kiro_ide')  'kiro_ide'  'kiro_ide is a surface'
Assert-Eq (Get-KiroSurface 'kiro_cli')  'kiro_cli'  'kiro_cli is a surface'
Assert-Eq (Get-KiroSurface 'kiro_crew') 'kiro_crew' 'kiro_crew is a surface'
Assert-Eq (Get-KiroSurface 'KIRO_CLI')  ''          'the vocabulary is case-sensitive'
Assert-Eq (Get-KiroSurface 'copilot')   ''          'an unknown surface is empty (no log token)'
Assert-Eq (Get-KiroSurface '')          ''          'a missing surface is empty'

# -- Add-KiroSessionId: the 2.x body gets the env session id -----------------
$sid = 'sess_0b7a4a1e-2c0f-4d8a-9e51-1234567890ab'
$cli2 = Read-Fixture 'cli2-preToolUse-execute_bash.json'
$out = Add-KiroSessionId $cli2 $sid
$obj = ConvertFrom-Json $out
Assert-Eq $obj.session_id $sid            '2.x body gets session_id from the env value'
Assert-Eq $obj.tool_name  'execute_bash'  '...and keeps its own fields'
Assert-Eq $obj.tool_input.command 'echo spike-ok' '...nested ones too (bytes preserved, not re-serialised)'

$cli3 = Read-Fixture 'cli3-PreToolUse-execute_bash.json'
Assert-Eq (Add-KiroSessionId $cli3 'sess_should-not-win') $cli3 'a body that already carries session_id is untouched, byte for byte'
Assert-Eq (Add-KiroSessionId $cli2 '') $cli2 'no env session id: body posted verbatim'
Assert-Eq (Add-KiroSessionId $cli2 $null) $cli2 'null env session id: body posted verbatim'
Assert-Eq (Add-KiroSessionId $cli2 'sess_"x') $cli2 'a session id with a quote is refused (would corrupt the JSON)'
Assert-Eq (Add-KiroSessionId $cli2 'a b') $cli2 'a session id with a space is refused'
Assert-Eq (Add-KiroSessionId '{}' 's1') '{"session_id":"s1"}' 'an empty object needs no separator'
Assert-Eq (Add-KiroSessionId "{`n}`n" 's1') '{"session_id":"s1"}' 'a pretty-printed empty object needs no separator'
Assert-Eq (Add-KiroSessionId '[1,2]' 's1') '[1,2]' 'a non-object body is left alone'
Assert-Eq (Add-KiroSessionId '' 's1') '' 'an empty body is left alone'

# -- Test-KiroDuplicateAgentHook: the 3.0 engine's agent-hook copy ------------
# That engine loads the hook file AND the 2.x agent configs; a PascalCase body
# under a camelCase trigger can only be it running a 2.x agent hook.
$cli3Pre = Read-Fixture 'cli3-PreToolUse-execute_bash.json'
$cli2Pre = Read-Fixture 'cli2-preToolUse-execute_bash.json'
Assert-Eq (Test-KiroDuplicateAgentHook 'preToolUse' $cli3Pre) 'True'  'camelCase trigger + PascalCase body is the 3.0 agent-hook copy'
Assert-Eq (Test-KiroDuplicateAgentHook 'PreToolUse' $cli3Pre) 'False' 'the hook-file copy (PascalCase trigger) goes through'
Assert-Eq (Test-KiroDuplicateAgentHook 'preToolUse' $cli2Pre) 'False' 'a 2.x body (camelCase) is never a duplicate'
Assert-Eq (Test-KiroDuplicateAgentHook 'agentSpawn' (Read-Fixture 'cli3-SessionStart.json')) 'True' 'agentSpawn under a SessionStart body is dropped too'
Assert-Eq (Test-KiroDuplicateAgentHook 'stop' (Read-Fixture 'cli2-stop.json')) 'False' 'a 2.x stop goes through'
Assert-Eq (Test-KiroDuplicateAgentHook 'preToolUse' '{}') 'False' 'a body without hook_event_name goes through'
Assert-Eq (Test-KiroDuplicateAgentHook 'preToolUse' '') 'False' 'an empty body goes through'

# -- Test-KiroBlock: strict pair match -----------------------------------------
Assert-Eq (Test-KiroBlock $BLOCK) 'True' 'the block shape matches'
Assert-Eq (Test-KiroBlock '{ "decision" : "block" }') 'True' 'whitespace around the pair is tolerated'
Assert-Eq (Test-KiroBlock '{}') 'False' 'allow is {}'
Assert-Eq (Test-KiroBlock '{"decision":"allow","reason":"no findings","rulesetMode":"block"}') 'False' 'an allow that merely mentions block is an allow'
Assert-Eq (Test-KiroBlock '') 'False' 'an empty body is an allow'

# -- Get-KiroBlockReason --------------------------------------------------------
Assert-Eq (Get-KiroBlockReason $BLOCK) 'Coding Agent Security: DESTRUCTIVE_COMMAND' 'reason is read from the JSON'
$escaped = '{"decision":"block","reason":"Rogue blocked ' + $BS + '"rm -rf' + $BS + '".' + $BS + 'nUse rgx! to override."}'
Assert-Eq (Get-KiroBlockReason $escaped) ('Rogue blocked "rm -rf".' + "`n" + 'Use rgx! to override.') 'reason is JSON-unescaped (quotes, newline)'
Assert-Eq (Get-KiroBlockReason '{"decision":"block"}') 'Blocked by Rogue Security' 'a reason-less block gets a default line'
Assert-Eq (Get-KiroBlockReason '{"decision":"block","reason":""}') 'Blocked by Rogue Security' 'an empty reason gets the default line'

# -- Resolve-KiroOutcome: the decision table -----------------------------------
$o = Resolve-KiroOutcome 'PreToolUse' $BLOCK
Assert-Eq $o.ExitCode 2 'PreToolUse block: exit 2'
Assert-Eq $o.Stdout '' 'PreToolUse block: empty stdout'
Assert-Eq $o.Stderr 'Coding Agent Security: DESTRUCTIVE_COMMAND' 'PreToolUse block: reason on stderr'
Assert-Eq $o.Outcome 'block' 'PreToolUse block: logged as block'

$o = Resolve-KiroOutcome 'UserPromptSubmit' $BLOCK
Assert-Eq $o.ExitCode 0 'UserPromptSubmit block: exit 0'
Assert-Eq $o.Stdout $BLOCK 'UserPromptSubmit block: JSON decision on stdout'
Assert-Eq $o.Stderr '' 'UserPromptSubmit block: nothing on stderr'
Assert-Eq $o.Outcome 'block' 'UserPromptSubmit block: logged as block'

foreach ($ev in @('Stop', 'PostToolUse', 'SessionStart', 'PostFileSave', 'PostFileCreate', 'PostFileDelete')) {
    $o = Resolve-KiroOutcome $ev $BLOCK
    Assert-Eq "$($o.ExitCode):$($o.Stdout)$($o.Stderr)" '0:' "$ev with a server block: exit 0, silent"
    Assert-Eq $o.Outcome 'allow' "$ev with a server block: logged as allow"
    Assert-Eq $o.Note 'decision=block' "$ev with a server block: the ignored decision is noted"
}

foreach ($ev in @('PreToolUse', 'UserPromptSubmit', 'Stop', 'PostToolUse')) {
    $o = Resolve-KiroOutcome $ev '{}'
    Assert-Eq "$($o.ExitCode):$($o.Stdout)$($o.Stderr):$($o.Outcome):$($o.Note)" '0::allow:' "$ev allow: exit 0, silent"
    $o = Resolve-KiroOutcome $ev ''
    Assert-Eq "$($o.ExitCode):$($o.Stdout)$($o.Stderr):$($o.Outcome)" '0::allow' "$ev with an empty response: fail-open"
}

# The 2.x trigger name never reaches the table (the main body canonicalises
# first), but a caller that forgets must still fail OPEN, never closed.
$o = Resolve-KiroOutcome 'preToolUse' $BLOCK
Assert-Eq $o.ExitCode 0 'a non-canonical event name cannot produce an exit 2'

# -- Sanitize: strip control characters (log-forgery guard) ---------------------
Assert-Eq (Sanitize "a`tb`nc`r`0d") 'abcd' 'Sanitize strips tab/LF/CR/NUL'
Assert-Eq (Sanitize $null) '' 'Sanitize tolerates null'

# -- structural: the main body wires the table to the process ------------------
# Resolve-KiroOutcome is worthless if the main body ignores its ExitCode, and a
# stray `exit 2` anywhere else would be a fail-closed path.
$src = Get-Content -Raw -LiteralPath $hook
$count++
if ($src -match '(?m)^exit \$o\.ExitCode\s*$') { Write-Host '  ok: main body exits with the resolved ExitCode' }
else { Write-Host 'FAIL [main body exits with the resolved ExitCode]'; $fails++ }
$count++
$literalExit2 = [regex]::Matches(($src -replace '(?m)#.*$', ''), '\bexit\s+2\b').Count
if ($literalExit2 -eq 0) { Write-Host '  ok: no literal `exit 2` outside the resolved outcome' }
else { Write-Host "FAIL [no literal exit 2]: found $literalExit2"; $fails++ }
$count++
if ($src -match "Add-KiroSessionId \`$payload \`$env:KIRO_SESSION_ID") { Write-Host '  ok: main body injects KIRO_SESSION_ID into the payload' }
else { Write-Host 'FAIL [main body injects KIRO_SESSION_ID]'; $fails++ }
# ROGUE_HOOK_TIMEOUT=0 must fall back to the default: -TimeoutSec 0 is NO timeout,
# which would hand the budget to Kiro's own 10s (mirrors hook.sh's `-gt 0` clamp).
$count++
if ($src -match '\[int\]\$t -gt 0\) \{ \$timeoutSec = \[int\]\$t \}') { Write-Host '  ok: a zero ROGUE_HOOK_TIMEOUT keeps the default budget' }
else { Write-Host 'FAIL [a zero ROGUE_HOOK_TIMEOUT keeps the default budget]'; $fails++ }

Write-Host ""
if ($fails -eq 0) { Write-Host "All $count Kiro PowerShell bridge tests passed."; exit 0 }
Write-Host "$fails of $count failed."
exit 1
