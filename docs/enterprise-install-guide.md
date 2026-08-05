# Installing the Rogue Security Claude Plugin (Enterprise)

This guide walks an enterprise admin through deploying the **Rogue Security plugin for Claude Code / Claude Cowork** across an organization using the Claude enterprise admin console. The plugin observes Claude lifecycle events and forwards them to Rogue Security for prompt-injection, secret-exfiltration, and destructive-command detection.

You will:

1. Confirm prerequisites
2. Obtain the signed plugin package from Rogue Security
3. Allow network egress to the Rogue API
4. Upload the plugin to the admin console
5. Distribute it to users — either as **required** (auto-installed) or **available** (self-install)
6. Verify the rollout on an endpoint

The entire process typically takes 10–15 minutes for an initial deployment.

---

## Prerequisites

Before you begin, make sure you have:

- **Admin access** to your Claude enterprise admin console with permission to manage plugins and egress settings.
- The **plugin `.zip` package** from Rogue Security. The package you receive is pre-provisioned with your organization's API key, so no additional configuration is required after upload. The filename will look similar to `rogue-security-claude-plugin-<org>-<version>.zip`.
- A short list of **target users, groups, or teams** that should receive the plugin. You can change this later.
- A **test endpoint** (your own workstation is fine) with Claude Code or Claude Cowork installed, so you can verify the rollout before going broad.

> _Screenshot placeholder 1 — **Admin console landing page**: full-window screenshot of the Claude enterprise admin console home, with the left-hand navigation visible. Highlight (with a red box or arrow) the **Plugins** entry in the side nav and the **Settings → Network / Egress** entry. Caption: "Two areas of the admin console you will touch in this guide."_

---

## Step 1 — Obtain the plugin package

Request the plugin from your Rogue Security contact. You will receive a single `.zip` file (for example, `rogue-security-claude-plugin-acme-1.0.10.zip`).

A few things to know about the package:

- It is **already provisioned for your organization** — the API key and any org-specific defaults are baked in. Do not edit the zip.
- The filename includes the **version**. Keep it intact; the admin console uses it to track which build is deployed.
- If you receive multiple zips (for example, one per environment), pick the one that matches the environment you are configuring.

Save the file somewhere you can reach from the browser you will use to sign in to the admin console.

---

## Step 2 — Sign in to the Claude enterprise admin console

Open your enterprise admin console and authenticate with an account that has plugin-management privileges. If your organization uses SSO, sign in with the IdP account that is mapped to the admin role.

> _Screenshot placeholder 2 — **Sign-in screen**: the admin console login page. Either the SSO redirect prompt or the email/password form, depending on your auth setup. Caption: "Sign in with an admin-privileged account — plugin management is gated behind admin role."_

Once signed in, confirm in the top-right user menu that you are operating in the correct organization (some admins manage multiple). If you are in the wrong tenant, switch before continuing.

---

## Step 3 — Allow egress to the Rogue API

The plugin POSTs lifecycle event payloads to the Rogue Security API. If your organization restricts outbound network access from Claude Code clients, you need to allow the Rogue domain **before** rolling the plugin out — otherwise hooks will fail to reach the API and the plugin will silently fail-open (no security signal) on every endpoint.

1. In the admin console, open **Settings → Network**, **Egress**, or **Allowlisted Domains** (the exact label varies by console version).
2. Add the following domain to the allowlist:

   ```
   *.rogue.security
   ```

   This wildcard covers the API host (`api.rogue.security`) plus any regional or future subdomains Rogue may use.

3. **Save** the change. If your console requires a separate "publish" or "apply" step for network settings, do that as well.

> _Screenshot placeholder 3 — **Egress allowlist before/after**: the network/egress settings panel with the `*.rogue.security` entry just added and highlighted. If your console shows a list of existing entries, capture the full list so it is clear the new entry was added (not replacing anything). Caption: "Add `*.rogue.security` to the allowlist and save before uploading the plugin."_

> **Tip:** if your network team manages egress outside the Claude admin console (for example, in a corporate proxy or firewall), repeat this step there as well. The admin console allowlist alone is not sufficient if traffic is also filtered upstream.

---

## Step 4 — Upload the plugin

1. In the side navigation, go to **Plugins** (or **Extensions** / **Plugin Management**, depending on console version).
2. Click **Upload plugin** (or **Add plugin** / **Import**).
3. Select the `.zip` file you received in Step 1.
4. Wait for the console to validate the package. Validation typically takes a few seconds; a signed, well-formed package is accepted without prompts.
5. Confirm the new plugin appears in the plugin list with:

   - **Name:** Rogue Security (or your org-prefixed variant)
   - **Version:** matches the version in the zip filename
   - **Status:** Available / Ready to distribute (not yet rolled out)

> _Screenshot placeholder 4 — **Upload dialog**: the file-picker / upload modal with the Rogue Security `.zip` selected and the **Upload** button highlighted. Caption: "Select the `.zip` provided by Rogue Security — do not unzip it first."_

> _Screenshot placeholder 5 — **Plugin list after upload**: the Plugins page showing the newly uploaded Rogue Security plugin in the list, with its version visible and a status of "Available" / "Ready". Highlight the row. Caption: "The plugin is uploaded but not yet distributed to any users."_

If the upload is rejected, see [Troubleshooting](#troubleshooting) below.

---

## Step 5 — Distribute the plugin

You have two distribution modes for any plugin in the admin console. Pick the one that matches your security policy.

### Option A — Required (recommended for security plugins)

In **Required** mode, the plugin is installed automatically on every targeted endpoint the next time the user starts Claude Code / Cowork. Users cannot opt out. This is the recommended mode for the Rogue Security plugin, because the value of the plugin depends on it being present everywhere — a single un-instrumented endpoint is a blind spot.

1. From the plugin's detail page, click **Distribute** (or **Manage rollout**).
2. Choose **Required** as the install mode.
3. Pick the audience:

   - **All users** — strongest coverage; recommended for organization-wide security plugins.
   - **Specific groups / teams** — useful for a phased rollout (for example, start with the security team and engineering, then expand).
   - **Specific users** — typically only for pilots.

4. Confirm and publish.

> _Screenshot placeholder 6 — **Required distribution config**: the distribution dialog with **Required** selected and an audience picker visible (for example, "All users" radio chosen). Caption: "Required mode installs the plugin automatically — no user action needed."_

### Option B — Available (self-install)

In **Available** mode, the plugin shows up in the user's in-app plugin catalog, and individual users choose whether to install it. Use this when you want to pilot the plugin with a small group of volunteers, or when a policy forbids forced installs.

1. From the plugin's detail page, click **Distribute**.
2. Choose **Available** as the install mode.
3. Pick the audience as in Option A.
4. Confirm and publish.

Users in the target audience will see the plugin listed in **Customize → Plugins** inside Claude Cowork and can install it from there.

> _Screenshot placeholder 7 — **Available distribution config**: same distribution dialog but with **Available** selected, and a note or banner indicating users will need to opt in. Caption: "Available mode lists the plugin for self-install — useful for pilots."_

### Choosing between Required and Available

| Situation | Recommended mode |
|---|---|
| Organization-wide security baseline | **Required** |
| Phased rollout starting with security / eng | **Required**, narrow audience first |
| Pilot with volunteers before broad rollout | **Available** |
| Policy forbids forced installs | **Available** |

You can change the mode later. A common path is to start with **Available** for a 1–2 week pilot, then switch to **Required** for the full organization once you have signal.

---

## Step 6 — Verify the rollout

Verify on at least one endpoint before considering the rollout done. The check is done from inside Claude Cowork on a real machine in the target audience.

1. On a targeted endpoint, fully quit and reopen **Claude Cowork** (a new session is required to load freshly distributed plugins).
2. In Cowork, open the **Customize** panel (the customization / settings entry in the app — typically a "Customize" button or menu item in the main UI).
3. In the Customize panel, find the **Plugins** section.
4. Confirm the **Rogue Security** plugin is listed and marked **Installed / Active**. If you distributed it as **Required**, it should already be installed with no user action. If you distributed it as **Available**, the user will see it listed and can click **Install** here.
5. Optionally, send a benign test prompt in Cowork and confirm — through the Rogue Security dashboard — that the corresponding hook event was received. This proves end-to-end: plugin loaded, egress allowed, API key valid.

> _Screenshot placeholder 8 — **Cowork Customize entry point**: the Claude Cowork main window with the **Customize** button / menu item highlighted (red box or arrow). Caption: "Open Customize from inside Claude Cowork on a target machine."_

> _Screenshot placeholder 9 — **Customize → Plugins panel showing Rogue Security installed**: the Customize panel open to the Plugins section, with the Rogue Security plugin row highlighted and its status visible as Installed / Active. Caption: "Confirm Rogue Security appears in the plugin list with status Installed."_

> _Screenshot placeholder 10 — **Rogue Security dashboard receiving events** _(optional, only if your Rogue account includes a dashboard)_: the Rogue dashboard showing recent hook events from the test endpoint, demonstrating end-to-end connectivity. Caption: "Events from the test endpoint appearing in Rogue Security confirms egress and API key are working."_

---

## Troubleshooting

**Upload rejected by the admin console.**
Re-download the `.zip` from your Rogue Security contact to rule out a corrupted file. Do not unzip and re-zip the package; that breaks the signature. If the rejection persists, send the error message from the console to Rogue Security support.

**Plugin appears installed but no events show up in Rogue Security.**
Almost always an egress issue. Re-check Step 3: confirm `*.rogue.security` is in the admin console allowlist **and** in any upstream proxy / firewall that filters outbound traffic from Claude clients. The plugin is designed to fail-open — if it cannot reach the API, it stays silent rather than blocking the user, so this failure mode is not visible to end users.

**Plugin fails to load on a specific endpoint.**
Have the user fully quit and reopen Claude Cowork. If the issue persists, ask them to open **Customize → Plugins** and share a screenshot of the panel. Verify the endpoint is in the distribution audience from Step 5 and that the egress allowlist applies to that endpoint's network.

**Users on Available mode aren't seeing the plugin in their catalog.**
Confirm the audience in Step 5 includes them, and that they have restarted Claude after the rollout was published. Plugin catalogs are typically refreshed at session start.

**Need to roll back a version.**
Upload the previous `.zip` (Step 4), redistribute it (Step 5) — the admin console will replace the active version on next session start across the targeted audience.

---

## Quick reference

| Item | Value |
|---|---|
| Egress domain to allow | `*.rogue.security` |
| Verification command | Cowork → **Customize → Plugins** |
| Recommended distribution mode | Required |
| Time to deploy | ~10–15 minutes |
| Failure behavior | Fail-open (plugin never blocks Claude) |

For questions or issues not covered here, contact your Rogue Security account team.
