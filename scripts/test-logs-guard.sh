#!/usr/bin/env bash
# Both directions of the T9 logs guard in scripts/lib/logs-guard.sh.
#
# The guard's first version compared the real logs folder before and after a
# suite, and went red whenever the installed app wrote its own lines meanwhile
# (2026-11-21 second fix review, M8). This pins that an app appending to the real
# folder during a run stays green, and that a test process writing one row through
# its home, the way every past leak did, turns it red.
#
# Everything happens under a scratch dir standing in for the real home: the real
# ~/Library/Logs is never read or written. One line per case; exits non-zero if any
# case fails.

set -u

# shellcheck source=scripts/lib/logs-guard.sh
source "$(cd "$(dirname "$0")" && pwd)/lib/logs-guard.sh"

failures=0
ok()   { printf '  ok    %s\n' "$1"; }
fail() { printf '  FAIL  %s\n' "$1"; failures=$((failures + 1)); }

SCRATCH=$(mktemp -d "${TMPDIR:-/tmp}/mp-logs-guard-test.XXXXXX")
APP_PID=""
cleanup() {
    if [ -n "$APP_PID" ]; then kill "$APP_PID" 2>/dev/null || true; fi
    rm -rf "$SCRATCH"
}
trap cleanup EXIT

# The stand-in real home, with the installed app's logs folder in it. Sentinels
# go under the scratch dir too.
export HOME="$SCRATCH/real-home"
export TMPDIR="$SCRATCH/tmp"
REAL_LOGS="$HOME/Library/Logs/MeetingPipe"
mkdir -p "$REAL_LOGS" "$TMPDIR"
echo "app start" > "$REAL_LOGS/daemon.log"

# run_guarded <label> <command...>: the ci-local shape, returns the check's status.
run_guarded() {
    local label=$1 home rc=0
    shift
    home=$(logs_sentinel_home)
    env HOME="$home" CFFIXED_USER_HOME="$home" "$@"
    logs_sentinel_check "$label" "$home" >/dev/null 2>&1 || rc=$?
    if [ -e "$home" ]; then fail "$label: the sentinel home is removed after the check"; fi
    return "$rc"
}

# 1. The sentinel is a fresh empty dir, not the real home.
probe=$(logs_sentinel_home)
if [ -d "$probe" ] && [ -z "$(ls -A "$probe")" ] && [ "$probe" != "$HOME" ]; then
    ok "sentinel home is a new empty directory"
else
    fail "sentinel home is a new empty directory (got $probe)"
fi
rm -rf "$probe"

# 2. THE FALSE RED FROM M8: the installed app appends to the real folder for the
# whole run (it resolves the real home, since it never sees the sentinel). Green.
( while :; do echo "heartbeat" >> "$REAL_LOGS/daemon.log"; sleep 0.05; done ) &
APP_PID=$!
before=$(wc -c < "$REAL_LOGS/daemon.log")
if run_guarded "idle suite" sleep 1; then
    ok "an app writing the real folder during the run is not blamed"
else
    fail "an app writing the real folder during the run is not blamed"
fi
after=$(wc -c < "$REAL_LOGS/daemon.log")
kill "$APP_PID" 2>/dev/null || true
wait "$APP_PID" 2>/dev/null || true
APP_PID=""
# The positive control: the app really did write during the run, so the case above
# would have been red under the before/after comparison.
if [ "$after" -gt "$before" ]; then
    ok "the stand-in app really wrote during the run"
else
    fail "the stand-in app really wrote during the run ($before -> $after bytes)"
fi

# 3. A Python test writing one row through Path.home(), the orchestrate and
# marker_path shape. Red.
if run_guarded "python leak" python3 -c '
from pathlib import Path
d = Path.home() / "Library" / "Logs" / "MeetingPipe"
d.mkdir(parents=True, exist_ok=True)
with (d / "events.jsonl").open("a") as f:
    f.write("{\"category\": \"pipeline\"}\n")
'; then
    fail "one row written through Path.home() turns it red"
else
    ok "one row written through Path.home() turns it red"
fi

# 4. A child that resolves the home the way Foundation does on macOS
# (CFFIXED_USER_HOME, the staged-doctor shape). Red. Single quotes on purpose: the
# child expands the variable.
# shellcheck disable=SC2016
if run_guarded "foundation leak" sh -c \
    'mkdir -p "$CFFIXED_USER_HOME/Library/Logs/MeetingPipe" && echo row >> "$CFFIXED_USER_HOME/Library/Logs/MeetingPipe/events.jsonl"'; then
    fail "one row written through CFFIXED_USER_HOME turns it red"
else
    ok "one row written through CFFIXED_USER_HOME turns it red"
fi

# 5. The failure names the leaked file.
home=$(logs_sentinel_home)
mkdir -p "$home/Library/Logs/MeetingPipe"
echo row > "$home/Library/Logs/MeetingPipe/pipeline.log"
message=$(logs_sentinel_check "named leak" "$home" 2>&1 || true)
case "$message" in
    *"Library/Logs/MeetingPipe/pipeline.log"*) ok "the failure names the leaked file" ;;
    *) fail "the failure names the leaked file (got: $message)" ;;
esac

# 6. An empty logs folder (a resolver that only creates the directory) is not a write.
# shellcheck disable=SC2016
if run_guarded "mkdir only" sh -c 'mkdir -p "$HOME/Library/Logs/MeetingPipe"'; then
    ok "a created but empty logs folder is not a leak"
else
    fail "a created but empty logs folder is not a leak"
fi

# 7. None of the leaks above reached the stand-in real folder.
if [ "$(ls "$REAL_LOGS")" = "daemon.log" ]; then
    ok "the stand-in real folder holds only the app's own file"
else
    fail "the stand-in real folder holds only the app's own file (got: $(ls "$REAL_LOGS" | tr '\n' ' '))"
fi

if [ "$failures" -ne 0 ]; then
    echo "test-logs-guard: $failures case(s) failed"
    exit 1
fi
echo "test-logs-guard: all cases passed"
