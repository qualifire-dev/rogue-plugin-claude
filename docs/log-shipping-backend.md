# Receiving the plugin logs — the Rogue API and the endpoint agent

Companion to [plugin-log-shipper.md](plugin-log-shipper.md) (the client, built and
merged in this repo) and [log-shipping.md](log-shipping.md) (why the feature exists,
and the two independent capabilities). **This file is the work that lands outside
this repo**, so it can start in parallel: nothing here needs another plugin change,
and the client is already exercised end to end in CI against a local receiver
(`tests/e2e_receiver.mjs`).

Two deliverables, in two repos, with one hard ordering constraint between them and
the plugin:

| # | what | where | blocks what |
|---|---|---|---|
| **1** | `POST /api/v1/hooks/logs` + the `log_source` mapping + redaction | the AIDR API service | flipping the plugin's default on |
| **2** | coding-agent log-upload task worker | the endpoint agent | nothing — independent of 1 and of the plugin |

> **This repository is public, so no backend coordinates appear here.** No repo
> names, file paths, module or symbol names, and no infrastructure vendor — only the
> requirements and the wire contract, which is what a client repo can legitimately
> pin down. Anyone implementing this has the internal locations already; anyone who
> does not have them should not be learning them from here.

> **The plugin now ships unconditionally.** The `ROGUE_SHIP_LOGS` opt-in and its `=0`
> kill switch were removed once the route was confirmed deployed (probed 2026-08-18: an
> empty body is answered `422` with a body-schema validation error, where an unknown
> hooks path still answers a bare `404 NOT_FOUND`). Every configured install therefore
> uploads, with no client-side way to opt a machine out — so #1 below is no longer a
> precondition to a rollout, it is a live requirement. See **Rollout** in
> [plugin-log-shipper.md](plugin-log-shipper.md).

---

# Part 1 — `POST /api/v1/hooks/logs`

## The wire contract, as the client already sends it

This is not a proposal — it is what `scripts/shared/ship-logs.{sh,ps1}` and
`plugins/gemini/scripts/ship-logs.mjs` put on the wire today, asserted byte-for-byte
by `tests/test_ship_logs.sh`. Treat it as fixed input.

```jsonc
POST /api/v1/hooks/logs
x-rogue-api-key: <the org's plugin API key>     // the ONLY auth; no machine id, no agent secret
Content-Type: application/json

{
  "host":            "amos-mbp",                // hostname(1) / COMPUTERNAME
  "actor_email":     "amos@rogue.security",     // or the literal "anon" — see below
  "actor_name":      "amos",                    // may be empty
  "agent_family":    "claude",                  // OPTIONAL — see "a hint, not the key"
  "shipper":         "claude",                  // log slug of the plugin that uploaded
  "shipper_version": "1.4.2",                   // that plugin's version, or "unknown"
  "log_file":        "claude.log",              // BASENAME ONLY, never a path
  "offset":          40960,                     // byte offset this chunk starts at
  "bytes":           4096,                      // decoded length of content_b64
  "rotated":         false,                     // true = from <file>.1, not the live file
  "content_b64":     "MjAyNi0wOC0xMlQwMDow…"    // base64 of raw log bytes
}
```

Response: the client reads **only the HTTP status**. No body is parsed, ever.

Four properties of the client that the server design has to respect:

1. **A 2xx makes the client forget those bytes.** The offset advances only on 2xx and
   the bytes are never re-sent. So a 2xx must mean *durably written*, not *received* —
   see **2xx is a durability promise** below. This is the single most important line
   in this document.
2. **`offset`/`bytes`/`rotated` are diagnostics, not an assembly protocol.** The
   server must not try to reorder or reassemble by offset: chunks always arrive in
   order per `(source, log_file)`, and after a rotation the offsets restart at 0.
   Store them and move on.
3. **`content_b64` decodes to a whole number of log lines** — never a fragment. The
   client stalls rather than advance to a non-newline boundary, so the server may
   split on `\n` without defensive re-joining.
4. **A chunk is at most ~1 MiB decoded** (`ROGUE_SHIP_MAX_BYTES`), except for a
   single oversized line, which is sent whole up to `ROGUE_SHIP_MAX_LINE_BYTES`
   (4 MiB). Size the body limit above 4 MiB of base64 (~5.6 MiB) or the client will
   stall on that one line forever, logging `outcome=fail` each run.

## Parsing a line

The format is phase 1's, identical across all six dispatchers:

```text
2026-08-11T11:26:16Z provider=claude surface=cli event=PreToolUse outcome=unconfigured
```

- **`surface=` is OPTIONAL, and sits between `provider=` and `event=`.** It names
  which surface of that agent family wrote the line — `cli` / `desktop` / `cowork`
  for `claude`, `codex_cli` / `codex_app`, `antigravity` / `antigravity_ide` /
  `antigravity_cli`, and a constant for the single-surface plugins. It is absent on
  every line written before the versions listed in
  [hook-log-format.md](hook-log-format.md), and absent whenever the surface could
  not be determined; there is no `surface=unknown` and no empty value. Treat the
  token as optional and define a behaviour for lines that lack it.
- **`provider=` is the per-line source of truth for attribution, not `log_file` and
  not `agent_family`.** A support upload (`ROGUE_SHIP_ALL=1`, which the no-argument
  form implies) carries several agents' files in one run, and an install that sets
  `ROGUE_LOG_FILE` has *every* agent writing into one arbitrary basename. So attribute
  each line by its own token.
- **`agent_family` on the envelope is a fallback hint for a line with no `provider=`.**
  The client sends it only for the uploading plugin's *own* log, and omits it for a
  foreign file (where the shipper's family would mislabel every line) and in
  `ROGUE_LOG_FILE` collapse mode. Its vocabulary is the heartbeat's
  (`openai` for Codex, not `codex`) — the same enum `/hooks/status` already takes.
- `provider=` is the log **slug**, which is deliberately *not* the family: five of six
  coincide, Codex's slug is `codex` where its family is `openai`, and the roster labels
  are `gemini_cli`/`github_copilot` where the slugs are `gemini`/`copilot`. Map, do not
  assume.
- Remaining `key=value` tokens are free-form and will grow. Parse permissively; keep
  the raw line.
- A line the parser does not understand is **kept as raw, not dropped** — this is
  diagnostics data whose value is highest exactly when something unexpected happened.

Suggested record shape, matching what the endpoint agent already produces so one
Log-store schema covers both capabilities:

```jsonc
{ "ts": "2026-08-11T11:26:16Z", "provider": "claude", "event": "PreToolUse",
  "fields": { "outcome": "unconfigured" },
  "raw": "<the original line, redacted>",
  "log_source_id": "…", "log_file": "claude.log", "rotated": false }
```

## `log_source` — a table, not a hash

Rows in the log store carry a random `log_source_id`, resolved (create-or-get) from
`(org_id, host, actor_email, agent_family)`.

- **A hash of those four is not a privacy boundary.** Work emails and hostnames inside
  one org are low-entropy enough to dictionary in milliseconds.
- **A random id makes erasure work on an append-only store**: delete the mapping row
  and the events become unlinkable, with no rewrite of the store.
- **Resolve-or-create, and never reject.** The client has no `log_source_id` to send
  and no way to learn one — it reads only the status code. A 4xx for "unknown source"
  would be a permanent stall.
- **This is coarser than a `coding_agent` roster row, on purpose.** The roster
  fingerprint is four parts including the *surface*
  (`` `${hostname}|${actorEmail ?? "anon"}|${family}|${agent}` ``), but every surface of
  a family shares one log file — all three Claude surfaces write one `claude.log` — so a
  chunk cannot resolve to a single roster row. Do not try to join it to one.
- **`actor_email` may be the literal `"anon"`.** All three clients canonicalize absent,
  empty and whitespace-only to that exact value, matching the roster's own
  `actorEmail ?? "anon"` fallback, so the two key alike. Do not treat it as an address.
- **Trim before keying, then apply the `anon` rule.** The clients trim, but the key must
  not depend on that: `" amos@rogue.security "` keyed verbatim resolves to a *different*
  `log_source_id` than the heartbeat's identity for the same person, and the logs then
  attach to a source row nothing else uses. Trim first, map an empty result to `anon`,
  and only then key.
- Case is **not** folded, in the client or in the key: the roster's existing
  fingerprints were computed on the raw case, and folding here would re-key every
  install.
- **Resolve `log_source_id` per LINE, not per request.** The envelope's `agent_family`
  is the *shipping* plugin, and the support form deliberately uploads every agent's log
  from one machine in one request — so a single request routinely carries `provider=`
  values from several families. Map each line's `provider=` slug to its family
  (`codex` → `openai`, `gemini` → `gemini`, `copilot` → `copilot`, …) and resolve the
  source for that record; fall back to the envelope's `agent_family` only for a line
  with no parseable `provider=`. One source per request misfiles exactly the uploads
  support depends on, and a `ROGUE_LOG_FILE` collapse-mode install (all agents in one
  file) the same way.

`machine_id` is deliberately **not** in the envelope. It was in an earlier draft and
was removed: its only job is joining a plugin row to an `endpoint_agent` row on the
same host, which belongs on the roster row once, not on every chunk. (And a
plugin-generated UUID was rejected outright — it cannot be correlated to a host, so it
is worse than absent.)

## 2xx is a durability promise

The route must **await** its write and **fail the request** if the write fails.

The existing endpoint-log sink is the shape to avoid: it fires the store client's
ingest without `await` inside its `try/catch` — so an async rejection is not even caught — and returns
`accepted: events.length` unconditionally, including when the store client is absent or
its dataset variable is unset. For a fire-and-forget tracing sink that is a
defensible trade. Here it is silent, unrecoverable data loss: the client advances its
offset on that 2xx and those bytes never exist anywhere again.

Concretely:

- `await` the ingest; a rejection is a **5xx**, so the client retries the same range
  next session.
- Misconfiguration (no client, no dataset) is a **5xx**, never a cheerful 200.
- A bad API key is **401**; the client logs `http=401` and does not advance. `/setup`
  is the operator fix, and `/rogue:status` already tells them so.
- A malformed envelope is **400**. The client will retry it forever, which is correct:
  a malformed body is a client bug, and the stalled offset plus the `outcome=fail`
  lines are how we find out.
- Prefer **429 with retry semantics over silent truncation** if volume ever needs
  limiting. The client treats every non-2xx identically (log, don't advance), so a
  429 is safe; a 200 that quietly dropped records is not.

## Redaction is server-side, over every field

The clients upload **verbatim** — deliberately, so policy lives where it is readable,
testable and changeable without a plugin release.

- **Order is fixed: redact the raw line FIRST, then parse the redacted line.** Parsing
  first and redacting the pieces afterwards leaves two ways to leak — free text that no
  parsed field claims stays in `raw`, and any field the redactor rewrites no longer
  matches the `raw` it came from. Redacting first makes `raw` and every parsed field
  consistent by construction.
- Reuse the endpoint agent's redaction helpers, which already walk
  every string value and rewrite home paths.
- **Persist the redacted line as `raw`, never the original.** There is no
  "store both" tier.
- Two tokens the existing helpers do not cover, each needing an explicit decision:
  `name=` (subagent display names — arbitrary vendor text, not a path) and the `raw=`
  policy itself (up to 400 chars of prompt/tool text).
- Apply per-tenant policy uniformly to `name=`, `raw=` and `reason=`: keep, truncate
  or drop — but the same choice in the parsed field and in the raw line, or a redacted
  field sits next to its unredacted twin.

## Storage and volume

- **Its own dataset in the log store** (settled). Hook logs are client-side diagnostics, not the
  security signal — what they add over `/hooks/<agent>` is transport failures plus
  outcomes the API never sees (a local alert, a failed enrichment, an unresolved
  subagent), not a second copy of the event stream.
- Volume is tiny: a busy machine is single-digit KB a day. Do not build streaming.
- **Duplicates are acceptable** (settled). Neither client dedups; a crash between
  "chunk accepted" and "state written" re-sends that range by design, because
  duplicating is recoverable and skipping is not. Collapse on
  `(log_source_id, log_file, ts, raw)` at query time if it ever matters.

## Definition of done for Part 1

- [ ] Route registered in the AIDR hooks router, authenticating `x-rogue-api-key`.
- [ ] Body limit above ~5.6 MiB.
- [ ] `log_source` resolve-or-create, random id, four-part key, `anon` handled.
- [ ] Per-line parse keyed on `provider=`, envelope `agent_family` as fallback only.
- [ ] Redaction over parsed fields **and** `raw`.
- [ ] Awaited ingest; 5xx on any failure, including misconfiguration.
- [ ] A test that a failed ingest returns non-2xx (the offset contract in one assert).
- [ ] Then, in this repo: flip the three defaults, re-run
      `scripts/sync-shared-scripts.sh`, release.

---

# Part 2 — the log-upload task (endpoint agent)

Capability B. **Independent of Part 1 and of the plugin** — it needs nothing from
either and neither needs it, so it can be built in any order. Full context in
[log-shipping.md](log-shipping.md) §"Phase 3"; this is the checklist.

Its distinct value over the plugin shipper is the reason to build it at all: it is
**pulled on demand** rather than pushed on a session that may not happen for days, it
uploads the **whole file** rather than the tail past an offset, and it carries a real
`machine_id`.

- A new task worker module, registered in
  the task registry, with a new task type added to its enum.
  `#[serde(other)] Unknown` already covers older agents, so an older install reports
  `unsupported` instead of breaking.
- **File resolution must match the dispatchers**, or the agent reads a path nothing
  writes to: `ROGUE_LOG_FILE` (an exact path, and it **takes precedence** over the
  glob — in that configuration the six default names do not exist), else
  `ROGUE_LOG_DIR`, else `~/.rogue/logs/` (`%USERPROFILE%\.rogue\logs\`), all from the
  shared env-file chain including the MDM files. Then glob
  `{claude,codex,cursor,gemini,copilot,antigravity}.log` plus each `.1`, shipping `.1`
  **before** its live file so the batch stays chronological.
- Optional narrowing payload: `agents[]`, `since`, `max_bytes` (oldest lines dropped
  first).
- Reuse the existing `LogShipRequest` and `/api/v1/endpoint/logs` rather than adding a
  third log path. **Batching is mandatory, and `max_bytes` does not cover it:**
  the existing endpoint-log upload schema caps `records` at **1000 items**, and a 5 MiB hook log is ~65k
  lines, so a single-request upload is rejected outright. Batch by record count as
  well as bytes.
- Reuse `redact::redact_home_path` and `redact_pii_in_text` from `log_ship/`. Do
  **not** reuse `capture.rs`/`shipper.rs`: that is a `tracing` subscriber with an
  in-memory ring and a 60 s flush loop — the wrong shape for reading files on demand.
- **Never touch the live log**: read-only, no truncation, **and no offset file**. The
  plugin shipper owns `~/.rogue/ship/`, and a second writer there would make both lose
  lines.
- Status flow `Running → Uploaded → Succeeded`. A missing log directory is **success
  with zero records** (the common case is a machine with no coding agent installed);
  only an unreadable-but-present file or a failed POST is `AgentFailed`. And do not
  report `Succeeded` while `/endpoint/logs` still returns 200 on a dropped ingest —
  either fix the route as in Part 1 or report "submitted".

## Still open

- Should a log-upload assignment be creatable from the dashboard (support
  clicks "collect logs" on a machine), or only by internal tooling? That decides
  whether Part 2 needs UI work at all.
- **The shared env-file chain is sourced with no ownership or permission check** — in
  all eleven dispatchers, all six heartbeats, both auto-updaters and both shippers
  (`[ -r /etc/rogue/env ] && . /etc/rogue/env`). A world-writable `/etc/rogue/env`
  redirects `ROGUE_BASE_URL` and exfiltrates `ROGUE_API_KEY` plus every hook payload;
  on the sh side it is arbitrary code execution. Raised in review against the shipper
  and declined *there* on purpose: the shipper is the least valuable of those readers
  (a diagnostics log versus full prompts and tool calls), and a one-script check is a
  false sense of coverage. It wants its own PR — a `safe_source` helper in sh,
  PowerShell and Node, refusing world-writable and non-root-owned system paths, with
  tests. Not a blocker for either part here.
