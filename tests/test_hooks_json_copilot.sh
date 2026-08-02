#!/usr/bin/env bash
# tests/test_hooks_json_copilot.sh — static lint of the Copilot plugin's
# hooks.json. Enforces the byte-stability + fail-open invariants that the
# hook-trust model and Copilot's fail-CLOSED preToolUse depend on.
set -euo pipefail

REPO="$(cd "$(dirname "$0")/.." && pwd)"
HOOKS="$REPO/plugins/copilot/hooks.json"

python3 - "$HOOKS" <<'PY'
import json, sys

path = sys.argv[1]
with open(path) as f:
    doc = json.load(f)   # raises on invalid JSON

errors = []

if doc.get("version") != 1:
    errors.append(f"top-level version must be 1, got {doc.get('version')!r}")

hooks = doc.get("hooks", {})
expected_events = {
    "sessionStart", "sessionEnd", "userPromptSubmitted", "userPromptTransformed",
    "preToolUse", "postToolUse", "postToolUseFailure", "permissionRequest",
    "agentStop", "subagentStart", "subagentStop", "preCompact",
    "errorOccurred", "notification",
}
got_events = set(hooks.keys())
if got_events != expected_events:
    errors.append(f"events {sorted(got_events)} != expected {sorted(expected_events)}")

# `Stop` is Copilot's PascalCase alias for turn-end; it fires alongside
# `agentStop`, so registering both would double-POST. Only `agentStop` is allowed.
if "Stop" in hooks:
    errors.append("event 'Stop' must not be registered (agentStop already fires for turn-end)")

matcher_required = {
    "preToolUse", "postToolUse", "postToolUseFailure", "permissionRequest",
    "subagentStart", "subagentStop", "preCompact", "notification",
}

for event, entries in hooks.items():
    if not isinstance(entries, list) or not entries:
        errors.append(f"{event}: must be a non-empty array")
        continue
    for i, entry in enumerate(entries):
        tag = f"{event}[{i}]"
        if entry.get("type") != "command":
            errors.append(f"{tag}: type must be 'command'")
        for key in ("bash", "powershell"):
            cmd = entry.get(key)
            if not isinstance(cmd, str) or not cmd:
                errors.append(f"{tag}: missing '{key}' command")
                continue
            # Fail-open safety net: every command must end with '; exit 0' so a
            # crashed/missing dispatcher yields exit 0 (allow), never a
            # fail-closed deny on preToolUse.
            if not cmd.rstrip().endswith("; exit 0"):
                errors.append(f"{tag}.{key}: must end with '; exit 0'")
            # Byte-stable substitution token for the plugin root.
            if "${PLUGIN_ROOT}" not in cmd:
                errors.append(f"{tag}.{key}: must reference ${{PLUGIN_ROOT}}")
            # References a shipped script.
            if key == "bash" and not ("hook.sh" in cmd or "heartbeat.sh" in cmd):
                errors.append(f"{tag}.bash: must invoke hook.sh or heartbeat.sh")
            if key == "powershell" and not ("hook.ps1" in cmd or "heartbeat.ps1" in cmd):
                errors.append(f"{tag}.powershell: must invoke hook.ps1 or heartbeat.ps1")
        ts = entry.get("timeoutSec")
        if not isinstance(ts, int) or ts <= 0:
            errors.append(f"{tag}: timeoutSec must be a positive int, got {ts!r}")

# Tool events must carry matcher '.*' so MCP + every tool is covered.
for event in matcher_required:
    for i, entry in enumerate(hooks.get(event, [])):
        if entry.get("matcher") != ".*":
            errors.append(f"{event}[{i}]: matcher must be '.*'")

# Every hook.sh/hook.ps1 entry must pass its own event name as the argument.
# (sessionStart also has a heartbeat.sh entry that carries no event arg — skip
# entries that don't invoke hook.sh/hook.ps1.)
for event, entries in hooks.items():
    for i, entry in enumerate(entries):
        bash = entry.get("bash", "")
        ps = entry.get("powershell", "")
        if "hook.sh" in bash and event not in bash:
            errors.append(f"{event}[{i}].bash: must pass '{event}' to hook.sh")
        if "hook.ps1" in ps and event not in ps:
            errors.append(f"{event}[{i}].powershell: must pass '{event}' to hook.ps1")

if errors:
    print("hooks.json lint FAILED:")
    for e in errors:
        print(f"  - {e}")
    sys.exit(1)

print("  ok: version == 1")
print("  ok: all 14 Copilot events registered (Stop not among them)")
print("  ok: every command has bash + powershell keys ending '; exit 0' with ${PLUGIN_ROOT}")
print("  ok: tool/lifecycle events carry matcher '.*'")
print("  ok: every hook.sh/hook.ps1 entry passes its event name")
print("  ok: timeoutSec is a positive int on every entry")
print()
print("All copilot hooks.json lint checks passed.")
PY
