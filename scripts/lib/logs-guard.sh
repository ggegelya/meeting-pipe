# shellcheck shell=bash
# T9: keep a test run's writes out of the owner's real logs folder, without
# blaming the installed app for its own. Sourced by scripts/ci-local.sh, not run.
#
# Both suites wrote into ~/Library/Logs/MeetingPipe for months (85 percent of one
# laptop's pipeline.log was `synthetic frame` fixture output), always through code
# that built the path from the home directory instead of honouring
# MEETINGPIPE_LOGS_DIR. The first fence (2026-11-18) compared size and mtime of
# every file in the real folder before and after each suite. The installed app
# writes there on its own (heartbeat, recorder and detector lines, event rows), so
# that fence went red with nothing wrong whenever the app was running (2026-11-21
# second fix review, M8). Same uid, same files, same line format: nothing in the
# real folder says which process wrote a line.
#
# So the two writers are told apart by which home they resolve. The test process
# runs with HOME (Python, shell, every child) and CFFIXED_USER_HOME (Foundation's
# home on macOS, which ignores HOME) pointed at an empty throwaway directory, the
# sentinel. A test that falls through to the default path writes under
# <sentinel>/Library/Logs/MeetingPipe, a folder only that run can reach, and any
# file there fails the run. The installed app never sees the sentinel and keeps
# writing to the real folder, which this guard does not read at all.
#
# Blind spot: a writer that finds the home by account (getpwuid,
# NSHomeDirectoryForUser) or by an absolute literal escapes. None exists in
# daemon/, pipeline/ or scripts/ today.
#
# The sentinel goes on the test process alone, never on `uv sync`, pip-audit or
# `swift build`, which read their caches from the real home:
#
#   home=$(logs_sentinel_home)
#   env HOME="$home" CFFIXED_USER_HOME="$home" <test command>
#   logs_sentinel_check <label> "$home"
#
# Pinned by scripts/test-logs-guard.sh.

# Prints the path of a new, empty sentinel home.
logs_sentinel_home() {
    mktemp -d "${TMPDIR:-/tmp}/mp-sentinel-home.XXXXXX"
}

# logs_sentinel_check <label> <sentinel home>
#
# Fails, naming each file, when the run left anything under the sentinel's
# Library/Logs/MeetingPipe. Removes the sentinel either way; it holds only what the
# test process wrote there, never a link to anything real.
logs_sentinel_check() {
    local label=$1 home=$2 leaked
    leaked=$(find "$home/Library/Logs/MeetingPipe" -type f 2>/dev/null | sort || true)
    rm -rf "$home"
    if [ -n "$leaked" ]; then
        echo "::error::T9: $label wrote into the logs folder of its home (~/Library/Logs/MeetingPipe) instead of MEETINGPIPE_LOGS_DIR. On an owner's Mac that is the real folder. Leaked files, under a throwaway home:" >&2
        printf '%s\n' "$leaked" >&2
        return 1
    fi
    echo "T9: $label wrote nothing into the logs folder of its home."
}
