# Claude's SURFACE, derived from CLAUDE_CODE_ENTRYPOINT - the PowerShell half of
# surface.sh, and kept in lockstep with it.
#
#   hook.ps1      stamps the SLUG on every log line     (surface=cli)
#   hook.ps1      sends the AGENT ID as x-rogue-agent    (claude_code)
#   heartbeat.ps1 sends the AGENT ID as the roster agent (claude_code)
#
# They must never disagree: a log line and the roster row it belongs to would then
# name different surfaces for one session, which is worse than the log saying
# nothing at all. Add a surface in surface.sh AND here.
#
#   slug     | agent id            | label                 | when
#   ---------|---------------------|-----------------------|-------------------
#   cowork   | claude_cowork       | Claude Cowork         | IS_COWORK set, or entrypoint contains "cowork"
#   desktop  | claude_code_desktop | Claude Code - Desktop | entrypoint contains "desktop"
#   cli      | claude_code         | Claude Code - CLI     | any other NON-EMPTY entrypoint
#   (none)   | claude_code         | Claude Code - CLI     | entrypoint empty or unset
#
# CLAUDE_CODE_IS_COWORK is checked BEFORE the entrypoint, and that ordering is
# load-bearing: Cowork spawns Claude Code with CLAUDE_CODE_ENTRYPOINT=local-agent,
# NOT a *cowork* value, so matching the entrypoint alone files every LOCAL Cowork
# session under the CLI surface. Cloud Cowork does carry "remote_cowork", which is
# why the entrypoint arm still exists.
#
# The ROSTER field is the AGENT ID, not the label: it doubles as the backend's
# PLUGIN_REPOS key, so a display label there resolves no latest version at all.
# Get-RogueSurfaceLabel is kept for human-facing output only. See surface.sh.
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
    # Checked first — see the CLAUDE_CODE_IS_COWORK note above. Deliberately ahead
    # of the empty-entrypoint arm too: a Cowork session is a Cowork session whether
    # or not it also exported an entrypoint.
    if ($env:CLAUDE_CODE_IS_COWORK)   { return 'cowork' }
    $entryPoint = ([string]$env:CLAUDE_CODE_ENTRYPOINT).ToLower()
    if (-not $entryPoint)             { return '' }
    if ($entryPoint -like '*cowork*') { return 'cowork' }
    if ($entryPoint -like '*desktop*') { return 'desktop' }
    return 'cli'
}

# The roster's `agent` / the x-rogue-agent header. A stable snake_case id, NOT a
# display label. Empty slug still answers claude_code: the roster field is
# required and must carry something.
function Get-RogueSurfaceAgentId {
    switch (Get-RogueSurfaceSlug) {
        'cowork'  { return 'claude_cowork' }
        'desktop' { return 'claude_code_desktop' }
        default   { return 'claude_code' }
    }
}

function Get-RogueSurfaceLabel {
    switch (Get-RogueSurfaceSlug) {
        'cowork'  { return 'Claude Cowork' }
        'desktop' { return 'Claude Code - Desktop' }
        default   { return 'Claude Code - CLI' }
    }
}
