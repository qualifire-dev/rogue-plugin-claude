#!/usr/bin/env node
// Rogue Security — Gemini CLI presence heartbeat.
//
// Spawned detached by hook.mjs on SessionStart. POSTs /api/v1/hooks/status so
// this install shows up in the dashboard's Coding Agents roster (Connected /
// version / host / user) and the org learns which plugin version runs. Pure
// side-effect: fire-and-forget, never blocks Gemini, exits 0 on every path.
//
// The roster dedups one row per (host | actor-email | family | agent), so we
// always send a stable host + actor-email. Family is the fixed enum "gemini";
// the surface rides `agent` as "gemini_cli" (drives the dashboard version badge).

import os from "node:os";
import { loadEnvFiles, gitConfig, installId } from "./shared.mjs";

async function main() {
  const env = loadEnvFiles();
  const apiKey = env.ROGUE_API_KEY || "";
  if (!apiKey) return; // not configured → no-op

  const email =
    env.ROGUE_ACTOR_EMAIL || gitConfig("user.email") || os.hostname() || "";
  let name = env.ROGUE_ACTOR_NAME || gitConfig("user.name");
  if (!name) {
    try {
      name = os.userInfo().username;
    } catch {
      name = "";
    }
  }

  const base = (env.ROGUE_BASE_URL || "https://api.rogue.security").replace(
    /\/+$/,
    "",
  );
  // Same three values hook.mjs sends as headers on every event, so both writers
  // land on one roster row (see installId).
  const install = installId();
  const body = JSON.stringify({
    agent_family: "gemini",
    agent: install.agent,
    version: install.version,
    host: install.host,
    actor_email: email,
    actor_name: name || "",
  });

  try {
    await fetch(`${base}/api/v1/hooks/status`, {
      method: "POST",
      headers: {
        "Content-Type": "application/json",
        "x-rogue-api-key": apiKey,
      },
      body,
      signal: AbortSignal.timeout(10000),
    });
  } catch {
    /* fire-and-forget */
  }
}

main().finally(() => process.exit(0));
