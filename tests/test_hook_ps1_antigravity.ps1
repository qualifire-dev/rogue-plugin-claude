#!/usr/bin/env pwsh
# tests/test_hook_ps1_antigravity.ps1 — structure + unit tests for the Antigravity
# PowerShell dispatcher.
#
# WHY THIS EXISTS. hook.ps1 only ever runs on Windows, and it is developed on
# machines that have none, so until now nothing executed it at all. Two things can
# be checked anywhere PowerShell runs, and both are the failure modes that
# actually bite:
#
#   1. SCOPE. Reading a script variable inside a function is implicit, but
#      ASSIGNING one needs the `$script:` prefix — without it the write lands in a
#      function-local copy and disappears with no error. In a main-and-functions
#      dispatcher that means, for example, an enriched `$payload` that never
#      reaches the POST: no crash, no log, just a silently unenriched event.
#   2. SHAPE. The file is main-and-functions on purpose (see the plugin CLAUDE.md).
#      A stray top-level statement would run before `Invoke-Main`, i.e. before the
#      non-Windows stand-down, which is the one thing that must happen first.
#
# The rest are ordinary unit tests over the pure helpers, reachable off-Windows
# through the ROGUE_PS_LIB_ONLY seam.
#
# Run:  pwsh tests/test_hook_ps1_antigravity.ps1
#
# ON A MAC, MIND THE EMULATOR. There is no native pwsh, and the obvious substitute
# is a container — but `mcr.microsoft.com/powershell` resolves to 32-bit arm/v7
# there, which aborts under QEMU, and the amd64 image dies at random points inside
# .NET (SIGSEGV, NullReferenceException in a call site, stack overflow in the
# formatter) on anything longer than a few statements. Sections were therefore
# verified one at a time:
#
#   docker run --rm --platform linux/amd64 -v "$PWD:/repo" -w /repo \
#     mcr.microsoft.com/powershell pwsh -NoProfile -NonInteractive \
#     -File tests/test_hook_ps1_antigravity.ps1 -Only scope
#
# parse, scope and shape each pass that way, and the helper expectations below
# were confirmed by calling each function directly through the same seam. A
# whole-file run needs real PowerShell (Windows, or Linux CI) — if it fails there,
# suspect this harness before suspecting hook.ps1.
#
# -Only runs a single section (parse | scope | shape | helpers); sections are
# independent, and the AST is parsed on demand so a section that does not need it
# does not pay for it.
param([ValidateSet('all', 'parse', 'scope', 'shape', 'helpers')][string]$Only = 'all')

$ErrorActionPreference = 'Stop'
function Test-Section { param([string]$Name) return ($Only -eq 'all' -or $Only -eq $Name) }
$here = Split-Path -Parent $MyInvocation.MyCommand.Path
$scripts = Join-Path (Split-Path -Parent $here) 'plugins/antigravity/scripts'
$hook = Join-Path $scripts 'hook.ps1'
# heartbeat.ps1 is main-and-functions for the same reasons and carries the same
# scope hazard, so the structural sections check both files.
$structural = @($hook, (Join-Path $scripts 'heartbeat.ps1'))

$failures = 0

# ── 1. it parses ───────────────────────────────────────────────────────────
# Parsed on demand so a section that does not need the AST does not pay for it:
# under emulation the AST walk plus a later dot-source is what tips the runtime
# over, and section independence is the whole point of -Only.
$astCache = @{}
function Get-ScriptAst {
    param([string]$Path)
    if ($script:astCache.ContainsKey($Path)) { return $script:astCache[$Path] }
    $errs = $null; $toks = $null
    $parsed = [System.Management.Automation.Language.Parser]::ParseFile($Path, [ref]$toks, [ref]$errs)
    if ($errs) {
        $errs | ForEach-Object { Write-Host "FAIL [parse]: $(Split-Path $Path -Leaf) line $($_.Extent.StartLineNumber): $($_.Message)" }
        exit 1
    }
    $script:astCache[$Path] = $parsed
    return $parsed
}

if (Test-Section 'parse') {
    foreach ($f in $structural) {
        [void](Get-ScriptAst $f)
        Write-Host "  ok: $(Split-Path $f -Leaf) parses"
    }
}

# ── 2. every write to shared state is $script:-qualified ───────────────────
if (Test-Section 'scope') {
# Shared state is PER FILE. One combined list produced false positives: `baseUrl`
# is shared state in heartbeat.ps1 but a function-LOCAL scratch value inside
# hook.ps1's Resolve-Url (only $script:url escapes it), so a global list demanded
# a `$script:` prefix that would have been actively misleading there.
$sharedByFile = @{
    'hook.ps1' = @(
        'logFile', 'logMaxBytes', 'creds', 'apiKey', 'url', 'actorName', 'actorEmail',
        'payload', 'subagentId', 'subagentName', 'brainDir', 'submapDir', 'payloadTp',
        'isIdeSurface', 'PluginRoot'
    )
    'heartbeat.ps1' = @('pluginRoot', 'baseUrl', 'ver', 'agent', 'creds', 'apiKey')
}
foreach ($file in $structural) {
$shared = $sharedByFile[(Split-Path $file -Leaf)]
$unscoped = @()
# Materialised with @(): FindAll returns a lazy enumerable, and nesting a second
# walk inside the first one's iteration silently yields null elements.
$functions = @((Get-ScriptAst $file).FindAll({ param($n) $n -is [System.Management.Automation.Language.FunctionDefinitionAst] }, $true))
foreach ($fn in $functions) {
    if (-not $fn -or -not $fn.Body) { continue }
    foreach ($a in @($fn.Body.FindAll({ param($n) $n -is [System.Management.Automation.Language.AssignmentStatementAst] }, $true))) {
        if (-not $a) { continue }
        $lhs = $a.Left
        if ($lhs -is [System.Management.Automation.Language.ConvertExpressionAst]) { $lhs = $lhs.Child }
        if ($lhs -isnot [System.Management.Automation.Language.VariableExpressionAst]) { continue }
        $p = $lhs.VariablePath
        if (($shared -contains $p.UserPath) -and -not $p.IsScript) {
            $unscoped += "$($fn.Name) line $($a.Extent.StartLineNumber): `$$($p.UserPath)"
        }
    }
}
if ($unscoped) {
    $unscoped | ForEach-Object { Write-Host "FAIL [scope]: $(Split-Path $file -Leaf) assigns without `$script: - $_" }
    $failures += $unscoped.Count
} else {
    Write-Host "  ok: $(Split-Path $file -Leaf): every shared-state write inside a function is `$script:-qualified"
}
}
}

# ── 3. main-and-functions: nothing runs at file scope but Invoke-Main ───────
# Top-level command calls are what would run before the stand-down.
if (Test-Section 'shape') {
foreach ($file in $structural) {
$entry = if ($file -eq $hook) { 'Invoke-Main' } else { 'Invoke-Main' }
$topLevelCalls = @()
foreach ($st in @((Get-ScriptAst $file).EndBlock.Statements)) {
    if ($st -is [System.Management.Automation.Language.FunctionDefinitionAst]) { continue }
    foreach ($c in @($st.FindAll({ param($n) $n -is [System.Management.Automation.Language.CommandAst] }, $false))) {
        if (-not $c) { continue }
        $name = $c.GetCommandName()
        if ($name) { $topLevelCalls += $name }
    }
}
$stray = @($topLevelCalls | Where-Object { $_ -ne $entry })
if ($stray.Count -eq 0) { Write-Host "  ok: $(Split-Path $file -Leaf): nothing is invoked at file scope except $entry" }
else { Write-Host "FAIL [file scope]: $(Split-Path $file -Leaf) runs these before the stand-down: $($stray -join ', ')"; $failures++ }
if ($topLevelCalls -contains $entry) { Write-Host "  ok: $(Split-Path $file -Leaf): $entry is actually called" }
else { Write-Host "FAIL [file scope]: $(Split-Path $file -Leaf) never calls $entry"; $failures++ }
}
}

# ── 4. unit tests over the helpers (loaded without running the hook) ───────
if (Test-Section 'helpers') {
$env:ROGUE_PS_LIB_ONLY = '1'
. $hook
$env:ROGUE_PS_LIB_ONLY = $null
# hook.ps1 sets SilentlyContinue in OUR scope (dot-sourcing shares it), which
# would swallow a failing assertion below. Put it back.
$ErrorActionPreference = 'Stop'

# Cases are compared inline rather than through Assert-Eq: calling a
# test-defined function after dot-sourcing the hook crashes the emulated amd64
# PowerShell people use on macOS (NullReferenceException inside a .NET call
# site), and the point of this section is the hook's behaviour, not the harness.
$payload = '{"conversationId":"../../etc/passwd"}'
$env:ROGUE_ANTIGRAVITY_DBPROMPT_DIR = '/tmp/rogue-test-markers'
$EventName = 'PreToolUse'; $preToolUseDefault = Get-FailOpenDefault
$EventName = 'Stop';       $otherDefault      = Get-FailOpenDefault
$marker = Get-MissMarker 'prompt'
$env:ROGUE_ANTIGRAVITY_DBPROMPT_DIR = $null

$cases = @(
    # PreToolUse must resolve to an explicit decision; a bare {} reads as
    # ambiguous there and loses the deny. Everything else fails open to {}.
    @{ what = 'PreToolUse fails open to an explicit allow'
       actual = $preToolUseDefault; expected = '{"decision":"allow"}' }
    @{ what = 'every other event fails open to {}'
       actual = $otherDefault; expected = '{}' }
    # Strips exactly ONE trailing brace: TrimEnd('}') eats both here and hands the
    # backend an unbalanced object, which drops the whole event.
    @{ what = 'Add-JsonFields strips one brace, not all of them'
       actual = (Add-JsonFields '{"toolArgs":{"command":"x"}}' ',"a":1')
       expected = '{"toolArgs":{"command":"x"},"a":1}' }
    # Surface comes from the state dir, ordered specific → general because the
    # bare segment is a prefix of the other two.
    @{ what = 'CLI surface'
       actual = (Get-AntigravitySurface '/h/.gemini/antigravity-cli/brain/c/x.jsonl')
       expected = 'antigravity_cli' }
    @{ what = 'IDE surface'
       actual = (Get-AntigravitySurface '/h/.gemini/antigravity-ide/brain/c/x.jsonl')
       expected = 'antigravity_ide' }
    @{ what = '2.0 app surface'
       actual = (Get-AntigravitySurface '/h/.gemini/antigravity/brain/c/x.jsonl')
       expected = 'antigravity' }
    @{ what = 'an unattributable path yields empty'
       actual = (Get-AntigravitySurface '/h/somewhere/else.jsonl'); expected = '' }
    # On Windows the payload holds `C:\\Users\\…`, so everything downstream keys
    # off the folded form or no Windows IDE session ever matches
    # '/antigravity-ide/' and that surface silently loses store recovery.
    @{ what = 'a Windows transcriptPath folds to forward slashes'
       actual = (Get-PayloadTranscriptPath '{"transcriptPath":"C:\\Users\\y\\.gemini\\antigravity-ide\\brain\\c\\t.jsonl"}')
       expected = 'C:/Users/y/.gemini/antigravity-ide/brain/c/t.jsonl' }
    # The conversation id becomes a path component, so anything but an id
    # character is dropped rather than trusted.
    @{ what = 'a traversal-shaped conversationId cannot escape the marker dir'
       actual = $marker; expected = '/tmp/rogue-test-markers/etcpasswd.missed-prompt' }
)
foreach ($c in $cases) {
    if ($c.actual -eq $c.expected) { Write-Host "  ok: $($c.what)" }
    else { Write-Host "FAIL [$($c.what)]: expected <$($c.expected)> but got <$($c.actual)>"; $failures++ }
}
}

if ($failures -gt 0) { Write-Host "`n$failures failure(s)"; exit 1 }
Write-Host "`nAll antigravity hook.ps1 tests passed."
