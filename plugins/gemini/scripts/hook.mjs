#!/usr/bin/env node
// Rogue Security — Gemini CLI hook dispatcher.
//
// Usage: node hook.mjs <EventName>
//   Reads the Gemini hook JSON payload on stdin, POSTs it to Rogue, and relays
//   the response verbatim on stdout. The backend already emits Gemini's native
//   decision shapes ({"decision":"deny"|"block", "reason":...} / toolConfig), so
//   this dispatcher is a PURE RELAY — Gemini renders the block itself.
//
// The POSTed body is BYTE-FOR-BYTE the bytes read from stdin. The dispatcher
// does parse those bytes (into a local, for subagent attribution — see
// resolveSubagentId), but the parse result never reaches the request: everything
// it derives travels as a HEADER. Never re-serialize the payload into `body`.
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
import { HOME, SCRIPT_DIR, loadEnvFiles, gitConfig } from "./shared.mjs";

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

// ── Subagent attribution (x-rogue-agent-id) ─────────────────────────────────
//
// A Gemini subagent's OWN hook events are shape-identical to the main agent's:
// createBaseInput emits only session_id / transcript_path / cwd /
// hook_event_name / timestamp, and nothing in the payload names the delegation
// that is running. But Gemini's own transcript records do, and the rule is a
// BOOKKEEPING one rather than a timing one:
//
//   a delegation appears in the subagent directory when it STARTS,
//   and in the parent transcript when it ENDS,
//   so (started minus finished) is what is running right now.
//
//   dir      = dirname(transcript_path) / sanitize(session_id)
//   started  = the .jsonl basenames in dir   (each IS a subagent session UUID)
//   finished = those recorded in the parent transcript
//   agentId  = the single remaining one, or nothing
//
// Both sides are append-only records upstream writes for its own reasons, so
// NO timestamp of any kind is read or compared: not file mtimes, not record
// timestamps. The answer is the same however long a hook takes and whatever the
// filesystem does with timestamp resolution.
//
// Bundle citations (Gemini CLI 0.55.1, @google/gemini-cli chunk-TBDX7VEE.js):
//   :285510-285531  ChatRecordingService.initialize — a subagent's transcript is
//                   `<chats>/<sanitizeFilenamePart(parentSessionId)>/<sessionId>.jsonl`,
//                   while the main session file sits directly in `<chats>/`.
//   :253978-253980  sanitizeFilenamePart = part.replace(/[^a-zA-Z0-9_-]/g, "_").
//   :331296         recordCompletedToolCalls stamps `agentId` (the subagent's
//                   session UUID, i.e. its filename) on the parent's completed
//                   invoke_agent record. That record is the "finished" marker.
//
// THE ONE ASSUMPTION: the parent's completion record must land BEFORE the main
// agent's next tool hook. It does structurally, not by timing margin —
// recordCompletedToolCalls is documented (:331283-331284) as running "before
// sending responses to Gemini" and its caller (:347827) invokes it as soon as
// scheduleAgentTools resolves, so the model roundtrip that produces the next
// tool call cannot precede it. If upstream ever reordered that, a finished
// delegation would stay "live" and a MAIN-agent tool row would be tagged with a
// subagent's UUID. That is the only route in this design to a WRONG id; every
// other failure yields no header at all. A main-agent row carrying a subagent
// UUID is the signature to look for after a Gemini version bump.
//
// The same ordering is what makes the delegation report itself work: the
// AfterTool invoke_agent hook fires before the completion record is written, so
// the finishing delegation is still "live" and its report row gets the id.

// Cost guards. A session that never delegates pays one ENOENT and stops.
const PARENT_MAX_BYTES = 32 * 1024 * 1024; // over this, send no header
const CANDIDATE_HEAD_BYTES = 64 * 1024; // enough for a subagent's first record

// Which events may carry the tag. Only a tool event can be fired BY a subagent.
// BeforeAgent/AfterAgent/BeforeModel/SessionStart/... are never a subagent's,
// and BeforeAgent carries the developer's prompt, where a wrong tag is worst.
//
// `BeforeTool invoke_agent` (the main agent's delegation REQUEST) is excluded as
// a CORRECTNESS GUARD, not merely for semantics: in a parallel batch of two
// invoke_agent calls the first delegation's file already exists when the
// second's BeforeTool fires, so the rule would hand the FIRST agent's id to the
// SECOND agent's request. Suppressing the event removes the case entirely.
// (Delegations are parallelizable: _isParallelizable, :346148, returns false
// only for edit tools, update_topic, and an explicit wait_for_previous: true.)
// `AfterTool invoke_agent` is included — that one IS the subagent's own report.
function isAgentTaggableEvent(parsed) {
  if (EVENT === "AfterTool") return true;
  if (EVENT === "BeforeTool") return parsed.tool_name !== "invoke_agent";
  return false;
}

// Read a file as UTF-8, or null if it is missing, unreadable or over `maxBytes`.
function readCapped(file, maxBytes) {
  try {
    if (fs.statSync(file).size > maxBytes) return null;
    return fs.readFileSync(file, "utf8");
  } catch {
    return null;
  }
}

// The delegated prompts recorded in the parent, JSON-escaped for a raw-text
// substring test against a subagent file (see hasDelegatedPrompt). Only lines
// mentioning invoke_agent are parsed; the rest of the transcript is never JSON.
function delegatedPrompts(parentText) {
  const out = [];
  for (const line of parentText.split("\n")) {
    if (!line.includes("invoke_agent")) continue;
    let record;
    try {
      record = JSON.parse(line);
    } catch {
      continue;
    }
    for (const call of record?.toolCalls ?? []) {
      const prompt = call?.args?.prompt;
      if (call?.name === "invoke_agent" && typeof prompt === "string" && prompt) {
        out.push(JSON.stringify(prompt).slice(1, -1));
      }
    }
  }
  return out;
}

// Fallback "finished" key for a delegation that ended WITHOUT an agentId: that
// value is read out of the tool RESPONSE, so an errored / cancelled / max-turns
// agent can be recorded without one, and it would otherwise stay "live" for the
// rest of the session and mis-tag every later main-agent tool call. `args` comes
// from the REQUEST and is always there, and the subagent's first `user` record
// embeds the delegated prompt verbatim inside its context preamble.
//
// Compared JSON-escaped against the raw head, so no parse of a possibly
// truncated head is needed and a multi-line prompt still matches. An unreadable
// head returns false, i.e. the candidate stays live and the usual
// unique-or-nothing guard applies.
function hasDelegatedPrompt(file, escapedPrompts) {
  if (escapedPrompts.length === 0) return false;
  let head = "";
  try {
    const fd = fs.openSync(file, "r");
    try {
      const buf = Buffer.alloc(CANDIDATE_HEAD_BYTES);
      const n = fs.readSync(fd, buf, 0, CANDIDATE_HEAD_BYTES, 0);
      head = buf.subarray(0, n).toString("utf8");
    } finally {
      fs.closeSync(fd);
    }
  } catch {
    return false;
  }
  return escapedPrompts.some((p) => head.includes(p));
}

// Returns the running delegation's session UUID, or undefined. NEVER throws:
// every failure path is "no header", because a wrong agent id is worse than a
// missing one and a throw here would cost the POST itself.
function resolveSubagentId(parsed) {
  try {
    if (!parsed || typeof parsed !== "object") return undefined;
    if (!isAgentTaggableEvent(parsed)) return undefined;

    const transcript = parsed.transcript_path;
    const session = parsed.session_id;
    if (typeof transcript !== "string" || !transcript) return undefined;
    if (typeof session !== "string" || !session) return undefined;

    // Upstream's own sanitizer (:253978-253980); it also makes the joined path
    // traversal-proof, since "/" and "." both become "_".
    const dir = path.join(
      path.dirname(transcript),
      session.replace(/[^a-zA-Z0-9_-]/g, "_"),
    );
    // No delegation in this session → ENOENT → no header, the common case.
    const started = fs
      .readdirSync(dir)
      .filter((f) => f.endsWith(".jsonl"))
      .map((f) => f.slice(0, -".jsonl".length));
    if (started.length === 0) return undefined;

    // Unreadable / absent (recording disabled, conversationFile nulled after
    // ENOSPC) or oversized: `finished` is uncomputable and every candidate would
    // look live, so send nothing.
    const parent = readCapped(transcript, PARENT_MAX_BYTES);
    if (parent === null) return undefined;

    // A subagent UUID appears in the parent on exactly one line, its completion
    // record, so the primary key is a plain substring test that needs no JSON
    // parsing at all. Everything recorded → nothing is running.
    const unresolved = started.filter((id) => !parent.includes(id));
    if (unresolved.length === 0) return undefined;

    // Only what the substring test missed pays for the prompt fallback.
    const prompts = delegatedPrompts(parent);
    const live = unresolved.filter(
      (id) => !hasDelegatedPrompt(path.join(dir, `${id}.jsonl`), prompts),
    );

    // Zero → a main-agent event. Two or more → concurrent delegations, which the
    // rule cannot separate. Both send nothing.
    if (live.length !== 1) return undefined;
    // The id is a filename, i.e. arbitrary bytes from disk. An invalid header
    // value makes fetch THROW, which would fail-open the whole POST — far worse
    // than no attribution. It must look like the vendor UUID it is, and the
    // backend rejects (never truncates) an id over 64 chars.
    const id = live[0];
    return /^[A-Za-z0-9_-]{1,64}$/.test(id) ? id : undefined;
  } catch {
    return undefined;
  }
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

  // Inspect the relayed bytes in a LOCAL. The parse result is only ever read
  // from — `body: payload` below stays the exact bytes Gemini piped in.
  let parsed = null;
  try {
    parsed = JSON.parse(payload);
  } catch {
    parsed = null;
  }
  const agentId = resolveSubagentId(parsed);
  const agentLog = `agent=${agentId || "none"}`;

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
        // Only the id. The agent NAME is already inside the relayed bytes on the
        // one event that has one (AfterTool invoke_agent's tool_input.agent_name)
        // and the backend reads it from there, so a name header would duplicate a
        // field for zero information.
        ...(agentId ? { "x-rogue-agent-id": agentId } : {}),
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
      log(`http=${resp.status} ${agentLog} ${describeOutcome(bodyText)}`);
    } else {
      log(`http=${resp.status} ${agentLog} outcome=fail-open`);
      bodyText = "{}";
    }
  } catch (e) {
    log(`error="${sanitize(e && e.message)}" ${agentLog} outcome=fail-open`);
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
