#!/usr/bin/env bash
# tests/test_actor_sh.sh — the actor identity cascade (plugins/rogue/scripts/actor.sh).
#
# Why this file exists: in Claude Cowork the hook runs in a sandbox as unix user
# `claude`, with git configured as Anthropic's synthetic
# "Claude <noreply@anthropic.com>", so a git-config-first cascade reported EVERY
# Cowork user as "Claude". actor.sh now ranks CLAUDE_CODE_USER_EMAIL (the real
# authenticated user, set by the Claude host) above git config and rejects
# synthetic identities from ANY source — including ROGUE_ACTOR_*, which compiled
# bundles already in the field pre-seed from git config.
#
# actor.sh is sourced by hook.sh, which hooks.json invokes via `sh`; override with
# TEST_SH=dash to exercise strict POSIX (Debian/Ubuntu /bin/sh) and catch bashisms.
set -euo pipefail

REPO="$(cd "$(dirname "$0")/.." && pwd)"
ACTOR="$REPO/plugins/rogue/scripts/actor.sh"
SH="${TEST_SH:-sh}"

# Stub git / hostname / whoami so the cascade's environment-dependent candidates
# are deterministic (the machine running the tests has its own git identity).
STUB="$(mktemp -d)"
cleanup() { rm -rf "$STUB"; }
trap cleanup EXIT

cat > "$STUB/git" <<'EOF'
#!/bin/sh
# Only `git config --global user.{email,name}` is used by actor.sh.
case "$*" in
  *user.email*) [ -n "${STUB_GIT_EMAIL:-}" ] || exit 1; printf '%s\n' "$STUB_GIT_EMAIL" ;;
  *user.name*)  [ -n "${STUB_GIT_NAME:-}" ]  || exit 1; printf '%s\n' "$STUB_GIT_NAME" ;;
  *) exit 1 ;;
esac
EOF
cat > "$STUB/hostname" <<'EOF'
#!/bin/sh
[ -n "${STUB_HOSTNAME:-}" ] || exit 1
printf '%s\n' "$STUB_HOSTNAME"
EOF
cat > "$STUB/whoami" <<'EOF'
#!/bin/sh
[ -n "${STUB_WHOAMI:-}" ] || exit 1
printf '%s\n' "$STUB_WHOAMI"
EOF
chmod +x "$STUB/git" "$STUB/hostname" "$STUB/whoami"

# Source actor.sh in a fresh shell and print what it resolved. Empty is passed
# instead of unset on purpose: actor.sh must treat both the same way.
resolve() {
  PATH="$STUB:$PATH" \
  ROGUE_ACTOR_EMAIL="${SEED_EMAIL:-}" ROGUE_ACTOR_NAME="${SEED_NAME:-}" \
  CLAUDE_CODE_USER_EMAIL="${HOST_EMAIL:-}" \
  STUB_GIT_EMAIL="${GIT_EMAIL:-}" STUB_GIT_NAME="${GIT_NAME:-}" \
  STUB_HOSTNAME="${HOST_NAME:-}" STUB_WHOAMI="${WHO:-}" \
    "$SH" -c '. "$1"; printf "%s|%s" "$ROGUE_ACTOR_EMAIL" "$ROGUE_ACTOR_NAME"' _ "$ACTOR"
}

assert_actor() {
  local expected="$1" label="$2" actual
  actual="$(resolve)"
  if [ "$actual" != "$expected" ]; then
    echo "FAIL [$label]: expected <$expected> but got <$actual>" >&2; exit 1
  fi
  echo "  ok: $label"
}

# Every case sets the whole environment explicitly, so no state leaks between them.
scenario() {
  SEED_EMAIL=""; SEED_NAME=""; HOST_EMAIL=""
  GIT_EMAIL=""; GIT_NAME=""; HOST_NAME="devbox"; WHO="jane"
}

# ── Case 1: normal dev machine — real git identity, no host email (no regression)
scenario
GIT_EMAIL="jane@corp.com"; GIT_NAME="Jane Dev"
assert_actor "jane@corp.com|Jane Dev" "git identity still wins when CLAUDE_CODE_USER_EMAIL is absent"

# ── Case 2: CLAUDE_CODE_USER_EMAIL outranks a real git identity ───────────────
scenario
HOST_EMAIL="real.user@corp.com"
GIT_EMAIL="jane@corp.com"; GIT_NAME="Jane Dev"
assert_actor "real.user@corp.com|real.user" "CLAUDE_CODE_USER_EMAIL beats git config (name = local-part)"

# ── Case 3: the Cowork sandbox — synthetic git identity is rejected ───────────
scenario
HOST_EMAIL="real.user@corp.com"
GIT_EMAIL="noreply@anthropic.com"; GIT_NAME="Claude"; WHO="claude"; HOST_NAME="sandbox"
assert_actor "real.user@corp.com|real.user" "synthetic git identity rejected in favor of CLAUDE_CODE_USER_EMAIL"

# ── Case 4: a POISONED ROGUE_ACTOR_* (old compiled bundle pre-seed) is rejected
# This is the field-repair path: bundles built before this fix bake
# `: "${ROGUE_ACTOR_EMAIL:=$(git config --global user.email)}"` into
# ${CLAUDE_PLUGIN_ROOT}/env, which hook.sh sources BEFORE actor.sh.
scenario
SEED_EMAIL="noreply@anthropic.com"; SEED_NAME="Claude"
HOST_EMAIL="real.user@corp.com"
GIT_EMAIL="noreply@anthropic.com"; GIT_NAME="Claude"; WHO="claude"
assert_actor "real.user@corp.com|real.user" "poisoned ROGUE_ACTOR_* rejected, CLAUDE_CODE_USER_EMAIL used"

# ── Case 5: a legitimate ROGUE_ACTOR_* still wins outright ────────────────────
scenario
SEED_EMAIL="mdm@corp.com"; SEED_NAME="MDM Provisioned"
HOST_EMAIL="real.user@corp.com"; GIT_EMAIL="jane@corp.com"; GIT_NAME="Jane Dev"
assert_actor "mdm@corp.com|MDM Provisioned" "explicit ROGUE_ACTOR_* (MDM/setup) keeps top precedence"

# ── Case 6: everything synthetic → the unknown marker, never a plausible name ─
scenario
SEED_EMAIL="noreply@anthropic.com"; SEED_NAME="claude code"
GIT_EMAIL="noreply@anthropic.com"; GIT_NAME="Claude"
WHO="claude"; HOST_NAME="sandbox-7f3a"
assert_actor "unknown@sandbox-7f3a|unknown" "all-synthetic input yields the unknown marker (hostname kept as domain)"

# ── Case 7: no hostname either → plain unknown ────────────────────────────────
scenario
GIT_NAME="Claude"; WHO="claude"; HOST_NAME=""
assert_actor "unknown|unknown" "plain unknown when hostname is unavailable"

# ── Case 8: synthetic matching is case/whitespace-insensitive ─────────────────
scenario
SEED_NAME="  CLAUDE   Code "; SEED_EMAIL="  NoReply@Anthropic.COM "
GIT_EMAIL="jane@corp.com"; GIT_NAME="Jane Dev"
assert_actor "jane@corp.com|Jane Dev" "synthetic match ignores case and surrounding/repeated whitespace"

# ── Case 9: whitespace-only values are rejected like empties ──────────────────
scenario
SEED_NAME="   "; SEED_EMAIL="  "
GIT_EMAIL="jane@corp.com"; GIT_NAME="Jane Dev"
assert_actor "jane@corp.com|Jane Dev" "whitespace-only ROGUE_ACTOR_* rejected"

# ── Case 10: only EXACT synthetic values are rejected — real humans pass ──────
scenario
GIT_EMAIL="claude.dubois@corp.com"; GIT_NAME="Claudia Claude-Smith"
assert_actor "claude.dubois@corp.com|Claudia Claude-Smith" "names merely containing 'claude' are NOT rejected"

# ── Case 11: fields resolve independently (synthetic email, real git name) ────
scenario
GIT_EMAIL="noreply@anthropic.com"; GIT_NAME="Jane Dev"; HOST_NAME="devbox"
assert_actor "unknown@devbox|Jane Dev" "email and name cascades are independent"

# ── Case 12: whoami is the last human candidate for the name ─────────────────
scenario
GIT_EMAIL=""; GIT_NAME=""; WHO="jane"; HOST_NAME="devbox"
assert_actor "unknown@devbox|jane" "whoami used for name when git config is absent"

# ── Case 13: the synthetic host email must not leak in through its local-part ─
# Screening the full address but splitting it first would report the actor as
# "noreply": that local-part is not itself on the screen list, so the whole
# address has to be rejected BEFORE the split.
scenario
HOST_EMAIL="noreply@anthropic.com"
GIT_EMAIL=""; GIT_NAME=""; WHO="claude"; HOST_NAME="sandbox-7f3a"
assert_actor "unknown@sandbox-7f3a|unknown" "synthetic CLAUDE_CODE_USER_EMAIL yields no name at all"

# ── Case 14: a real address whose local-part is itself synthetic ─────────────
scenario
HOST_EMAIL="claude@corp.com"
GIT_EMAIL=""; GIT_NAME=""; WHO="jane"; HOST_NAME="devbox"
assert_actor "claude@corp.com|jane" "real address kept as email, unusable local-part falls through"

echo
echo "All actor.sh cascade tests passed (SH=$SH)."
