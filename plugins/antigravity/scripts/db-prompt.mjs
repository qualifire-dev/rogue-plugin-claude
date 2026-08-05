// Recover what an Antigravity IDE turn is doing, from Antigravity's own
// conversation store, at the moments the hook contract can still act on it.
//
// Usage: db-prompt.mjs <prompt|steps>   (stdin: the hook payload)
//
// WHY THIS EXISTS. The IDE writes `transcript.jsonl` only at invocation
// boundaries and at Stop, so the events that can enforce see nothing:
//   * `PreInvocation` — the pending prompt is not on disk yet (verified by
//     polling the file every 0.1s across six held hook windows, 62s of waiting,
//     rows provably pending in memory, zero change).
//   * `PostInvocation` — the tool result the next model call will read is not on
//     disk yet either; it appears only at the following boundary.
// Both ARE already committed to the store, usually in the WAL. Antigravity 2.0
// and the `agy` CLI write the transcript live and need none of this: their tail
// already carries this content at those same events.
//
// WHY THE TWO MODES MAP TO THOSE TWO EVENTS. They are the only events that can
// act: `PreInvocation` can inject (the `systemMessage` arm makes the model
// refuse), `PostInvocation` can `terminate` — and it fires after the tool ran but
// BEFORE the model call that consumes the result, so terminating there prevents
// the exposure rather than reporting it. `PostToolUse` is the natural moment but
// its result message has no fields at all, so it can neither carry a decision nor
// deliver the output.
//
// PURE READER. Prints base64 of a JSON envelope on success, NOTHING otherwise —
// never a hook decision, never JSON on stdout. hook.sh owns the decision shape,
// so a crash here can only ever degrade to "nothing recovered".
//
// Read-only, with one honest caveat: a WAL reader takes a read lock, which writes
// read-mark slots into the `-shm` sidecar. The main `.db` is never written, never
// checkpointed, never opened read-write.
//
// UNDOCUMENTED SURFACE. The store is acknowledged publicly only by one CLI
// changelog line (v1.0.4, 2026-06-06). Field numbers and step types below were
// derived from live data and cross-checked against the documented transcript, so
// everything is validated per read and fails open; `stepFormat` and `userVersion`
// ride along so the backend can alarm on drift.
import { DatabaseSync } from "node:sqlite";
import { existsSync, mkdirSync, readFileSync, statSync, writeFileSync } from "node:fs";
import { homedir } from "node:os";
import { join } from "node:path";

const IDE_SEGMENT = "/antigravity-ide/";
const SUPPORTED_STEP_FORMAT = 0;
const DEADLINE_MS = 150;
const CACHE_DIR = process.env.ROGUE_ANTIGRAVITY_DBPROMPT_DIR
  || join(homedir(), ".rogue", "antigravity-dbprompt");
// Keep the POST sane: a single file read can be enormous, and this rides a hook
// that blocks the developer's turn.
const MAX_TEXT = 16_384;
const MAX_TOTAL = 65_536;

// `steps.step_type`, confirmed by aligning rows against the transcript's `type`.
const STEP = {
  USER_INPUT: 14,
  PLANNER_RESPONSE: 15,
};
// Client scaffolding, excluded for the same reason the transcript parser excludes
// it: CHECKPOINT, EPHEMERAL_MESSAGE, CONVERSATION_HISTORY, KNOWLEDGE_ARTIFACTS.
const BOOKKEEPING_STEPS = new Set([23, 90, 98, 99]);
const SOURCE_USER_EXPLICIT = 4;
const SOURCE_ROGUE_INJECTION = 6; // our own injected block message
// Must stay in sync with blockInstruction() in antigravity-hook-formatter.ts.
const OWN_INJECTION_PREFIX = "[Rogue Security AIDR]";

// ── protobuf wire format ───────────────────────────────────────────────────
// No .proto ships with Antigravity, so this walks the wire format directly. It
// never throws: any malformation (truncation, a length that overruns the buffer,
// an unknown wire type) ends the walk with whatever was valid so far.
function* walk(buf, prefix = "") {
  let i = 0;
  while (i < buf.length) {
    let tag = 0;
    let shift = 0;
    for (;;) {
      if (i >= buf.length) return;
      const b = buf[i++];
      tag |= (b & 0x7f) << shift;
      if (!(b & 0x80)) break;
      shift += 7;
      if (shift > 28) return;
    }
    const num = tag >>> 3;
    const wire = tag & 7;
    if (wire === 0) {
      let value = 0;
      let s = 0;
      for (;;) {
        if (i >= buf.length) return;
        const b = buf[i++];
        value += (b & 0x7f) * 2 ** s;
        if (!(b & 0x80)) break;
        s += 7;
      }
      yield { path: `${prefix}${num}`, num, wire, value };
    } else if (wire === 2) {
      let len = 0;
      let s = 0;
      for (;;) {
        if (i >= buf.length) return;
        const b = buf[i++];
        len += (b & 0x7f) * 2 ** s;
        if (!(b & 0x80)) break;
        s += 7;
      }
      if (i + len > buf.length) return;
      yield { path: `${prefix}${num}`, num, wire, bytes: buf.subarray(i, i + len) };
      i += len;
    } else if (wire === 5) i += 4;
    else if (wire === 1) i += 8;
    else return;
  }
}

function message(buf, num) {
  for (const f of walk(buf)) if (f.num === num && f.wire === 2) return f.bytes;
  return undefined;
}

function varint(buf, num) {
  for (const f of walk(buf)) if (f.num === num && f.wire === 0) return f.value;
  return undefined;
}

function text(buf, ...path) {
  let cur = buf;
  for (const num of path.slice(0, -1)) {
    cur = message(cur, num);
    if (!cur) return undefined;
  }
  const leaf = message(cur, path[path.length - 1]);
  if (!leaf || leaf.length === 0) return undefined;
  return new TextDecoder().decode(leaf);
}

function printable(s) {
  if (!s) return false;
  let ok = 0;
  for (const c of s) if (c >= " " || c === "\n" || c === "\t") ok++;
  return ok / s.length > 0.9;
}

/**
 * Every printable string inside a step's TYPE-SPECIFIC payload.
 *
 * Each step type keeps its payload in its own top-level field — `19` for a user
 * prompt, `20` for the model's prose, `14` for a `view_file` result, `15` for
 * `list_dir` — while field `5` is the shared envelope (ids, timestamps, model
 * metadata) and `1`/`4` are the type and status. The NUMBER differs per tool, but
 * the SHAPE is regular, so harvesting the type payload's strings works for tools
 * we have never seen instead of needing a table of all 131 step types. Precise
 * field paths are used where we know them (see decodeStep).
 */
function harvestTypePayload(payload) {
  const out = [];
  let total = 0;
  for (const field of walk(payload)) {
    if (field.wire !== 2) continue;
    if (field.num === 5) continue; // shared envelope, never content
    for (const leaf of walk(field.bytes, `${field.num}.`)) {
      if (leaf.wire !== 2 || !leaf.bytes.length) continue;
      // A nested message decodes as garbage text; only keep plausible strings.
      let s;
      try {
        s = new TextDecoder("utf-8", { fatal: true }).decode(leaf.bytes);
      } catch {
        continue;
      }
      if (!printable(s) || s.trim().length === 0) continue;
      if (out.includes(s)) continue; // the payloads duplicate strings freely
      out.push(s);
      total += s.length;
      if (total >= MAX_TOTAL) return out;
    }
  }
  return out;
}

/** A step row → the canonical message it should become, or undefined to skip. */
function decodeStep(row) {
  const payload = row.step_payload;
  if (!(payload instanceof Uint8Array)) return undefined;
  const stepType = Number(row.step_type);
  if (BOOKKEEPING_STEPS.has(stepType)) return undefined;
  const envelope = message(payload, 5);
  const source = envelope ? varint(envelope, 3) : undefined;
  if (source === SOURCE_ROGUE_INJECTION) return undefined; // never read our own writes

  let role;
  let body;
  if (stepType === STEP.USER_INPUT) {
    if (source !== SOURCE_USER_EXPLICIT) return undefined;
    role = "user";
    body = text(payload, 19, 2); // the prompt, stored bare
  } else if (stepType === STEP.PLANNER_RESPONSE) {
    role = "assistant";
    // The model's prose. Absent on a tool-call-only response — the call itself is
    // already recorded from the PreToolUse payload, so there is nothing to add.
    body = text(payload, 20, 1);
  } else {
    role = "tool";
    const parts = harvestTypePayload(payload);
    body = parts.length > 0 ? parts.join("\n") : undefined;
  }
  if (!body) return undefined;
  const truncated = body.length > MAX_TEXT;
  return {
    idx: Number(row.idx),
    stepType,
    status: Number(row.status),
    stepFormat: Number(row.step_format),
    source: source ?? -1,
    role,
    text: truncated ? body.slice(0, MAX_TEXT) : body,
    ...(truncated ? { truncated: true } : {}),
  };
}

// ── dedup: one high-water mark per conversation ─────────────────────────────
// Step indices only grow, so a single "last emitted idx" both stops a tool-loop
// turn re-sending what it already sent and makes it impossible to read back our
// own injected block message. An unreadable cache is treated as "already sent" —
// never risk a duplicate.
function cacheFile(conversationId) {
  return join(CACHE_DIR, conversationId.replace(/[^A-Za-z0-9._-]/g, "_"));
}

function highWater(conversationId) {
  try {
    const idx = Number.parseInt(readFileSync(cacheFile(conversationId), "utf8").trim(), 10);
    return Number.isFinite(idx) ? idx : Infinity;
  } catch (err) {
    return err && err.code === "ENOENT" ? -1 : Infinity;
  }
}

function setHighWater(conversationId, idx) {
  try {
    mkdirSync(CACHE_DIR, { recursive: true });
    writeFileSync(cacheFile(conversationId), `${idx}\n`);
    return true;
  } catch {
    return false;
  }
}

function walBytes(dbPath) {
  try {
    return statSync(`${dbPath}-wal`).size;
  } catch {
    return -1;
  }
}

function main() {
  const started = performance.now();
  const mode = process.argv[2] === "steps" ? "steps" : "prompt";
  let body;
  try {
    body = JSON.parse(readFileSync(0, "utf8"));
  } catch {
    return;
  }
  if (!body || typeof body !== "object") return;

  const transcriptPath = typeof body.transcriptPath === "string" ? body.transcriptPath : "";
  const conversationId = typeof body.conversationId === "string" ? body.conversationId : "";
  const initialNumSteps = body.initialNumSteps;
  // IDE only: the other surfaces already carry this content in the transcript
  // tail at these same events, so reading their store is risk for no gain.
  if (!transcriptPath.includes(IDE_SEGMENT)) return;
  if (!conversationId || !Number.isInteger(initialNumSteps) || initialNumSteps < 0) return;

  const stateDir = transcriptPath.split("/brain/")[0];
  if (!stateDir) return;
  const dbPath = join(stateDir, "conversations", `${conversationId}.db`);
  if (!existsSync(dbPath)) return;

  const already = highWater(conversationId);
  let db;
  let rows = [];
  let userVersion = -1;
  try {
    // `mode=ro`, never `immutable=1`: immutable ignores the WAL, and this content
    // is WAL-only when we need it (measured), so immutable returns an empty table
    // on exactly the events that matter.
    db = new DatabaseSync(`file:${dbPath}?mode=ro`, { readOnly: true, timeout: DEADLINE_MS });
    rows = mode === "prompt"
      // The prompt this invocation is about to send: the newest USER_INPUT below
      // the boundary. Not "the row at initialNumSteps - 1" — on a tool-loop
      // continuation that index is a tool result.
      ? db.prepare(
        "select idx, step_type, status, step_format, step_payload from steps "
          + "where step_type = ? and idx < ? and idx > ? order by idx desc limit 4",
      ).all(STEP.USER_INPUT, initialNumSteps, already)
      // What the invocation that just finished produced: its prose and, crucially,
      // the tool results the NEXT model call would read.
      : db.prepare(
        "select idx, step_type, status, step_format, step_payload from steps "
          + "where idx >= ? and idx > ? order by idx asc limit 32",
      ).all(initialNumSteps, already);
    const uv = db.prepare("pragma user_version").get();
    if (uv && Number.isFinite(Number(uv.user_version))) userVersion = Number(uv.user_version);
  } catch {
    return;
  } finally {
    try {
      db?.close();
    } catch { /* nothing actionable */ }
  }

  const steps = [];
  for (const row of rows) {
    if (Number(row.step_format) !== SUPPORTED_STEP_FORMAT) continue; // layout changed
    const step = decodeStep(row);
    if (!step) continue;
    if (step.text.startsWith(OWN_INJECTION_PREFIX)) continue;
    steps.push(step);
    if (mode === "prompt") break; // newest prompt only
  }
  if (steps.length === 0) return;
  if (performance.now() - started > DEADLINE_MS) return; // too late to act on
  const maxIdx = Math.max(...steps.map((s) => s.idx));
  if (!setHighWater(conversationId, maxIdx)) return;

  const common = {
    v: 1,
    src: "conversation-db",
    userVersion,
    readMs: Math.round((performance.now() - started) * 100) / 100,
    walBytes: walBytes(dbPath),
    runtime: process.env.ROGUE_ANTIGRAVITY_NODE_KIND
      || (process.versions.electron ? "electron" : "node"),
  };
  const envelope = mode === "prompt"
    ? { ...common, ...steps[0] }
    : { ...common, kind: "steps", steps };
  // Base64 has no JSON-special characters, so hook.sh can append it by
  // re-closing the object — the same technique it uses for transcriptTailB64.
  process.stdout.write(Buffer.from(JSON.stringify(envelope), "utf8").toString("base64"));
}

try {
  main();
} catch {
  // Unreachable by design; a reader must never fail loudly on a user's keystroke.
}
process.exitCode = 0;
