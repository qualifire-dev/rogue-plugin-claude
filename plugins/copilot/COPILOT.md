# Rogue Security AIDR

This project is protected by **Rogue Security AIDR** for GitHub Copilot CLI.
Every lifecycle event (prompts, tool calls, tool results, MCP calls) is observed
in real time; risky tool calls are evaluated and can be **denied** before they run.

- `/rogue:setup` — connect your Rogue API key and confirm your identity.
- `/rogue:status` — check connection, active rulesets, and configuration.
- **False positive?** Prepend `rgx!` to your next prompt to allow it once and
  mark the previous detection as a false positive (per-prompt only).
- **In JetBrains**, a blocked prompt is shown as a desktop alert, because the IDE
  renders nothing for it itself; set `ROGUE_IDE_ALERT=0` in `~/.rogue-env` to
  disable that alert (the block is still enforced). Rogue only covers the
  **CLI/Agent** provider — the IDE's built-in **Local** agent ignores installed
  plugins entirely.

Dashboard: https://app.rogue.security/aidr
