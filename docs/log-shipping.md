# Shipping the hook logs to the backend (phases 2–3)

Phase 1 (PR #29, merged first in this stack) gave every plugin its own log file at
`~/.rogue/logs/<agent>.log`, a shared line format, and a size cap. This document
is the design for getting those lines to the backend.

There are **two independent capabilities**, and they are independent on purpose:

| | ships from | auth | trigger | coverage |
|---|---|---|---|---|
| **A. Plugin shipper** | the plugin itself | `ROGUE_API_KEY` | its own detached session-start process | every machine that has a Rogue plugin |
| **B. Endpoint collector** | `rogue-endpoint` | enrolled agent secret | a backend-dispatched task | machines that also run the endpoint agent |

**A is the baseline** — not every customer runs `rogue-endpoint`, so a design that
depends on it leaves logs unreachable on exactly the installs we most often need
to debug (a fresh one-liner install that never showed up in the dashboard). **B
is an on-demand pull** for support and IR: "collect this machine's logs now",
whole file rather than the incremental tail, and it carries a real `machine_id`.
Neither blocks the other; either alone is useful.

## What the log is actually worth

The backend already receives every hook event. The delta in `<agent>.log` is
exactly the set of events that **never reached the API**:

```
outcome=unconfigured          no API key on this machine
http=<code> rc=<rc>           non-2xx, or curl/Invoke-WebRequest transport failure
outcome=fail-open             timeout, unreachable, malformed body
ide_alert=fired               a JetBrains silent block we had to surface locally
dbstore=miss / tail=none      an enrichment that could not be produced
subagent=… outcome=unresolved  re-attribution that failed
```

So this is **client-side diagnostics**, not the security signal. That has two
consequences: the cadence can be lazy (nothing here is real-time), and the volume
is tiny — a busy day is single-digit KB. Do not build continuous streaming.

## Why the plugin can attribute its own logs

This was the original blocker: the plugins have no machine identity, and we
decided **not** to invent one (a generated UUID cannot be correlated to a host,
so it is worse than absent).

It turns out not to matter, because the heartbeat already solved it. Every plugin
POSTs `/api/v1/hooks/status` with `host` (`hostname`), `actor_email` and
`actor_name`, and the roster **dedups one row per `(host | actor-email | family)`**
— see the comment at the top of `plugins/rogue/scripts/heartbeat.sh`. A shipped
log chunk carrying that same triple joins the roster row it belongs to with no
`machine_id` at all. The shipper resolves the triple through the identical code
path the heartbeat uses (`scripts/actor.sh`, env → `git config --global` →
`CLAUDE_CODE_USER_EMAIL` → `hostname`/`whoami`), so the two cannot disagree.

`machine_id` remains the only way to join a plugin row to an `endpoint_agent` row
on the same host — that is capability B's contribution, and phase 2 below.

## Phase 2 — the plugin shipper (this repo)

### One agent-agnostic shipper, not six

All six plugins write into the **same** directory (`~/.rogue/logs/`), and phase 1
made every line stamp `provider=<slug>`. So the shipper does not need to know
which agent it belongs to: it ships **every** `<slug>.log` it finds, and each
record is attributed by the `provider=` token on its own line.

That is worth more than tidiness:

- **Coverage is the union, not the intersection.** A machine with Claude Code and
  Cursor where only Claude has run this week still gets `cursor.log` shipped. An
  agent whose plugin is installed but whose session-start path is rare (Antigravity
  fires on the first `PreInvocation`) is covered by whoever ran first.
- **The six copies are byte-identical**, so lockstep drift — the standing hazard in
  this repo, and the thing phase 1 spent most of its effort on — is enforceable by
  `cmp`, not by review. `tests/test_ship_logs.sh` asserts it.

Agent-specific values arrive as **arguments**, which is what keeps the file
identical: `ship-logs.sh <plugin-root> <provider> <version>`. The plugin-root env
var is the one thing that genuinely differs per plugin (`CLAUDE_PLUGIN_ROOT`,
`PLUGIN_ROOT`, `CURSOR_PLUGIN_ROOT`, `extensionPath`, …) and the caller already
has it in hand.

Files: `plugins/<each>/scripts/ship-logs.sh` + `ship-logs.ps1`, and
`plugins/gemini/scripts/ship-logs.mjs` (Gemini is Node-only by design — see the
root `CLAUDE.md`; do not port it to shell).

### Where it runs: nowhere new

**No `hooks.json` entry is added.** This is the load-bearing constraint of the
whole feature: Codex, Gemini and Copilot fingerprint the hook definition and
**skip untrusted command hooks until the user reviews `/hooks`**, so a new entry
would silently disable enforcement for every existing install until each user
went and re-trusted it. Shipping logs is not worth that.

Instead the shipper is invoked by the process that is *already* detached at
session start — the heartbeat — as its last step. The heartbeat is already
fire-and-forget, already outside the hook's 20 s budget, and already has
credentials, actor and version resolved, so this costs the hook nothing:

| plugin | invoked from |
|---|---|
| claude, codex, copilot, antigravity | tail of `scripts/heartbeat.sh` / `heartbeat.ps1` |
| gemini | tail of `scripts/heartbeat.mjs` |
| cursor | the existing inline detached `sessionStart` block in `hook.sh` / `hook.ps1` (Cursor has no heartbeat script) |

It is a separate script rather than inline code in the heartbeat for three
reasons: the heartbeat stays short and obviously-correct, the shipper is testable
on its own, and support can tell a customer to **run it by hand** — which is the
single most useful thing about it on a machine that has no endpoint agent.
`/rogue:status` gains a step that offers exactly that.

### Cursor and Antigravity are the two that need care

- **Cursor** has no `heartbeat.*`; its heartbeat is an inline `( curl … & )` in
  `hook.sh` (and the mirror in `hook.ps1`). The shipper call goes in the same
  `if [ "$event" = "sessionStart" ]` block, likewise detached. It is a *script*
  change, not a `hooks.json` change, so trust is unaffected.
- **Antigravity** has no `SessionStart` at all; its heartbeat fires on the first
  `PreInvocation` of a session (`invocationNum == 0`). Same hook point, nothing
  new.

### Offsets, rotation, and not losing lines

State lives in `~/.rogue/ship/` (`%USERPROFILE%\.rogue\ship\`):

```
~/.rogue/ship/<slug>.offset   byte offset already accepted by the backend
~/.rogue/ship/.last           unix seconds of the last attempt (throttle)
~/.rogue/ship/.lock           mkdir-based mutex, see below
```

Per file:

1. Read `<slug>.offset` (absent → 0). Read the current size with `wc -c` — **not
   `stat`**, whose flags differ between BSD and GNU (same reason as phase 1's
   rotation check).
2. **`size < offset` means the file rotated** between sessions. Ship the tail of
   `<slug>.log.1` from `offset` first (best-effort — if `.1` is gone, those lines
   are lost and that is acceptable for diagnostics), then reset `offset` to 0 and
   continue with the live file.
3. Send `[offset, min(size, offset + ROGUE_SHIP_MAX_BYTES))`, oldest-first, and
   advance the offset by **exactly what the backend accepted**. Anything left over
   goes next session. Ordering is preserved and nothing is skipped.
4. **Advance the offset only on HTTP 2xx.** Any other outcome leaves it untouched,
   logs `outcome=ship-fail`, and exits 0. Delivery is therefore at-least-once —
   the backend must tolerate a duplicate chunk (see the open questions).

The live log is opened read-only and never truncated. Two plugins can start a
session at the same instant, so the shipper takes `~/.rogue/ship/.lock` with
`mkdir` (atomic on POSIX and on Windows via `New-Item -ItemType Directory`,
which fails if it exists) and exits 0 silently if it cannot. A lock older than
10 minutes is stale and is removed — a killed shipper must not wedge the feature.

Throttle: at most one attempt per `ROGUE_SHIP_MIN_INTERVAL` (default 3600 s),
stamped in `.last`. Session starts are frequent — a fresh CLI session per
terminal tab — and there is nothing time-sensitive here.

### Wire format

`POST ${ROGUE_BASE_URL}/api/v1/hooks/logs`, `x-rogue-api-key`,
`Content-Type: application/json`:

```jsonc
{ "shipper":      "claude",        // which plugin's copy ran; NOT the content's provider
  "shipper_version": "1.4.2",
  "host":         "…",             // the roster's dedup triple, resolved exactly
  "actor_email":  "…",             // as heartbeat.sh resolves it
  "actor_name":   "…",
  "log_file":     "claude.log",    // basename only — the directory is site config
  "offset":       12345,           // byte offset this chunk starts at
  "bytes":        4096,
  "rotated":      false,           // true when this is the tail of <file>.1
  "content_b64":  "…" }            // base64 of the raw chunk
```

**`content_b64`, not a parsed record array.** Three reasons, in order of weight:

1. The log line's tail is **server-controlled text** — `raw=` holds up to 400
   characters of our own API response, including block-reason findings with
   arbitrary quotes and backslashes. Concatenating that into JSON by hand is the
   exact corruption/injection hazard that `transcriptTailB64` already exists to
   avoid in `plugins/copilot/scripts/hook.sh`.
2. **No `jq`, no `python3`.** `jq` is absent from older macOS and minimal Linux
   images, and `/usr/bin/python3` is a stub that fails silently without Xcode CLT
   (a repo-wide rule). `base64 | tr -d '\r\n'` is available everywhere, and
   `[Convert]::ToBase64String` / `Buffer.toString('base64')` need nothing.
3. Parsing belongs on the server, where it can be fixed without a plugin release.
   The line format is stable but the field set is not — phase 1 alone added three
   tokens.

Server-side, each line parses as: leading RFC3339 timestamp, `provider=`,
`event=`, then best-effort `k=v` for the remainder, always keeping the original
line as `raw`. Parse **leniently and never drop a line** — `raw=` is a
space-bearing, `=`-bearing free-text tail (and Codex puts it mid-line), so a
strict k=v parse loses data. Attribute each record by **its own `provider=`**, not
by the envelope's `shipper`.

### Privacy

The hook log contains **no prompt or file content** by construction — event
names, outcomes, HTTP codes, and the head of Rogue's own API response. It goes to
the customer's own tenant, which already has that response. The shipper still
replaces the literal `$HOME` / `%USERPROFILE%` prefix with `~` in the chunk before
encoding, since a relocated `ROGUE_LOG_DIR` or an error string can carry a
username.

`ROGUE_SHIP_LOGS=0` disables shipping entirely, resolved from the same env-file
chain as everything else (so `/etc/rogue/env` can turn it off fleet-wide).

### Tests

`tests/test_ship_logs.sh` / `.ps1`, alongside the phase-1 suites:

- the six `ship-logs.sh` are byte-identical (`cmp`), likewise the five `.ps1`;
- offset advances on 2xx, does **not** advance on 5xx/timeout/no-network;
- `size < offset` ships `.1`'s tail then resets;
- the lock serialises two concurrent runs, and a >10 min lock is reclaimed;
- throttle honored, `ROGUE_SHIP_LOGS=0` honored, both from `~/.rogue-env`;
- a chunk containing `"` `\` and a newline round-trips through base64 byte-exact;
- unconfigured (no API key) is a silent no-op that leaves the offset alone;
- `wc -c`, not `stat`; runs green under both `dash` and `bash` in `validate.yml`.

A mock server is needed for the first time in this repo's tests (phase 1
deliberately only exercised the unconfigured path). A `nc`-based one-shot
responder is enough and avoids adding a dependency.

## Phase 2b — `machine_id` in the plugin heartbeat (optional, decide separately)

Not needed for attribution any more (see above), so this is now **independent and
lower value**. It is still the only way to join a plugin's roster row to an
`endpoint_agent` row on the same host, which matters once capability B exists and
the same log can arrive by both routes.

If we do it: read the OS id only — macOS `ioreg -rd1 -c IOPlatformExpertDevice`
→ `IOPlatformUUID`, Linux `/etc/machine-id`, Windows
`HKLM\SOFTWARE\Microsoft\Cryptography` → `MachineGuid` (all three are exactly
what `machine_uid::get()` reads, so the values correlate). Cache in
`~/.rogue/machine-id`, add it to the `/hooks/status` body, and **omit the field
when it cannot be read** — do not synthesise one. A generated UUID is not
correlatable to a host, which makes it worse than absent; the roster's existing
`(host | actor-email | family)` key stays the fallback.

## Phase 3 — `CodingAgentLogUpload` task worker (rogue-endpoint)

Capability B, in the `qualifire/rogue-endpoint` repo. Independent of phase 2:
it needs nothing from the plugins and the plugins need nothing from it.

Its distinct value over the plugin shipper is the reason to build it anyway: it
is **pulled on demand** by the backend rather than pushed on a session that may
not happen for days, it uploads the **whole file** rather than the tail past an
offset, and it carries a real `machine_id`.

New file `src-tauri/src/tasks/coding_agent_log_upload_worker.rs`, registered in
`TaskRegistry::default()`, with `TaskType::CodingAgentLogUpload` added to the enum
(`#[serde(other)] Unknown` already covers older agents, so an older install
reports `unsupported` instead of breaking). From
`src-tauri/src/tasks/task_worker.rs`: tasks are backend-dispatched — the agent
polls, receives a `PendingTask` (`id`, `type`, `task_key`, `payload`), runs a
`TaskWorker`, and reports `Running → Succeeded | AgentFailed | AgentTimeout |
Unsupported`. An install is per-machine and the backend addresses one at a time,
which is literally "a task that runs on a single computer in a fleet".

**Which files.** Resolve the log directory the same way the dispatchers do, or the
agent reads a path nothing writes to:

1. `ROGUE_LOG_DIR` / `ROGUE_LOG_FILE` from the shared env-file chain
   (`/etc/rogue/env` or `C:\ProgramData\rogue\env`, then `~/.rogue-env`) — the
   MDM files are the ones that matter here, and phase 1 made all eleven
   dispatchers honor them.
2. Otherwise `~/.rogue/logs/` (`%USERPROFILE%\.rogue\logs\`).

Then glob `<dir>/{claude,codex,cursor,gemini,copilot,antigravity}.log` plus each
`.1`. Ship `.1` **before** its live file so the batch stays chronological.

**Payload.** Let the task narrow the request, all optional:

```jsonc
{ "agents": ["claude", "copilot"],   // default: all present
  "since":  "2026-08-01T00:00:00Z",  // default: whole file
  "max_bytes": 5242880 }             // per-agent cap, oldest lines dropped first
```

**Format.** Reuse the existing `LogShipRequest`
(`machine_id`, `agent_version`, `records: Vec<Box<RawValue>>`) and the
`/api/v1/endpoint/logs` route rather than adding a third log path. Unlike the
plugin shipper this side has a real JSON serialiser, so it parses the lines
itself into the same record shape the server produces from `content_b64`:

```jsonc
{ "ts": "2026-08-11T11:26:16Z", "provider": "claude", "event": "PreToolUse",
  "fields": { "outcome": "unconfigured" },
  "raw": "<the original line>" }
```

**Reuse from `log_ship/`.** Take `redact::redact_home_path` and
`redact_pii_in_text`. Do **not** take `capture.rs`/`shipper.rs`: that is a
`tracing` subscriber with an in-memory ring and a 60 s flush loop, which is the
wrong shape for reading files off disk on demand.

**Ordering and failure.** Report `Running` first (the trait's `pre_run` does it),
then `Uploaded`, then `Succeeded`. A missing log directory is **success with zero
records**, not a failure — the common case is a machine with no coding agent
installed. Only an unreadable-but-present file or a failed POST is `AgentFailed`.
Never touch the live log: read-only, no truncation, **and no offset file** — the
plugin shipper owns `~/.rogue/ship/`, and a second writer there would make both
lose lines.

## Open questions for the backend

- **One store or two?** The plugin shipper posts to `/api/v1/hooks/logs`
  (API-key auth, base64 chunk) and the endpoint agent to `/api/v1/endpoint/logs`
  (enrolled secret, parsed records). They should land in the same table with a
  `source` discriminator (`plugin` | `endpoint_agent`) — otherwise the UI cannot
  show one machine's history, and the same lines arriving by both routes look
  like distinct data.
- **Dedup key.** Both routes are at-least-once, and B re-uploads whole files by
  design, so the same line can arrive several times.
  `(host, actor_email, provider, log_file, line_ts, hash(raw))` is enough. If
  duplicates are simply acceptable for diagnostics, say so explicitly — it
  removes work from both clients.
- Should a `CodingAgentLogUpload` assignment be creatable from the dashboard
  (support clicks "collect logs" on a machine), or only by internal tooling? That
  decides whether B needs UI work at all.
