# Shipping the hook logs to the backend (phases 2–3)

Phase 1 (PR #29, merged first in this stack) gave every plugin its own log file at
`~/.rogue/logs/<agent>.log`, a shared line format, and a size cap. This document
is the design for getting those lines to the backend, and it records the one
decision that changed the shape of the whole feature.

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
is tiny. Do not build continuous streaming.

## The decision: the endpoint agent ships, not the plugins

The original plan had each plugin's detached heartbeat drain its own log. That
was the only option **if the plugins had to do it themselves** — a hook is a
short-lived process, so there is no daemon to own a flush loop, and every
approach reduced to "piggyback the one detached process we already spawn".

`rogue-endpoint` (the Tauri desktop agent) is a better home for it, and its task
system is already the exact shape we need. From
`src-tauri/src/tasks/task_worker.rs`:

- Tasks are **backend-dispatched**: the agent polls, receives a `PendingTask`
  (`id`, `type`, `task_key`, `payload`), runs a `TaskWorker`, and reports
  `Running → Succeeded | AgentFailed | AgentTimeout | Unsupported`.
- An install is per-machine, and the backend addresses one install at a time.
  That is literally "a task that runs on a single computer in a fleet": support
  asks *that* machine for *its* logs, instead of every machine streaming
  unprompted.
- `machine_id` (`identity::machine_id()` → `machine_uid::get()`) already exists
  there, already enrolled, already the key of the `endpoint_agent` row. The
  plugins have no such identity, and we decided **not** to invent one (a
  generated fallback id cannot be correlated to a host, so it is worse than
  absent — see the phase-2 note below).
- The credential problem disappears: the agent is enrolled and authenticates with
  its own secret. No new auth path, no plugin API key on a log route.

Cost of the choice, stated plainly: **coding-agent logs are only collectable on
machines that also run the endpoint agent.** For the MDM fleets this is aimed at
that is the normal deployment, and a plugin-side fallback can be added later
without changing the wire format. It is a deliberate trade of coverage for a
vastly smaller, safer implementation.

## Phase 3 — `CodingAgentLogUpload` task worker (rogue-endpoint)

New file `src-tauri/src/tasks/coding_agent_log_upload_worker.rs`, registered in
`TaskRegistry::default()`, with `TaskType::CodingAgentLogUpload` added to the enum
(`#[serde(other)] Unknown` already covers older agents, so an older install
reports `unsupported` instead of breaking).

**Which files.** Resolve the log directory the same way the dispatchers do, or
the agent reads a path nothing writes to:

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
`/api/v1/endpoint/logs` route rather than adding a second log path. The hook log
is logfmt text, so the worker parses each line into one record:

```jsonc
{ "ts": "2026-08-11T11:26:16Z", "agent": "claude", "event": "PreToolUse",
  "fields": { "outcome": "unconfigured" },
  "raw": "<the original line, if fields could not be parsed>" }
```

Parse leniently: split the leading timestamp, `provider=`, `event=`, then treat
the remainder as best-effort `k=v` and always keep `raw`. `raw=` deliberately
holds up to 400 characters of arbitrary JSON with spaces and `=` (and Codex puts
it mid-line), so a strict k=v parse would lose data.

**Reuse from `log_ship/`.** Take `redact::redact_home_path` and
`redact_pii_in_text` — hook lines carry `path=` values with usernames in them.
Do **not** take `capture.rs`/`shipper.rs`: that is a `tracing` subscriber with an
in-memory ring and a 60 s flush loop, which is the wrong shape for reading files
off disk on demand.

**Ordering and failure.** Report `Running` first (the trait's `pre_run` does it),
then `Uploaded`, then `Succeeded`. A missing log directory is **success with zero
records**, not a failure — the common case is a machine with no coding agent
installed. Only an unreadable-but-present file or a failed POST is
`AgentFailed`. Never touch the live log: read-only, no truncation, no offset
file. Re-running the task re-uploads; the backend dedups (or accepts duplicates
— these are diagnostics).

## Phase 2 — `machine_id` in the plugin heartbeat (optional, decide separately)

Phase 2 as originally scoped was "add `machine_id` to the plugins". With the
endpoint agent doing the shipping, the plugins no longer need it to attribute
logs, so this is now **independent and lower value**. It is still the only way to
join a plugin's roster row to an `endpoint_agent` row on the same host.

If we do it: read the OS id only — macOS `ioreg -rd1 -c IOPlatformExpertDevice`
→ `IOPlatformUUID`, Linux `/etc/machine-id`, Windows
`HKLM\SOFTWARE\Microsoft\Cryptography` → `MachineGuid` (all three are exactly
what `machine_uid::get()` reads, so the values correlate). Cache in
`~/.rogue/machine-id`, add it to the `/hooks/status` body, and **omit the field
when it cannot be read** — do not synthesise one. A generated UUID is not
correlatable to a host, which makes it worse than absent; the roster's existing
`(host | actor-email | family)` key stays the fallback.

## Open questions for the backend

- Does the table behind `/api/v1/endpoint/logs` distinguish agent-process logs
  from coding-agent hook logs? If not it needs a `source` discriminator, or
  filtering the two apart in the UI is guesswork.
- Should a `CodingAgentLogUpload` assignment be creatable from the dashboard
  (support clicks "collect logs" on a machine), or only by internal tooling? That
  decides whether this needs UI work at all.
