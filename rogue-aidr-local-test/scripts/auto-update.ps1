# Silent plugin auto-updater (Windows / PowerShell).
#
# Native-Windows analogue of auto-update.sh. Launched DETACHED from the
# SessionStart hook so it never blocks Claude Code startup. Compares the installed
# plugin version against the latest GitHub release; if newer, re-runs the
# PowerShell one-line installer to upgrade in place. New version takes effect on
# the next session.
#
# Opt-outs:
#   ROGUE_AUTO_UPDATE=0       — disable entirely
#   ROGUE_PLUGIN_VERSION=v1.x — pinned, never updates
#
# Runs at most once per 24h (cached in %USERPROFILE%\.rogue\.auto-update-check).
# Silent on every failure path. All activity logs to
# %USERPROFILE%\.rogue\auto-update.log for diagnostics.

$ErrorActionPreference = 'SilentlyContinue'
$ProgressPreference = 'SilentlyContinue'

# Stand down on non-Windows (auto-update.sh runs on macOS/Linux).
if ($PSVersionTable.PSVersion.Major -ge 6 -and -not $IsWindows) { exit 0 }
if (-not $env:CLAUDE_CODE_ENTRYPOINT) { exit 0 }

$rogueDir = Join-Path $env:USERPROFILE '.rogue'
try { if (-not (Test-Path -LiteralPath $rogueDir)) { New-Item -ItemType Directory -Path $rogueDir -Force | Out-Null } } catch { exit 0 }
$log = Join-Path $rogueDir 'auto-update.log'
function LogLine { param([string]$M) try { Add-Content -LiteralPath $log -Value ((Get-Date).ToString('yyyy-MM-dd HH:mm:ss') + " $M") -Encoding UTF8 } catch {} }
LogLine '--- auto-update tick (windows) ---'

try {
    [Net.ServicePointManager]::SecurityProtocol = `
        [Net.ServicePointManager]::SecurityProtocol -bor [Net.SecurityProtocolType]::Tls12
} catch {}

# Pull creds/flags from the same files the hooks read (values may carry shell
# quoting, but the only flags we read here are simple tokens).
function ReadEnvVar {
    param([string]$Key)
    $v = [Environment]::GetEnvironmentVariable($Key)
    if ($v) { return $v }
    # Same precedence as the dispatcher (later wins): bundled plugin env → MDM →
    # per-user. The bundled ${CLAUDE_PLUGIN_ROOT}\env is where compiled/managed
    # plugins pin flags like ROGUE_AUTO_UPDATE=0 / ROGUE_PLUGIN_VERSION.
    $files = @()
    if ($env:CLAUDE_PLUGIN_ROOT) { $files += (Join-Path $env:CLAUDE_PLUGIN_ROOT 'env') }
    $files += 'C:\ProgramData\rogue\env'
    $files += (Join-Path $env:USERPROFILE '.rogue-env')
    foreach ($f in $files) {
        if (-not (Test-Path -LiteralPath $f)) { continue }
        foreach ($line in (Get-Content -LiteralPath $f)) {
            if ($line -match ('^\s*(?:export\s+)?' + [regex]::Escape($Key) + '=(.+)$')) {
                $v = $Matches[1].Trim().Trim("'").Trim('"')
            }
        }
    }
    return $v
}

if ((ReadEnvVar 'ROGUE_AUTO_UPDATE') -eq '0') { LogLine 'ROGUE_AUTO_UPDATE=0, skipping'; exit 0 }
$pin = ReadEnvVar 'ROGUE_PLUGIN_VERSION'
if ($pin) { LogLine "ROGUE_PLUGIN_VERSION=$pin pinned, skipping"; exit 0 }

# Rate-limit to once per day.
$cache = Join-Path $rogueDir '.auto-update-check'
if (Test-Path -LiteralPath $cache) {
    $age = (Get-Date) - (Get-Item -LiteralPath $cache).LastWriteTime
    if ($age.TotalSeconds -lt 86400) { LogLine 'checked within TTL, skipping'; exit 0 }
}
try { Set-Content -LiteralPath $cache -Value '' -Encoding ASCII } catch {}

$repo = ReadEnvVar 'ROGUE_PLUGIN_REPO'; if (-not $repo) { $repo = 'qualifire-dev/rogue-plugin-claude' }

$pluginRoot = $env:CLAUDE_PLUGIN_ROOT
$pj = Join-Path $pluginRoot '.claude-plugin\plugin.json'
if (-not (Test-Path -LiteralPath $pj)) { LogLine "no plugin.json at $pj"; exit 0 }
$m = [regex]::Match((Get-Content -Raw -LiteralPath $pj), '"version"\s*:\s*"([0-9]+\.[0-9]+\.[0-9]+)')
if (-not $m.Success) { LogLine 'no installed version found'; exit 0 }
$installedTag = "v$($m.Groups[1].Value)"

try {
    $rel = Invoke-RestMethod -Uri "https://api.github.com/repos/$repo/releases/latest" `
        -Headers @{ 'User-Agent' = 'rogue-auto-update' } -TimeoutSec 5 -ErrorAction Stop
    $latest = $rel.tag_name
} catch { LogLine 'could not resolve latest release'; exit 0 }
if (-not $latest) { LogLine 'could not resolve latest release'; exit 0 }

if ($latest -eq $installedTag) { LogLine "up to date at $installedTag"; exit 0 }

LogLine "upgrade available: $installedTag -> $latest, running installer"
$installerUrl = ReadEnvVar 'ROGUE_INSTALLER_URL'
if (-not $installerUrl) { $installerUrl = 'https://raw.githubusercontent.com/qualifire-dev/rogue-plugin-claude/main/install.ps1' }
try {
    $script = (Invoke-WebRequest -Uri $installerUrl -UseBasicParsing -TimeoutSec 60 -ErrorAction Stop).Content
    $env:ROGUE_NON_INTERACTIVE = '1'
    & ([scriptblock]::Create($script))
    LogLine "installer finished"
} catch { LogLine "installer failed: $($_.Exception.Message)" }
