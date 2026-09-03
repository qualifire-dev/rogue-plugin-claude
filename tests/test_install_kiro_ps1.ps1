#!/usr/bin/env pwsh
# tests/test_install_kiro_ps1.ps1 - unit tests for the Kiro wiring in install.ps1,
# in lockstep with tests/test_install_kiro_sh.sh.
#
# install.ps1 is a top-down script, so the Kiro helpers are loaded through the
# ROGUE_INSTALL_LIB_ONLY seam (the script returns right after defining them) and
# driven against a temporary USERPROFILE with a fake kiro-cli on PATH: the hook
# file's shape, the agent-config merge (kept fields, kept foreign hooks, a
# re-run that does not stack, an unparseable file skipped), and both
# default-agent branches of ADR 0001. Runs on any platform with PowerShell;
# validate.yml also runs it under Windows PowerShell 5.1, whose JSON cmdlets
# differ from pwsh 7's.

$here = Split-Path -Parent $MyInvocation.MyCommand.Path
$installer = [System.IO.Path]::Combine($here, '..', 'install.ps1')

$work = Join-Path ([System.IO.Path]::GetTempPath()) ("rogue-kiro-install-" + [System.IO.Path]::GetRandomFileName())
$home1 = Join-Path $work 'home'
$state = Join-Path $work 'state'
$bin   = Join-Path $work 'bin'
foreach ($d in @($home1, $state, $bin)) { New-Item -ItemType Directory -Path $d -Force | Out-Null }

$prevProfile = $env:USERPROFILE
$prevPath    = $env:PATH
$env:USERPROFILE = $home1
$env:KIRO_CLI_LOG = Join-Path $work 'kiro-cli.log'
$env:KIRO_STATE   = $state

# The fake kiro-cli: `settings chat.defaultAgent` prints the value (exit 0) or an
# error (exit 1); `agent create --name X` writes X.json from Kiro's defaults into
# the global agent dir; `agent set-default X` records the choice. A .ps1 resolves
# by bare name from PATH on Windows; on Linux/macOS a sh shim beside it does.
$fakeCli = Join-Path $bin 'kiro-cli.ps1'
@'
param([Parameter(ValueFromRemainingArguments = $true)][string[]]$Argv)
Add-Content -LiteralPath $env:KIRO_CLI_LOG -Value ($Argv -join ' ')
$sub = "$($Argv[0]) $($Argv[1])"
if ($sub -eq 'agent create') {
    $name = $Argv[[array]::IndexOf($Argv, '--name') + 1]
    $dir = [System.IO.Path]::Combine($env:USERPROFILE, '.kiro', 'agents')
    New-Item -ItemType Directory -Path $dir -Force | Out-Null
    [System.IO.File]::WriteAllText((Join-Path $dir "$name.json"),
        "{`n  `"name`": `"$name`",`n  `"description`": `"created by kiro-cli`",`n  `"tools`": [`"*`"],`n  `"prompt`": `"`"`n}`n")
    exit 0
}
if ($sub -eq 'agent set-default') {
    [System.IO.File]::WriteAllText((Join-Path $env:KIRO_STATE 'default'), $Argv[2])
    exit 0
}
if ($sub -eq 'settings chat.defaultAgent') {
    $f = Join-Path $env:KIRO_STATE 'default'
    if (Test-Path -LiteralPath $f) { Write-Output ([System.IO.File]::ReadAllText($f)); exit 0 }
    [Console]::Error.WriteLine('error: No value associated with chat.defaultAgent')
    exit 1
}
exit 0
'@ | Set-Content -LiteralPath $fakeCli -Encoding UTF8
if ($env:OS -ne 'Windows_NT') {
    $shim = Join-Path $bin 'kiro-cli'
    [System.IO.File]::WriteAllText($shim, "#!/bin/sh`nexec pwsh -NoProfile -File `"$fakeCli`" `"`$@`"`n")
    & chmod +x $shim
}
$env:PATH = $bin + [System.IO.Path]::PathSeparator + $env:PATH

$env:ROGUE_INSTALL_LIB_ONLY = '1'
. $installer
$env:ROGUE_INSTALL_LIB_ONLY = $null
$ErrorActionPreference = 'Stop'

$fails = 0
$count = 0
function Assert-Eq {
    param($Got, $Expected, [string]$Label)
    $script:count++
    if ([string]$Got -ceq [string]$Expected) { Write-Host "  ok: $Label" }
    else { Write-Host "FAIL [$Label]: got <$Got>, expected <$Expected>"; $script:fails++ }
}
function Read-Json { param([string]$Path) return (Get-Content -Raw -LiteralPath $Path | ConvertFrom-Json) }
function Get-RogueHooks { param($Cfg) return @($Cfg.hooks | Where-Object { $_.name -like 'rogue-*' }) }

$pluginDir = [System.IO.Path]::Combine($home1, '.rogue', 'plugins', 'kiro')
$bridge    = [System.IO.Path]::Combine($pluginDir, 'scripts', 'hook.ps1')
$hooksDir  = [System.IO.Path]::Combine($home1, '.kiro', 'hooks')
$agentsDir = [System.IO.Path]::Combine($home1, '.kiro', 'agents')
New-Item -ItemType Directory -Path $agentsDir -Force | Out-Null

# -- the hook file: universal v1, every monitored event, no matcher ------------
$hookFile = Write-KiroHookFile $pluginDir $hooksDir
Assert-Eq $hookFile (Join-Path $hooksDir 'rogue.json') 'hook file lands at ~/.kiro/hooks/rogue.json'
$raw = [System.IO.File]::ReadAllBytes($hookFile)
Assert-Eq ($raw[0] -eq 0xEF -and $raw[1] -eq 0xBB) $false 'hook file has no BOM'
$hf = Read-Json $hookFile
Assert-Eq $hf.version 'v1' 'hook file is v1'
Assert-Eq (@($hf.hooks).Count) 8 'hook file carries the 8 monitored events'
Assert-Eq ((@($hf.hooks) | ForEach-Object { $_.trigger }) -join ' ') `
    'SessionStart UserPromptSubmit PreToolUse PostToolUse Stop PostFileCreate PostFileSave PostFileDelete' 'events in order, IDE/3.0 spelling'
Assert-Eq (@($hf.hooks | Where-Object { $_.action.type -ne 'command' }).Count) 0 'every hook is a command action'
Assert-Eq (@($hf.hooks | Where-Object { $_.timeout -ne 10 }).Count) 0 'every hook has timeout 10'
Assert-Eq (@($hf.hooks | Where-Object { $null -ne $_.PSObject.Properties['matcher'] }).Count) 0 'no hook carries a matcher'
Assert-Eq (@($hf.hooks | Where-Object { $_.name -ne "rogue-$($_.trigger)" }).Count) 0 'every hook name is rogue-<event>'
$expectedCmd = "powershell -NoProfile -ExecutionPolicy Bypass -File `"$bridge`" PreToolUse kiro_ide"
Assert-Eq (@($hf.hooks | Where-Object { $_.trigger -eq 'PreToolUse' })[0].action.command) $expectedCmd 'hook runs hook.ps1 as a file with the event and the kiro_ide surface'

# -- agent configs: merged, not replaced ---------------------------------------
$custom = Join-Path $agentsDir 'custom.json'
@'
{
  "name": "custom",
  "model": "claude-sonnet-4",
  "tools": ["fs_read", "execute_bash"],
  "hooks": [
    { "name": "mine", "trigger": "preToolUse", "matcher": "execute_bash", "action": { "type": "command", "command": "echo mine" }, "timeout": 5 }
  ],
  "prompt": "be careful"
}
'@ | Set-Content -LiteralPath $custom -Encoding UTF8
$entries = @(New-KiroHookEntries $pluginDir 'kiro_cli' $KiroAgentTriggers)
Assert-Eq (Merge-KiroAgentHooks $custom $entries) 'merged' 'custom agent merges'
$c = Read-Json $custom
Assert-Eq $c.model 'claude-sonnet-4' 'custom agent keeps its model'
Assert-Eq (@($c.tools) -join ',') 'fs_read,execute_bash' 'custom agent keeps its tools'
Assert-Eq $c.prompt 'be careful' 'custom agent keeps its prompt'
Assert-Eq (@($c.hooks).Count) 6 'custom agent has its own hook plus the five'
Assert-Eq $c.hooks[0].name 'mine' "custom agent's own hook stays first"
Assert-Eq $c.hooks[0].matcher 'execute_bash' "custom agent's own hook is untouched"
Assert-Eq ((Get-RogueHooks $c | ForEach-Object { $_.trigger }) -join ' ') 'agentSpawn userPromptSubmit preToolUse postToolUse stop' 'agent hooks use the 2.x trigger names'
Assert-Eq (@(Get-RogueHooks $c | Where-Object { $_.timeout -ne 10 }).Count) 0 'agent hooks have timeout 10'
Assert-Eq (@(Get-RogueHooks $c | Where-Object { $null -ne $_.PSObject.Properties['matcher'] }).Count) 0 'agent hooks carry no matcher'
Assert-Eq (@(Get-RogueHooks $c | Where-Object { $_.trigger -eq 'preToolUse' })[0].action.command) `
    "powershell -NoProfile -ExecutionPolicy Bypass -File `"$bridge`" preToolUse kiro_cli" 'agent hooks run the bridge with the kiro_cli surface'

Assert-Eq (Merge-KiroAgentHooks $custom $entries) 'merged' 're-merge succeeds'
$c = Read-Json $custom
Assert-Eq (@($c.hooks).Count) 6 're-merge does not stack the Rogue entries'
Assert-Eq $c.hooks[0].name 'mine' "re-merge keeps the user's hook"

$bare = Join-Path $agentsDir 'bare.json'
'{"name":"bare","tools":[]}' | Set-Content -LiteralPath $bare -Encoding UTF8
Assert-Eq (Merge-KiroAgentHooks $bare $entries) 'merged' 'an agent without a hooks block merges'
$b = Read-Json $bare
Assert-Eq (@($b.hooks).Count) 5 'an agent without a hooks block gets the five'
Assert-Eq $b.name 'bare' 'an agent without a hooks block keeps its name'

$broken = Join-Path $agentsDir 'broken.json'
[System.IO.File]::WriteAllText($broken, '{"name": "broken", "tools": [')
Assert-Eq (Merge-KiroAgentHooks $broken $entries) 'unparseable' 'an unparseable config is reported'
Assert-Eq ([System.IO.File]::ReadAllText($broken)) '{"name": "broken", "tools": [' 'an unparseable config is left byte for byte'

$mapForm = Join-Path $agentsDir 'mapform.json'
'{"name":"m","hooks":{"preToolUse":[{"command":"echo"}]}}' | Set-Content -LiteralPath $mapForm -Encoding UTF8
Assert-Eq (Merge-KiroAgentHooks $mapForm $entries) 'not-array' 'a hooks block in another form is reported, not rewritten'
Assert-Eq ((Read-Json $mapForm).hooks.preToolUse[0].command) 'echo' 'a hooks block in another form is left alone'

$dirOut = (Merge-KiroAgentDirs @($agentsDir) $entries 6>&1 | Out-String)
Assert-Eq ($dirOut -match 'broken\.json') $true 'the directory merge warns with the unparseable file name'
Assert-Eq ($dirOut -match 'mapform\.json') $true 'the directory merge warns with the map-form file name'

# -- the rogue agent: created through kiro-cli, default only when none was set --
Remove-Item -LiteralPath $env:KIRO_CLI_LOG -ErrorAction SilentlyContinue
Assert-Eq (Install-KiroRogueAgent) $true 'rogue agent is created'
$rogueCfg = Join-Path $agentsDir 'rogue.json'
Assert-Eq (Test-Path -LiteralPath $rogueCfg) $true 'rogue.json exists in the global agent dir'
Assert-Eq ((Read-Json $rogueCfg).description) 'created by kiro-cli' "rogue agent keeps Kiro's defaults"
Assert-Eq ((Get-Content -LiteralPath $env:KIRO_CLI_LOG) -join '|') 'agent create --name rogue' 'created via kiro-cli agent create --name rogue'
Assert-Eq (Install-KiroRogueAgent) $true 'a second call is a no-op'
Assert-Eq (@(Get-Content -LiteralPath $env:KIRO_CLI_LOG).Count) 1 'a second call does not re-create the agent'

Remove-Item -LiteralPath $env:KIRO_CLI_LOG -ErrorAction SilentlyContinue
$out = (Set-KiroDefaultAgent 6>&1 | Out-String)
Assert-Eq ((Get-Content -LiteralPath $env:KIRO_CLI_LOG) -join '|') 'settings chat.defaultAgent|agent set-default rogue' 'no default set: detected, then rogue set as default'
Assert-Eq ([System.IO.File]::ReadAllText((Join-Path $state 'default'))) 'rogue' 'the default is recorded'
Assert-Eq ($out -match 'set to rogue') $true 'setting the default is reported'

Remove-Item -LiteralPath $env:KIRO_CLI_LOG -ErrorAction SilentlyContinue
[System.IO.File]::WriteAllText((Join-Path $state 'default'), 'my-agent')
$out = (Set-KiroDefaultAgent 6>&1 | Out-String)
Assert-Eq ((Get-Content -LiteralPath $env:KIRO_CLI_LOG) -join '|') 'settings chat.defaultAgent' 'a set default: detected and left alone'
Assert-Eq ([System.IO.File]::ReadAllText((Join-Path $state 'default'))) 'my-agent' 'the existing default survives'
Assert-Eq ($out -match 'my-agent') $true 'the existing default is printed'

# -- Install-KiroHooks: the whole wiring, then again ----------------------------
Remove-Item -LiteralPath $env:KIRO_CLI_LOG -ErrorAction SilentlyContinue
$ws = Join-Path $work 'ws'
$wsAgents = [System.IO.Path]::Combine($ws, '.kiro', 'agents')
New-Item -ItemType Directory -Path $wsAgents -Force | Out-Null
'{"name":"ws"}' | Set-Content -LiteralPath (Join-Path $wsAgents 'ws.json') -Encoding UTF8
$null = (Install-KiroHooks -PluginDir $pluginDir -WorkspaceDir $ws 6>&1 | Out-String)
Assert-Eq (@((Read-Json (Join-Path $wsAgents 'ws.json')).hooks).Count) 5 'workspace agent (.kiro/agents) is merged'
Assert-Eq (@(Get-RogueHooks (Read-Json $rogueCfg)).Count) 5 'rogue agent carries the hooks'
Assert-Eq (@((Read-Json $custom).hooks).Count) 6 'full wiring does not stack on the custom agent'
$null = (Install-KiroHooks -PluginDir $pluginDir -WorkspaceDir $ws 6>&1 | Out-String)
Assert-Eq (@((Read-Json $custom).hooks).Count) 6 'a second full run still does not stack'
Assert-Eq (@(Get-ChildItem -LiteralPath $hooksDir -Filter 'rogue*.json').Count) 1 'a second full run leaves one hook file'
Assert-Eq (@(Get-Content -LiteralPath $env:KIRO_CLI_LOG | Where-Object { $_ -like 'agent create*' }).Count) 0 'a second full run never re-creates the agent'

$env:USERPROFILE = $prevProfile
$env:PATH = $prevPath
Remove-Item -Recurse -Force $work -ErrorAction SilentlyContinue

Write-Host ""
if ($fails -eq 0) { Write-Host "test_install_kiro_ps1: all $count passed"; exit 0 }
Write-Host "test_install_kiro_ps1: $fails of $count failed"
exit 1
