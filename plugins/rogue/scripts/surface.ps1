# Claude's SURFACE, derived from CLAUDE_CODE_ENTRYPOINT - the PowerShell half of
# surface.sh, and kept in lockstep with it.
#
#   hook.ps1      stamps the SLUG on every log line   (surface=cli)
#   heartbeat.ps1 sends the LABEL as the roster agent  (Claude Code - CLI)
#
# They must never disagree: a log line and the roster row it belongs to would then
# name different surfaces for one session, which is worse than the log saying
# nothing at all. Add a surface in surface.sh AND here.
#
#   slug     | label                 | when
#   ---------|-----------------------|--------------------------------------
#   cowork   | Claude Cowork         | entrypoint contains "cowork"
#   desktop  | Claude Code - Desktop | entrypoint contains "desktop"
#   cli      | Claude Code - CLI     | any other NON-EMPTY entrypoint
#   (none)   | Claude Code - CLI     | entrypoint empty or unset
#
# Slugs are lowercase, contain no space and no '=', so a reader can find the value
# by scanning to the next 'key=' token. They are a closed set: never a path, a user
# name, a host, or anything else read off the environment.
#
# An EMPTY entrypoint yields an EMPTY slug and the caller omits the token entirely -
# the log never says surface=unknown. It cannot arise on the logging path (both
# dispatchers exit before their first log line when the variable is unset). The
# LABEL side still defaults to the CLI, because the roster field is required.
#
# Dot-sourced, so it defines functions and does nothing else. Windows PowerShell
# 5.1 compatible.

function Get-RogueSurfaceSlug {
    $entryPoint = ([string]$env:CLAUDE_CODE_ENTRYPOINT).ToLower()
    if (-not $entryPoint)             { return '' }
    if ($entryPoint -like '*cowork*') { return 'cowork' }
    if ($entryPoint -like '*desktop*') { return 'desktop' }
    return 'cli'
}

function Get-RogueSurfaceLabel {
    switch (Get-RogueSurfaceSlug) {
        'cowork'  { return 'Claude Cowork' }
        'desktop' { return 'Claude Code - Desktop' }
        default   { return 'Claude Code - CLI' }
    }
}
