#!/usr/bin/env bash
# Every compiled plugin bundle must be ignored, by whatever name it ships under.
#
# A bundle's `env` file carries a live ROGUE_API_KEY, so committing one publishes
# a working key. This has happened twice: `rogue-aidr-local-test.zip` and the
# customer bundle `rogue-aidr-1.0.22-sunbit.zip` both landed on branches while
# .gitignore only listed `rogue-aidr-compiled-*`. This test pins the wider rules,
# including the unpacked-directory case that a `*.zip` rule alone cannot cover.
set -u
REPO="$(cd "$(dirname "$0")/.." && pwd)"
cd "$REPO" || exit 1
fails=0

must_ignore() {
  if git check-ignore -q "$1"; then
    echo "  ok: ignored — $1"
  else
    echo "FAIL: NOT ignored — $1"
    fails=$((fails + 1))
  fi
}

echo "gitignore covers plugin bundles"
# Names the compile scripts emit today.
must_ignore "rogue-aidr-compiled-1.0.22.zip"
must_ignore "rogue-aidr-local-289aa2c.zip"
# Names that slipped through the old narrow rule.
must_ignore "rogue-aidr-local-test.zip"
must_ignore "rogue-aidr-1.0.22-sunbit.zip"
must_ignore "rogue-security-sunbit-hybrid-1.0.22.zip"
# Unpacked bundles: the leak is the env file inside, not the archive.
must_ignore "rogue-aidr-local-test/env"
must_ignore "rogue-aidr-compiled-1.0.22/scripts/hook.sh"
# Any archive at all, whatever it is named.
must_ignore "some-other-bundle.zip"

# The rules must not shadow anything actually tracked.
shadowed=$(git ls-files | while IFS= read -r f; do git check-ignore -q "$f" && printf '%s\n' "$f"; done)
if [ -z "$shadowed" ]; then
  echo "  ok: no tracked file is shadowed by these rules"
else
  echo "FAIL: these tracked files are now ignored:"; printf '%s\n' "$shadowed"
  fails=$((fails + 1))
fi

[ "$fails" -eq 0 ] || { echo "$fails failure(s)"; exit 1; }
echo "all gitignore bundle tests passed"
