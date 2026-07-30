#!/usr/bin/env bash
# Whether the user has turned launch-at-login OFF. Sourced by install.sh and
# rebuild.sh, not run.
#
# Why this exists (UX42): the Preferences ▸ General "Launch at login" toggle now
# owns login-start, and it expresses "off" the only way launchd offers for a
# resident agent, by writing a disabled override with
# `launchctl disable gui/<uid>/com.meetingpipe.daemon`. Off is `disable` rather
# than `bootout` on purpose: the agent owns the running process, so booting it
# out would kill the app under the user's pointer.
#
# Both scripts have to respect that override or they undo it:
#
#   - install.sh used `launchctl load -w`, and the `-w` is exactly a write of an
#     *enabled* override. Every install re-armed a login-start the owner had
#     turned off. `bootstrap` loads the job without touching the overrides
#     database, so an install over a disabled agent leaves it disabled.
#   - rebuild.sh boots out and bootstraps on every dev rebuild. Bootstrapping a
#     disabled service fails, so without this check a rebuild would die on a
#     state the owner chose on purpose.
#
# The text predicate is split out from the launchctl query so it can be pinned
# without touching real launchd state: `scripts/test-login-agent-guard.sh`.

# login_agent_disabled_in_output <print-disabled output> <label>
#
# Exit 0 when the label carries a `=> disabled` override in that output. Lines
# read `\t\t"com.meetingpipe.daemon" => disabled` inside a `disabled services =
# {}` block. A label with no line at all is NOT disabled: launchd reads a missing
# override as "use the plist", and our plist carries RunAtLoad=true.
#
# The quotes around the label are load-bearing. Without them a sibling label that
# merely starts with ours (`com.meetingpipe.daemon.helper`) would match.
login_agent_disabled_in_output() {
    local output="$1" label="$2"
    printf '%s\n' "$output" | grep -qE "^[[:space:]]*\"${label}\"[[:space:]]*=>[[:space:]]*disabled[[:space:]]*$"
}

# login_agent_disabled <label>
#
# Exit 0 when launchd currently has that label disabled for this user. A
# launchctl that cannot be queried at all reads as "not disabled", so a broken
# query never silently suppresses an install's relaunch.
login_agent_disabled() {
    local label="$1"
    login_agent_disabled_in_output "$(launchctl print-disabled "gui/$(id -u)" 2>/dev/null || true)" "$label"
}
