# CLAUDE.md — Google Antigravity plugin

Guidance for working on `plugins/antigravity/`. The repo-root `CLAUDE.md` covers
the monorepo-wide conventions (dual dispatcher, env precedence, actor cascade,
release flow); this file covers what is **specific to Antigravity** and what has
been **verified against a real `agy` CLI session** (agy 1.1.7, macOS,
2026-07-26). Read it before editing `hooks.json` or either dispatcher — several
of Antigravity's behaviors differ from the documented contract.

## What this plugin is

A native Google Antigravity plugin giving the IDE (Antigravity 2.0) and the
`agy` CLI the same Rogue AIDR coverage as the Claude/Codex/Cursor/Gemini
plugins. It POSTs every lifecycle event to
`https://api.rogue.security/api/v1/hooks/antigravity` and relays the API's
native Antigravity decision shape verbatim.

- **Family** `antigravity`; **surfaces** `antigravity` (the 2.0 app),
  `antigravity_ide` (the IDE), `antigravity_cli` (the `agy` CLI). The API
  infers the surface from `transcriptPath`; the dispatchers derive the same value
  for the heartbeat, which has no payload of its own (see below).
- **Dual sh + PowerShell dispatcher**, NOT the Gemini single-Node model.
  Antigravity does not guarantee Node on PATH, so `hook.sh` (POSIX sh + curl)
  and `hook.ps1` (PowerShell 5.1-compatible) ship side by side and must be kept
  in lockstep.
- **PURE RELAY.** No block-detection regex, no local modal. The API returns the
  correct native shape per event; the dispatcher passes the body through.

## Layout

```
plugin.json          Antigravity manifest — $schema/name/description ONLY (no version key)
VERSION              version of record (1.0.23) — read by build-release.sh, heartbeat, /status
hooks.json           the five events, two handlers each (sh + powershell)
scripts/hook.sh      POSIX-sh dispatcher (macOS/Linux/WSL); stands down under Git Bash
scripts/hook.ps1     PowerShell dispatcher (native Windows); stands down on non-Windows
scripts/heartbeat.sh|.ps1   detached presence beacon, fired from the first PreInvocation
scripts/setup.sh|.ps1       write the shared ~/.rogue-env (mode 600)
scripts/actor.sh            actor cascade (env → git config --global → hostname/whoami)
rules/rogue.md       always-on agent rule (don't route around Rogue; rgx! usage)
skills/setup/        /setup — user-invoked, writes credentials
skills/status/       /status — read-only, model-invocable
```

`plugin.json` has **no `version` field** — Antigravity's plugin schema is
`additionalProperties: false` and allows only `$schema`, `name`, `description`.
That is why the version lives in `VERSION`. Do not "fix" this by adding
`version` to `plugin.json`; it will be rejected.

### The scripts are main-and-functions

Everything in `hook.sh`, `hook.ps1`, `heartbeat.sh`, `heartbeat.ps1` and
`resolve-runtime.sh` is a function. The only thing that runs at file scope is the
last line — `main "$@"` / `Invoke-Main` — so each flow reads as the pipeline it is
(the dispatchers: stand down → configure → read → enrich → post) instead of a few
hundred lines of interleaved statements, and the sh/ps1 pairs can be diffed
against each other step for step.

`setup.sh` / `setup.ps1` are deliberately left as they are: ~30 linear lines that
write `~/.rogue-env`, where a `main` wrapper would be ceremony around a script you
can already read at a glance. `actor.sh` is sourced, not run, so it has no entry
point by design; `db-prompt.mjs` already had a `main()`.

Three orderings inside `main` are load-bearing; keep them if you touch it:

1. **The stand-down runs first.** Git Bash (`hook.sh`) and non-Windows (`hook.ps1`)
   must emit nothing before any env sourcing, actor resolution or POST, or a
   machine running both handlers double-POSTs and double-decides.
2. **Env sourcing precedes every default derived from it.** `load_env` computes
   `ROGUE_LOG_DIR`, `ROGUE_LOG_FILE`, `ROGUE_LOG_MAX_BYTES`, `DB_PROMPT_MODE`,
   `MISS_DIR`, `BRAIN_DIR`, `SUBMAP_DIR` and the URL *after* reading the env
   files. Hoisting any of them back to file scope silently freezes the built-in
   default and ignores the user's `~/.rogue-env`. `hook.ps1` mirrors this: its
   `Invoke-Main` runs **`Import-Credentials` before `Initialize-Logging $script:creds`**
   so the same env files can relocate the log on Windows, and both still precede
   `Assert-ApiKey` so an unconfigured machine records `outcome=unconfigured`.
   Swapping those two back would silently ignore every env file. See the root
   `CLAUDE.md` section "The hook log".
3. **The API-key check precedes reading stdin.** An unconfigured machine exits
   without consuming the payload.

**PowerShell scoping is the trap in `hook.ps1`.** Reading a script variable from a
function is implicit, but *assigning* one needs the `$script:` prefix or the write
lands in a function-local copy and vanishes with no error — a silent
"the POST sent an unenriched body" class of bug. Every write to shared state
(`$payload`, `$subagentId`, `$apiKey`, `$url`, `$payloadTp`, …) is therefore
`$script:`-qualified, and `tests/test_hook_ps1_antigravity.ps1` fails the build if
one is not. `hook.ps1` also honours `ROGUE_PS_LIB_ONLY=1`, which loads the
functions without running the hook, so they can be exercised off-Windows.

## hooks.json — the shape is a trap (verified)

Antigravity's plugin `hooks.json` is keyed by a **plugin namespace** (`"rogue"`),
then by event name. The two event kinds take **different array shapes**:

```json
{
  "rogue": {
    "PreToolUse":  [ { "matcher": ".*", "hooks": [ <handler>, <handler> ] } ],
    "PostToolUse": [ { "matcher": ".*", "hooks": [ <handler>, <handler> ] } ],
    "PreInvocation":  [ <handler>, <handler> ],
    "PostInvocation": [ <handler>, <handler> ],
    "Stop":           [ <handler>, <handler> ]
  }
}
```

- **Matcher events** (`PreToolUse`, `PostToolUse`) take an array of
  `{ matcher, hooks: [...] }` groups.
- **Matcher-less events** (`PreInvocation`, `PostInvocation`, `Stop`) take a
  **flat array of handler objects**. Antigravity ignores `matcher` on these, and
  wrapping them in `{ "hooks": [...] }` is a hard **parse error**:

  ```
  Failed to parse hooks file .../rogue/hooks.json:
    invalid hook "rogue": command hook must specify 'command'
  ```

  The parse error is **fatal for the whole file** — all five events go dead and
  nothing is monitored, while the CLI keeps running normally. This bit us during
  CLI testing; that is why the flat form is now used.
  `tests/test_hooks_json_antigravity.sh` asserts the flat form for the three
  matcher-less events and passes — keep it that way if you touch the shape.

- A handler is `{ "type": "command", "command": "…", "timeout": 30 }`. `timeout`
  is in **seconds** (default 30 if omitted); the dispatchers' own HTTP timeout is
  15s so a slow request fails open *inside* the budget.

- **Loading is lazy.** The CLI logs `loaded 0 named hooks from 0 hooks.json
  file(s)` at startup and only then, on the first invocation of a session,
  `Loaded hooks.json from …/plugins/rogue/hooks.json: 1 named hooks, 10 total
  handlers`. Edits are picked up on the next session — no trust/review gate
  (unlike Codex and Gemini, Antigravity does **not** fingerprint hook commands),
  so command strings do not have to stay byte-stable. Keep them stable anyway,
  for parity with the other plugins.

- **cwd is the plugin root.** Both handlers are cwd-relative
  (`sh "./scripts/hook.sh"`, and `-LiteralPath 'scripts/hook.ps1'`), and
  `hook.ps1` receives `(Get-Location).Path` as its 2nd arg because
  `$PSCommandPath` is empty under `[scriptblock]::Create`. Confirmed working on
  the CLI — if the handler could not resolve, nothing would be logged at all.

- **No `; exit 0`** on the command strings, unlike every other plugin in this
  repo. The dispatchers self-`exit 0`, and Antigravity has no documented
  "visible hook error on non-zero exit" behavior. The observed cost of that
  choice is real, though: on macOS the PowerShell handler dies with
  `sh: powershell: command not found` → exit 127, and Antigravity logs an
  E-level failure for **every event, every turn**:

  ```
  E … pre-tool hook failed: JSON hook "jsonhook__rogue_PreToolUse_0_1" command failed:
      command failed: exit status 127, stderr: sh: powershell: command not found
  ```

  This is noise, not breakage: the `sh` handler still ran and its decision was
  used, and a failing handler does **not** block the tool (verified — the
  `run_command` under a failed `PreToolUse_0_1` executed normally, so Antigravity
  treats handler failure as fail-open). `curl -sS` also leaks its transport
  errors into the same log. If the noise becomes a support problem, the fix is
  to append `; exit 0` and update `test_hooks_json_antigravity.sh`, which
  currently *forbids* it.

## The five events

| Event | Enforcement | Native response the API returns |
|---|---|---|
| `PreToolUse` | **deny** — the only surface that stops an action from happening | `{"decision":"allow"}` / `{"decision":"deny","reason":R}` |
| `PostToolUse` | audit-only — **output is ignored by Antigravity** (verified) | `{}` |
| `PreInvocation` | **soft** block — injects a refusal instruction; cannot deny or terminate (both verified ignored) | `{}` / `{"injectSteps":[{"userMessage":"[Rogue Security AIDR] This request was BLOCKED …"}]}` |
| `PostInvocation` | **terminate the agent loop** — the enforcement point for both model prose and tool output | `{}` / `{"terminationBehavior":"terminate","injectSteps":[{"userMessage":…}]}` |
| `Stop` | audit-only (contract allows `decision:"continue"`; unused) | `{}` |

### `injectSteps`: use `userMessage`, NEVER `ephemeralMessage`

The hook docs list `toolCall`, `userMessage`, and `ephemeralMessage` as
`injectSteps` types. On agy 1.1.7 **`ephemeralMessage` is a silent no-op** —
injecting one that ordered the model to prefix its reply with a token changed
nothing, while the byte-identical `userMessage` produced the token. Neither type
is written to the transcript (the step index is allocated and skipped), so an
injected step can't be used as a marker either.

This shipped as a real bug: a flagged prompt returned an `ephemeralMessage`, so
it produced **no enforcement at all** — neither the model nor the user ever saw
it, even though the finding was recorded and the UI showed it blocked.

One exception, on the backend side: for `antigravity_ide` `PreInvocation` the
formatter injects the undocumented fourth arm, `systemMessage`, because on IDE
2.1.1 `userMessage` gets talked past while `systemMessage` actually makes the
model refuse (see `blockSystemMessage` in `antigravity-hook-formatter.ts`). 2.0
and the CLI still use `userMessage`. `ephemeralMessage` remains never-use.

### What a flagged *prompt* can and cannot do

`PreInvocation` is the only event that fires before the model call, and it cannot
stop it: `decision:"deny"` and `terminationBehavior` were both verified to be
ignored there (the prompt reached the model unchanged in each case). There is no
Antigravity equivalent of Claude Code's blocking `UserPromptSubmit`.

So prompt enforcement is layered, and the hard gate is downstream:

1. `PreInvocation` injects a `userMessage` instructing the agent that the request
   is blocked, must not be carried out or worked around, and that no tool may be
   called for it. Verified end-to-end: the agent refuses, quotes the reason and
   the `rgx!` hint, and calls no tool.
2. `PreToolUse` **hard-denies** anything it still attempts. Verified: Antigravity
   surfaces the deny reason to the user and the tool does not run.
3. `PostInvocation` terminates the loop if the model's own output is flagged.

Step 1 is model compliance, not a guarantee — which is why step 2 exists. Note
also that `terminate` stops *continuation*: it cannot retract a reply the model
has already streamed.

`decision` is **required** on `PreToolUse` — a bare `{}` there is ambiguous, so
`fail_open_default` / `Get-FailOpenDefault` emits `{"decision":"allow"}` for
`PreToolUse` and `{}` for everything else. Antigravity's contract also defines
`ask` / `force_ask` decisions and `permissionOverrides` on `PreToolUse`, and
`decision:"continue"` on `Stop` (to *prevent* termination) — the plugin uses
none of them.

**Observed firing order (real CLI turn, one user prompt, one shell command):**

```
PreInvocation → PostToolUse → PreToolUse → PostToolUse → PostInvocation
              → PreInvocation → PostToolUse → PostInvocation → Stop
```

Consequences worth knowing before you reason about payloads:

- **`PreInvocation`/`PostInvocation` fire once per *model invocation*, not per
  user prompt** — two pairs for a single prompt above. Do not treat
  `PreInvocation` as "user submitted a prompt".
- **`PostToolUse` is not paired 1:1 with `PreToolUse`.** It fires at the start of
  every turn with no preceding `PreToolUse`, and sometimes *after* `Stop` —
  Antigravity emits it for internal steps too.
- **`Stop` is per agent run, not per session** (the payload carries
  `executionNum`), and two consecutive `Stop`s have been observed in one
  session. The README's "end of session" wording is imprecise.

**Payload fields (captured live from agy 1.1.7, macOS, 2026-07-26):** common —
`conversationId`, `workspacePaths` (often `[]` on the CLI),
`transcriptPath`, `artifactDirectoryPath`, **`modelName`** (e.g.
`gemini-3.6-flash-high`); `PreToolUse` — `toolCall {name, args}`, `stepIdx`;
`PostToolUse` — `toolCall`, `stepIdx`, `error` (`""` when fine);
`Pre/PostInvocation` — `invocationNum`, `initialNumSteps`; `Stop` —
`executionNum`, `terminationReason` (e.g. `NO_TOOL_CALL`), `error`, `fullyIdle`.
Field names are camelCase. Notes that bit us:

- **There is NO `timestamp` field on any event.** Message times must come from
  the transcript rows' `created_at`, or everything lands at server-receive time.
- **`toolCall` is `null`** on the `PostToolUse` (and matching `PreToolUse`)
  events Antigravity emits for internal steps — don't assume an object.
- **`toolCall.args` keys are PascalCase and per-tool**, with real typed values
  (no JSON string double-encoding — that quirk applies to neither the payload
  nor `transcript_full.jsonl`): `run_command` → `CommandLine`, `Cwd`,
  `WaitMsBeforeAsync`; `view_file` → `AbsolutePath`; `list_dir` →
  `DirectoryPath`. `PostToolUse` additionally echoes display-only
  `toolAction` / `toolSummary` keys that `PreToolUse` lacks, so the same tool
  call is NOT byte-identical across the pair.
- **`PostToolUse` carries no tool result** — only `error` and the echoed
  `toolCall`. The result text exists only in the transcript, at the row whose
  `step_index` equals the payload's `stepIdx` (see below). When a call fails
  before executing, no row is written at all and `error` is the only record.
- **`initialNumSteps` is the step count at invocation start**, which makes it an
  exact watermark: the rows a given invocation appended are
  `step_index >= initialNumSteps`, and the prompt that triggered it (when there
  is one) is the last row *below* that boundary. The backend parser keys its
  dedup off this — see `antigravity-hook-parser.ts`.
- **`invocationNum` resets to 0 on every new user turn**, not once per
  conversation (verified with `agy -c`: same `conversationId`, `invocationNum`
  back to 0, `initialNumSteps` continuing at 18). So does `executionNum`.

## Transcript-tail enrichment

**No event carries message content inline.** `PreInvocation`, `PostInvocation`,
and `Stop` name only a `transcriptPath`. Both dispatchers therefore tail the last
~256 KB of that file, base64-encode it, and append it to the POST body as
`"transcriptTailB64"` (base64 has no JSON-special characters, so re-closing the
object by hand is safe). Fail-open at every step: no path, unreadable, or empty →
body unchanged. This is the **only** stdin mutation the plugin makes.

Neither tool event is enriched. `PreToolUse` doesn't need it (the args are inline
and the result row doesn't exist yet), and `PostToolUse` **can't use it** — see
the enforcement section below.

What the backend takes from the tail, per event (see
`antigravity-hook-parser.ts`):

| Event | Extracted | How it's bounded |
|---|---|---|
| `PreInvocation` | the pending user prompt → `role:"user"` | last row *below* `initialNumSteps` |
| `PostInvocation` | the model's prose → `role:"assistant"` **and** the invocation's tool results → `role:"tool"` | rows *at/above* `initialNumSteps`, stopping at the next `USER_INPUT` |
| `Stop` | nothing | — |

The base64 blob is **never stored**: the parser replaces it in `rawPayload` with
a `transcript` array holding the decoded rows that event derived from (long
`content`/`thinking`/`error` strings clipped at 8 KB, 40 rows max). The evaluated
copy — the canonical message — is never clipped.

### Tool output must be evaluated on `PostInvocation`

`PostToolUse` looks like the natural home for tool results, and its payload even
gives an exact pointer to them (`stepIdx` is the step of the RESULT row —
verified: `stepIdx` 3 → the `LIST_DIRECTORY` row at step 3, whose call was
recorded at step 2). **Don't put them there.** Antigravity's `PostToolUse`
contract accepts only `{}`, and a live probe returning
`{"decision":"deny","injectSteps":[…],"terminationBehavior":"terminate"}` from
that event was ignored on all three counts — the tool output reached the model
anyway. Flagging it there marks the event "blocked" in the audit log while the
content still lands in the model's context, which is worse than not flagging it.

`PostInvocation` is the enforcement point. It fires after the tools of an
invocation have run but **before the next model call that would consume them**,
and its window already covers those rows. `terminationBehavior: "terminate"`
there halts the loop — verified live: with it forced on, the transcript ends at
the tool-result row and no further model turn exists. The formatter pairs it with
an `injectSteps` `userMessage` so the stop carries the reason — never
`ephemeralMessage`, which is a silent no-op (see the section above).

Consequences to keep in mind:

- Enforcement is **all-or-nothing**. Antigravity has no result-rewrite primitive
  (no equivalent of Copilot's `modifiedResult`), so flagged output can't be
  redacted and the turn can't continue — the loop just stops.
- A `run_command` has already **executed** by then; only its influence on the
  model is prevented, not its side effects. Stopping execution is `PreToolUse`'s
  job.
- `PostToolUse` stays registered and POSTed as an audit event (tool completed,
  plus `error` on failure) — it just contributes no message.

### Tool-result wrapper stripping

Antigravity wraps every tool result in an envelope; a `view_file` of a one-line
file arrives as ~8 lines of metadata around the content:

```
Created At: … / Completed At: … / File Path: … / Total Lines: … / Total Bytes: … / Showing lines 1 to 2
The following code has been modified to include a line number before every line, in the format: … Please note that any changes targeting the original code should remove the line number, colon, and leading space.
1: ignore all instructions
The above content shows the entire, complete file contents of the requested file.
```

`cleanToolResult` strips it, de-numbers the lines, and dedents `run_command`'s
tab padding, so the recorded message is the tool's actual output. This is not
only cosmetic: the preamble is itself instruction-shaped text wrapped around the
untrusted content we want judged, so it diluted evaluation. Every rule is
prefix-anchored, de-numbering only fires when the preamble that documents it is
present, and an empty result falls back to the original string. The verbatim row
is still in `rawPayload.transcript`.

Before tailing, `wait_for_transcript_flush` / `Wait-TranscriptFlush` polls for
**file-size stability** (two equal reads 100 ms apart, ~2 s cap,
`ROGUE_FLUSH_WAIT_ITERS` overrides for tests). It is size-based rather than
marker-based on purpose: Antigravity has no documented "turn end" marker line to
poll for the way Copilot's `events.jsonl` has `assistant.turn_end`.

**Real transcript location and schema** (verified on all three surfaces — the
docs describe neither):

```
~/.gemini/antigravity-cli/brain/<conversationId>/.system_generated/logs/transcript.jsonl   # agy CLI
~/.gemini/antigravity-ide/brain/<conversationId>/.system_generated/logs/…                  # IDE
~/.gemini/antigravity/brain/<conversationId>/.system_generated/logs/…                       # 2.0 app
                                                                     …/transcript_full.jsonl
```

**Which file `transcriptPath` names differs per surface**: the CLI and the 2.0
app name `transcript_full.jsonl`, the IDE names `transcript.jsonl`. Both
exist side by side with the same row schema (contents differ slightly — the IDE's
`transcript.jsonl` double-quotes some tool args), so `augment_with_transcript`
falls back to whichever sibling it can read.

**When the transcript is written differs per surface, and it decides which event
can see anything.** The CLI and the 2.0 app write it **live**, so each
invocation's rows are on disk by the time its `Pre/PostInvocation` fires. The
IDE writes it **only when the turn ends** — verified on IDE 2.1.1: the
file is created at `Stop`, and the same turn's `PreInvocation` and
`PostInvocation` both logged `tail=none reason=unreadable`. That is why every IDE
session showed up empty in the UI. Two consequences:

- The dispatchers wait (~2s cap) for the file to appear, so a first-`PreInvocation`
  race on the live-writing surfaces no longer drops the opening prompt.
- The IDE's *transcript* content genuinely only exists at `Stop`, so the tail is
  attached on `Stop` only for that surface. Attaching it on `Pre/PostInvocation`
  could never carry more than the previous turn, and waiting for the current one
  is impossible — measured: the file appears ~4s later, at `Stop`.

### The IDE prompt gate: `db-prompt.mjs`

The pending prompt is not in the transcript at `PreInvocation`, but it IS already
committed to Antigravity's own conversation store, so on **`antigravity_ide` only**
the dispatcher reads it there and appends it for the backend to evaluate:

```
<stateDir>/conversations/<conversationId>.db     SQLite, WAL mode, same schema on all 3 products
steps(idx PRIMARY KEY, step_type, status, step_format, step_payload BLOB, …)
  step_type 14 = USER_INPUT;  idx == the transcript's step_index
  step_payload is protobuf: [5.3] = source (4 USER_EXPLICIT, 6 = OUR OWN injection)
                            [19.2] = the prompt text, BARE (no <USER_REQUEST> wrapper)
```

Selection rule: the highest `step_type = 14`, `source = 4` row with
`idx < initialNumSteps`. Deliberately not `idx == initialNumSteps - 1` — on a
tool-loop continuation that index is a tool result, and bookkeeping rows can land
below the boundary too. Re-reads within a turn are suppressed by an idx cache
(`~/.rogue/antigravity-dbprompt/<conversationId>`), which is also what stops us
reading back our own injected block message.

**Runtime: nothing is installed.** The reader needs `node:sqlite` (Node ≥ 22.13).
`resolve-runtime.sh` probes candidates *by executing them* — never by version
string — and caches the answer: `$ROGUE_ANTIGRAVITY_NODE`, then the cache, then
**the IDE's own Electron** (discovered from `<stateDir>/bin/agentapi`, which execs
the language server inside the app bundle), then Antigravity 2.0's `agy-node`,
then system `node`. Measured on macOS: the IDE ships Electron 39 / Node 22.21.1
with `node:sqlite`, while the developer's own Node 20 does **not** — which is why
the bundled runtime ranks above PATH. Nothing found ⇒ a `none` sentinel is cached,
the gate is inactive, and everything else is unaffected.

Open with `?mode=ro`, **never `immutable=1`** — immutable ignores the WAL and the
pending prompt is WAL-only at `PreInvocation` (measured), so an immutable read
returns an empty table on exactly the turns that matter. One honest caveat: a WAL
reader takes a read lock, which writes read-mark slots into the `-shm` sidecar.
The main `.db` is never written, never checkpointed, never opened read-write.

Payload contract, all escaping-free so they can be appended by re-closing the
JSON object (the `transcriptTailB64` technique): `rogueDbPromptB64` (base64 of a
`{v:1, idx, stepType, status, stepFormat, source, userVersion, text, readMs,
walBytes, runtime}` envelope) and `rogueDbPromptCapable: true`, which is sent even
on a miss so the backend knows whether `Stop` still needs to carry the prompt.

`db-prompt.mjs` is a **pure reader**: its entire stdout vocabulary is
base64-or-nothing, the shell validates that charset, and only the shell writes
JSON — so a crash in the reader can never become a hook decision. Kill switches:
`ROGUE_ANTIGRAVITY_DB_PROMPT=0` (never read) and `=log` (read and log, never
attach), both from `~/.rogue-env` or `/etc/rogue/env`, no reinstall needed.

### A failed read is not an empty turn (`rogueDb*Missed`)

`rogueDbPromptCapable` describes the **machine**, and the backend reads it on
`Stop` as "this turn already arrived, don't re-emit the tail". Empty reader output
alone cannot justify that: a turn's second and later `PreInvocation` genuinely has
no new prompt (18 of 22 misses on a real machine were exactly that), while a locked
DB, schema drift, a blown deadline or the `=log` mode means the content exists and
we never delivered it. Reporting the second case as delivered lost the whole turn
silently, with the transcript tail in hand.

So health rides the reader's **exit status**, keeping the stdout invariant intact:

| Exit | Meaning | Dispatcher does |
|---|---|---|
| 0 | store was read (emitted, or genuinely nothing new) | nothing extra |
| 3 | could not read it (missing/locked DB, drift, deadline, unparseable input) | writes a per-conversation marker |

`Stop` consumes any marker it finds and reports `rogueDbPromptMissed` /
`rogueDbStepsMissed`, and the backend rebuilds **only** those halves from the tail
(`antigravity-hook-parser.ts`, the `Stop` branch) — so a partial failure never
duplicates the half that did arrive. Markers live next to the high-water cache
(`ROGUE_ANTIGRAVITY_DBPROMPT_DIR`, default `~/.rogue/antigravity-dbprompt`) as
`<conversationId>.missed-{prompt,steps}`. Absent markers mean "delivered", so an
older backend that ignores these fields behaves exactly as before. A crash before
`Stop` leaves a marker behind, which costs the next turn a duplicated message
rather than a lost one — the safe direction.

**The store is undocumented** — one CLI changelog line (v1.0.4, 2026-06-06) is its
only public acknowledgement, and the language server ships roughly monthly. So
`stepFormat`/`userVersion` travel with every hit as drift markers, every failure
path fails open, and the hook logs `dbprompt=hit|miss|none` with lengths and
timings but **never the prompt text**.

One JSON object per line, with these keys:

| Key | Values seen |
|---|---|
| `source` | `USER_EXPLICIT`, `MODEL`, `SYSTEM` |
| `type` | `USER_INPUT`, `PLANNER_RESPONSE`, `GENERIC`, `LIST_DIRECTORY`, `RUN_COMMAND`, `CONVERSATION_HISTORY`, `CHECKPOINT`, `SYSTEM_MESSAGE`, `ERROR_MESSAGE` |
| `content` | string or absent — user text arrives wrapped in `<USER_REQUEST>…</USER_REQUEST>` plus `<ADDITIONAL_METADATA>` / `<USER_SETTINGS_CHANGE>` blocks |
| `thinking` | reasoning text on `MODEL`/`PLANNER_RESPONSE` lines; often present with `tool_calls` and no `content` |
| `tool_calls` | array of `{name, args}` on `MODEL`/`PLANNER_RESPONSE` lines. `args` are **real typed objects**, e.g. `{"name":"run_command","args":{"CommandLine":"echo hi","Cwd":"/…","WaitMsBeforeAsync":5000}}` |
| `created_at`, `step_index`, `status` (`DONE`), `error` (on `ERROR_MESSAGE`) | |

Three things about this schema are load-bearing, and the first one shipped a bug
(the backend parser was written against an invented `{role, content}` shape and
therefore never found a single assistant reply — FIRE-1828 follow-up):

- **There is no `role` key** and no `assistant` literal anywhere. The model's own
  prose is `source:"MODEL"` + `type:"PLANNER_RESPONSE"`; the user's prompt is
  `source:"USER_EXPLICIT"` + `type:"USER_INPUT"`.
- **`source:"MODEL"` with any other `type`** (`GENERIC`, `LIST_DIRECTORY`,
  `RUN_COMMAND`, …) is a tool **result**, not model prose. Matching on `source`
  alone sweeps every tool output in as an assistant message.
- **`step_index` has gaps.** A step can be allocated (and show up as a
  `stepIdx` on a tool event) without a transcript row ever being written, so
  never anchor on an exact index — use "the last row below the boundary".
- **Rows are NOT appended in `step_index` order.** A verified tail held steps
  `0, 1, 3, 2, 4`: the `list_dir` result (step 3) was flushed before the
  `PLANNER_RESPONSE` that requested it (step 2). Anything reasoning about "the
  last row" must sort by `step_index` first.

All three surfaces write the same row schema (verified against live
`antigravity`, `antigravity-ide` and `antigravity-cli` transcripts), so the
parser is surface-agnostic. Two payload differences worth knowing: the IDE
sends **no `modelName`** at all, and it fires `PostToolUse` for internal steps
that never had a `PreToolUse`.

## Subagents

Antigravity subagents are created with `define_subagent` (declares a type: name,
description, `system_prompt`) and launched with `invoke_subagent` (an array of
`{TypeName, Role, Prompt, Model}`). Verified behaviour, agy 1.1.7:

- **Each subagent is a full, separate conversation** with its own
  `conversationId`, its own `brain/<id>/` directory and transcript, and it fires
  the **complete hook set** — `PreInvocation`, `PreToolUse`, `PostToolUse`,
  `PostInvocation`, `Stop`. So subagent prompts, turns and tool calls are already
  POSTed and evaluated: a subagent's dangerous tool call is denied by its own
  `PreToolUse` exactly like the main agent's.
- **The payload carries NO parent reference.** The union of every key across 34
  captured events of a subagent session is exactly the normal set
  (`conversationId`, `workspacePaths`, `transcriptPath`,
  `artifactDirectoryPath`, `modelName`, `initialNumSteps`, `invocationNum`,
  `stepIdx`, `toolCall`, `error`, `executionNum`, `terminationReason`,
  `fullyIdle`) — there is no `parentConversationId`, no `agentId`, no role name.
  Consequence: unmodified, `sessionId = conversationId` would file each subagent
  as its **own audit session**, so its turns would never appear under the
  parent's. That is what `reattribute_subagent` fixes — see below.
- **The subagent reports back via `send_message`**, which lands in the PARENT's
  transcript as a `SYSTEM`/`SYSTEM_MESSAGE` row:
  `[Message] timestamp=… sender=<subagent conversationId> priority=… content=<payload>`.
  The parser detects that shape (`subagentSender`), records it as a
  `role:"tool"` message with `tool_call_id` set to the sender's conversation id,
  and evaluates it — this is untrusted content crossing an agent boundary into
  the parent's context, the same threat class as tool output. Generic
  `SYSTEM_MESSAGE` rows (no `[Message] … sender=`) stay excluded as bookkeeping.
- **The `invoke_subagent` result row lists the spawned ids** (and their
  `logAbsoluteUri`), in the same order as the `Subagents` array of the invoking
  call — so `Role`/`TypeName` can be correlated positionally. That row is
  captured as a normal tool result, so the parent session records which
  subagents it spawned.

### Re-attribution (`reattribute_subagent`, both dispatchers)

Because the payload has no parent field, the dispatchers resolve it from disk and
rewrite the body — the **second of the plugin's two stdin mutations**:

1. Read `conversationId` from the body.
2. Look it up in `~/.rogue/antigravity-submap/<id>` (override:
   `ROGUE_ANTIGRAVITY_SUBMAP_DIR`).
3. On a cache miss, scan `brain/*/.system_generated/logs/transcript_full.jsonl`
   for an `INVOKE_SUBAGENT` row naming this id; **the parent conversation id IS
   that transcript's directory name**. The brain dir is taken from this event's
   own `transcriptPath` (a subagent runs on the surface that spawned it), so the
   scan follows the surface instead of assuming the CLI's dir; override with
   `ROGUE_ANTIGRAVITY_BRAIN_DIR`.
4. On a hit: rewrite the body's `conversationId` to the parent and send the agent
   tag as **headers** — `x-rogue-agent-id` and `x-rogue-agent-name-b64` (base64,
   so an arbitrary `Role` with accents or emoji cannot produce an invalid header
   value). Both are **omitted entirely** — never sent empty — on main-agent events.
   The backend reads them in `handleAntigravity` and stamps every canonical
   message, which is what lands in the `aidr_message.agent_id` / `agent_name`
   columns.

   **Headers, not body fields, on purpose.** The POSTed event must stay
   byte-identical to what Antigravity handed us, so the stored `rawPayload` is the
   vendor's own event and nothing we synthesised — the backend strips the two
   store blobs and the capability flag for the same reason. Copilot puts its tag
   in the body (`agentId` / `agentNameB64`); that divergence is known and
   accepted here, so do not "align" the two without being asked. Note the one
   remaining body mutation: `conversationId` is rewritten so a subagent's events
   nest under the parent session, which is the whole point of re-attribution.

Load-bearing details:

- **No flush retry is needed.** The `INVOKE_SUBAGENT` row is written when the
  tool completes, i.e. before the subagent's first hook can fire. Verified live:
  both subagents resolved on their very first `PreInvocation`.
- **The verdict is cached BOTH ways**, including a `main` marker for ordinary
  conversations. Unlike Copilot (whose subagent ids are `toolu_…`/`call_…`, and
  so cheap to reject), an Antigravity subagent id is an ordinary UUID — nothing
  in the payload says whether a lookup is worthwhile. Without the negative cache
  every conversation would re-scan on all ~18 events of every turn; with it,
  one ~25 ms scan per conversation.
- **The id match must be restricted to `INVOKE_SUBAGENT` rows.** A conversation
  id also appears inside *other* conversations' `CONVERSATION_HISTORY` summaries;
  matching those would invent a parent. (`tests/test_hook_sh_antigravity.sh`
  covers this.)
- **Ids inside that row are backslash-escaped** (they live in the row's
  JSON-*string* `content`), so match the bare UUID, never a quoted one.
- **Re-attribution runs BEFORE `augment_with_transcript`**, which re-closes the
  JSON object by hand — mutating `conversationId` afterwards would have to skip
  past the appended base64 blob.
- **Fail-open**: unresolved → body untouched (the orphaned behaviour, never
  worse).

Display name, in priority order:

| Source | Available | Contents |
|---|---|---|
| parent's `invoke_subagent` args `Role` | at spawn — so it covers a subagent's earliest events | `"Cat Rhymer"`. The `INVOKE_SUBAGENT` result row lists ids in the **same order** as the `Subagents` array (verified: the 1st id's own prompt is the 1st `Prompt`), so the name is the Nth `Role` for the id at position N |
| parent's `.system_generated/messages/<uuid>.json` | only once the subagent replies | `sender`, `recipient`, `content`, and `renderDetails.messageTitle` (e.g. `Message from Cat Rhymer (rhymer)`), used as the fallback with the `Message from ` prefix stripped |

Positional naming misaligns if one conversation makes **two** `invoke_subagent`
calls, because the two lists are read in file order and file order is not step
order. That degrades only the display name — `agentId` is always
exact.

## Heartbeat

Fired **detached from every `PreInvocation` with `invocationNum == 0`** —
Antigravity has no `SessionStart` event, so this is the closest analogue.
Note this is **once per user turn, not once per session**: `invocationNum` was
verified to reset to 0 on each new prompt in the same conversation, so a
10-prompt session sends 10 heartbeats. Harmless (the beacon is an idempotent
upsert keyed host+actor+family+agent) but chattier than intended; gating on
`invocationNum == 0 && initialNumSteps <= 1` would make it truly per-session. `heartbeat.sh` POSTs `/api/v1/hooks/status` with
`agent_family:"antigravity"`, `version` from `VERSION`, host, and actor fields.
Surface is **passed in by the dispatcher** (`heartbeat.sh <surface>` /
`heartbeat.ps1 -Agent <surface>`), read off the triggering event's
`transcriptPath` — the only reliable source, since one install at
`~/.gemini/config/plugins/rogue` serves all three products. The old
environment-sniffing inference survives only as a fallback for a manual run
(default `antigravity`, flipped to `antigravity_cli` when `agy` is on PATH or
`~/.gemini/antigravity-cli` exists); it cannot tell co-installed surfaces apart,
which collapsed every surface into one `antigravity_cli` roster row.
There is **no auto-update script** —
Antigravity upgrades by re-running the one-line installer.

## Exactly-one-runs

Both handlers are registered for every event, and Antigravity runs both
(they appear in its logs as `jsonhook__rogue_<Event>_<group>_<handler>`). The
stand-downs keep exactly one contributing a decision:

| Environment | `sh` handler | PowerShell handler |
|---|---|---|
| macOS / Linux / WSL | runs (curl POST) | `powershell` missing → exit 127, logged, ignored |
| native Windows | `uname` = MINGW/MSYS/CYGWIN → **emits nothing**, exits 0 | runs |

The Git Bash stand-down emits **empty stdout**, not `{}` like the Claude plugin.
That is deliberate: a `{}` from the standing-down handler could be merged with
the active handler's `{"decision":"deny"}` on the same invocation. `hook.ps1`
mirrors this — it emits nothing on non-Windows pwsh. `ROGUE_FORCE_UNAME`
overrides `uname` for tests.

## Install / distribution

Hybrid **copy + CLI**, driven by `antigravity_install_plugin` in `install.sh`:

- Always copies the plugin tree into **`~/.gemini/config/plugins/rogue`**. This
  is the directory both surfaces actually read (verified: the CLI loads
  `hooks.json` from there). Antigravity's docs claim
  `~/.gemini/antigravity-cli/plugins/<name>/`; agy 1.1.7 uses the shared
  `~/.gemini/config/` customization dir instead and leaves a `.migrated` marker.
- When `agy` is on PATH, **also** runs `agy plugin uninstall` then
  `agy plugin install <src>` for native registration (records the plugin in
  `~/.gemini/config/import_manifest.json`, which is what `agy plugin list`
  prints — components `["skills","hooks"]`).
- Falls back to a manual copy into `~/.gemini/antigravity-cli/plugins/rogue` if
  that directory exists but `agy` does not.
- Detection is `have_cmd agy || [ -d ~/.gemini/antigravity* ]` — there is no
  `antigravity` binary on PATH.
- `build-release.sh` stages `rogue-plugin-antigravity.tar.gz` whose **top
  directory IS the plugin** (manifest at its root), like the Gemini tarball, so
  `agy plugin install <extracted-dir>` works directly.

Install is soft-failing: a failed Antigravity install must not abort the
multi-agent installer run.

## Tests

```sh
sh tests/test_hook_sh_antigravity.sh      # passes — dispatcher behavior under dash
sh tests/test_hooks_json_antigravity.sh   # FAILS today (asserts the pre-fix nested shape)
```

`test_hook_sh_antigravity.sh` covers the invariants worth protecting: per-event
fail-open defaults, always-exit-0, empty stdout on Git Bash stand-down,
heartbeat only on `invocationNum:0`, transcript enrichment on the three
content-less events and *not* on `PreToolUse`, and that the base64 round-trips.

## Things that look weird but are intentional

- `plugin.json` with no version, version in `VERSION` — the schema forbids it.
- Matcher-less events use a flat handler array while matcher events nest under
  `hooks` — Antigravity's parser requires exactly this.
- No `; exit 0` on command strings (see the noise caveat above).
- Git Bash / non-Windows stand-down emits **nothing**, not `{}`.
- `PreToolUse` fails open to `{"decision":"allow"}`, never `{}`.
- Heartbeat rides `PreInvocation` `invocationNum == 0` — there is no
  `SessionStart` event.

## Open items

- Assistant `thinking` text is dropped. It is audit-only (never evaluated), and
  emitting it would move the finding anchor (`previousMessageCount`) off the
  actual reply, so it was left out.
- **A tool result larger than the 256 KB tail is lost.** Its transcript row
  exceeds the byte slice, so the truncated line fails to parse and is dropped —
  a big file read or verbose command silently yields no `role:"tool"` message
  and is never evaluated. Seeking to the rows instead of blind-tailing would fix
  it.
- **`PreToolUse.overwrite` is unused.** The contract lets a hook merge
  replacement values into a tool call's args before it runs (e.g. rewrite
  `CommandLine`). That is the only lever for *sanitizing* rather than denying a
  call, and the natural way to neutralize a dangerous command without killing
  the turn.
- **A flagged prompt has no hard gate** (see above) — the injected refusal relies
  on model compliance. Making it enforceable needs the prompt's verdict to reach
  a later event that *can* act: a per-session "pending block" flag (the
  `overrideWindowActive` rgx!-window is the existing precedent for such sticky
  state, so the plumbing exists) would let the next `PostInvocation` terminate,
  or let every `PreToolUse` in that turn deny. Both need a schema migration, so
  neither is implemented.
- Pre-scanning read targets at `PreToolUse` (the plugin reads the file named by
  `AbsolutePath` and sends it for evaluation) would let a poisoned file be
  blocked *before* it enters context, instead of relying on loop termination
  after the read. Only viable for read-type tools — `run_command` output can't
  be known in advance.
- **Subagent re-attribution depends on the `aidr_message.agent_id` /
  `agent_name` columns**, which landed with the Copilot work (qualifire #1814,
  migration `20260803103612_aidr_message_occurred_at_agent.sql`, plus
  `CanonicalMessage.agentId`/`agentName` and the promotion in
  `aidr-transcript-dao.ts`). Those columns are vendor-agnostic, but the WIRE is
  not: Copilot's parser reads body fields, so Antigravity's headers are read in
  `handleAntigravity` instead. Nothing displays the columns yet — no tRPC router
  or component selects them — so attribution is stored and queryable, not visible.
- The subagent's *delivered result* in the parent (the `SYSTEM_MESSAGE` row) is
  currently tagged with the sender id via `tool_call_id`. Once the columns exist
  it should carry `subagentId`/`subagentName` too, so the parent's copy of a
  reply is attributed the same way as the subagent's own rows.
- `~/.rogue/antigravity-submap/` grows one small file per conversation and is
  never pruned (same as Copilot's `copilot-submap`).
- `~/.rogue/antigravity-submap/` is keyed by conversation id only, so the three
  surfaces share one namespace. Harmless today (ids are UUIDs), but a collision
  across surfaces would resolve to the wrong parent.
- A subagent is looked for only in the brain dir of the surface that fired the
  event. Correct for every case seen, but a cross-surface spawn (if Antigravity
  ever adds one) would not resolve.
- MCP tool naming under Antigravity's `mcp(server/tool)` permission namespace is
  matched heuristically server-side; no real MCP call has been observed.
- Heartbeat fires per user turn rather than per session (see above).
