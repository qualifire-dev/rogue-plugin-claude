#!/usr/bin/env bash
set -euo pipefail
# Print the per-plugin version manifest as JSON.
#
# THIS IS THE ONLY PLACE THE SIX VERSION FILES ARE READ. build-release.sh calls
# it once and derives every per-tarball echo from the result, so the manifest
# attached to a release and the tarballs beside it cannot disagree. Reading a
# version file twice is exactly how they would.
#
# Keys are the plugin SLUGS (the hook-log file basenames), not the roster's
# agent_family: codex's family is `openai`. See
# docs/superpowers/specs/2026-08-20-plugin-version-manifest-design.md.
#
# Every read fails hard. A manifest with a hole reads as "up to date" on the
# dashboard forever, which is strictly worse than a failed build.
#
# Usage: plugin-versions.sh [repo-root]     (root defaults to this script's parent)

ROOT="${1:-$(cd "$(dirname "$0")/.." && pwd)}"

# Read a "version" field WITHOUT python3 or jq — the /usr/bin/python3 stub fails
# silently on a fresh macOS, and jq is absent from minimal images. Same approach
# as heartbeat.sh and the old build-release.sh reads.
read_json_version() { # <path-relative-to-root>
  local rel="$1" f="$ROOT/$1" v
  [ -f "$f" ] || { echo "✗ missing $rel" >&2; exit 1; }
  v=$(grep -oE '"version"[[:space:]]*:[[:space:]]*"[0-9][^"]*"' "$f" 2>/dev/null \
    | head -1 | grep -oE '[0-9]+\.[0-9]+\.[0-9]+') || true
  [ -n "$v" ] || { echo "✗ no X.Y.Z version in $rel" >&2; exit 1; }
  printf '%s' "$v"
}

# Antigravity's plugin.json cannot carry a version: its CLI schema is
# additionalProperties:false. The version of record is a bare VERSION file.
read_plain_version() { # <path-relative-to-root>
  local rel="$1" f="$ROOT/$1" v
  [ -f "$f" ] || { echo "✗ missing $rel" >&2; exit 1; }
  v=$(head -n1 "$f" | tr -d ' \r\n')
  case "$v" in
    [0-9]*.[0-9]*.[0-9]*) ;;
    *) echo "✗ no X.Y.Z version in $rel" >&2; exit 1 ;;
  esac
  printf '%s' "$v"
}

CLAUDE_V=$(read_json_version "plugins/rogue/.claude-plugin/plugin.json")
CODEX_V=$(read_json_version "plugins/codex/.codex-plugin/plugin.json")
CURSOR_V=$(read_json_version "plugins/cursor/.cursor-plugin/plugin.json")
COPILOT_V=$(read_json_version "plugins/copilot/plugin.json")
GEMINI_V=$(read_json_version "plugins/gemini/gemini-extension.json")
ANTIGRAVITY_V=$(read_plain_version "plugins/antigravity/VERSION")

cat <<JSON
{
  "schema": 1,
  "plugins": {
    "claude": "$CLAUDE_V",
    "codex": "$CODEX_V",
    "cursor": "$CURSOR_V",
    "copilot": "$COPILOT_V",
    "gemini": "$GEMINI_V",
    "antigravity": "$ANTIGRAVITY_V"
  }
}
JSON
