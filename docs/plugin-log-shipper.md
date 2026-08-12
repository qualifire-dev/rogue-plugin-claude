# Plugin log shipper — implementation design

Capability A from [log-shipping.md](log-shipping.md). This is the build spec: what
files, what contract, what each step does and why. Review this before code lands.

Storage decision is settled: hook logs go to a **separate Axiom dataset**, not into
the endpoint agent's table. Axiom is an append-only event store, so at-least-once
delivery just means an occasional duplicate event and there is **no client-side
dedup work** — a query can collapse on `(log_source_id, log_file, ts, raw)` if it
ever matters.

## Files

```
plugins/{rogue,codex,cursor,copilot,antigravity}/scripts/ship-logs.sh    byte-identical ×5
plugins/{rogue,codex,cursor,copilot,antigravity}/scripts/ship-logs.ps1   byte-identical ×5
plugins/gemini/scripts/ship-logs.mjs                                     Node-only, per repo rule
tests/test_ship_logs.sh
tests/test_ship_logs.ps1
```

Callers (one line each, no `hooks.json` change anywhere):

| plugin | call site |
|---|---|
| claude, codex, copilot, antigravity | `scripts/heartbeat.sh` / `heartbeat.ps1` |
| gemini | `scripts/heartbeat.mjs` |
| cursor | inside the existing `if [ "$event" = "sessionStart" ]` block in `hook.sh` / `hook.ps1` |

**Not the last line — right after the API-key check, before any agent-specific
gate.** `plugins/rogue/scripts/heartbeat.sh:23` is
`[ -z "${CLAUDE_CODE_ENTRYPOINT:-}" ] && exit 0`; a call at the tail would inherit
that and every future guard, so an agent that stopped exporting one env var would
silently stop shipping logs with no other symptom. The heartbeat's guards decide
whether to *beacon*, which is a different question from whether to ship.
Concretely: move that gate below the `ROGUE_API_KEY` check (behaviour-neutral —
both are bare `exit 0` guards ahead of any side effect) and put the shipper call
between them.

`scripts/build-release.sh` needs **no change**: every plugin is staged with
`cp -R plugins/<x>`, so a new file in `scripts/` ships automatically.

**No heartbeat change and no new client-side identifier** — the backend hashes the
shipper's identity fields into an opaque `log_source_id` and stores only that in
Axiom. See §9, which also explains why it is *not* a `coding_agent.id`.

## Argument contract

```
sh   ship-logs.sh  <plugin-root> <shipper-slug> <shipper-version> <agent-family>
ps   ship-logs.ps1 <plugin-root> <shipper-slug> <shipper-version> <agent-family>
node ship-logs.mjs <plugin-root> <shipper-slug> <shipper-version> <agent-family>
```

All per-plugin variation lives in the arguments — that is what lets the five copies
be **byte-identical** and lets `cmp` enforce lockstep instead of review. The
plugin-root var name is the one thing that genuinely differs
(`CLAUDE_PLUGIN_ROOT`, `PLUGIN_ROOT`, `CURSOR_PLUGIN_ROOT`, `extensionPath`, …) and
the caller already holds it. `<shipper-version>` is likewise already resolved by
the heartbeat.

**`<agent-family>` is passed in and never derived from the slug.** The two are
deliberately different vocabularies — Codex's log slug is `codex` but its
`agent_family` is `openai`, and the roster labels are `gemini_cli` /
`github_copilot` where the slugs are `gemini` / `copilot` (see **The hook log** in
`CLAUDE.md`). The heartbeat already hardcodes the family in its `/hooks/status`
body (`plugins/rogue/scripts/heartbeat.sh:60`), so it is free to pass, and a
slug→family table inside a byte-identical script would be one more thing to keep in
lockstep.

**No-argument invocation implies `ROGUE_SHIP_ALL=1`.** A bare
`sh .../ship-logs.sh` has no slug, so "ship my own log" is not a question it can
answer — an earlier draft said the slug falls back to `unknown`, which would make
it look for `unknown.log` and ship nothing. Since the only caller without arguments
is a human collecting diagnostics, no-args means *collect everything*, with
`shipper` / `shipper_version` reported as `unknown` in the envelope. The plugin root
is still derived from `$0`/`$PSCommandPath` so the bundled `env` is not skipped.
`/rogue:status` passes the arguments explicitly — see **Support use**.

## Flow

```
 1. Git Bash stand-down: uname = MINGW*/MSYS*/CYGWIN* → exit 0   (ps1 owns Windows)
 2. load env files, later wins: <plugin-root>/env → /etc/rogue/env → $HOME/.rogue-env
 3. ROGUE_SHIP_LOGS=0 → exit 0
 4. no ROGUE_API_KEY → exit 0
 5. resolve which log file(s) to ship — own slug only by default
 6. mkdir -p ~/.rogue/ship
 7. per-file: throttle check on .last-<key>; too recent → skip this file
 8. per-file: acquire .lock-<key> (mkdir); stamp .last-<key> immediately
 9. resolve host, actor_email, actor_name (same cascade as the heartbeat)
10. ship chunks until drained or the run budget is spent
11. release the lock; exit 0
```

Every path `exit 0`, no `set -e`. Two separate disciplines, both load-bearing:

- **No `set -e`** because non-zero is *normal* here: `curl` returns 7 with no
  network, `grep` returns 1 on no match. Under `set -e` either aborts the script
  mid-run, skipping the state write and the lock release.
- **`exit 0` on every path** because a non-zero exit means something to the caller.
  Repo-wide rule with real teeth elsewhere — Copilot's `preToolUse` is
  fail-**closed**, so a non-zero hook exit *denies the tool*. The shipper is not on
  that path, but the rule is uniform on purpose: a broken shipper must be silence,
  never a failure, and never the reason enforcement breaks.

### 5. Which file — its own, not everyone's

**Each plugin's shipper uploads only its own agent's log.** Claude's copy ships
`claude.log`; Cursor's ships `cursor.log`.

An earlier draft had every copy ship all six known logs, for coverage: if an
agent's own shipper never runs, only another agent's copy can retrieve its log. The
concrete case was Claude's heartbeat exiting at the `CLAUDE_CODE_ENTRYPOINT` gate —
**which the call-site fix above already eliminates**, taking the main justification
with it. What remained (logs from an uninstalled plugin, still on disk) is not
worth the costs:

- **Least astonishment.** A Cursor-only install reading and uploading a file
  written by another vendor's tooling is a bad line in a security review.
- **Data minimisation.** "The Cursor plugin uploads the Cursor plugin's own
  diagnostic log" is a sentence that fits in a DPA. The other one needs a
  paragraph.
- **Uninstall would not mean uninstall** — remove the Claude plugin, keep Cursor,
  and `claude.log` keeps being uploaded.
- **Less code**: the six-name allowlist and its "never glob `*.log`" guard both
  disappear.

Path resolution matches the dispatchers exactly, or the shipper reads a path
nothing writes:

- `ROGUE_LOG_FILE` set → that file. **All six agents write to it in this mode**, and
  its basename is arbitrary (`/var/log/rogue-all.log`), so neither the envelope nor
  the filename can attribute the chunk — see **Attribution is per line** below.
- else `ROGUE_LOG_DIR`, else `$HOME/.rogue/logs`, file `<slug>.log`.

**`ROGUE_SHIP_ALL=1` restores the ship-everything behaviour** for the support case
— on a call with a customer, one invocation collects the whole machine. Manual and
opt-in, never the default.

#### Attribution is per line, not per file

`ROGUE_LOG_FILE` collapse mode breaks any file-level identity scheme, and the break
is silent in the worst way: one chunk holds interleaved `provider=claude`,
`provider=codex`, `provider=cursor` lines, so tagging it with the shipping plugin's
`agent_family` would file **Claude lines under `openai`**, and the server cannot
recover the family from a basename that is not a known slug.

So the server attributes **each line**, keyed on its `provider=` token, and the
envelope's `agent_family` is a **hint used only as a fallback** for a line that has
no `provider=` (a torn line, or a future format change). In the normal per-file
configuration every line in `claude.log` says `provider=claude`, so per-line and
per-file agree and nothing changes; collapse mode simply works.

This costs nothing on the server — the ingest already emits one Axiom event per
line, so deriving that line's `log_source` alongside its other fields is the same
loop. It costs nothing on the client either: no slug table, no per-line work, no
new field.

> **This reverses my earlier recommendation to delete `provider=`.** That
> recommendation rested on one finding — nothing consumed the token, so it was
> write-only overhead. Per-line attribution gives it a consumer, and a load-bearing
> one: it is the *only* thing that can attribute a line in collapse mode. Keep it.
> The alternative is coherent but worse — declare `ROGUE_LOG_FILE` unsupported for
> shipping, so any fleet that set it (it exists purely for pre-split back-compat,
> and MDM configs are exactly where it would live) silently ships nothing.

### 7–8. Throttle and lock

`~/.rogue/ship/` holds all state, keyed per log file (`<key>` = the log's basename
minus `.log`, so `ROGUE_LOG_FILE` collapse mode shares one key across agents,
which is correct — it is one file):

```
<key>.state      offset= and head= for that log file (see §10)
.last-<key>      unix seconds of the last attempt
.lock-<key>/     directory used as a mutex
```

**Keyed per file, not global.** A shared `.last` plus per-agent shipping would
starve: whichever agent starts a session first stamps it and blocks every other
agent for the whole interval.

#### The throttle, and why it exists at all

`ROGUE_SHIP_MIN_INTERVAL`, **default 900 s**. `.last-<key>` is a one-line Unix
timestamp:

```
$ cat ~/.rogue/ship/.last-claude
1786512847
```

Content rather than the file's mtime because reading mtime portably needs `stat`,
whose flags differ between BSD and GNU — the same reason phase 1 reads size with
`wc -c`.

It is **not** a bandwidth measure. A run with nothing new makes **no HTTP request
at all** (offset equals size, nothing to send), so the happy path is already free.
The throttle exists to bound *our own worst case*:

- **Crash-loop guard.** `.last-<key>` is stamped the instant the lock is taken,
  **before any upload**. So a shipper that dies before persisting its offset — a
  bug in our code, a killed process, an OOM — reruns at most once per interval
  instead of on every single session start. Without it, a build that uploads 1 MiB
  and then crashes before writing state would re-upload that megabyte on all 50 of
  a heavy user's daily sessions, forever, until a fix propagates (24 h on the
  auto-update cycle at best, and only after they restart sessions). With it, the
  blast radius is 4 runs an hour.
- **Rate ceiling per machine**, for the same reason, on any future bug that makes
  the shipper chattier than intended.

**Why 900 s and not less:** the trigger is *session start*, not a timer. Someone
in one four-hour session ships nothing during it no matter what the interval says
— their logs arrive at their next session. So a lower interval only helps people
who open many sessions, and 15 minutes already puts that group inside the window
where a support request is still warm. Going to 60 s would multiply the crash-loop
ceiling by 15 to make no practical difference to freshness.

#### The lock

`mkdir .lock-<key>` — creating a directory is a single atomic filesystem operation,
succeed-or-fail-because-it-exists with no gap. The naive shell version
(`if [ ! -e lock ]; then touch lock; fi`) is two operations and both processes can
pass the test before either touches. `New-Item -ItemType Directory` fails the same
way on Windows, so one implementation covers both.

What it protects is the window between **reading the state file** and **writing the
new offset back** — which includes the HTTP request, up to 15 s. Two sessions of
the same agent starting together (two terminal tabs, common) would otherwise both
read `offset=5000`, both upload bytes 5000–5400, both write `offset=5400`:
duplicate rows, plus a real chance of a torn state file. In `ROGUE_LOG_FILE`
collapse mode the contenders are different agents instead, and the same lock
covers it because the key is the file.

- Cannot acquire → skip that file silently.
- A lock whose mtime is **older than 600 s is stale**: remove it, one retry. A
  killed shipper must not wedge the feature permanently.
- Released via `trap … EXIT INT TERM` / `try/finally`, so an early return still
  releases it.
- **A `.last-<key>` in the future** (clock stepped back, bad write) is treated as
  stale rather than blocking shipping until the clock catches up.

### 9. Identity — send the PII, store the id

The privacy boundary is **Rogue → Axiom**, not plugin → Rogue. Every hook POST and
every heartbeat already sends `host` + `actor_email` to our own API, so sending
them to `/hooks/logs` adds no new exposure. What must stay clean is the Axiom
dataset, whose retention and access controls are not the main database's.

So the shipper sends the identity fields as-is and the **backend resolves them to an
opaque id before ingesting**:

```
plugin  → POST /hooks/logs   host, actor_email, actor_name, agent_family,
                             log_file, chunk
backend → resolve-or-create log_source row for
          (org_id, host, actor_email, family-of-this-line)  → random uuid
Axiom   ← log_source_id, log_file, offset, chunk                  (no PII)
```

#### A log file is coarser than a `coding_agent` row

The first draft said "look up `coding_agent` by `(host | actor-email | family)`,
the triple the roster dedups on". **That is wrong on both halves**, and the second
half is the interesting one.

The roster's real dedup key is **four** parts, not three —
`` `${hostname}|${actorEmail ?? "anon"}|${family}|${agent}` ``
(`apps/rogue-aidr-api/src/routers/hooks.ts:343`, and the `fingerprint` column
comment in `packages/rogue-database/src/schema.ts` says the same). `agent` is the
*surface*: `claude_code` | `claude_desktop` | `cowork`, `codex_cli` | `codex_app`,
`antigravity_ide` | `antigravity_cli`.

But **one log file is written by every surface of its family.** All three Claude
surfaces share one plugin install, one `$HOME`, and therefore one
`~/.rogue/logs/claude.log`. So a chunk of that file does not belong to one
`coding_agent` row — it belongs to *all* the rows for that host, actor and family.
Sending the shipping session's own surface (which the heartbeat does know, from
`CLAUDE_CODE_ENTRYPOINT`) would attach a multi-surface chunk to whichever surface
happened to open a session first. That is not under-specified, it is incorrect.

**So the log's identity is genuinely the triple** — the same granularity as the file
name — and the fix is to stop pretending it is a `coding_agent.id`:

- The shipper sends `agent_family` (new field, and the reason it is now an
  argument) as a fallback hint; per-line `provider=` drives the real attribution.
- The backend keeps a **`log_source` table** — `id` (random uuid), `org_id`,
  `hostname`, `actor_email`, `agent_family`, unique on the four — and resolves or
  creates a row per `(org, host, actor, family)`. Only `log_source_id` reaches
  Axiom.
- "Show me this roster row's plugin log" is a lookup of that row's own columns in
  `log_source`. No schema change to `coding_agent`, no PII crossing over.
- The UI surfaces plugin logs at machine + family granularity, which is what the
  file actually is. A roster row for `claude_desktop` shows the same log as
  `claude_code` on that machine — correct, not a bug.

**If per-surface attribution is ever needed**, the only honest way is to stamp the
surface into each *line* at hook time (the dispatcher knows it) and let the server
split. That is phase-1 format scope, deliberately not done here.

#### A plain hash would not have been a privacy boundary

An earlier version of this section specified
`log_source_id = hash(org_id | host | actor_email | agent_family)` and called it
opaque. **It is not.** Hostnames and work emails are extremely low-entropy,
especially within one organisation: `firstname@rogue.security` over a known
employee list, `<firstname>-mbp` / `<firstname>-macbook` over the same list, six
known families. That is a few thousand candidates — a dictionary attack completes
in milliseconds, so anyone with Axiom-only access recovers every hostname and email
exactly. It would have been pseudonymisation dressed up as removal, which is worse
than an honest plaintext field because it invites reliance it cannot support.

Three ways to fix it, in increasing strength:

1. **Salted hash** — no better. The salt must be stored, and whoever can query
   Axiom is inside the same system.
2. **HMAC under a server-held key** — genuinely resistant, and it keeps the
   derive-from-any-row property.
3. **A random id in a `log_source` table** — what this spec now requires.

(3) beats (2) on two counts beyond the crypto. **Erasure**: Axiom is append-only, so
an HMAC scheme cannot honour a delete request without rewriting immutable data,
whereas deleting the `log_source` row leaves the events permanently unlinkable —
which is precisely what "erase this person" requires. And **rotation**: there is no
key to rotate, leak, or fail to rotate.

Cost is one indexed lookup per distinct `(host, actor, family)` per request,
in-process cacheable, and at most six per chunk even in collapse mode.

**Note this reintroduces resolve-or-create**, which §9 removed a revision ago for a
different reason. That removal was about not inventing a `coding_agent` row with a
guessed `agent` surface. `log_source` has no surface column and no guessing: the
four fields all arrive in the request, and creating the row *is* the correct
behaviour when a machine ships before it beacons.

**The plugin carries no identifier of its own.** An earlier draft proposed a
generated `install_id` in `~/.rogue/install-id`; that was inventing a primary key
the database already has. Deleted. `machine_id` is likewise **not** sent — its only
job was joining to the endpoint agent's rows for the same device, and that belongs
on the roster row once (from the heartbeat), not in every log chunk.

**A chunk arriving before any heartbeat is fine.** It creates its own `log_source`
row from fields that are all present in the request, and the `coding_agent` row
joins to it whenever the heartbeat lands. The log ingest never touches
`coding_agent`, so it can never invent a roster row with a guessed `agent` surface
— which, given the four-part fingerprint, a `coding_agent` lookup would have had
to.

`host` is `hostname`; `actor_email` / `actor_name` come from `scripts/actor.sh`
where present (`env` → `git config --global` → `CLAUDE_CODE_USER_EMAIL` →
`hostname`/`whoami`). Cursor and Gemini have no `actor.sh` and resolve the same
cascade inline today; the shipper reuses whatever the caller already exported. Same
resolution as the heartbeat by construction — if the two disagreed, the lookup
would create a second roster row instead of matching the existing one.

### 10. Not re-reading what was already exported

State is one file per log, `~/.rogue/ship/<key>.state`, two `k=v` lines:

```
offset=12345      bytes the backend has ACCEPTED for this file
head=MjAyNi0w…    base64 of the file's FIRST LINE, as of that offset
```

```
off, stored_head = read state         # off = 0 if absent or non-numeric
size = wc -c < file                   # NOT stat — BSD and GNU differ on flags
head = base64(first line of file)     # bytes up to the first \n, cap 200

rotated = (size < off) or (head is known and head != stored_head)

if rotated:
    if file.1 exists and base64(first line of file.1) == stored_head
       and size(file.1) > off:
        send(file.1, off, …, rotated=true)
        on failure: return            # leave state untouched; next run retries
    off = 0; persist offset=0 head=<head>   # BEFORE shipping the live file, so a
                                            # later failure cannot re-ship .1
while off < size and run budget remains:
    n     = min(size - off, ROGUE_SHIP_MAX_BYTES)
    chunk = bytes [off, off+n)  →  temp file
    n     = trim_to_last_newline(chunk)      # whole lines only
    if base64(first line of file) != head: return   # rotated under us — discard
    send(chunk, off, n, rotated=false)
    on non-2xx / transport failure / timeout: return
    off += n; persist offset=off head=<head>
```

**The offset advances only on 2xx.** A non-2xx, transport failure or timeout leaves
the state untouched, so the same range is re-sent next run. Nothing is ever marked
exported on unconfirmed data.

> **Requirement on the endpoint, not a client concern — but load-bearing for this
> contract.** A 2xx from `/hooks/logs` is the *only* thing that makes the plugin
> forget a byte range, so 2xx must mean **durably accepted**. The existing endpoint
> sink is the counter-example to copy from carefully:
> `apps/rogue-aispm-api/src/services/endpoint-logs-sink.ts` calls
> `axiomClient.ingest(...)` **without `await`** inside a `try/catch` — so an async
> rejection is not even caught — and returns `accepted: events.length`
> unconditionally, including when `axiomClient` is null or the dataset env var is
> unset. Built that way, `/hooks/logs` would 200 on a dropped chunk and the shipper
> would advance its offset past data that never landed: **silent, permanent loss**,
> which is exactly what the offset design exists to prevent. The ingest must be
> awaited and its failure must produce a non-2xx.

**Chunks loop until the file is drained**, rather than one chunk per run. With a
10 MiB rotation cap and a 1 MiB per-request size, one-chunk-per-run would take ten
runs to catch up — so `ROGUE_SHIP_MAX_BYTES` is the per-*request* size and the loop
is bounded by `ROGUE_SHIP_MAX_RUN_BYTES` (default 10 MiB, i.e. one whole
generation) plus a hard iteration guard.

#### Why `head` is the first LINE, not the first N bytes

The obvious version — fingerprint the first 200 bytes — **misfires on a young
file**:

```
run 1:  file is one 60-byte line     → head = b64(60 bytes)
run 2:  file now has 4 lines         → head = b64(bytes 0..200) spans lines 1–3
        head != stored_head          → "rotated!" → offset reset to 0
        → the whole file is re-shipped, every run, until it passes 200 bytes
```

Not data loss (duplicates), but it makes the check useless for exactly the small
files where it should be cheapest. A **line** is stable instead: logs are
append-only, so once a `\n` exists at byte *k*, bytes 0..*k* never change again. If
there is no `\n` yet (a partially written first line), the head is "unknown" and
the check falls back to `size < off` alone.

#### Why `head` exists at all

`size < off` alone has a **silent data-loss hole**. Rotation resets the file to
zero length, but if the new file grows *past* the old offset before the next run,
`size > off` and no rotation is detected:

```
off = 10 MiB, everything shipped
dispatcher rotates at the cap → old file becomes .1, new file starts at 0
new file passes 10 MiB before the next run
size > off  →  looks like normal growth
we ship [10 MiB, size) and skip the new file's first 10 MiB — silently
```

At a 10 MiB cap and a 15-minute interval this needs an implausible write rate. An
admin who sets `ROGUE_LOG_MAX_BYTES=65536` makes it routine, and the symptom is
missing lines with nothing to indicate they were missed.

**A base64'd line, not a hash**, for one hard reason: all three languages share
`~/.rogue/ship/`. In `ROGUE_SHIP_ALL` mode Gemini's `.mjs` shipper writes state
that Claude's `.sh` shipper reads next session. A `cksum`/CRC would have to be
bit-identical across sh, PowerShell and Node — reimplementing POSIX `cksum` twice
for no gain. Base64 of a byte range is identical everywhere by construction, and
the comparison is string equality with no collision argument to make.

Rejected: **inode** (reliable on POSIX, but PS 5.1 cannot read a file id without
P/Invoke) and **Windows creation time** (NTFS file-system tunneling makes a file
recreated under the same name within 15 s inherit the old creation time, silently
defeating it).

**Validating `.1`'s head against the stored head** is what stops a double rotation
from re-shipping a generation we already sent: if `.1` is not the file the offset
belongs to, skip it and reset.

#### Rotation *during* a read (the TOCTOU)

```
t0   size = 5400, head = H
t1   dispatcher hits the cap → renames to .1, starts a new empty file
t2   we extract bytes [5000, 5400)  ←  from the NEW file
```

That ships the new file's first 400 bytes labelled `offset=5000`, loses the old
file's real tail, and then persists `offset=5400` over the top of it. Window is
milliseconds and rotation is once per 10 MiB, but the corruption is silent and
permanent.

**Fix: re-read the head after extracting the chunk** and discard the chunk if it
changed (the `if base64(first line) != head: return` line in the pseudocode). One
extra short read per chunk; the next run then handles the rotation properly.

#### Chunks end on line boundaries

Hitting `ROGUE_SHIP_MAX_BYTES` mid-line would put a line's first half in chunk *N*
and its second half in chunk *N+1* — two Axiom events, two corrupt lines instead of
one good one. Same hazard from a torn concurrent append at the tail.

So every chunk is **trimmed back to the last `\n`** and the offset advances by the
trimmed length. Byte length of the trailing fragment, without `jq` or `python3`:

```sh
LC_ALL=C awk 'BEGIN{RS="\n"} END{print length($0)}' "$chunk"
```

POSIX awk; `LC_ALL=C` so `length()` counts bytes and not characters. Trivial in
PowerShell and Node (scan back for `0x0A`). If a chunk contains **no** newline at
all (a single line over 1 MiB), ship it whole rather than stalling forever.

#### The chunk never passes through a shell variable

sh variables cannot hold NUL bytes, and a stray NUL would silently truncate the
chunk. Extract straight to a temp file under `~/.rogue/ship/`, base64 the file, and
let only the base64 output (NUL-free by construction) live in a variable.

#### Windows file sharing — both directions

Two distinct failures, one of them nasty:

- Our `FileStream` **must** pass `FileShare.ReadWrite`, or the read fails
  intermittently whenever a dispatcher is appending.
- It must **also** pass `FileShare.Delete`, or holding the file open makes the
  dispatcher's `Move-Item` rotation fail — and phase 1 swallows that failure under
  `-ErrorAction SilentlyContinue`, so **the log would grow past the cap forever**.
  A log shipper causing unbounded log growth is the worst outcome in this document.

Open with `ReadWrite -bor Delete`, keep the open window as short as possible.

#### What this covers

| event | detected by | outcome |
|---|---|---|
| normal append | `head` matches, `size > off` | ship `[off, size)` in chunks |
| rotation, new file smaller than `off` | `size < off` | ship `.1` tail, then reset |
| rotation, new file already larger than `off` | `head != stored_head` | ship `.1` tail, then reset |
| rotation *while* we read | post-extract head re-check | discard chunk, retry next run |
| `> file` (truncate in place) | `size < off`; `.1` head will not match | reset to 0, no bogus `.1` ship |
| log `rm`'d, dispatcher recreates it | `.1` head will not match | reset to 0 (the unshipped tail is gone — unavoidable) |
| state file deleted or corrupt | `off = 0` | whole file re-shipped (duplicates, safe) |
| empty / 0-byte log | `size == off == 0` | no request |
| chunk cap hit mid-line | newline trim | chunk ends on a line boundary |
| **two rotations between runs** | — | **middle generation lost — accepted**; needs 20 MiB inside 15 min |

#### Delivery is at-least-once, deliberately

If the backend commits a chunk and the 2xx is lost in transit, the next run re-sends
that range. Axiom is append-only and hook logs go to their own dataset, so that is
a duplicate event, not corruption, and a query can collapse on
`(log_source_id, log_file, ts, raw)`. The alternative — advancing the offset
before confirmation — trades duplicates for silent loss, the wrong trade for
diagnostics.

Other invariants:

- **Oldest-first.** Chunks go in offset order; a failure stops the loop and leaves
  the rest for next run, so ordering is preserved and nothing is skipped.
- The live log is opened **read-only, never truncated**. Concurrent appends are
  safe: we only ever read `[off, off+n)`, a range already written.
- `<key>.state` is written **write-to-temp-then-`mv`** so a crash mid-write cannot
  leave a half-written offset (`mv` within a directory is atomic; on Windows,
  `Move-Item` after removing the destination, per phase 1's rotation note).

Byte range extraction:

```sh
tail -c +$((off + 1)) "$f" | head -c "$n"      # tail -c +N is 1-based
```

Both flags are already load-bearing elsewhere in this repo (`tail -c 262144` and
`head -c 400` in `plugins/copilot/scripts/hook.sh`), so this adds no new
portability assumption. PowerShell uses `FileStream.Seek` + `Read`; Node uses
`fs.readSync` with a position.

### Redaction happens server-side, not here

The chunk is uploaded **verbatim**. The scripts do no rewriting of the log body at
all — no `sed`, no `$HOME` → `~` substitution, no field stripping.

An earlier draft claimed only home paths and `reason=`/`raw=` need redacting and
that "nothing else in a line is personal". **That was wrong** — the real inventory,
grepped out of the current dispatchers rather than assumed:

| token | written by | risk |
|---|---|---|
| timestamp, `provider=`, `event=`, `outcome=`, `http=`, `rc=` | all | none |
| `raw=` / `reason=` | all (`hook.sh:692`) | up to 400 chars of Rogue's own API response; a finding can quote the prompt fragment that triggered it |
| `path=` | antigravity (`hook.sh:239,244,245`) | **absolute transcript paths** — `/Users/<name>/…`, plus project directory names |
| `name=` | copilot (`hook.sh:318`), antigravity (`hook.sh:576`) | **subagent display name** — arbitrary vendor-or-user-authored text, sanitized of control chars only |
| `subagent=`, `parent=`, `dbstore=`, `tail=`, `len=`, `mode=` | antigravity, copilot | opaque ids and counters |

So the requirement is **not** "redact two fields": server-side redaction must run
over **every parsed field and the raw line**, the way
`apps/rogue-aispm-api/src/services/endpoint-logs-redact.ts` already does for the
endpoint agent — `redactEvent` walks every string value through `redactString`,
which rewrites `/Users/<name>`, `/home/<name>` and `C:\Users\<name>` to `~`. Reuse
it rather than growing a second implementation. Two gaps it does not cover today
and this ingest needs:

- **`name=`** is arbitrary text, not a path, so `redactString` passes it through
  untouched. Needs its own decision — keep (it is a tool label, usually harmless),
  or drop under the same policy switch as `raw=`.
- **`raw=` / `reason=`** likewise. Whether it is kept, truncated or dropped is
  per-tenant policy.

Doing any of this in `sh` and PowerShell would mean the same substitutions written
three times, with a `sed` escaping hazard in one of them (a `$HOME` containing `&`,
`|` or `\` silently mangles the chunk) and no realistic way to unit-test a policy.
Server-side it is one function, one test file, and it can change without a plugin
release — which matters because the fleet updates on a 24 h auto-update cycle at
best.

**Tests must cover the real cases**, not a synthetic `$HOME` line: an antigravity
`tail=none reason=unreadable path=/Users/amos/…/transcript.jsonl` line, and a
copilot `subagent=… parent=… name=<display name>` line.

## Wire format

`POST ${ROGUE_BASE_URL:-https://api.rogue.security}/api/v1/hooks/logs`

Headers: `x-rogue-api-key`, `Content-Type: application/json`. Nothing else — no
`x-rogue-event` (not a hook event), no `x-rogue-source`, no `x-rogue-agent`.

```jsonc
{ "host":             "…",          // hashed into log_source_id server-side,
  "actor_email":      "…",          //   NOT forwarded to Axiom — see §9
  "actor_name":       "…",
  "agent_family":     "claude",     // roster vocabulary: codex's family is `openai`
  "shipper":          "claude",     // which plugin's copy ran (log-slug vocabulary)
  "shipper_version":  "1.4.2",
  "log_file":         "claude.log", // basename only; the directory is site config
  "offset":           12345,        // byte offset this chunk starts at
  "bytes":            4096,
  "rotated":          false,        // true → this is the tail of <file>.1
  "content_b64":      "…" }         // base64 of the raw chunk, whole lines only
```

`shipper` and `log_file` are equal in the default configuration and differ only
under `ROGUE_SHIP_ALL` or `ROGUE_LOG_FILE`. Both are envelope-level hints; the
per-line `provider=` token remains authoritative for which agent a line came from.
`agent_family` is a **fallback hint, not the key**: attribution runs per line off
`provider=` (see **Attribution is per line**). It is sent when the caller passed one
— its own log — and omitted for a foreign log under `ROGUE_SHIP_ALL` and for a
custom `ROGUE_LOG_FILE`, because in both of those the shipping plugin's family is
not the chunk's family. The slug→family mapping (`codex` → `openai`, …) is server
vocabulary; a copy of it inside a byte-identical shell script is exactly the
lockstep liability this design avoids elsewhere.

**No `agent` (surface) field, deliberately** — see §9: one log file spans every
surface of its family, so a surface on the envelope would be a false precision.

**Why `content_b64` and not parsed records**, in order of weight:

1. `raw=` holds up to 400 characters of **our own API response**, including block
   reasons with arbitrary quotes and backslashes. Hand-concatenating that into JSON
   is the exact hazard `transcriptTailB64` already exists to avoid.
2. **No `jq`, no `python3`** — `jq` is absent from older macOS and minimal Linux
   images, and `/usr/bin/python3` is a stub that fails silently without Xcode CLT
   (repo-wide rule). `base64 | tr -d '\r\n'` is everywhere;
   `[Convert]::ToBase64String` and `Buffer.toString('base64')` need nothing.
3. Parsing on the server can be fixed without a plugin release. The line format is
   stable; the field set is not — phase 1 alone added three tokens.

Server side, per line: leading RFC3339 timestamp, `provider=`, `event=`, then
best-effort `k=v`, always keeping the original line as `raw`. **Never drop a line**
— `raw=` is a space- and `=`-bearing free-text tail (Codex puts it mid-line), so a
strict k=v parse loses data. **`provider=` selects the line's `log_source`**; a line
without one falls back to the envelope's `agent_family`, and a line with an
unrecognised `provider=` is still stored, attributed to a family of `unknown` rather
than discarded.

PowerShell builds the body with `ConvertTo-Json -Compress`. That is allowed here
and is *not* the thing `CLAUDE.md` forbids: the prohibition is on re-serialising a
**relayed payload** (which would reshape a body the server must see verbatim). This
body is constructed fresh, so a real serialiser is strictly safer than manual
escaping. The sh side hand-builds it with the existing `esc()` sed helper because
it has no serialiser — the two produce the same *fields*, not the same bytes, and
only one ever runs on a given machine.

HTTP timeouts: 15 s connect+transfer, matching the dispatchers. Nothing is inside a
hook budget here, but a wedged upload holding the lock for minutes is worse than a
failed one.

## Environment knobs

All resolved from the shared env-file chain, so `/etc/rogue/env` can set them
fleet-wide, and process env still wins:

| var | default | meaning |
|---|---|---|
| `ROGUE_SHIP_LOGS` | `1` | `0` disables shipping entirely |
| `ROGUE_SHIP_MIN_INTERVAL` | `900` | seconds between attempts, per log file |
| `ROGUE_SHIP_MAX_BYTES` | `1048576` | bytes per HTTP request |
| `ROGUE_SHIP_MAX_RUN_BYTES` | `10485760` | bytes per file per run (one generation) |
| `ROGUE_SHIP_ALL` | `0` | `1` ships every known agent's log, not just this one |
| `ROGUE_BASE_URL` | `https://api.rogue.security` | as elsewhere |

Numeric parsing follows phase 1's rule exactly, in all three languages: a
non-numeric value **falls back to the default** (a typo must not disable shipping
or blow the size cap), and zero-padding counts as its numeric value.

## Support use

Run by hand on a machine with no endpoint agent — the single most useful property
of this script:

```sh
# No arguments → collects every agent's log (ROGUE_SHIP_ALL is implied, since
# without a slug there is no "own log" to pick). Throttled like any other run.
sh ~/.claude/plugins/.../scripts/ship-logs.sh

# Same, ignoring the throttle — the actual support one-liner.
ROGUE_SHIP_MIN_INTERVAL=0 sh ~/.claude/plugins/.../scripts/ship-logs.sh

# This agent only, attributed properly: pass what the heartbeat passes.
sh .../ship-logs.sh "$CLAUDE_PLUGIN_ROOT" claude 1.4.2 claude
```

`/rogue:status` gains a final step offering exactly that — **with the arguments
filled in**, since the status command knows its own plugin root, slug, version and
family — in all six status commands (`plugins/{rogue,gemini,antigravity,copilot}/skills/status/SKILL.md`,
`plugins/{codex,cursor}/commands/status.md`), with the bash and PowerShell forms
each already carries.

## Tests

`tests/test_ship_logs.sh` and `tests/test_ship_logs.ps1`, both wired into
`.github/workflows/validate.yml` (sh under **both `dash` and `bash`**, as phase 1's
log test is).

**No mock server.** The sh test puts a fake `curl` earlier on `PATH` that records
argv and stdin to a file and exits with a scripted status; the PowerShell test
defines an `Invoke-WebRequest` function in the dot-sourcing scope, through the
existing `ROGUE_PS_LIB_ONLY` seam. Deterministic, no network, no new dependency,
and it lets a test assert the exact body. Node stubs `globalThis.fetch`, which means
`ship-logs.mjs` must export its entry point and auto-run only when it is
`process.argv[1]`.

Cases:

- the five `ship-logs.sh` are byte-identical (`cmp`), likewise the five `.ps1`;
- **each shipper ships only its own slug** — with all six logs present, the claude
  copy POSTs `claude.log` and nothing else; `ROGUE_SHIP_ALL=1` ships all six;
- offset advances on 2xx; does **not** advance on 500, on a transport failure, or on
  a timeout;
- **nothing is re-sent** across two runs with no new lines (assert the second run
  makes no request at all);
- `size < off` ships `.1`'s tail with `rotated=true`, then resets — and a failed
  `.1` upload leaves the state alone so the next run retries;
- **the grow-past-offset rotation is caught**: ship, rotate, then write *more* than
  the old offset into the new file, and assert the next run detects it by `head`
  and re-ships from 0 rather than skipping the new file's first `off` bytes. The
  case a size-only check misses, so it is the test that justifies `head=`;
- **a young file is not re-shipped**: one short line, ship it, append three more
  lines, assert the next run ships only the new lines (the first-200-bytes version
  of `head` fails this — it is the regression test for first-**line** semantics);
- a `.1` whose head does **not** match the stored head is skipped, not shipped;
- truncation in place (`: > file`) resets to 0 and ships no `.1`;
- **rotation mid-read is discarded**: rotate the file between the size read and the
  chunk read (via a wrapper on the fake `curl`, or a pre-send hook) and assert the
  chunk is *not* sent and the offset does not move;
- **every chunk ends with `\n`** — cap set mid-line, assert no partial line is ever
  sent and that concatenating the chunks reproduces the file byte-exactly;
- a single line longer than `ROGUE_SHIP_MAX_BYTES` is shipped whole rather than
  stalling the file forever;
- the chunk loop drains a file larger than `ROGUE_SHIP_MAX_BYTES` **in one run**,
  stopping at `ROGUE_SHIP_MAX_RUN_BYTES`;
- `head=` written by one language is honored by another — generate state with the
  `.mjs` shipper, run the `.sh` one against it and assert it does not re-ship
  (they share `~/.rogue/ship/`, so the encoding must agree byte-for-byte);
- a crash between "chunk accepted" and "state written" re-sends the chunk rather
  than skipping it (kill after the fake curl succeeds, assert the range repeats);
- the lock serialises two concurrent runs of the same key; a lock older than 600 s
  is reclaimed; **two different keys do not block each other**;
- throttle honored per key, honored **from `~/.rogue-env`** (phase 1's actual bug),
  and a `.last-<key>` timestamped in the future is treated as stale;
- `ROGUE_SHIP_LOGS=0` is a no-op that leaves the offset untouched;
- a chunk containing `"`, `\`, a newline and a UTF-8 multibyte character round-trips
  through base64 **byte-exact**; a chunk containing a NUL byte is not truncated
  (the temp-file path, not a shell variable);
- `host` / `actor_email` / `actor_name` in the envelope match what the heartbeat
  resolves on the same machine — if they drift, `log_source_id` differs from the one
  a roster row hashes to and the logs orphan (assert against `actor.sh`'s output);
- `agent_family` is the value the **caller passed**, never derived from the slug —
  assert the codex copy sends `openai` while its `shipper` stays `codex`, the one
  case a naive slug→family assumption breaks;
- under `ROGUE_SHIP_ALL=1`, the caller's own log carries `agent_family` and a
  foreign log **omits** it; a custom `ROGUE_LOG_FILE` omits it too (its lines are
  mixed-provider, so the shipping plugin's family would mislabel them);
- a collapse-mode file round-trips: write interleaved `provider=claude` and
  `provider=codex` lines to one custom `ROGUE_LOG_FILE`, ship it, and assert the
  body carries no `agent_family` and every line survives byte-exact (the server-side
  half — one `log_source` per distinct provider — is asserted in the backend repo);
- **no `agent` / surface field is ever sent** (§9: a log file spans every surface of
  its family, so a surface on the envelope would be false precision);
- **no-argument invocation ships every log**, not `unknown.log`, and reports
  `shipper: "unknown"`;
- unconfigured (no API key) is a silent no-op.

## Not doing

- **No `hooks.json` entry.** Codex, Gemini and Copilot fingerprint the hook
  definition and skip untrusted command hooks until the user reviews `/hooks`, so a
  new entry would silently disable enforcement for every existing install until
  each user re-trusted it.
- **No content rewriting in the scripts.** Redaction is the API's job — see
  **Redaction happens server-side**. The scripts read bytes and upload bytes.
- **No log truncation or deletion.** Rotation already caps disk at 2× the cap per
  agent; a shipper that also deleted would race the dispatcher's append.
- **No retry loop inside one run.** A failed chunk stops the loop and waits for the
  next session. Simpler, and the data is not time-sensitive.
- **No streaming or per-event upload.** Volume is single-digit KB per busy day.
