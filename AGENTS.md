# AGENTS.md

This file provides guidance to Codex (Codex.ai/code) when working with code in this repository.

## What this repo is

A Codex **plugin** (not an app) that ships Rogue Security AIDR — it observes every Codex lifecycle event and POSTs the payload to `https://api.rogue.security/api/v1/hooks/Codex` for prompt-injection / secret-exfil / destructive-command detection.

There is no build step for the plugin itself: it's a directory of JSON + shell scripts loaded by Codex at session start. The only "build" is `scripts/build-release.sh`, which tars the plugin tree for GitHub Releases.

**Cross-platform by dual dispatcher.** Every event ships TWO implementations — a POSIX-`sh` script (`hook.sh` & friends) for macOS/Linux/WSL and a PowerShell sibling (`hook.ps1` & friends) for **native Windows (no WSL, no Git Bash)**. `hooks.json` registers an `sh` entry and a PowerShell entry for each event; exactly one does real work per machine (see "The hook pattern"). When you change one dispatcher's behavior, change the other to match — keep `hook.sh` / `hook.ps1` in lockstep.

## Repo layout (load-bearing pieces)

- `.Codex-plugin/marketplace.json` — marketplace manifest. Points at `./plugins/rogue`.
- `plugins/rogue/.Codex-plugin/plugin.json` — plugin manifest. **`version` here is the source of truth** — `build-release.sh` reads it, and `auto-update.sh` compares it against the latest GitHub release tag (`v${version}`).
- `plugins/rogue/hooks/hooks.json` — 12 lifecycle hooks, all `type: "command"`. **Every event registers two entries** (an `sh` one and a PowerShell one) — see below.
- `plugins/rogue/scripts/hook.sh` — POSIX-`sh` + `curl` dispatcher (macOS/Linux/WSL). Invoked via `sh` (NOT `bash`), so it is kept POSIX-clean (tested under `dash` via `tests/test_hook_sh.sh`). **Stands down** (emits `{}`, exits) under Git Bash (`uname` = MINGW/MSYS/CYGWIN) so the PowerShell entry owns native Windows.
- `plugins/rogue/scripts/hook.ps1` — PowerShell + `Invoke-WebRequest` dispatcher. Owns native Windows; stands down on non-Windows (`pwsh` on macOS/Linux). Mirrors `hook.sh` stage-for-stage AND replicates Codex's block detection, native modal, logging, and SessionStart unconfigured hint.
- `plugins/rogue/scripts/setup.sh` / `setup.ps1` — write `~/.rogue-env` (mode 600) / `%USERPROFILE%\.rogue-env` (ACL-restricted) with `ROGUE_API_KEY` / `ROGUE_ACTOR_EMAIL` / `ROGUE_ACTOR_NAME`. Both emit the same `export KEY=value` POSIX-quoted format. Called by `/rogue:setup`.
- `plugins/rogue/scripts/auto-update.sh` / `auto-update.ps1` — fire (detached) from `SessionStart`. Rate-limited once/24h. Re-invoke the matching one-line installer (`install.sh` / `install.ps1`) when a newer release tag exists.
- `plugins/rogue/scripts/heartbeat.sh` / `heartbeat.ps1` — SessionStart presence beacon (detached). POST `/api/v1/hooks/status`.
- `plugins/rogue/scripts/security-alert.sh` / `security-alert.ps1` — modal block alert: osascript (macOS) / notify-send (Linux) / `System.Windows.Forms.MessageBox` (Windows). Launched in the background by `hook.sh` / `hook.ps1` on a block.
- `plugins/rogue/scripts/warn.sh` — SessionStart "not configured" nudge (sh path only; the ps1 path emits the hint inline from `hook.ps1`).
- `plugins/rogue/commands/{setup,status}.md` — slash commands. **Instructions to Codex**, not scripts — Codex runs the bash/PowerShell inside them step-by-step (each carries macOS/Linux and Windows variants).
- `install.sh` / `install.ps1` — one-line installers. Both add the marketplace via the Codex CLI (`Codex plugin marketplace add` + `Codex plugin install`) — they do NOT download the release tarball.
- `scripts/build-release.sh` + `.github/workflows/release.yml` — tag-driven release pipeline. Pushing a `v*` tag builds a single cross-platform `dist/rogue-plugin-Codex.tar.gz` (both `.sh` and `.ps1` scripts) and attaches it to the release. The artifact filename intentionally has **no version and no OS suffix** so `/latest/` URLs stay stable. (The tarball is consumed by `compile-customer-plugin.sh` for MDM bundles; the marketplace install clones the repo directly.)

## The hook pattern

Every event registers two entries — an `sh` one and a PowerShell one — pointing at the matching dispatcher:

```json
{ "type": "command",
  "command": "sh \"${CLAUDE_PLUGIN_ROOT}/scripts/hook.sh\" PreToolUse || echo '{}'",
  "timeout": 12 },
{ "type": "command",
  "command": "powershell -NoProfile -NonInteractive -Command \"& ([scriptblock]::Create((Get-Content -Raw -LiteralPath (Join-Path $env:CLAUDE_PLUGIN_ROOT 'scripts/hook.ps1')))) PreToolUse\"",
  "timeout": 15 }
```

`scripts/hook.sh <EventName>` is the orchestrator: stands down under Git Bash, sources env files, fail-opens on missing API key, sources `scripts/actor.sh` for actor resolution, POSTs stdin to `/api/v1/hooks/Codex` with the four `x-rogue-*` headers, parses the response for a block decision, fires `scripts/security-alert.sh` in the background on block (skipped when `CLAUDE_CODE_ENTRYPOINT=cli`), and prints the API response to stdout. `hook.ps1` does the same on Windows. Logs every invocation to `$ROGUE_LOG_FILE` (default `~/.rogue/hook.log` / `%USERPROFILE%\.rogue\hook.log`); the logged `reason` is sanitized of control characters to prevent log forgery from server-controlled text.

### Exactly-one-runs (cross-platform arbitration)

Codex runs **all** entries for an event. The two entries are arranged so exactly one does real work per machine:

| Environment | `sh` entry | PowerShell entry |
|---|---|---|
| macOS / Linux / WSL | runs (curl POST) | `powershell` absent → fails to spawn, no output |
| native Windows + Git Bash | `uname`=MINGW/MSYS/CYGWIN → **stands down** (`{}`) | runs |
| native Windows, no Git Bash | `sh` not found → clean fail-open (no output) | runs |

**`sh`, not `bash`.** On bash-less Windows, `bash` resolves to the WSL launcher stub (`System32\bash.exe`), which prints UTF-16 "no installed distributions" noise that breaks Codex's JSON parse. There is no `sh.exe` stub, so `sh` cleanly fails to spawn instead. The Git Bash stand-down matters because Git Bash's `~` maps to `%USERPROFILE%` — the SAME creds `hook.ps1` reads — so without it both would POST (and double-alert on a block).

**No `-File` on the PowerShell entry.** Logic loads via `[scriptblock]::Create((Get-Content ...))` so ExecutionPolicy never applies (this also survives a GPO-enforced policy, which `-ExecutionPolicy Bypass` does not). The only variable in the one-liner is `$env:CLAUDE_PLUGIN_ROOT`, resolved at runtime via `Join-Path` — it must **not** be single-quoted (literal in PowerShell).

`scripts/warn.sh` is the SessionStart "not configured" nudge (sh path; `hook.ps1` emits the hint inline on the Windows path). `auto-update.{sh,ps1}` are the SessionStart background updaters. `heartbeat.{sh,ps1}` are the SessionStart background presence beacons — fire-and-forget `POST /api/v1/hooks/status` (JSON body: `agent_family: "Codex"` fixed enum, `agent` display label from `$CLAUDE_CODE_ENTRYPOINT`, `version` from `plugin.json` via grep/sed or regex, `host`, actor fields) that registers the install in the dashboard's Coding Agents roster and learns `update_available`. Reads the plugin version without `python3` for the fresh-macOS reason below.

Invariants to preserve when editing hooks (apply to **both** dispatchers — keep them in lockstep):

- **Resolve env files in this precedence order** — `${CLAUDE_PLUGIN_ROOT}/env` (bundled defaults), then `/etc/rogue/env` (MDM) / `C:\ProgramData\rogue\env`, then `$HOME/.rogue-env` / `%USERPROFILE%\.rogue-env` (per-user). Later wins; process env wins over all files. `hook.sh` `source`s the files (valid POSIX sh); `hook.ps1` regex-parses the same `export KEY=value` lines and decodes the shell quoting via `ConvertFrom-ShellQuoted` so values round-trip identically. Never source from a world-writable path like `/tmp`.
- **Actor cascade lives in `scripts/actor.sh`** (sh) / is inlined in `hook.ps1` (ps). Per-var fallback: existing env → `git config --global user.{email,name}` → `CLAUDE_CODE_USER_EMAIL` (local-part as name) → `hostname`/`whoami` (`COMPUTERNAME`/`USERNAME`) last-resort. Resolved every hook; no on-disk cache.
- **Fail-open is layered** — the dispatcher emits `{}` on missing API key or any HTTP failure. The `sh` entries are additionally wrapped `sh ... || echo '{}'`. PowerShell entries can NOT use `|| echo` (invalid in PS 5.1), so `hook.ps1` must guarantee `{}` on every path itself.
- **`x-rogue-event` must match the hook's key** in `hooks.json`. The server routes on this header. There is **no** `x-rogue-source` header (that is cursor-only).
- Block detection covers `"decision":"block"`, `"continue":false`, `"permissionDecision":"deny"`, `"behavior":"deny"`; reason from `permissionDecisionReason`→`reason`→`stopReason`→`message`. On block both dispatchers relay the response verbatim AND fire the native modal (unless `CLAUDE_CODE_ENTRYPOINT=cli`).
- Timeouts: HTTP client uses 10s; the `sh` hook `timeout` is 2s higher, the PowerShell hook `timeout` a little higher again for cold PowerShell start.

## Releasing

1. Bump `version` in **both** `plugins/rogue/.Codex-plugin/plugin.json` and `.Codex-plugin/marketplace.json` (the marketplace lists the plugin's version too — keep them in sync).
2. Commit, tag `vX.Y.Z`, push the tag. The `release.yml` workflow checks out the tag, runs `scripts/build-release.sh`, and creates the GitHub Release with the single `rogue-plugin-Codex.tar.gz`.
3. `auto-update.{sh,ps1}` on user machines pick up the new release on the next `SessionStart` (rate-limited 24h). One-line users can also re-run the installer.

## Things that look weird but are intentional

- Hooks are shell one-liners, not script files referenced directly. This keeps the manifest self-contained for `/plugin install`.
- Each event has **two** entries (`sh` + PowerShell). On any given machine only one produces output; the other's binary is missing or it stands down. Asymmetric but correct per platform — see the exactly-one-runs table.
- The PowerShell entry loads logic via `[scriptblock]::Create((Get-Content ...))` rather than `-File`, to dodge ExecutionPolicy/GPO without `-ExecutionPolicy Bypass`. Don't "simplify" it to `-File`.
- The `SessionStart` event has **four separate hook groups** (auto-update kick-off, heartbeat kick-off, unconfigured-warning, API POST). They run independently so a failure in one doesn't suppress the others. auto-update/heartbeat are detached (`nohup ... &` on sh; `Start-Process -WindowStyle Hidden` on PowerShell) with short timeouts — the hook returns immediately. Don't "fix" the short timeout.
- Release tarballs deliberately omit BOTH the version and an OS suffix from the filename, so `/releases/latest/download/rogue-plugin-Codex.tar.gz` stays stable. The package is cross-platform by content (ships `.sh` and `.ps1`).
- `install.sh` / `install.ps1` install via the Codex CLI marketplace (git clone), NOT by downloading the tarball. The tarball exists for `compile-customer-plugin.sh` (MDM bundles).
- `rgx!` prompt prefix is a server-side convention (false-positive escape hatch). The plugin itself doesn't parse it — the API does.

## Imported Claude Cowork project instructions
