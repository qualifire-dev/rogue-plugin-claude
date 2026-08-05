# Installing the Rogue Security Cursor Plugin (Enterprise)

This guide walks an enterprise admin through deploying the **Rogue Security plugin for Cursor** across an organization using Cursor's Team Marketplace feature plus MDM-managed credentials.

The Rogue plugin observes every Cursor agent event - prompts, tool calls, shell commands, MCP invocations, file reads, subagents - and forwards each one to Rogue's detection engine for prompt-injection, secret-exfiltration, and destructive-command analysis. Allow / ask / deny decisions come from your Rogue org configuration; there are no client-side policy knobs to misconfigure.

You will:

1. Confirm prerequisites
2. Import the Rogue plugin into your Cursor Team Marketplace
3. Distribute the plugin to developers - **Default Off**, **Default On**, or **Required**
4. Push the API key to every endpoint via MDM (`~/.rogue-env`)
5. Verify the rollout on a real endpoint

Initial deployment typically takes 20-30 minutes (most of which is the MDM packaging step).

> **Important - Cursor is not Claude Cowork.**
> Cursor does **not** support uploading a pre-built `.zip` package the way the Claude Cowork admin console does. Instead, Cursor pulls plugin source from a Git repository you register as a **Team Marketplace**, and credentials are provisioned separately via MDM or per-user setup. The compiled-tarball-with-key approach used for Cowork is not available here.

---

## Prerequisites

Before you begin:

- A **Cursor Teams or Enterprise plan** (Cursor 2.6+). Team Marketplaces are limited to 1 on Teams and unlimited on Enterprise.
- **Cursor admin role** in your organization - only admins can add team marketplaces.
- An **MDM** that can push files to endpoints (Jamf, Intune, Kandji, Workspace ONE, etc.) - used to deliver credentials. If you don't run MDM, see the [No-MDM fallback](#no-mdm-fallback) section.
- A **Rogue API key** issued at <https://app.rogue.security/settings/api-keys>.
- A **test endpoint** (your own workstation is fine) with Cursor installed, so you can verify the rollout before going broad.

> _Screenshot placeholder 1 - **Cursor admin dashboard landing**: full-window screenshot of the Cursor admin dashboard at `cursor.com/dashboard`, with the left-hand navigation visible. Highlight (with a red box or arrow) **Settings → Plugins**. Caption: "The Plugins area of the Cursor admin dashboard is where the Team Marketplace lives."_

---

## Step 1 - Import the Rogue marketplace into Cursor

The Rogue plugin lives in a public GitHub repository - the consolidated `rogue-plugins` monorepo, which houses the Rogue integrations for Claude Code, OpenAI Codex, and Cursor side by side. Cursor reads the Cursor marketplace manifest (`.cursor-plugin/marketplace.json`) from the repo root and serves the plugin from `plugins/cursor/`. You'll register that repo as a Team Marketplace inside Cursor.

1. Sign in to <https://cursor.com/dashboard> with a Cursor admin account.
2. Open **Settings → Plugins**.
3. Under **Team Marketplaces**, click **Import**.
4. Paste the repository URL:

   ```
   https://github.com/qualifire-dev/rogue-plugins
   ```

5. Cursor parses the marketplace manifest and shows the `rogue-security` plugin available for distribution.
6. Set a marketplace **name** (e.g., `Rogue Security`) and a short **description**, then save.

> _Screenshot placeholder 2 - **Team Marketplaces → Import dialog**: the Import dialog open, with the GitHub URL pasted into the input. Highlight the URL field and the Import button. Caption: "Paste the public Rogue plugin repo URL - Cursor reads the marketplace manifest from `main`."_

> _Screenshot placeholder 3 - **Marketplace successfully imported**: the Team Marketplaces section showing the newly imported "Rogue Security" entry, with the `rogue` plugin listed underneath and a status indicating it's available for distribution. Caption: "Marketplace imported. Plugin is visible but not yet distributed."_

> **GitHub Enterprise Server (self-hosted GHE) users:** register a Cursor GHE app at <https://cursor.com/dashboard?tab=integrations> and install it in your GHE organization before importing the marketplace. Otherwise Cursor cannot read the manifest. The repo URL you paste will then be your GHE URL, not github.com.

> **Source review.** Security teams typically review the plugin source before importing it as a Team Marketplace. The full source is in the `rogue-plugins` monorepo at <https://github.com/qualifire-dev/rogue-plugins>; the Cursor plugin specifically lives under [`plugins/cursor/`](https://github.com/qualifire-dev/rogue-plugins/tree/main/plugins/cursor).

---

## Step 2 - Distribute the plugin

Decide who receives the plugin and in which install mode.

### Audience

Under **Team Access** in the marketplace settings, choose which distribution groups receive the plugin - typically **all developers**. If your org uses **SCIM with Cursor**, manage distribution groups in your IdP (Okta, Entra, etc.); Cursor syncs group membership automatically, so onboarding a new engineer to your "Engineering" group will deploy Rogue to their Cursor install on next launch.

### Install mode

Cursor offers three modes:

| Mode | Behavior |
|---|---|
| **Default Off** | Visible in the developer's marketplace; they choose whether to install. |
| **Default On** | Installed automatically; developer can uninstall. |
| **Required** | Installed automatically; developer **cannot** uninstall or disable it. |

Set the rogue plugin to **Required**. Cursor's own guidance reserves Required mode for security-critical tools - that's exactly the case here. A single un-instrumented endpoint is a blind spot, so the value of the plugin depends on it being present everywhere with no opt-out.

If you'd prefer a phased rollout, start with **Default On** for a 1-2 week pilot in a single group, then switch to **Required** organization-wide once you have signal.

> _Screenshot placeholder 4 - **Distribution mode set to Required**: the plugin's distribution settings panel with **Required** selected and an audience picker visible (for example, "All developers" or a SCIM-synced group). Caption: "Required mode is what makes this enforceable - developers cannot disable Rogue."_

---

## Step 3 - Push the API key to endpoints via MDM

The marketplace install delivers **plugin code** to every endpoint. It does **not** deliver an API key - Cursor marketplaces don't ship secrets. You need to write a small credentials file to each developer's home directory: `~/.rogue-env`, mode `600`.

That's the whole job. The plugin auto-detects the developer's identity (email and name) from `git config --global` at session start, so the file only needs **one** line.

### File contents

```sh
# ~/.rogue-env - managed by MDM. Do not edit.
export ROGUE_API_KEY=rsk_xxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxx
```

> **About the API key.** The Rogue API key is an **attribution token**, not a credential in the usual sense. It can only POST hook events to `api.rogue.security` - it cannot read data, fetch configuration, or change anything on your org. Treat a leaked key as a noise-attribution problem (rotate it in the dashboard and re-ship), not a data-exfiltration one.

### MDM deployment snippet

MDM agents run as root, so the script needs to write into the **logged-in user's** home directory. This pattern works for any MDM that lets you run a root-level shell script (Jamf, Intune, Kandji, Workspace ONE, etc.) on macOS:

```sh
#!/bin/bash
# Drop ~/.rogue-env for the console user. macOS - adapt path detection for Linux.
set -euo pipefail

ROGUE_API_KEY="rsk_xxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxx"

# Console user (the human at the keyboard), not root.
CONSOLE_USER=$(stat -f%Su /dev/console)
USER_HOME=$(eval echo "~${CONSOLE_USER}")

umask 077
cat > "${USER_HOME}/.rogue-env" <<EOF
export ROGUE_API_KEY=${ROGUE_API_KEY}
EOF
chmod 600 "${USER_HOME}/.rogue-env"
chown "${CONSOLE_USER}" "${USER_HOME}/.rogue-env"
```

For Linux endpoints, replace the console-user detection with whatever your MDM exposes (`$USER`, `logname`, or an MDM-provided variable) and drop the `chown` group flag if needed.

Drop this script into your MDM as a one-shot policy scoped to your developer group, and re-run it whenever you rotate the API key.

### Verifying the file landed

On a managed endpoint, as the developer:

```sh
ls -l ~/.rogue-env        # → -rw------- 1 user staff
cat ~/.rogue-env          # → export ROGUE_API_KEY=rsk_...
```

If the file is missing or world-readable, fix the MDM script before continuing.

> _Screenshot placeholder 5 - **MDM policy view**: your MDM console (Jamf / Intune / Kandji) showing the script that delivers `~/.rogue-env`, scoped to your developer group. Highlight the scope and the success rate. Caption: "Push `~/.rogue-env` via MDM so the API key is in place before developers open Cursor."_

---

## Step 4 - Verify the rollout

Verify on at least one endpoint before considering the rollout done. The check is done from inside Cursor on a real machine in the target audience.

1. On a targeted endpoint, fully quit and reopen **Cursor**.
2. Confirm `~/.rogue-env` exists with mode `600` on the developer's account (see [Verifying the file landed](#verifying-the-file-landed) above).
3. In Cursor, run `/rogue:status` in the chat - you should see **API: reachable** and a non-zero hook count.
4. Send any benign prompt in agent mode. Within a few seconds it should appear in the AIDR dashboard at <https://app.rogue.security/aidr>.

This proves end-to-end: marketplace install worked, MDM dropped credentials, and the API key is valid.

> _Screenshot placeholder 6 - **`/rogue:status` output in Cursor**: a Cursor chat panel showing the result of `/rogue:status`, with **API: reachable** highlighted and a hook count visible. Caption: "Verify on a real endpoint - plugin loaded, credentials found, API reachable."_

> _Screenshot placeholder 7 - **AIDR dashboard receiving events**: the Rogue AIDR dashboard at `app.rogue.security/aidr` showing recent events from the test endpoint, demonstrating end-to-end connectivity. Caption: "Events from the test endpoint appearing in AIDR confirms the API key is working."_

---

## Configuration reference

These environment variables are read from `~/.rogue-env` (mode `600`) at every Cursor session start:

| Variable | Required | Purpose |
|---|---|---|
| `ROGUE_API_KEY` | Yes | API key from <https://app.rogue.security/settings/api-keys>. |
| `ROGUE_BASE_URL` | No | Override the API endpoint (default `https://api.rogue.security`). |
| `ROGUE_AUTO_UPDATE` | No | Set `0` to disable the background updater (one-line install only - irrelevant for marketplace installs, since Cursor manages updates). |
| `ROGUE_PLUGIN_VERSION` | No | Pin to a specific release (e.g., `v1.0.0`). One-line install only. |

The developer's identity (`ROGUE_ACTOR_EMAIL` and `ROGUE_ACTOR_NAME`) is auto-detected from `git config --global user.email` and `git config --global user.name` at install / session time, so you do **not** need to set these in MDM. They can still be set explicitly in `~/.rogue-env` if you want to override what `git config` returns.

---

## Troubleshooting

**Plugin appears installed but no events show up in AIDR.**
Almost always a missing credential file or an unreachable API. Check, in order:

1. `cat ~/.rogue-env` on the affected endpoint - does the file exist and contain `ROGUE_API_KEY`?
2. `curl -fsS -H "x-rogue-api-key: $ROGUE_API_KEY" https://api.rogue.security/api/v1/hooks/ping` from the endpoint - does it return HTTP 200?
3. If both pass, the plugin should be sending events; check the AIDR dashboard filter.

The plugin is designed to fail-open - if it cannot reach the API or has no API key, it stays silent rather than blocking the user, so this failure mode is not visible to end users.

**Marketplace import rejected by Cursor.**
Confirm the URL is exactly `https://github.com/qualifire-dev/rogue-plugins` (public repo). For GHE-hosted forks, confirm the Cursor GHE app is installed in your org first.

**Developers in a SCIM-synced group aren't receiving the plugin.**
SCIM sync is not instant. Wait a sync interval (typically 15-60 minutes depending on your IdP), then confirm the developer's group membership in Cursor's user list before debugging further.

**`/rogue:status` says "API: unreachable" but the file is present.**
The endpoint can't reach `api.rogue.security`. If your network filters outbound traffic via a corporate proxy, firewall, SSE/SWG (Zscaler, Netskope, etc.), or VPN split-tunnel, allowlist `*.rogue.security` in that layer.

**Need to rotate the API key.**
Generate a new key in <https://app.rogue.security/settings/api-keys>, update the MDM script with the new value, and re-run it across your developer group. The old key continues to work until you revoke it in the dashboard, so there is no downtime.

**Developer reported a false positive.**
They can prepend `rgx!` to the offending prompt. That request is allowed through and the previous detection is flagged as a false positive in AIDR. Per-prompt only - it doesn't whitelist anything globally.

### No-MDM fallback

If you don't run MDM, two options:

- **Per-user `/setup` command.** After the marketplace install lands on a developer's machine, they run `/rogue:setup` once inside Cursor, which writes `~/.rogue-env` with their API key. Works for smaller teams; relies on each developer completing the step.
- **One-line installer in non-interactive mode.** Push a provisioning script (via SSH bootstrap, dotfiles repo, onboarding doc) that runs:

  ```sh
  curl -fsSL https://raw.githubusercontent.com/qualifire-dev/rogue-plugins/main/install.sh \
    | ROGUE_API_KEY=rsk_xxxxxxxx bash -s -- --cursor --non-interactive
  ```

  The installer auto-detects email and name from `git config --global`, so you usually don't need to pass them. If `git config` isn't set on the box, pass `ROGUE_ACTOR_EMAIL` / `ROGUE_ACTOR_NAME` as additional env vars.

Neither is enforceable the way an MDM + Required marketplace combination is. Use MDM if you can.

---

## Quick reference

| Item | Value |
|---|---|
| Marketplace URL | `https://github.com/qualifire-dev/rogue-plugins` |
| MDM credentials path | `~/.rogue-env` (mode 600, owned by the developer) |
| Recommended distribution mode | **Required** |
| Verification command | `/rogue:status` in Cursor |
| AIDR dashboard | <https://app.rogue.security/aidr> |
| Failure behavior | Fail-open (plugin never blocks Cursor) |
| False-positive escape hatch | Prepend `rgx!` to the prompt |

For questions or rollout help: **support@rogue.security**.
