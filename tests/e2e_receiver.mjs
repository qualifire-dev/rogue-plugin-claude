#!/usr/bin/env node
// A REAL HTTP server for tests/e2e_ship_logs.sh — the one thing the contract suite
// (tests/test_ship_logs.sh) cannot do, because it replaces `curl` with a stub.
//
//   node tests/e2e_receiver.mjs <work-dir>
//
// Writes <work-dir>/port as soon as it is listening, so the caller can poll for it
// instead of sleeping. Then, for every request:
//
//   POST /api/v1/hooks/logs    -> the shipper. Verifies the API key, decodes
//                                 content_b64 and APPENDS it to
//                                 <work-dir>/reassembled-<log_file>, i.e. the file is
//                                 rebuilt from the wire exactly as a real ingest
//                                 would rebuild it. One envelope (minus the payload)
//                                 per line in <work-dir>/envelopes.jsonl.
//   POST /api/v1/hooks/claude  -> the dispatcher, so hook.sh runs its real code path.
//   POST /api/v1/hooks/status  -> the heartbeat.
//
// <work-dir>/status_code, if present and numeric, is the code returned to the SHIPPER
// only (never to the dispatcher, which must stay on its happy path). It is re-read per
// request, so the test can flip the server to 500 mid-run to exercise "the offset must
// not advance on a non-2xx" against a real HTTP failure rather than a stubbed one. A
// non-2xx records the envelope but NOT the payload - that is the whole point: bytes the
// server did not accept must not appear in the dataset, and must arrive again later.
import fs from "node:fs";
import http from "node:http";
import path from "node:path";

const workDir = process.argv[2];
if (!workDir) {
  process.stderr.write("usage: e2e_receiver.mjs <work-dir>\n");
  process.exit(2);
}
fs.mkdirSync(workDir, { recursive: true });

const EXPECTED_KEY = process.env.E2E_API_KEY || "e2e-key";

function readStatusCode() {
  try {
    const raw = fs.readFileSync(path.join(workDir, "status_code"), "utf8").trim();
    if (/^[0-9]{3}$/.test(raw)) return Number(raw);
  } catch {}
  return 200;
}

function recordEnvelope(kind, envelope) {
  const { content_b64: _payload, ...rest } = envelope;
  fs.appendFileSync(
    path.join(workDir, "envelopes.jsonl"),
    JSON.stringify({ kind, ...rest }) + "\n",
  );
}

const server = http.createServer((req, res) => {
  const chunks = [];
  req.on("data", (c) => chunks.push(c));
  req.on("end", () => {
    const raw = Buffer.concat(chunks);
    const url = req.url || "";
    if (url.endsWith("/hooks/logs")) {
      const code = readStatusCode();
      if (req.headers["x-rogue-api-key"] !== EXPECTED_KEY) {
        fs.appendFileSync(path.join(workDir, "bad_key.log"), `${req.headers["x-rogue-api-key"]}\n`);
        res.writeHead(401, { "Content-Type": "application/json" });
        res.end("{}");
        return;
      }
      let envelope = null;
      try {
        envelope = JSON.parse(raw.toString("utf8"));
      } catch (err) {
        fs.appendFileSync(path.join(workDir, "bad_json.log"), `${err}\n`);
        res.writeHead(400, { "Content-Type": "application/json" });
        res.end("{}");
        return;
      }
      recordEnvelope(code >= 200 && code < 300 ? "logs" : "logs-rejected", {
        ...envelope,
        http: code,
      });
      if (code >= 200 && code < 300) {
        // Rebuilt from the wire, in arrival order. `log_file` is a basename by
        // contract, so a path traversal in it would be a server bug; refuse anything
        // that is not one rather than trusting it.
        const name = String(envelope.log_file || "unknown");
        if (name.includes("/") || name.includes("\\") || name.includes("..")) {
          res.writeHead(400, { "Content-Type": "application/json" });
          res.end("{}");
          return;
        }
        fs.appendFileSync(
          path.join(workDir, `reassembled-${name}`),
          Buffer.from(String(envelope.content_b64 || ""), "base64"),
        );
      }
      res.writeHead(code, { "Content-Type": "application/json" });
      res.end("{}");
      return;
    }
    // The dispatcher and the heartbeat: allow, and record that they were seen so the
    // e2e script can prove the log lines came from a REAL dispatcher run.
    fs.appendFileSync(path.join(workDir, "other.log"), `${req.method} ${url}\n`);
    res.writeHead(200, { "Content-Type": "application/json" });
    res.end("{}");
  });
});

server.listen(0, "127.0.0.1", () => {
  fs.writeFileSync(path.join(workDir, "port"), String(server.address().port));
});

// The e2e script kills this; exit cleanly on a signal so the port file is not left
// behind for a following run to read as live.
for (const sig of ["SIGTERM", "SIGINT"]) {
  process.on(sig, () => {
    try {
      fs.unlinkSync(path.join(workDir, "port"));
    } catch {}
    process.exit(0);
  });
}
