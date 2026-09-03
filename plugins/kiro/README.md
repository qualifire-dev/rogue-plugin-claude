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
TEST_SH=dash bash tests/test_hook_sh_kiro.sh
pwsh tests/test_hook_ps1_kiro.ps1          # the PowerShell bridge's decision table
sh tests/test_hook_logs.sh                 # hook-log contract, all dispatchers
```

`tests/fixtures/kiro/` holds the verbatim payload captures the suites feed the
bridge (kiro-cli 2.21.0 on both engines, Kiro IDE 1.0.437).
