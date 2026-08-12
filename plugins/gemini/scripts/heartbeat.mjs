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

import fs from "node:fs";
import os from "node:os";
import path from "node:path";
import { EXT_ROOT, loadEnvFiles, gitConfig } from "./shared.mjs";

// Read the extension version from the manifest (source of truth).
function readVersion() {
  try {
    const m = JSON.parse(
      fs.readFileSync(path.join(EXT_ROOT, "gemini-extension.json"), "utf8"),
    );
    return typeof m.version === "string" ? m.version : "unknown";
  } catch {
    return "unknown";
  }
}

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
  const version = readVersion();
  const body = JSON.stringify({
    agent_family: "gemini",
    agent: "gemini_cli",
    version,
    host: os.hostname() || "unknown",
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

  // ── ship the hook log ──────────────────────────────────────────────────────
  // AFTER the status POST, as in every other plugin: the heartbeat is what creates
  // or refreshes the roster row an uploaded log attaches to, so this order means
  // the server has somewhere to put the logs before they arrive.
  //
  // IN-PROCESS, unlike the sh and PowerShell callers, which spawn a child. Those
  // have to: a sourced sh script shares every variable, and a PowerShell
  // scriptblock resolves `$script:` against the caller's scope. An ESM module has
  // neither problem - its scope is its own - and ship-logs.mjs only calls
  // process.exit from the `argv[1] === this file` auto-run branch, which an import
  // does not take. So this saves a whole node startup for free. This script is
  // already spawned detached by hook.mjs, so nothing a user sees waits on it.
  //
  // THE ACTOR MUST BE PUT INTO process.env FIRST. It is resolved into module
  // locals above (never process.env), and the shipper reads it from the
  // environment because it deliberately has no cascade of its own - the plugins'
  // cascades differ, so a re-resolve would key the log's source row differently
  // from the roster row just posted and the logs would attach to nothing. Note
  // loadEnvFiles() returns a merged object WITHOUT mutating process.env, which is
  // exactly why this assignment is needed rather than assumed.
  try {
    process.env.ROGUE_ACTOR_EMAIL = email;
    process.env.ROGUE_ACTOR_NAME = name || "";
    const shipper = await import("./ship-logs.mjs");
    await shipper.main([EXT_ROOT, "gemini", version, "gemini"]);
  } catch {
    /* a missing or broken shipper must never affect the heartbeat */
  }
}

main().finally(() => process.exit(0));
