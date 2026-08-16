// Tests for the Gemini CLI hook dispatcher (plugins/gemini/scripts/hook.mjs).
// Self-contained: uses node:test + a local http server, no external deps.
//   node --test tests/test_hook_mjs.mjs
import { test } from "node:test";
import assert from "node:assert/strict";
import http from "node:http";
import os from "node:os";
import fs from "node:fs";
import path from "node:path";
import { spawn } from "node:child_process";
import { fileURLToPath } from "node:url";

const HOOK = path.join(
  path.dirname(fileURLToPath(import.meta.url)),
  "..",
  "plugins",
  "gemini",
  "scripts",
  "hook.mjs",
);

// A throwaway HOME so the hook never reads the developer's real ~/.rogue-env.
function freshHome() {
  return fs.mkdtempSync(path.join(os.tmpdir(), "rogue-gem-"));
}

// Run hook.mjs <event> with `payload` on stdin and `env` overrides; resolve stdout.
function runHook(event, payload, env) {
  return new Promise((resolve) => {
    const home = freshHome();
    const child = spawn(process.execPath, [HOOK, event], {
      env: {
        PATH: process.env.PATH,
        HOME: home,
        USERPROFILE: home,
        ...env,
      },
    });
    let out = "";
    child.stdout.on("data", (c) => (out += c));
    child.on("close", () => {
      fs.rmSync(home, { recursive: true, force: true });
      resolve(out);
    });
    child.stdin.end(payload ?? "");
  });
}

// Start a one-shot server that records the request and replies with `body`.
function startServer(status, body) {
  return new Promise((resolve) => {
    const seen = {};
    const server = http.createServer((req, res) => {
      seen.headers = req.headers;
      let b = "";
      req.on("data", (c) => (b += c));
      req.on("end", () => {
        seen.body = b;
        res.writeHead(status, { "Content-Type": "application/json" });
        res.end(body);
      });
    });
    server.listen(0, "127.0.0.1", () =>
      resolve({ server, seen, port: server.address().port }),
    );
  });
}

test("no API key → fail-open {}", async () => {
  const out = await runHook("BeforeAgent", '{"prompt":"hi"}', {});
  assert.equal(out, "{}");
});

test("SessionStart unconfigured → systemMessage hint, no POST", async () => {
  const out = await runHook("SessionStart", "", {});
  const j = JSON.parse(out);
  assert.match(j.systemMessage, /Rogue Security/);
  assert.match(j.systemMessage, /\/setup/);
});

test("relays server body verbatim and sends the right headers", async () => {
  const denyBody = JSON.stringify({ decision: "deny", reason: "blocked by test" });
  const { server, seen, port } = await startServer(200, denyBody);
  try {
    const out = await runHook("BeforeTool", '{"tool_name":"run_shell_command"}', {
      ROGUE_API_KEY: "rsk_test",
      ROGUE_ACTOR_EMAIL: "dev@example.com",
      ROGUE_ACTOR_NAME: "Dev",
      ROGUE_BASE_URL: `http://127.0.0.1:${port}`,
    });
    assert.equal(out, denyBody, "stdout must be the server body verbatim");
    assert.equal(seen.headers["x-rogue-event"], "BeforeTool");
    assert.equal(seen.headers["x-rogue-api-key"], "rsk_test");
    assert.equal(seen.headers["x-rogue-actor-email"], "dev@example.com");
    assert.equal(seen.headers["x-rogue-actor-name"], "Dev");
    // Fleet-liveness trio: the same host/version/agent the heartbeat sends, on
    // EVERY event, so the roster row is refreshed by ordinary traffic and not
    // only at SessionStart. `agent` must stay the PLUGIN_REPOS key, or the
    // backend stops resolving a latest version for these rows. Host and version
    // are machine-specific, so they are only asserted non-empty (see installId).
    assert.equal(seen.headers["x-rogue-agent"], "gemini_cli");
    assert.ok(seen.headers["x-rogue-host"], "x-rogue-host sent on every event");
    assert.ok(seen.headers["x-rogue-version"], "x-rogue-version sent on every event");
    assert.equal(seen.body, '{"tool_name":"run_shell_command"}');
  } finally {
    server.close();
  }
});

test("allow response ({}) relays verbatim", async () => {
  const { server, port } = await startServer(200, "{}");
  try {
    const out = await runHook("AfterTool", '{"tool_name":"x"}', {
      ROGUE_API_KEY: "rsk_test",
      ROGUE_BASE_URL: `http://127.0.0.1:${port}`,
    });
    assert.equal(out, "{}");
  } finally {
    server.close();
  }
});

test("non-200 → fail-open {}", async () => {
  const { server, port } = await startServer(500, "boom");
  try {
    const out = await runHook("BeforeAgent", '{"prompt":"hi"}', {
      ROGUE_API_KEY: "rsk_test",
      ROGUE_BASE_URL: `http://127.0.0.1:${port}`,
    });
    assert.equal(out, "{}");
  } finally {
    server.close();
  }
});

test("200 with malformed (non-JSON) body → fail-open {}", async () => {
  const { server, port } = await startServer(200, "not json <html>oops");
  try {
    const out = await runHook("BeforeTool", '{"tool_name":"x"}', {
      ROGUE_API_KEY: "rsk_test",
      ROGUE_BASE_URL: `http://127.0.0.1:${port}`,
    });
    assert.equal(out, "{}", "malformed 200 body must not be relayed verbatim");
  } finally {
    server.close();
  }
});

test("unreachable endpoint → fail-open {}", async () => {
  const out = await runHook("BeforeAgent", '{"prompt":"hi"}', {
    ROGUE_API_KEY: "rsk_test",
    // 127.0.0.1:1 is not listening → connection refused → fail-open.
    ROGUE_BASE_URL: "http://127.0.0.1:1",
  });
  assert.equal(out, "{}");
});

// Start a server that COLLECTS every request (keyed by url). SessionStart also
// fires the detached heartbeat to /hooks/status, so a one-shot server would
// race — this lets us pick out the /hooks/gemini request deterministically.
function startCollectingServer(status, body) {
  return new Promise((resolve) => {
    const requests = [];
    const server = http.createServer((req, res) => {
      let b = "";
      req.on("data", (c) => (b += c));
      req.on("end", () => {
        requests.push({ url: req.url, headers: req.headers, body: b });
        res.writeHead(status, { "Content-Type": "application/json" });
        res.end(body);
      });
    });
    server.listen(0, "127.0.0.1", () =>
      resolve({ server, requests, port: server.address().port }),
    );
  });
}

test("SessionStart configured → POSTs the event and relays body", async () => {
  const relayed = JSON.stringify({ systemMessage: "welcome" });
  const { server, requests, port } = await startCollectingServer(200, relayed);
  try {
    const out = await runHook("SessionStart", '{"session_id":"s1"}', {
      ROGUE_API_KEY: "rsk_test",
      ROGUE_ACTOR_EMAIL: "dev@example.com",
      ROGUE_ACTOR_NAME: "Dev",
      ROGUE_BASE_URL: `http://127.0.0.1:${port}`,
    });
    // The /hooks/gemini POST must have happened with the SessionStart event.
    const gem = requests.find((r) => r.url.endsWith("/api/v1/hooks/gemini"));
    assert.ok(gem, "SessionStart must POST to /api/v1/hooks/gemini");
    assert.equal(gem.headers["x-rogue-event"], "SessionStart");
    assert.equal(gem.body, '{"session_id":"s1"}');
    // …and the server body is relayed verbatim on stdout.
    assert.equal(out, relayed);
  } finally {
    server.close();
  }
});

test("SessionEnd → POSTs with x-rogue-event SessionEnd", async () => {
  const { server, seen, port } = await startServer(200, "{}");
  try {
    const out = await runHook("SessionEnd", '{"session_id":"s1"}', {
      ROGUE_API_KEY: "rsk_test",
      ROGUE_BASE_URL: `http://127.0.0.1:${port}`,
    });
    assert.equal(seen.headers["x-rogue-event"], "SessionEnd");
    assert.equal(out, "{}");
  } finally {
    server.close();
  }
});
