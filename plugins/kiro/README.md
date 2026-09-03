# Rogue Security plugin for Kiro

Real-time AI agent detection and response (AIDR) for Kiro — the IDE, the CLI
(2.x and 3.0 engines) and Kiro Crew. One family, `kiro`; three surfaces,
`kiro_ide`, `kiro_cli`, `kiro_crew`.

Installed by `install.sh --kiro` under `~/.rogue/plugins/kiro/` — outside every
Kiro path, so a Kiro upgrade or a `.kiro/` reset never removes it. The installer
writes the hook files that point Kiro at the bridge; this directory holds the
bridge and its helpers.

## The bridge

```
scripts/hook.sh  <hookEvent> <surface>      # macOS / Linux
scripts/hook.ps1 <hookEvent> <surface>      # Windows (Windows PowerShell 5.1+)
```

A Kiro hook runs the bridge with the event JSON on stdin. The bridge POSTs it to
`/api/v1/hooks/kiro` (`x-rogue-event` = the canonical hook event,
`x-rogue-agent` = the surface, plus the API key, actor and install-identity
headers every plugin sends) and answers in Kiro's native form:

| Rogue decision | PreToolUse | UserPromptSubmit | Stop, every other event |
| --- | --- | --- | --- |
| allow | exit 0, no output | exit 0, no output | exit 0, no output |
| block | **exit 2**, reason on stderr, empty stdout | exit 0, `{"decision":"block","reason":…}` on stdout | exit 0, no output — a block on Stop would tell Kiro to keep working |

Any error — no API key, network failure, timeout, non-200, empty body — is
exit 0 with an empty stdout. `ROGUE_HOOK_TIMEOUT` (seconds, default 8) caps the
request under the hook file's 10s.

Both engines' dialects are accepted: the 2.x camelCase trigger names
(`agentSpawn`, `preToolUse`, `stop`, …) are sent as their canonical PascalCase
event, and when a 2.x body carries no `session_id` the bridge copies
`KIRO_SESSION_ID` from the hook's environment into it.

One line per event lands in `~/.rogue/logs/kiro.log`
(`provider=kiro surface=<surface> event=<Event> outcome=… http=… rc=… raw=…`),
see `docs/hook-log-format.md`.

## What the installer writes

`install.sh --kiro` (auto-detected from `kiro-cli`, `/Applications/Kiro.app` or
`~/.kiro`; `install.ps1 -Kiro` on Windows) wires one bridge into every surface.
Re-running upgrades in place: the bridge is replaced, its own `rogue-*` hook
entries are replaced, everything else is kept.

| Path | Read by | Surface | Notes |
| --- | --- | --- | --- |
| `~/.rogue/plugins/kiro/` | the hooks below | — | the bridge and its helpers, outside every Kiro path |
| `~/.kiro/hooks/rogue.json` | IDE 1.x, CLI 3.0 engine | `kiro_ide` | universal v1: `{version:"v1", hooks:[{name, trigger, action:{type:"command", command}, timeout:10}]}`, all eight monitored events, **no matcher** (`*` is an invalid regex there and the file fails to load) |
| `~/.kiro/hooks/rogue-crew-{pre,post}.sh` | Kiro Crew | `kiro_crew` | executable wrappers Crew imports by their `# event:` header — absolute path, no shell metacharacters (macOS/Linux only) |
| `~/.kiro/agents/*.json`, `./.kiro/agents/*.json` | CLI 2.x engine (the default) | `kiro_cli` | a `hooks` array in the same form, merged beside the user's own entries; a file that does not parse, or whose `hooks` is not an array, is skipped with a warning |
| `~/.kiro/agents/rogue.json` | CLI 2.x engine | `kiro_cli` | created with `kiro-cli agent create --name rogue` (Kiro's defaults + the hooks) and made the default with `kiro-cli agent set-default rogue` **only when `kiro-cli settings chat.defaultAgent` reports none**; a default the user chose is left alone and printed (ADR 0001) |

The 2.x engine's built-in default agent is not a file and cannot be shadowed, so
without the `rogue` agent a plain `kiro-cli chat` carries no hooks. Each file
fixes the bridge's surface to the surface it is authoritative for: no Kiro
payload names its surface, and the IDE reads nothing but the hook file (the
prompt block is IDE-only, so that file must say `kiro_ide`). A 3.0-engine
session on a custom agent therefore fires both the hook file and the agent
hooks — every event is recorded twice, once per surface. The agent-config merge
runs on `node`; without it the hook file and the Crew wrappers are still written
and the 2.x gap is named.

## Credentials

Later file wins:

1. `<root>/env` — baked into a compiled customer plugin
2. `/etc/rogue/env` (`C:\ProgramData\rogue\env`) — MDM-provisioned
3. `~/.rogue-env` — per-user, written by the installer

The two bridges differ on the process environment, as the sibling plugins do:
`hook.sh` sources the files (`export X=…`), so a value in a later file overwrites
one the hook inherited; `hook.ps1` reads the files into a map and then lets a
non-empty process-env value beat every file. Set the value in `~/.rogue-env` to
be sure it applies on both.

## Tests

```
bash tests/test_hook_sh_kiro.sh            # bridge end to end against tests/mock_server.py
bash tests/test_install_kiro_sh.sh         # install.sh --kiro under a temp HOME with a fake kiro-cli
pwsh tests/test_install_kiro_ps1.ps1       # the same wiring in install.ps1
TEST_SH=dash bash tests/test_hook_sh_kiro.sh
pwsh tests/test_hook_ps1_kiro.ps1          # the PowerShell bridge's decision table
sh tests/test_hook_logs.sh                 # hook-log contract, all dispatchers
```

`tests/fixtures/kiro/` holds the verbatim payload captures the suites feed the
bridge (kiro-cli 2.21.0 on both engines, Kiro IDE 1.0.437).
