# The hook log line

Every Rogue plugin's hook dispatcher appends **one line per invocation** to its own
file under `~/.rogue/logs/` (`%USERPROFILE%\.rogue\logs\` on Windows) —
`claude.log`, `codex.log`, `cursor.log`, `gemini.log`, `copilot.log`,
`antigravity.log`, `kiro.log`.

```
2026-08-13T07:02:05Z provider=claude surface=cli event=PreToolUse outcome=allow
```

Fields are `key=value`, separated by single spaces, in a fixed order. A reader
finds a value by scanning from `<key>=` to the next space, so **no value contains a
space or an `=`**.

| position | token | always present | notes |
| --- | --- | --- | --- |
| 1 | timestamp | yes | UTC ISO-8601, second precision, no fractional part |
| 2 | `provider=` | yes | the agent slug, which is also the file's basename |
| 3 | `surface=` | **no — optional** | which surface of that agent wrote the line |
| 4 | `event=` | yes | the vendor's own event name, verbatim casing |
| 5+ | free-form | yes | `outcome=`, `raw=`, `reason=`, … per dispatcher |

## `surface=` — which surface wrote the line

There is **one log file per agent family per machine**, and every surface of that
family appends to it. Claude Code launched from the CLI, from the Desktop app and a
Cowork session all write into the same `claude.log`. The heartbeat knows the
surface, but it describes *one session*, while a log file holds lines from many
sessions across many surfaces — so the surface has to be stamped on each line as it
is written.

### Vocabulary

Lowercase, no spaces, no `=`. A **closed list**: the token is one of these strings
and nothing else — never a path, a user name, a host name, or a window title.

| plugin (`provider=`) | `surface=` | how it is determined |
| --- | --- | --- |
| `claude` | `cli` | `CLAUDE_CODE_ENTRYPOINT` is set and matches nothing below |
| `claude` | `desktop` | `CLAUDE_CODE_ENTRYPOINT` contains `desktop` |
| `claude` | `cowork` | `CLAUDE_CODE_ENTRYPOINT` contains `cowork` |
| `codex` | `codex_cli` | `ROGUE_CODEX_SURFACE` unset, `codex_cli`, or unrecognised |
| `codex` | `codex_app` | `ROGUE_CODEX_SURFACE=codex_app` (the installer pins it) |
| `antigravity` | `antigravity` | the event's `transcriptPath` is under `…/antigravity/…` |
| `antigravity` | `antigravity_ide` | `transcriptPath` under `…/antigravity-ide/…` |
| `antigravity` | `antigravity_cli` | `transcriptPath` under `…/antigravity-cli/…` |
| `cursor` | `cursor` | single surface — a constant |
| `copilot` | `github_copilot` | single surface — a constant |
| `gemini` | `gemini_cli` | single surface — a constant |
| `kiro` | `kiro_ide` / `kiro_cli` / `kiro_crew` | the bridge's second argument, fixed by the installer per hook file; no Kiro payload names its surface |

Each plugin resolves this **once**, from the signal its heartbeat already uses, and
the two read one shared table:

- `plugins/rogue/scripts/surface.sh` / `.ps1` — `hook` takes the slug, `heartbeat`
  takes the display label, from the same `case`.
- `plugins/codex/scripts/surface.sh` / `.ps1` — one read of `ROGUE_CODEX_SURFACE`,
  validated against the closed list, feeding the log token, the `x-rogue-agent`
  header and the heartbeat alike.
- Antigravity resolves it from the payload once per invocation and passes the same
  value to its log line, its heartbeat and its per-surface enrichment.

A second, independent way to decide the surface would be worse than no token at
all: a line and the roster row for the same session could then name different
surfaces.

### The token is OPTIONAL

It is **absent** when the surface cannot be determined. There is no
`surface=unknown` and no empty `surface=` — either would be indistinguishable from
a real value to a reader scanning `key=` tokens.

In practice it is absent in two cases:

1. **Lines written by a plugin version older than the ones below.** Old lines are
   never rewritten; they have no token, permanently.
2. **An antigravity event whose payload carries no `transcriptPath`** — including
   every line written before the payload is read, such as `outcome=unconfigured` on
   a machine with no API key. `transcriptPath` is the only reliable signal (three
   Antigravity products share one install, so a filesystem probe cannot tell which
   is running), and guessing is worse than omitting.

The other five plugins determine their surface on every line they write.

### First version that ships it

| plugin | version |
| --- | --- |
| rogue (Claude Code) | 1.0.24 |
| codex | 1.0.1 |
| cursor | 1.1.1 |
| copilot | 1.2.1 |
| antigravity | 1.0.24 |
| gemini | 1.0.25 |
| kiro | 1.0.0 |

### Guarantees

- The three dispatchers of a plugin (POSIX `sh`, PowerShell, and Node for Gemini)
  emit **the same token for the same event** — asserted by
  `tests/test_hook_logs.sh`, `tests/test_hook_logs.ps1` and
  `tests/test_hook_mjs.mjs`.
- Resolving a surface can never block a session, change an allow/deny outcome, or
  write to stderr. Every resolution is guarded; a failure yields an empty slug,
  which yields no token.
- The upload envelope is unchanged. This is a per-line change only.
