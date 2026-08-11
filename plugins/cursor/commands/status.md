---
name: status
description: Check Rogue Security AIDR connection, active rulesets, and configuration
---

# Rogue Security Status

Verify the current Rogue Security integration. Sources credentials in order: `/etc/rogue/env` (MDM), `~/.rogue-env` (per-user).

## Step 1: Source credentials and report what was found

```bash
[ -r /etc/rogue/env ]     && . /etc/rogue/env     && echo "  /etc/rogue/env  (MDM)"
[ -r "$HOME/.rogue-env" ] && . "$HOME/.rogue-env" && echo "  $HOME/.rogue-env  (per-user)"
[ -n "$ROGUE_API_KEY" ] && echo "API key resolved: ...${ROGUE_API_KEY: -4}" || { echo "API key: not resolved"; }
```

If `ROGUE_API_KEY` is empty, stop and tell the user to run `/rogue:setup`.

## Step 2: Ping the API

```bash
. "$HOME/.rogue-env" 2>/dev/null; [ -r /etc/rogue/env ] && . /etc/rogue/env
curl -s -w "\n%{http_code}" -H "x-rogue-api-key: $ROGUE_API_KEY" \
  "${ROGUE_BASE_URL:-https://api.rogue.security}/api/v1/hooks/ping"
```

## Step 3: Fetch active config

```bash
. "$HOME/.rogue-env" 2>/dev/null; [ -r /etc/rogue/env ] && . /etc/rogue/env
curl -s -H "x-rogue-api-key: $ROGUE_API_KEY" \
  "${ROGUE_BASE_URL:-https://api.rogue.security}/api/v1/hooks/config"
```

Parse the JSON and show: mode (enforce/monitor), fail-open setting, active rulesets.

## Step 4: Show identity + recent hook activity

```bash
. "$HOME/.rogue-env" 2>/dev/null
echo "Actor email: ${ROGUE_ACTOR_EMAIL:-(unset)}"
echo "Actor name:  ${ROGUE_ACTOR_NAME:-(unset)}"
echo "--- recent hook activity ---"
tail -n 20 "${ROGUE_LOG_FILE:-${ROGUE_LOG_DIR:-$HOME/.rogue/logs}/cursor.log}" 2>/dev/null || echo "(no hook log yet)"
```

On Windows, use `Get-Content -Tail 20 "$env:USERPROFILE\.rogue\logs\cursor.log"`.

Each Rogue plugin logs to its **own** file under `~/.rogue/logs/`, so this reads
`cursor.log` only — a sibling agent's activity lives in `claude.log`,
`codex.log`, and so on. `<file>.1` is the previous rotation, if any. An empty or
missing file with a healthy connection just means no events have fired yet.

## Step 5: Summary

Combine credential sources, connection status, and identity into one clean summary. If everything looks good, confirm the integration is active. Block/allow/ask policy is managed server-side — direct the user to the dashboard to view or change it.

## Step 6: False-positive escape hatch

Tell the user: prepend `rgx!` to a prompt to allow it through and mark the previous detection as a false positive in the dashboard.
