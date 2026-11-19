#!/usr/bin/env bash
# Stop the installed daemon and start the new build, verified. Sourced by
# install.sh and rebuild.sh, not run (DIST5).
#
# rebuild.sh learned the hard way what a relaunch needs, and install.sh did not
# get the lesson until DIST5:
#
#   - `kickstart -k` after a cdhash change reuses launchd's stale launch
#     constraint, so the respawn fails with EX_CONFIG (78) while kickstart still
#     returns 0: the script prints success over a dead daemon. A full bootout
#     followed by bootstrap makes launchd recompute it from the new binary.
#   - `bootstrap` can lose a race with the bootout's teardown, so it retries.
#   - Nothing short of seeing the process proves it came up, so the start is
#     verified with pgrep and a failure names launchd.err.log.
#
# Launch at login off (UX42) is the owner's choice, expressed as a launchd
# disabled override. These functions never call `bootstrap`, `load -w` or
# anything else that writes that override when it is off: they stop whatever is
# running from the installed binary (a launchd job still loaded from before the
# toggle, or a copy the owner opened from Finder) and `open` the new bundle.
# Before DIST5 install.sh's off branch only printed a line, so a hand-started
# old build kept running and the newly opened one stood itself down
# (SingleInstanceGuard: the newcomer always loses).
#
# Every external command is reached through PATH, so scripts/test-relaunch.sh
# can stub launchctl, pkill, pgrep, open and sleep and pin each branch without
# touching real launchd state.

# relaunch_binary <app>: the path every pgrep and pkill here matches on.
relaunch_binary() {
    printf '%s/Contents/MacOS/MeetingPipe' "$1"
}

# relaunch_stop_daemon <app> <label> <login-off: 0|1> [tries]
#
# Boot the agent out (a no-op when it is not loaded) and stop anything still
# running from the installed binary, then wait up to <tries> seconds for it to
# exit. Never touches the disabled-overrides database. Returns 1, with a line on
# stderr, when a process is still there after the wait.
relaunch_stop_daemon() {
    local app="$1" label="$2" off="$3" tries="${4:-10}" bin
    bin="$(relaunch_binary "$app")"
    # Both branches boot the agent out. With launch at login off the toggle has only
    # disabled the label (UX42 never boots out), so a daemon launchd started earlier
    # can still be a loaded KeepAlive job that a pkill alone would see respawned.
    launchctl bootout "gui/$(id -u)/$label" 2>/dev/null || true
    # With it off, the running copy is usually one the owner opened, which no bootout
    # reaches. With it on, a hand-opened copy is rare, so it is signalled only when
    # one is still there after the bootout.
    if [[ "$off" == 1 ]] || pgrep -f "$bin" >/dev/null; then
        pkill -f "$bin" 2>/dev/null || true
    fi
    local n
    for ((n = 0; n < tries; n++)); do
        pgrep -f "$bin" >/dev/null || return 0
        sleep 1
    done
    pgrep -f "$bin" >/dev/null || return 0
    printf 'MeetingPipe is still running from %s after %d s; quit it from the menu bar and re-run.\n' \
        "$bin" "$tries" >&2
    return 1
}

# relaunch_start_daemon <app> <plist> <label> <login-off: 0|1>
#
# Start the new build: `open` when launch at login is off, else bootstrap the
# agent, retried five times. Returns 1, with a line on stderr, when launchd will
# not take the job.
relaunch_start_daemon() {
    local app="$1" plist="$2" label="$3" off="$4" _
    if [[ "$off" == 1 ]]; then
        open "$app"
        return 0
    fi
    for _ in 1 2 3 4 5; do
        launchctl bootstrap "gui/$(id -u)" "$plist" 2>/dev/null && return 0
        sleep 1
    done
    printf "launchctl bootstrap failed for %s. See 'launchctl print gui/%s/%s'\n" \
        "$plist" "$(id -u)" "$label" >&2
    return 1
}

# relaunch_verify_daemon <app> <label> [tries]
#
# Wait up to <tries> seconds for a process on the installed binary. The stop
# above waited for every old one to exit, so any process found here is the new
# build. Returns 1, naming launchd.err.log, when none appears.
relaunch_verify_daemon() {
    local app="$1" label="$2" tries="${3:-5}" bin n
    bin="$(relaunch_binary "$app")"
    # Not `_`: bash rewrites $_ after every command, so a loop counting on it never ends.
    for ((n = 0; n < tries; n++)); do
        pgrep -f "$bin" >/dev/null && return 0
        sleep 1
    done
    pgrep -f "$bin" >/dev/null && return 0
    printf "daemon did not start. Check ~/Library/Logs/MeetingPipe/launchd.err.log and 'launchctl print gui/%s/%s'\n" \
        "$(id -u)" "$label" >&2
    return 1
}
