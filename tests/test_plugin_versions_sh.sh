#!/usr/bin/env bash
# Unit tests for scripts/plugin-versions.sh — the ONLY reader of the six plugin
# version files.
#
# This script's output is the contract the backend resolves "outdated" from, so a
# regression here is silent in the worst way: a missing key reads as "up to date"
# forever, and a malformed value makes semver.coerce return null, which also reads
# as "up to date". Both must fail the BUILD instead.
set -u
REPO="$(cd "$(dirname "$0")/.." && pwd)"
SCRIPT="$REPO/scripts/plugin-versions.sh"
fails=0

ok() { echo "  ok: $1"; }
bad() { echo "FAIL [$1]: $2"; fails=$((fails + 1)); }

# ── Against the real tree ────────────────────────────────────────────────────
out=$(bash "$SCRIPT" "$REPO" 2>/dev/null) || { bad "real tree" "exited non-zero"; out=""; }

flat=$(printf '%s' "$out" | tr -d ' \t\n\r')

for slug in claude codex cursor copilot gemini antigravity; do
  case "$flat" in
    *"\"$slug\":\""*) ok "emits $slug" ;;
    *) bad "emits $slug" "key missing from: $out" ;;
  esac
done

case "$flat" in
  *'"schema":1'*) ok "carries schema 1" ;;
  *) bad "carries schema 1" "not found in: $out" ;;
esac

# Exactly six plugin keys — an extra key means a plugin was added without a
# matching backend mapping, which resolves to null (never outdated).
keys=$(printf '%s' "$flat" | grep -oE '"[a-z]+":"[0-9]+\.[0-9]+\.[0-9]+"' | wc -l | tr -d ' ')
if [ "$keys" = "6" ]; then ok "exactly six plugin versions"; else
  bad "exactly six plugin versions" "found $keys"; fi

# Every value must be a bare X.Y.Z. "unknown", "v1.2.3" and "1.2" all coerce
# wrong on the consumer side.
bogus=$(printf '%s' "$flat" | grep -oE '"[a-z]+":"[^"]*"' | grep -vE '"schema"' \
  | grep -vE '"[a-z]+":"[0-9]+\.[0-9]+\.[0-9]+"' || true)
if [ -z "$bogus" ]; then ok "all values are bare X.Y.Z"; else
  bad "all values are bare X.Y.Z" "$bogus"; fi

# Every value must equal what that plugin's OWN version file says — all six, not
# a sample. The slug-to-file mapping is hand-written per plugin, so a slug reading
# from the wrong file produces a valid-looking X.Y.Z that every other check here
# accepts. That is precisely the bug this manifest exists to end: a version key
# that reads as something it is not.
expect_json() { # <slug> <path-relative-to-repo>
  _exp=$(grep -oE '"version"[[:space:]]*:[[:space:]]*"[0-9][^"]*"' "$REPO/$2" \
    | head -1 | grep -oE '[0-9]+\.[0-9]+\.[0-9]+')
  if [ -z "$_exp" ]; then bad "$1 matches its manifest" "could not read a version from $2"; return; fi
  case "$flat" in
    *"\"$1\":\"$_exp\""*) ok "$1 matches $2 ($_exp)" ;;
    *) bad "$1 matches $2" "expected $_exp in: $out" ;;
  esac
}

expect_json claude  plugins/rogue/.claude-plugin/plugin.json
expect_json codex   plugins/codex/.codex-plugin/plugin.json
expect_json cursor  plugins/cursor/.cursor-plugin/plugin.json
expect_json copilot plugins/copilot/plugin.json
expect_json gemini  plugins/gemini/gemini-extension.json

# Antigravity is the one plugin whose version is NOT in a JSON manifest: its CLI
# schema is additionalProperties:false, so the version of record is a bare file.
agv_expected=$(head -n1 "$REPO/plugins/antigravity/VERSION" | tr -d ' \r\n')
case "$flat" in
  *"\"antigravity\":\"$agv_expected\""*) ok "antigravity matches its VERSION file ($agv_expected)" ;;
  *) bad "antigravity matches its VERSION file" "expected $agv_expected in: $out" ;;
esac

# The six must be DISTINCT reads, not one file echoed six times. A mapping bug
# that pointed several slugs at the same manifest would satisfy every assertion
# above only if those plugins happened to share a version - so assert the shape
# of the real tree instead: not all six versions are equal today.
uniq_count=$(printf '%s' "$flat" | grep -oE '"(claude|codex|cursor|copilot|gemini|antigravity)":"[0-9]+\.[0-9]+\.[0-9]+"' \
  | sed -E 's/.*:"//; s/"//' | sort -u | wc -l | tr -d ' ')
if [ "$uniq_count" -gt 1 ]; then ok "the six versions are not one value repeated ($uniq_count distinct)"; else
  bad "the six versions are not one value repeated" "all six read $uniq_count distinct value(s)"; fi

# ── Fail-hard cases, against fixture trees ───────────────────────────────────
# A build that emits a manifest with a hole is worse than a build that fails:
# the hole is invisible and reads as "up to date".
fixture=$(mktemp -d)
trap 'rm -rf "$fixture"' EXIT
mkdir -p "$fixture/plugins/rogue/.claude-plugin" "$fixture/plugins/codex/.codex-plugin" \
         "$fixture/plugins/cursor/.cursor-plugin" "$fixture/plugins/copilot" \
         "$fixture/plugins/gemini" "$fixture/plugins/antigravity"
echo '{"version":"9.9.9"}' > "$fixture/plugins/rogue/.claude-plugin/plugin.json"
echo '{"version":"9.9.9"}' > "$fixture/plugins/codex/.codex-plugin/plugin.json"
echo '{"version":"9.9.9"}' > "$fixture/plugins/cursor/.cursor-plugin/plugin.json"
echo '{"version":"9.9.9"}' > "$fixture/plugins/copilot/plugin.json"
echo '{"version":"9.9.9"}' > "$fixture/plugins/gemini/gemini-extension.json"
echo '9.9.9' > "$fixture/plugins/antigravity/VERSION"

if bash "$SCRIPT" "$fixture" >/dev/null 2>&1; then ok "complete fixture tree succeeds"; else
  bad "complete fixture tree succeeds" "exited non-zero"; fi

rm -f "$fixture/plugins/gemini/gemini-extension.json"
if bash "$SCRIPT" "$fixture" >/dev/null 2>&1; then
  bad "missing manifest fails" "exited 0"; else ok "missing manifest fails"; fi
echo '{"version":"9.9.9"}' > "$fixture/plugins/gemini/gemini-extension.json"

echo '{"name":"rogue"}' > "$fixture/plugins/copilot/plugin.json"
if bash "$SCRIPT" "$fixture" >/dev/null 2>&1; then
  bad "manifest with no version fails" "exited 0"; else ok "manifest with no version fails"; fi
echo '{"version":"9.9.9"}' > "$fixture/plugins/copilot/plugin.json"

: > "$fixture/plugins/antigravity/VERSION"
if bash "$SCRIPT" "$fixture" >/dev/null 2>&1; then
  bad "empty VERSION file fails" "exited 0"; else ok "empty VERSION file fails"; fi

# ── build-release.sh must publish the manifest, not re-read the files ────────
# Two readers is how the manifest and the tarballs drift apart.
if grep -qE '\|\| echo "unknown"' "$REPO/scripts/build-release.sh"; then
  bad "no soft-fail version read" "build-release.sh still has || echo \"unknown\""
else
  ok "no soft-fail version read"
fi

reads=$(grep -cE 'grep -oE .\"version\"' "$REPO/scripts/build-release.sh" || true)
if [ "$reads" = "0" ]; then ok "build-release.sh does not re-read version files"; else
  bad "build-release.sh does not re-read version files" "$reads direct read(s) remain"; fi

if grep -q 'plugin-versions.sh' "$REPO/scripts/build-release.sh"; then
  ok "build-release.sh calls plugin-versions.sh"
else
  bad "build-release.sh calls plugin-versions.sh" "no reference found"
fi

if grep -q 'versions.json' "$REPO/scripts/build-release.sh"; then
  ok "build-release.sh writes versions.json"
else
  bad "build-release.sh writes versions.json" "no reference found"
fi

echo ""
if [ "$fails" = 0 ]; then echo "plugin-versions.sh: all checks passed"; else
  echo "plugin-versions.sh: $fails failure(s)"; exit 1; fi
