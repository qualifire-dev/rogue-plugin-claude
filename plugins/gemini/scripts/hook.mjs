#!/usr/bin/env node
// Rogue Security — Gemini CLI hook dispatcher.
//
// Usage: node hook.mjs <EventName>
//   Reads the Gemini hook JSON payload on stdin, POSTs it to Rogue, and relays
//   the response verbatim on stdout. The backend already emits Gemini's native
//   decision shapes ({"decision":"deny"|"block", "reason":...} / toolConfig), so
//   this dispatcher is a PURE RELAY — Gemini renders the block itself.
//
// One cross-platform script replaces the sh + PowerShell dual-dispatcher used by
// the Claude/Codex/Cursor plugins: Gemini CLI guarantees Node 20+ on PATH (every
// install method requires it; Homebrew declares `node` as a dependency), so we
// use Node built-ins only (global fetch, node:fs/os/path/child_process) — no
// curl, no jq, no dependencies, no build step.
//
// Fail-open by design: any missing key / network error / bad response prints
// "{}" (allow) and exits 0. stdout carries ONLY the final JSON, per the Gemini
// hook contract; everything else goes to the log file.

import fs from "node:fs";
import os from "node:os";
import path from "node:path";
import { spawn } from "node:child_process";
import { HOME, SCRIPT_DIR, loadEnvFiles, gitConfig, installId } from "./shared.mjs";

const EVENT = process.argv[2] || "unknown";

// Surface label stamped on every log line. The hook log (~/.rogue/hook.log) is
// SHARED with the Claude/Codex/Cursor plugins, so this token is what lets you
// tell whose events a line belongs to when reading the merged file.
const PROVIDER = "gemini_cli";

// ── Emit + exit ────────────────────────────────────────────────────────────
// stdout must be ONLY the final JSON object. Always exit 0 — a blocking verdict
// is carried in the relayed JSON body, not the exit code.
function emit(obj) {
  process.stdout.write(typeof obj === "string" ? obj : JSON.stringify(obj));
  process.exit(0);
}

// ── Logging (file only; stdout is reserved for Gemini) ───────────────────────
const LOG_FILE =
  process.env.ROGUE_LOG_FILE || path.join(HOME, ".rogue", "hook.log");
// eslint-disable-next-line no-control-regex
const CONTROL_CHARS = /[\x00-\x1f\x7f]/g;
const sanitize = (s) => String(s ?? "").replace(CONTROL_CHARS, "");
function log(msg) {
  try {
    fs.mkdirSync(path.dirname(LOG_FILE), { recursive: true });
    const ts = new Date().toISOString().replace(/\.\d+Z$/, "Z");
    fs.appendFileSync(LOG_FILE, `${ts} provider=${PROVIDER} event=${EVENT} ${msg}\n`);
  } catch {
    /* logging is best-effort */
  }
}

// Actor cascade (mirrors scripts/actor.sh): env → git --global → host/user.
function resolveActor(env) {
  const email =
    env.ROGUE_ACTOR_EMAIL ||
    gitConfig("user.email") ||
    os.hostname() ||
    "unknown";
  let name = env.ROGUE_ACTOR_NAME || gitConfig("user.name");
  if (!name) {
    try {
      name = os.userInfo().username;
    } catch {
      name = "unknown";
    }
  }
  return { email, name: name || "unknown" };
}

// ── Detached heartbeat (SessionStart only) ──────────────────────────────────
// Fire-and-forget so it never adds latency to session start.
function fireHeartbeat() {
  try {
    const child = spawn(
      process.execPath,
      [path.join(SCRIPT_DIR, "heartbeat.mjs")],
      { detached: true, stdio: "ignore" },
    );
    child.unref();
  } catch {
    /* best-effort */
  }
}

// ── Block detection (for the log only; the body is relayed verbatim) ─────────
function describeOutcome(bodyText) {
  try {
    const j = JSON.parse(bodyText);
    const decision = j?.decision;
    const toolMode = j?.hookSpecificOutput?.toolConfig?.mode;
    if (decision === "deny" || decision === "block" || toolMode === "NONE") {
      const reason =
        j?.reason ?? j?.systemMessage ?? j?.stopReason ?? "blocked";
      return `outcome=block reason="${sanitize(reason)}"`;
    }
  } catch {
    /* non-JSON / empty → treated as allow */
  }
  return "outcome=allow";
}

// ── Read all of stdin ────────────────────────────────────────────────────────
function readStdin() {
  return new Promise((resolve) => {
    const chunks = [];
    process.stdin.on("data", (c) => chunks.push(c));
    process.stdin.on("end", () => resolve(Buffer.concat(chunks).toString("utf8")));
    process.stdin.on("error", () => resolve(""));
    // If nothing is piped, don't hang.
    if (process.stdin.isTTY) resolve("");
  });
}

async function main() {
  const env = loadEnvFiles();
  const apiKey = env.ROGUE_API_KEY || "";

  // SessionStart: fire the detached roster heartbeat, then fall through to POST
  // the event like any other so it is captured for audit. SessionStart is
  // advisory in Gemini (its decision is ignored), so the relayed response can't
  // block — we still send it so nothing is dropped. Unconfigured → emit the
  // /setup hint and return without POSTing.
  if (EVENT === "SessionStart") {
    if (!apiKey) {
      log("outcome=unconfigured");
      return emit({
        systemMessage:
          "[Rogue Security] Not configured. Run /setup to connect your API key.",
      });
    }
    fireHeartbeat();
  }

  if (!apiKey) {
    log("outcome=unconfigured");
    return emit({});
  }

  const payload = await readStdin();
  const actor = resolveActor(env);
  const base = (env.ROGUE_BASE_URL || "https://api.rogue.security").replace(
    /\/+$/,
    "",
  );
  const url = env.ROGUE_API_URL || `${base}/api/v1/hooks/gemini`;
  // Host + version + surface, resolved exactly as heartbeat.mjs does. Sent on
  // every event so the fleet roster's row stays fresh between session starts,
  // which are the only moments the heartbeat runs. See installId.
  const install = installId();

  let bodyText = "{}";
  try {
    const resp = await fetch(url, {
      method: "POST",
      headers: {
        "Content-Type": "application/json",
        "x-rogue-api-key": apiKey,
        "x-rogue-event": EVENT,
        "x-rogue-actor-email": actor.email,
        "x-rogue-actor-name": actor.name,
        "x-rogue-host": install.host,
        "x-rogue-version": install.version,
        "x-rogue-agent": install.agent,
      },
      body: payload,
      signal: AbortSignal.timeout(15000),
    });
    if (resp.ok) {
      const text = await resp.text();
      if (text && text.trim()) {
        try {
          JSON.parse(text); // relay only well-formed JSON; malformed → fail-open
          bodyText = text;
        } catch {
          bodyText = "{}";
        }
      }
      log(`http=${resp.status} ${describeOutcome(bodyText)}`);
    } else {
      log(`http=${resp.status} outcome=fail-open`);
      bodyText = "{}";
    }
  } catch (e) {
    log(`error="${sanitize(e && e.message)}" outcome=fail-open`);
    bodyText = "{}";
  }

  return emit(bodyText);
}

main().catch((e) => {
  try {
    log(`error="${sanitize(e && e.message)}" outcome=fail-open`);
  } catch {
    /* ignore */
  }
  emit({});
});
