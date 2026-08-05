# Rogue Security hook bridge for Google Antigravity — PowerShell implementation.
#
# Cross-platform sibling of hook.sh. hooks.json fires the `sh` command on
# macOS/Linux/WSL and this `powershell` command on native Windows (PS 5.1+,
# so this stays 5.1-compatible). PURE RELAY: reads one Antigravity hook event
# JSON on stdin, POSTs it to /api/v1/hooks/antigravity, relays the native
# Antigravity decision shape verbatim on stdout. No block-detection regex, no
# local modal — Antigravity renders the native deny shape.
#
# FAIL-OPEN IS SAFETY-CRITICAL. PreToolUse must always resolve to an explicit
# decision — never a bare `{}` — so Get-FailOpenDefault emits
# {"decision":"allow"} for PreToolUse and {} for every other event. This
# script MUST always exit 0. A block is carried in the relayed JSON body on
# stdout, never via the exit code.
#
# Exactly-one-runs (Windows): unlike Copilot (which selects one command per
# platform), both the sh entry and the PowerShell entry are registered for
# every event in hooks.json. On non-Windows pwsh this script stands down by
# emitting NOTHING (not even `{}`) and exiting 0, so it never contributes a
# decision when the sh handler also runs on the same invocation (mirrors
# hook.sh's Git Bash stand-down).
#
# Loaded via [scriptblock]::Create((Get-Content ...)) rather than -File, so it
# runs regardless of ExecutionPolicy/GPO. Because it is a scriptblock (not a
# file), $PSCommandPath is empty — hooks.json passes the plugin root
# ((Get-Location).Path) as the 2nd argument instead.
#
# Credential resolution (later file wins; process env wins over all):
#   1. <PluginRoot>\env            (baked into a compiled customer plugin)
#   2. C:\ProgramData\rogue\env    (MDM-provisioned; mirrors /etc/rogue/env)
#   3. %USERPROFILE%\.rogue-env    (user / installer-written)

param([string]$EventName = '', [string]$PluginRoot = '')

$ErrorActionPreference = 'SilentlyContinue'
$ProgressPreference = 'SilentlyContinue'

function Write-Raw {
    param([string]$Text)
    $bytes = [System.Text.Encoding]::UTF8.GetBytes($Text)
    $stdout = [Console]::OpenStandardOutput()
    $stdout.Write($bytes, 0, $bytes.Length)
    $stdout.Flush()
}
function Dbg { param([string]$Msg) if ($env:ROGUE_DEBUG) { [Console]::Error.WriteLine("[rogue] $Msg") } }

# Per-event fail-open default. PreToolUse must resolve to an explicit
# decision (never a bare {}), or Antigravity would treat it as ambiguous;
# every other event is audit/monitor-only and fails open to a clean {}.
# Mirrors hook.sh's fail_open_default.
function Get-FailOpenDefault {
    if ($EventName -eq 'PreToolUse') { return '{"decision":"allow"}' }
    return '{}'
}

function ConvertFrom-ShellQuoted {
    # Decode one shell "word" the way hook.sh would when it sources the env file,
    # so values round-trip across both bridges (POSIX single-quoted or bash %q).
    param([string]$Val)
    if ($null -eq $Val) { return $Val }
    $sb = [System.Text.StringBuilder]::new()
    $i = 0; $n = $Val.Length; $state = 'normal'
    while ($i -lt $n) {
        $c = $Val[$i]
        switch ($state) {
            'single' { if ($c -eq "'") { $state = 'normal' } else { [void]$sb.Append($c) } }
            'double' {
                if ($c -eq '"') { $state = 'normal' }
                elseif ($c -eq '\' -and ($i + 1) -lt $n -and ('"\$`'.IndexOf($Val[$i+1]) -ge 0)) { [void]$sb.Append($Val[$i+1]); $i++ }
                else { [void]$sb.Append($c) }
            }
            default {
                if ($c -eq "'") { $state = 'single' }
                elseif ($c -eq '"') { $state = 'double' }
                elseif ($c -eq '\' -and ($i + 1) -lt $n) { [void]$sb.Append($Val[$i+1]); $i++ }
                else { [void]$sb.Append($c) }
            }
        }
        $i++
    }
    return $sb.ToString()
}

# Windows PowerShell 5.1 may negotiate only TLS 1.0/1.1 by default; add TLS 1.2.
try {
    [Net.ServicePointManager]::SecurityProtocol = `
        [Net.ServicePointManager]::SecurityProtocol -bor [Net.SecurityProtocolType]::Tls12
} catch {}

# Stand down on non-Windows (Antigravity runs hook.sh there for real work; this
# guards a stray pwsh). Emit NOTHING (not `{}`) so this entry never
# contributes a decision alongside the sh entry — see the exactly-one-runs
# note above.
if ($PSVersionTable.PSVersion.Major -ge 6 -and -not $IsWindows) { exit 0 }

if (-not $EventName) { Write-Raw (Get-FailOpenDefault); exit 0 }
Dbg "event=$EventName"

# Self-locate the plugin root from the 2nd argument (hooks.json passes
# (Get-Location).Path). $PSCommandPath is empty under
# [scriptblock]::Create, so there is no file-path fallback here — fall
# straight back to the current working directory.
if (-not $PluginRoot) { try { $PluginRoot = (Get-Location).Path } catch { $PluginRoot = '.' } }

$logFile = $env:ROGUE_LOG_FILE
if (-not $logFile) { $logFile = Join-Path (Join-Path $env:USERPROFILE '.rogue') 'hook.log' }
function Sanitize { param([string]$S) if ($null -eq $S) { return '' } ($S -replace '[\x00-\x1f\x7f]', '') }
function Log {
    param([string]$Msg)
    try {
        $dir = Split-Path $logFile
        if ($dir -and -not (Test-Path -LiteralPath $dir)) { New-Item -ItemType Directory -Path $dir -Force | Out-Null }
        $stamp = (Get-Date).ToUniversalTime().ToString('yyyy-MM-ddTHH:mm:ssZ')
        Add-Content -LiteralPath $logFile -Value "$stamp provider=antigravity event=$EventName $Msg" -Encoding UTF8
    } catch {}
}

# ── credential resolution (later file wins; process env wins over all) ─────
$creds = @{}
foreach ($f in @((Join-Path $PluginRoot 'env'), 'C:\ProgramData\rogue\env', (Join-Path $env:USERPROFILE '.rogue-env'))) {
    if (-not $f -or -not (Test-Path -LiteralPath $f)) { continue }
    foreach ($line in (Get-Content -LiteralPath $f)) {
        if ($line -match '^\s*(?:export\s+)?([A-Z_][A-Z0-9_]*)=(.+)$') {
            $creds[$Matches[1]] = ConvertFrom-ShellQuoted ($Matches[2].Trim())
        }
    }
}
foreach ($k in 'ROGUE_API_KEY','ROGUE_ACTOR_EMAIL','ROGUE_ACTOR_NAME','ROGUE_BASE_URL','ROGUE_API_URL') {
    $val = [Environment]::GetEnvironmentVariable($k); if ($val) { $creds[$k] = $val }
}

$apiKey = $creds['ROGUE_API_KEY']

# Not configured: never POST without a key. Emit the per-event fail-open
# default so PreToolUse still resolves to an explicit allow decision.
if (-not $apiKey) {
    Log 'outcome=unconfigured'
    Write-Raw (Get-FailOpenDefault)
    exit 0
}

# URL: explicit ROGUE_API_URL wins, else base + path.
$url = $creds['ROGUE_API_URL']
if (-not $url) {
    $baseUrl = $creds['ROGUE_BASE_URL']; if (-not $baseUrl) { $baseUrl = 'https://api.rogue.security' }
    $url = "$($baseUrl.TrimEnd('/'))/api/v1/hooks/antigravity"
}

# ── actor resolution (mirrors actor.sh) ────────────────────────────────────
$actorName = $creds['ROGUE_ACTOR_NAME']
if (-not $actorName) { try { $actorName = (& git config --global user.name 2>$null | Out-String).Trim() } catch {} }
if (-not $actorName) { $actorName = $env:USERNAME }

$actorEmail = $creds['ROGUE_ACTOR_EMAIL']
if (-not $actorEmail) { try { $actorEmail = (& git config --global user.email 2>$null | Out-String).Trim() } catch {} }
if (-not $actorEmail) {
    if ($env:USERNAME -and $env:COMPUTERNAME) { $actorEmail = "$($env:USERNAME)@$($env:COMPUTERNAME)" }
    elseif ($env:USERNAME) { $actorEmail = $env:USERNAME } else { $actorEmail = $env:COMPUTERNAME }
}

# ── payload from stdin (recover UTF-8, strip BOM) ──────────────────────────
$payload = [Console]::In.ReadToEnd()
if (-not $payload) { $payload = '{}' }
try {
    $raw = [Console]::InputEncoding.GetBytes($payload)
    $payload = [System.Text.Encoding]::UTF8.GetString($raw)
} catch {}
$payload = $payload.TrimStart([char]0xFEFF)

# Which Antigravity product fired this event, from the state dir its transcript
# lives in. Slash-anchored and ordered specific → general because the bare
# segment is a prefix of the other two: the `-ide` dir is the Antigravity IDE and
# the bare one is Antigravity 2.0 (both current products). Mirrors
# hook.sh's surface_from_transcript and the backend's surfaceFromTranscript.
# Unattributable → empty, so the caller keeps its own fallback.
function Get-AntigravitySurface {
    param([string]$TranscriptPath)
    $p = ($TranscriptPath -replace '\\', '/')
    if ($p -like '*/antigravity-cli/*') { return 'antigravity_cli' }
    if ($p -like '*/antigravity-ide/*') { return 'antigravity_ide' }
    if ($p -like '*/antigravity/*')     { return 'antigravity' }
    return ''
}

# Heartbeat on the first invocation of a session (invocationNum == 0). Fire
# detached (Start-Process -WindowStyle Hidden) so the hook itself returns
# immediately regardless of heartbeat.ps1's own latency — mirrors hook.sh's
# `( nohup sh heartbeat.sh & )`.
if ($EventName -eq 'PreInvocation' -and ($payload -like '*"invocationNum":0*' -or $payload -like '*"invocationNum": 0*')) {
    try {
        $hbPath = Join-Path $PluginRoot 'scripts/heartbeat.ps1'
        # Pass the surface along: only the hook can know it (three products share
        # one install, and the event's transcriptPath names which state dir it
        # lives in). Mirrors hook.sh's `heartbeat.sh "$_hb_agent"`.
        $hbArgs = @('-NoProfile','-ExecutionPolicy','Bypass','-File',$hbPath)
        $hbTp = [regex]::Match($payload, '"transcriptPath"\s*:\s*"([^"]*)"').Groups[1].Value
        $hbAgent = Get-AntigravitySurface $hbTp
        if ($hbAgent) { $hbArgs += @('-Agent', $hbAgent) }
        Start-Process -FilePath 'powershell' `
            -ArgumentList $hbArgs `
            -WindowStyle Hidden -ErrorAction Stop
    } catch { Dbg "heartbeat launch failed: $($_.Exception.Message)" }
}

# PreInvocation/PostInvocation/Stop carry no message content inline — only a
# transcriptPath pointing at the session's transcript.jsonl. Append the last
# ~256KB of that file, base64-encoded, as "transcriptTailB64" so the backend
# can extract recent turn content. base64 has no JSON-special chars, so
# re-closing the object is safe. Fail-open: any problem returns the payload
# unchanged.
#
# Antigravity's transcript.jsonl line schema is undocumented — there is no
# known "turn end" marker line to poll for (unlike Copilot's events.jsonl), so
# this wait is schema-agnostic: it polls file SIZE stability instead of a
# marker line, and is hard time-bounded (~2s). On timeout it fails open and
# tails whatever is on disk rather than hanging or guessing at an undocumented
# marker format. Mirrors hook.sh's wait_for_transcript_flush.
function Wait-TranscriptFlush {
    param([string]$Path)
    # ~2s cap (20 * 100ms), well inside the 30s hook budget.
    # ROGUE_FLUSH_WAIT_ITERS overrides the iteration count (tests set it low
    # to exercise the fail-open path).
    $max = 20
    if ($env:ROGUE_FLUSH_WAIT_ITERS) { try { $max = [int]$env:ROGUE_FLUSH_WAIT_ITERS } catch {} }
    $prevSize = -1
    for ($i = 0; $i -lt $max; $i++) {
        try { $size = (Get-Item -LiteralPath $Path).Length } catch { return }
        if ($i -gt 0 -and $size -eq $prevSize) { return }
        $prevSize = $size
        Start-Sleep -Milliseconds 100
    }
}

# The surfaces disagree on which file transcriptPath names: the IDE points at
# `transcript.jsonl`, the 2.0 app and the `agy` CLI at `transcript_full.jsonl`.
# Both are written to the same logs dir with the same row schema, so the sibling
# is a valid substitute when the named file can't be read. Mirrors hook.sh's
# transcript_sibling.
function Get-TranscriptSibling {
    param([string]$Path)
    if ($Path -like '*transcript_full.jsonl') {
        return ($Path.Substring(0, $Path.Length - 'transcript_full.jsonl'.Length) + 'transcript.jsonl')
    }
    if ($Path -like '*transcript.jsonl') {
        return ($Path.Substring(0, $Path.Length - 'transcript.jsonl'.Length) + 'transcript_full.jsonl')
    }
    return ''
}

# Return a readable transcript path (the named one, else its sibling), waiting
# briefly for one to appear: a brand-new conversation creates its transcript
# ~1s AFTER the first PreInvocation fires, so giving up immediately drops the
# FIRST prompt of every session. Mirrors hook.sh's resolve_transcript_path.
function Resolve-TranscriptPath {
    param([string]$Path)
    $alt = Get-TranscriptSibling $Path
    $max = 20
    if ($env:ROGUE_TRANSCRIPT_WAIT_ITERS) { try { $max = [int]$env:ROGUE_TRANSCRIPT_WAIT_ITERS } catch {} }
    for ($i = 0; ; $i++) {
        if (Test-Path -LiteralPath $Path) { return $Path }
        if ($alt -and (Test-Path -LiteralPath $alt)) { return $alt }
        if ($i -ge $max) { return '' }
        Start-Sleep -Milliseconds 100
    }
}


# ── Subagent re-attribution (mirrors hook.sh's reattribute_subagent) ───────
# An Antigravity subagent runs as its own conversation and its events carry no
# parent reference, so persisted verbatim they orphan into a separate audit
# session. The link is in the PARENT transcript's INVOKE_SUBAGENT row (which
# lists the spawned conversationIds); the parent id IS that transcript's
# directory name. That row is written before the subagent's first hook can fire,
# so no flush retry is needed. Subagent ids are ordinary UUIDs — indistinguish-
# able from a main conversation — so the verdict is cached per conversation BOTH
# ways ('main' for ordinary ones) to keep it at one scan per conversation.
# Fail-open: unresolved → payload untouched.
$subagentId = ''
$subagentName = ''
# Prefer the brain dir holding THIS event's transcript — which is also where its
# parent conversation lives, since a subagent runs on the surface that spawned
# it. Each product has its own brain dir, so the CLI-only default below left
# subagents in the IDE / 2.0 app unresolved, orphaning them into their own
# session. transcriptPath is `<brain>/<conversationId>/.system_generated/logs/…`.
# Mirrors hook.sh's brain_dir_from_transcript. An explicit override still wins.
$brainDir = $env:ROGUE_ANTIGRAVITY_BRAIN_DIR
if (-not $brainDir) {
    $tpForBrain = ([regex]::Match($payload, '"transcriptPath"\s*:\s*"([^"]*)"').Groups[1].Value `
        -replace '\\\\', '\' -replace '\\/', '/' -replace '\\', '/')
    $m2 = [regex]::Match($tpForBrain, '^(?<root>.*)/brain/[^/]+/\.system_generated/logs/')
    if ($m2.Success) { $brainDir = Join-Path $m2.Groups['root'].Value 'brain' }
}
if (-not $brainDir) { $brainDir = Join-Path $env:USERPROFILE '.gemini\antigravity-cli\brain' }
$submapDir = $env:ROGUE_ANTIGRAVITY_SUBMAP_DIR
if (-not $submapDir) { $submapDir = Join-Path (Join-Path $env:USERPROFILE '.rogue') 'antigravity-submap' }

function Get-SubagentDisplayName {
    # Primary: the spawning call. invoke_subagent's args carry a `Role` per
    # subagent and the INVOKE_SUBAGENT result row lists the conversationIds in
    # the SAME order, so the name is the Nth Role for the id at position N. This
    # is the only source available for a subagent's EARLY events.
    # Fallback: messages/<uuid>.json {"sender": <child>, "renderDetails":
    # {"messageTitle": "Message from <Role> (<TypeName>)"}} — richer, but only
    # written once the subagent has reported back.
    # Mirrors hook.sh's subagent_role_name / subagent_message_name.
    param([string]$ParentId, [string]$SubId)
    try {
        $pd = Join-Path $brainDir $ParentId
        $tf = Join-Path (Join-Path (Join-Path $pd '.system_generated') 'logs') 'transcript_full.jsonl'
        if (Test-Path -LiteralPath $tf) {
            $ids = @()
            $roles = @()
            foreach ($line in (Get-Content -LiteralPath $tf -ErrorAction SilentlyContinue)) {
                if ($line -like '*"INVOKE_SUBAGENT"*') {
                    # The ids sit inside the row's JSON-STRING content, so their
                    # quotes are backslash-escaped — match the bare UUID.
                    foreach ($mm in [regex]::Matches($line, 'conversationId[^0-9a-f]*([0-9a-f-]{36})')) {
                        $ids += $mm.Groups[1].Value
                    }
                }
                if ($line -like '*"invoke_subagent"*') {
                    foreach ($rm in [regex]::Matches($line, '"Role"\s*:\s*"([^"]*)"')) {
                        $roles += $rm.Groups[1].Value
                    }
                }
            }
            $idx = [Array]::IndexOf($ids, $SubId)
            if ($idx -ge 0 -and $idx -lt $roles.Count) { return $roles[$idx] }
        }
        $md = Join-Path (Join-Path $pd '.system_generated') 'messages'
        if (-not (Test-Path -LiteralPath $md)) { return '' }
        foreach ($mf in Get-ChildItem -LiteralPath $md -Filter '*.json' -File -ErrorAction SilentlyContinue) {
            $txt = Get-Content -Raw -LiteralPath $mf.FullName -ErrorAction SilentlyContinue
            if (-not $txt -or $txt -notmatch [regex]::Escape($SubId)) { continue }
            $t = [regex]::Match($txt, '"messageTitle"\s*:\s*"([^"]*)"')
            if ($t.Success) { return ($t.Groups[1].Value -replace '^Message from ', '') }
        }
    } catch {}
    return ''
}

function Resolve-SubagentParent {
    # Returns the parent conversation id, or '' when $SubId was not spawned as a
    # subagent. The INVOKE_SUBAGENT filter is required: a conversation id also
    # appears inside other conversations' CONVERSATION_HISTORY summaries, which
    # must NOT be read as a parent link.
    param([string]$SubId)
    try {
        if (-not (Test-Path -LiteralPath $brainDir)) { return '' }
        foreach ($d in Get-ChildItem -LiteralPath $brainDir -Directory -ErrorAction SilentlyContinue) {
            if ($d.Name -eq $SubId) { continue }
            $tf = Join-Path (Join-Path (Join-Path $d.FullName '.system_generated') 'logs') 'transcript_full.jsonl'
            if (-not (Test-Path -LiteralPath $tf)) { continue }
            $hit = Select-String -LiteralPath $tf -SimpleMatch -Pattern '"INVOKE_SUBAGENT"' -ErrorAction SilentlyContinue |
                Where-Object { $_.Line -match [regex]::Escape($SubId) } | Select-Object -First 1
            if ($hit) { return $d.Name }
        }
    } catch {}
    return ''
}

try {
    $cm = [regex]::Match($payload, '"conversationId"\s*:\s*"([^"]*)"')
    if ($cm.Success -and $cm.Groups[1].Value) {
        $cid = $cm.Groups[1].Value
        $cacheFile = Join-Path $submapDir $cid
        $map = $null
        if (Test-Path -LiteralPath $cacheFile) {
            $map = @(Get-Content -LiteralPath $cacheFile -ErrorAction SilentlyContinue)
        } else {
            $parent = Resolve-SubagentParent $cid
            if ($parent) { $map = @($parent, (Get-SubagentDisplayName $parent $cid)) } else { $map = @('main') }
            try {
                if (-not (Test-Path -LiteralPath $submapDir)) { New-Item -ItemType Directory -Path $submapDir -Force | Out-Null }
                Set-Content -LiteralPath $cacheFile -Value $map -Encoding UTF8
            } catch {}
        }
        if ($map -and $map.Count -ge 1 -and $map[0] -and $map[0] -ne 'main') {
            $subagentId = $cid
            if ($map.Count -ge 2) { $subagentName = [string]$map[1] }
            # Normalize to compact form, tolerating whitespace around the colon.
            $payload = [regex]::Replace(
                $payload,
                '"conversationId"\s*:\s*"' + [regex]::Escape($cid) + '"',
                '"conversationId":"' + $map[0] + '"')
            Log "subagent=$cid parent=$($map[0]) name=$(Sanitize $subagentName)"
        }
    }
} catch { Dbg "subagent re-attribution failed: $($_.Exception.Message)" }

# ── IDE prompt recovery (mirrors hook.sh's augment_with_db_prompt) ──────────
# The IDE writes transcript.jsonl only at invocation boundaries and Stop, so the
# pending prompt is not on disk at PreInvocation; it IS in Antigravity's own
# conversation store. db-prompt.mjs reads it there with node:sqlite, using the
# runtime the IDE itself ships (Electron run as Node) — nothing is installed.
#
# UNVERIFIED ON WINDOWS: the macOS path is measured end to end, but no Windows
# install was available. Every failure here is a no-op, so the worst case is the
# behaviour that shipped before this file gained the feature.
function Get-JsRuntime {
    param([string]$StateDir)
    if ($env:ROGUE_ANTIGRAVITY_NODE) { return $env:ROGUE_ANTIGRAVITY_NODE }
    $cache = Join-Path (Join-Path $env:USERPROFILE '.rogue') 'antigravity-runtime'
    if (Test-Path -LiteralPath $cache) {
        $line = (Get-Content -LiteralPath $cache -TotalCount 1) -split "`t"
        if ($line[0] -eq 'none') { return '' }
        if ($line.Count -gt 1 -and (Test-Path -LiteralPath $line[1])) { return $line[1] }
    }
    $candidates = @()
    # Discover the IDE from state the IDE itself writes, not a hardcoded path:
    # <stateDir>\bin\agentapi execs the language server inside the install root.
    $shim = Join-Path (Join-Path $StateDir 'bin') 'agentapi'
    foreach ($p in @($shim, "$shim.cmd", "$shim.bat")) {
        if (-not (Test-Path -LiteralPath $p)) { continue }
        $raw = Get-Content -Raw -LiteralPath $p
        $lm = [regex]::Match($raw, '"?([A-Za-z]:\\[^"]*?)\\resources\\app\\')
        if ($lm.Success) { $candidates += (Join-Path $lm.Groups[1].Value 'Antigravity IDE.exe') }
        break
    }
    $candidates += (Get-Command node -ErrorAction SilentlyContinue | Select-Object -First 1 -ExpandProperty Source)
    foreach ($c in $candidates) {
        if (-not $c -or -not (Test-Path -LiteralPath $c)) { continue }
        try {
            $env:ELECTRON_RUN_AS_NODE = '1'
            $out = & $c --no-warnings --experimental-sqlite -e 'require("node:sqlite").DatabaseSync;process.stdout.write("OK")' 2>$null
            if ("$out".Trim() -eq 'OK') {
                New-Item -ItemType Directory -Path (Split-Path $cache) -Force | Out-Null
                Set-Content -LiteralPath $cache -Value "runtime`t$c" -Encoding UTF8
                return $c
            }
        } catch {}
    }
    try {
        New-Item -ItemType Directory -Path (Split-Path $cache) -Force | Out-Null
        Set-Content -LiteralPath $cache -Value "none`t" -Encoding UTF8
    } catch {}
    return ''
}

# Read from the store and attach the result (mirrors hook.sh's augment_from_store).
# `prompt` at PreInvocation is the pending prompt; `steps` at PostInvocation is what
# the finished invocation produced — its tool results are what the NEXT model call
# would read, and PostInvocation is the only event that owns terminationBehavior.
# Per-conversation record of what the store failed to DELIVER this turn, consumed
# at Stop (mirrors hook.sh's miss_marker / mark_store_miss). rogueDbPromptCapable
# describes the machine, and the backend reads it on Stop as "the turn already
# arrived" — so a read that could not reach the content (reader exit 3, or a kill,
# or output we refuse to trust) has to be recorded, or the turn is lost outright
# with the transcript tail sitting right there.
function Get-MissMarker {
    param([string]$Kind)
    $dir = if ($env:ROGUE_ANTIGRAVITY_DBPROMPT_DIR) { $env:ROGUE_ANTIGRAVITY_DBPROMPT_DIR }
           else { Join-Path (Join-Path $env:USERPROFILE '.rogue') 'antigravity-dbprompt' }
    $cid = [regex]::Match($payload, '"conversationId"\s*:\s*"([^"]*)"').Groups[1].Value
    # This becomes a path component, so anything but an id character is dropped.
    $cid = ($cid -replace '[^0-9A-Za-z_-]', '')
    if (-not $cid) { return '' }
    if ($cid.Length -gt 64) { $cid = $cid.Substring(0, 64) }
    return (Join-Path $dir "$cid.missed-$Kind")
}

function Mark-StoreMiss {
    param([string]$Kind)
    try {
        $f = Get-MissMarker $Kind
        if (-not $f) { return }
        New-Item -ItemType Directory -Path (Split-Path $f) -Force | Out-Null
        Set-Content -LiteralPath $f -Value '' -Encoding UTF8
    } catch { Dbg "miss marker failed ($Kind): $($_.Exception.Message)" }
}

function Add-StoreRead {
    param([string]$Mode, [string]$Field)
    if ($payload -notmatch '/antigravity-ide/') { return }
    if ($env:ROGUE_ANTIGRAVITY_DB_PROMPT -eq '0') { return }
    try {
        $tpm = [regex]::Match($payload, '"transcriptPath"\s*:\s*"([^"]*)"')
        $dbTp = $tpm.Groups[1].Value.Replace('\/', '/').Replace('\\', '\')
        $runtime = Get-JsRuntime (($dbTp -split '/brain/')[0])
        if (-not $runtime) { Log "dbstore=none mode=$Mode reason=no-runtime"; return }

        $reader = Join-Path (Join-Path $PluginRoot 'scripts') 'db-prompt.mjs'
        $env:ELECTRON_RUN_AS_NODE = '1'
        $psi = New-Object System.Diagnostics.ProcessStartInfo
        $psi.FileName = $runtime
        foreach ($a in @('--no-warnings', '--experimental-sqlite', $reader, $Mode)) { [void]$psi.ArgumentList.Add($a) }
        $psi.RedirectStandardInput = $true; $psi.RedirectStandardOutput = $true
        $psi.RedirectStandardError = $true; $psi.UseShellExecute = $false
        $proc = [System.Diagnostics.Process]::Start($psi)
        $proc.StandardInput.Write($payload); $proc.StandardInput.Close()
        $b64 = ''
        # The exit status is what separates "read it, nothing new" (0) from "could
        # not read it"; a timeout is the latter.
        $readOk = $false
        if ($proc.WaitForExit(1000)) {
            $b64 = $proc.StandardOutput.ReadToEnd().Trim()
            $readOk = ($proc.ExitCode -eq 0)
        } else { try { $proc.Kill() } catch {} }

        # The reader's whole stdout vocabulary is base64-or-nothing, so anything
        # else is discarded unread and can never become a hook decision.
        if ($b64 -and $b64 -match '^[A-Za-z0-9+/=]+$') {
            if ($env:ROGUE_ANTIGRAVITY_DB_PROMPT -eq 'log') {
                Log "dbstore=hit mode=$Mode len=$($b64.Length) (not attached)"
                # Read but deliberately not attached, so nothing was delivered:
                # recording the miss keeps this mode observational.
                Mark-StoreMiss $Mode
                $script:payload = $payload.TrimEnd().TrimEnd('}') + ',"rogueDbPromptCapable":true}'
            } else {
                Log "dbstore=hit mode=$Mode len=$($b64.Length)"
                $script:payload = $payload.TrimEnd().TrimEnd('}') +
                    ',"' + $Field + '":"' + $b64 + '","rogueDbPromptCapable":true}'
            }
        } elseif ($readOk -and -not $b64) {
            # Nothing new to send: the ordinary case on a turn's later invocations.
            Log "dbstore=miss mode=$Mode reason=nothing-new capable=1"
            $script:payload = $payload.TrimEnd().TrimEnd('}') + ',"rogueDbPromptCapable":true}'
        } else {
            Log "dbstore=fail mode=$Mode capable=1"
            Mark-StoreMiss $Mode
            $script:payload = $payload.TrimEnd().TrimEnd('}') + ',"rogueDbPromptCapable":true}'
        }
    } catch { Dbg "store read failed ($Mode): $($_.Exception.Message)" }
}

if ($EventName -eq 'PreInvocation')  { Add-StoreRead 'prompt' 'rogueDbPromptB64' }
if ($EventName -eq 'PostInvocation') { Add-StoreRead 'steps'  'rogueDbStepsB64' }

# Transcript enrichment is per surface: the 2.0 app and the CLI write the file
# live so all three events can tail it, but on the IDE only Stop can — at
# Pre/PostInvocation the file holds at most the PREVIOUS turn, and waiting for the
# current one cannot work (it appears ~4s later, at Stop). Mirrors hook.sh.
$tailEvents = if ($payload -match '/antigravity-ide/') { @('Stop') }
              else { @('PreInvocation', 'PostInvocation', 'Stop') }
if ($tailEvents -contains $EventName) {
    try {
        $m = [regex]::Match($payload, '"transcriptPath"\s*:\s*"([^"]*)"')
        if ($m.Success) {
            # Undo JSON's optional `\/` escape (and `\\` on Windows paths) — an
            # escaped value fails every file test, silently skipping enrichment.
            $tp = $m.Groups[1].Value.Replace('\/', '/').Replace('\\', '\')
            $tp = Resolve-TranscriptPath $tp
            if (-not $tp) { Log "tail=none reason=unreadable path=$($m.Groups[1].Value)" }
            if ($tp) {
                Wait-TranscriptFlush $tp
                $fs = [System.IO.File]::Open($tp, 'Open', 'Read', 'ReadWrite')
                try {
                    $len = $fs.Length
                    $take = [Math]::Min(262144, $len)
                    if ($take -gt 0) {
                        [void]$fs.Seek($len - $take, 'Begin')
                        $buf = New-Object byte[] $take
                        # Stream.Read may return fewer bytes than requested — loop
                        # until $take bytes are read (or EOF) so no trailing NULs
                        # leak into the base64.
                        $read = 0
                        while ($read -lt $take) {
                            $n = $fs.Read($buf, $read, $take - $read)
                            if ($n -le 0) { break }
                            $read += $n
                        }
                        if ($read -gt 0) {
                            $b64 = [Convert]::ToBase64String($buf, 0, $read)
                            # Strip exactly ONE trailing '}' (mirrors hook.sh's
                            # "${_body%\}}"). String.TrimEnd('}') would strip ALL
                            # trailing braces and corrupt a body ending in "}}".
                            $p = $payload.TrimEnd()
                            if ($p.EndsWith('}')) { $p = $p.Substring(0, $p.Length - 1) }
                            if ($b64) {
                                $payload = $p + ',"transcriptTailB64":"' + $b64 + '"}'
                                Log "tail=$($b64.Length) path=$tp"
                            }
                        }
                    }
                } finally { $fs.Close() }
            }
        }
    } catch { Dbg "transcript augment failed: $($_.Exception.Message)" }
}

# Stop must also declare the capability: it re-reads the whole turn from the
# transcript, and without this the backend cannot know the prompt was already
# recorded at PreInvocation, so every user message lands twice. It also reports
# whichever halves of the turn the store failed to deliver, so the backend rebuilds
# exactly those from the tail. Mirrors hook.sh's mark_db_prompt_capable.
if ($EventName -eq 'Stop' -and $payload -match '/antigravity-ide/' `
    -and $env:ROGUE_ANTIGRAVITY_DB_PROMPT -ne '0') {
    try {
        # Consume the markers whether or not a runtime still resolves, so a stale one
        # cannot leak into a later turn.
        $missed = ''
        foreach ($kind in @('prompt', 'steps')) {
            $f = Get-MissMarker $kind
            if (-not $f -or -not (Test-Path -LiteralPath $f)) { continue }
            Remove-Item -LiteralPath $f -Force -ErrorAction SilentlyContinue
            $field = if ($kind -eq 'prompt') { 'rogueDbPromptMissed' } else { 'rogueDbStepsMissed' }
            $missed += ',"' + $field + '":true'
        }
        $stopTp = [regex]::Match($payload, '"transcriptPath"\s*:\s*"([^"]*)"').Groups[1].Value.Replace('\/', '/').Replace('\\', '\')
        if (Get-JsRuntime (($stopTp -split '/brain/')[0])) {
            if ($missed) { Log "dbstore=stop missed=$($missed.TrimStart(','))" }
            $payload = $payload.TrimEnd().TrimEnd('}') + $missed + ',"rogueDbPromptCapable":true}'
        }
    } catch { Dbg "capability flag failed: $($_.Exception.Message)" }
}

# ── POST (fail-open) → relay verbatim ──────────────────────────────────────
$headers = @{
    'x-rogue-api-key'     = $apiKey
    'x-rogue-event'       = $EventName
    'x-rogue-actor-email' = $actorEmail
    'x-rogue-actor-name'  = $actorName
}
# The agent tag rides in HEADERS, never in the body: the POSTed event must stay
# byte-identical to what Antigravity handed us, so the stored raw payload is the
# vendor's own event and nothing we synthesised. The name is base64 so an arbitrary
# subagent Role (accents, emoji) cannot produce an invalid header value. Both are
# omitted entirely — never sent empty — on main-agent events. Mirrors hook.sh.
if ($subagentId) {
    $headers['x-rogue-agent-id'] = $subagentId
    if ($subagentName) {
        $headers['x-rogue-agent-name-b64'] =
            [Convert]::ToBase64String([System.Text.Encoding]::UTF8.GetBytes($subagentName))
    }
}
$bodyBytes = [System.Text.Encoding]::UTF8.GetBytes($payload)
$resp = ''
try {
    $r = Invoke-WebRequest -Uri $url -Method Post `
        -Headers $headers -ContentType 'application/json' -Body $bodyBytes `
        -UseBasicParsing -TimeoutSec 15 -ErrorAction Stop
    if ($r.StatusCode -eq 200) {
        try { $resp = [System.Text.Encoding]::UTF8.GetString($r.RawContentStream.ToArray()) }
        catch { $resp = [string]$r.Content }
    }
} catch { Dbg "POST failed: $($_.Exception.Message)"; $resp = '' }

$respHead = if ($resp.Length -gt 400) { $resp.Substring(0, 400) } else { $resp }
Log "raw=$(Sanitize $respHead)"

# Fail-open on transport error, any non-200, or an empty body: emit the
# per-event default rather than relaying garbage as a decision.
if (-not $resp) {
    Log 'outcome=allow'
    Write-Raw (Get-FailOpenDefault)
    exit 0
}

# rogue-api already returns the correct native Antigravity shape; relay it
# verbatim.
Write-Raw $resp
exit 0
