#!/usr/bin/env node
// Rogue Security — credential storage helper (Gemini CLI).
//
// Called by the /setup command. Writes the shared ~/.rogue-env (mode 600) —
// the SAME file the Claude/Codex/Cursor plugins read — so credentials are
// shared across every Rogue coding-agent integration on this machine.
//
// Usage: node setup.mjs <api-key> <email> <name>
//
// Hooks read credentials from (later wins): <ext>/env → /etc/rogue/env
// (C:\ProgramData\rogue\env on Windows) → ~/.rogue-env (written here).

import fs from "node:fs";
import os from "node:os";
import path from "node:path";

const [apiKey, actorEmail = "", actorName = ""] = process.argv.slice(2);
if (!apiKey) {
  process.stderr.write("Usage: setup.mjs <api-key> <email> <name>\n");
  process.exit(1);
}

const HOME = os.homedir() || process.env.HOME || process.env.USERPROFILE || ".";
const ENV_FILE = process.env.ROGUE_ENV_FILE || path.join(HOME, ".rogue-env");

// POSIX single-quote: the other plugins source this file with `sh`.
const q = (s) => `'${String(s).replace(/'/g, "'\\''")}'`;

const MANAGED = {
  ROGUE_API_KEY: apiKey,
  ROGUE_ACTOR_EMAIL: actorEmail,
  ROGUE_ACTOR_NAME: actorName,
};

// Merges, and must produce the same bytes as scripts/shared/env-file.sh.
const HEADER = [
  "# Managed by the Rogue plugins. Read by hook subprocesses at runtime.",
  "# Delete this file to revoke credentials.",
];
const OWNED = new RegExp(`^\\s*(?:export\\s+)?(?:${Object.keys(MANAGED).join("|")})\\s*=`);
const OWN_HEADER = /^\s*# (Managed by the [Rr]ogue|Delete this file to revoke credentials)/;

let preserved = [];
try {
  preserved = fs
    .readFileSync(ENV_FILE, "utf8")
    .split(/\r?\n/)
    .filter((line, index, all) => !(index === all.length - 1 && line === ""))
    .filter((line) => !OWNED.test(line) && !OWN_HEADER.test(line));
} catch {
  /* No file yet: nothing to preserve. */
}

const contents =
  [...HEADER, ...Object.entries(MANAGED).map(([k, v]) => `export ${k}=${q(v)}`), ...preserved]
    .join("\n") + "\n";

// mode 0o600 on write; chmod again in case the file pre-existed with wider bits.
fs.writeFileSync(ENV_FILE, contents, { mode: 0o600 });
try {
  fs.chmodSync(ENV_FILE, 0o600);
} catch {
  /* Windows: POSIX mode bits are best-effort; the file lands under the user profile. */
}

process.stdout.write("OK\n");
process.stdout.write(`ENV_FILE=${ENV_FILE}\n`);
