# Codex's SURFACE - the PowerShell half of surface.sh, kept in lockstep with it.
#
#   hook.ps1      sends it as the x-rogue-agent header AND stamps it on each log line
#   heartbeat.ps1 sends it as the roster agent
#
# Codex exposes no app/cli entrypoint variable of its own, so the installer pins
# ROGUE_CODEX_SURFACE per surface and everything reads that one value.
#
#   slug       | when
#   -----------|-------------------------------------------------------
#   codex_app  | ROGUE_CODEX_SURFACE=codex_app
#   codex_cli  | ROGUE_CODEX_SURFACE=codex_cli, unset, or ANYTHING ELSE
#
# THE CLOSED LIST IS ENFORCED HERE. The value comes from an env file, so it is
# whatever someone wrote there: a space or an '=' would break the log line's
# key=value shape, and arbitrary text is exactly what this token must never carry.
#
# Takes the resolved credential map rather than reading $env: directly - the
# variable normally lives in ~/.rogue-env, which the process environment has not
# seen. Dot-sourced; Windows PowerShell 5.1 compatible.

function Get-CodexSurfaceSlug {
    param([hashtable]$Creds = @{})
    if ([string]$Creds['ROGUE_CODEX_SURFACE'] -eq 'codex_app') { return 'codex_app' }
    return 'codex_cli'
}
