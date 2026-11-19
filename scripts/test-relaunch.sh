#!/usr/bin/env bash
# shellcheck disable=SC2034  # CI12: results are read inside the single-quoted `check` conditions
# Gate matrix for scripts/lib/relaunch.sh and scripts/lib/toolchain.sh (DIST5).
#
# relaunch.sh is the stop, start and verify that install.sh and rebuild.sh share.
# Each case sources it in a subshell with launchctl, pkill, pgrep, open and sleep
# stubbed first on PATH: each logs its call, and a state directory stands in for
# "a MeetingPipe process is running" and for how many bootstraps launchd refuses.
# The toolchain predicate runs on canned `swift --version` output.
#
# Never invokes the real launchctl and never signals a real process. Exits
# non-zero if any case fails.

set -u

HERE="$(cd "$(dirname "$0")" && pwd)"
failures=0
ok()   { printf '  ok    %s\n' "$1"; }
fail() { printf '  FAIL  %s\n' "$1"; failures=$((failures + 1)); }
check() { if eval "$2"; then ok "$1"; else fail "$1"; fi; }

ROOT="$(mktemp -d "${TMPDIR:-/tmp}/mp-relaunch.XXXXXX")"
trap 'rm -rf "$ROOT"' EXIT
APP="$ROOT/Applications/MeetingPipe.app"
PLIST="$ROOT/com.meetingpipe.daemon.plist"
LABEL="com.meetingpipe.daemon"

# A stub is bypassed by an absolute path, which PATH cannot intercept.
if grep -nE '(^|[^[:alnum:]_.-])/(usr/)?(s?bin)/(launchctl|pkill|pgrep|open|sleep)' "$HERE/lib/relaunch.sh" >/dev/null; then
    fail "relaunch.sh calls a guarded command by absolute path"
else
    ok "no guarded command is called by absolute path"
fi

# setup <case>: fresh stubs and state. Knobs, as files in $ST:
#   running        a MeetingPipe process exists
#   refuse_boot N  launchd refuses the next N bootstraps
#   stubborn       pkill does not stop it (and bootout does not either)
#   no_spawn       a bootstrap that succeeds starts no process
setup() {
    T="$ROOT/$1"; ST="$T/state"; BIN="$T/bin"; LOG="$T/calls.log"
    mkdir -p "$ST" "$BIN"; : >"$LOG"
    stub() { printf '#!/usr/bin/env bash\n%s\n' "$2" >"$BIN/$1"; chmod +x "$BIN/$1"; }
    stub sleep ":"
    stub pgrep "[[ -e '$ST/running' ]]"
    stub pkill "echo \"pkill \$*\" >>'$LOG'; [[ -e '$ST/stubborn' ]] || rm -f '$ST/running'"
    stub open  "echo \"open \$*\" >>'$LOG'; : >'$ST/running'"
    stub launchctl "echo \"launchctl \$*\" >>'$LOG'
case \"\$1\" in
    bootout) [[ -e '$ST/stubborn' || -e '$ST/hand_started' ]] || rm -f '$ST/running' ;;
    bootstrap)
        n=\$(cat '$ST/refuse_boot' 2>/dev/null || echo 0)
        if (( n > 0 )); then echo \$((n - 1)) >'$ST/refuse_boot'; exit 5; fi
        [[ -e '$ST/no_spawn' ]] || : >'$ST/running' ;;
esac"
}

# call <function> args...: run one helper with the stubs, capturing exit code and stderr.
call() {
    ERR=$(PATH="$BIN:/usr/bin:/bin" bash -c 'source "$0"; "$@"' "$HERE/lib/relaunch.sh" "$@" 2>&1 >/dev/null); RC=$?
}

echo "start: launch at login on"
setup on_third_try; echo 2 >"$ST/refuse_boot"
call relaunch_start_daemon "$APP" "$PLIST" "$LABEL" 0
check "a bootstrap that succeeds on the third try passes" '[[ "$RC" == 0 ]]'
check "it tried three times" '[[ $(grep -c "^launchctl bootstrap" "$LOG") == 3 ]]'

setup refused; echo 9 >"$ST/refuse_boot"
call relaunch_start_daemon "$APP" "$PLIST" "$LABEL" 0
check "five refused bootstraps exit non-zero" '[[ "$RC" != 0 ]]'
check "after exactly five tries" '[[ $(grep -c "^launchctl bootstrap" "$LOG") == 5 ]]'
check "and say what failed" 'grep -q "launchctl bootstrap failed" <<<"$ERR"'

setup no_spawn; : >"$ST/no_spawn"
call relaunch_start_daemon "$APP" "$PLIST" "$LABEL" 0
start_rc=$RC
call relaunch_verify_daemon "$APP" "$LABEL"
check "a bootstrap that succeeds with no process: the start passes, the verify fails" '[[ "$start_rc" == 0 && "$RC" != 0 ]]'
check "the failure points at launchd.err.log" 'grep -q "launchd.err.log" <<<"$ERR"'

setup verified
call relaunch_start_daemon "$APP" "$PLIST" "$LABEL" 0 && call relaunch_verify_daemon "$APP" "$LABEL"
check "a process that appears verifies" '[[ "$RC" == 0 ]]'

echo "start: launch at login off (UX42)"
setup off_start
call relaunch_start_daemon "$APP" "$PLIST" "$LABEL" 1
check "it opens the app" '[[ "$RC" == 0 ]] && grep -q "^open $APP$" "$LOG"'
check "it never calls bootstrap, load or enable" '! grep -qE "^launchctl (bootstrap|load|enable)" "$LOG"'

echo "stop"
setup stop_on; : >"$ST/running"
call relaunch_stop_daemon "$APP" "$LABEL" 0
check "launch at login on: the agent is booted out and the process is gone" \
    '[[ "$RC" == 0 ]] && grep -q "^launchctl bootout gui/[0-9]*/$LABEL$" "$LOG" && [[ ! -e "$ST/running" ]]'
check "and no pkill when the bootout stopped it" '! grep -q "^pkill" "$LOG"'

setup stop_hand_on; : >"$ST/running"; : >"$ST/hand_started"
call relaunch_stop_daemon "$APP" "$LABEL" 0
check "launch at login on, a copy the bootout cannot reach: it is pkilled" \
    '[[ "$RC" == 0 ]] && grep -q "^pkill -f $APP/Contents/MacOS/MeetingPipe$" "$LOG"'

setup stop_off; : >"$ST/running"; : >"$ST/hand_started"
call relaunch_stop_daemon "$APP" "$LABEL" 1
check "launch at login off, a hand-started copy: it is stopped" \
    '[[ "$RC" == 0 ]] && grep -q "^pkill -f $APP/Contents/MacOS/MeetingPipe$" "$LOG" && [[ ! -e "$ST/running" ]]'
check "launch at login off: the stop never calls bootstrap, load or enable" \
    '! grep -qE "^launchctl (bootstrap|load|enable)" "$LOG"'

setup stop_stubborn; : >"$ST/running"; : >"$ST/stubborn"
call relaunch_stop_daemon "$APP" "$LABEL" 1
check "launch at login off, a process still there after the wait: exits non-zero" '[[ "$RC" != 0 ]]'
check "and says so" 'grep -q "still running" <<<"$ERR"'
check "still never bootstraps" '! grep -q "^launchctl bootstrap" "$LOG"'

echo "the whole off branch, in install.sh's order"
setup off_flow; : >"$ST/running"; : >"$ST/hand_started"
PATH="$BIN:/usr/bin:/bin" bash -c 'source "$0"; relaunch_stop_daemon "$1" "$2" 1 && relaunch_start_daemon "$1" "$3" "$2" 1 && relaunch_verify_daemon "$1" "$2"' \
    "$HERE/lib/relaunch.sh" "$APP" "$LABEL" "$PLIST" >/dev/null 2>&1; RC=$?
check "stop, open, verify passes with exactly one process at the end" '[[ "$RC" == 0 && -e "$ST/running" ]]'
check "the stop came before the open" \
    '[[ $(grep -n "^pkill" "$LOG" | cut -d: -f1) -lt $(grep -n "^open" "$LOG" | cut -d: -f1) ]]'
check "no bootstrap anywhere" '! grep -q "^launchctl bootstrap" "$LOG"'

echo "both scripts use the helper"
for s in install.sh rebuild.sh; do
    check "$s sources lib/relaunch.sh and calls all three" \
        'grep -q "lib/relaunch.sh" "$HERE/$s" && grep -q "relaunch_stop_daemon" "$HERE/$s" && grep -q "relaunch_start_daemon" "$HERE/$s" && grep -q "relaunch_verify_daemon" "$HERE/$s"'
    check "$s never uses kickstart -k" '! grep -qE "^[^#]*launchctl kickstart" "$HERE/$s"'
done

echo "Swift toolchain floor"
# shellcheck source=scripts/lib/toolchain.sh
source "$HERE/lib/toolchain.sh"
v510=$'Apple Swift version 5.10 (swiftlang-5.10.0.13 clang-1500.3.9.4)\nTarget: arm64-apple-macosx14.0'
v60=$'swift-driver version: 1.115 Apple Swift version 6.0 (swiftlang-6.0.0.9.10 clang-1600.0.26.2)\nTarget: arm64-apple-macosx15.0'
v633=$'Apple Swift version 6.3.3 (swiftlang-6.3.3.1.1 clang-1700.6.3.2)\nTarget: arm64-apple-macosx26.0'
check "5.10 is refused" '! swift_version_ok "$v510"'
check "6.0 passes" 'swift_version_ok "$v60"'
check "6.3.3 passes" 'swift_version_ok "$v633"'
check "a 10.x would pass (numeric, not string, compare)" 'swift_version_ok "Swift version 10.1"'
check "unreadable output is refused" '! swift_version_ok "swift: command not found"'
check "the version is read as MAJOR.MINOR" '[[ "$(swift_version_from_output "$v633")" == 6.3 ]]'
stop_at="$(grep -n "^relaunch_stop_daemon" "$HERE/install.sh" | head -1 | cut -d: -f1)"
tcc_at="$(grep -n "tccutil reset" "$HERE/install.sh" | head -1 | cut -d: -f1)"
start_at="$(grep -n "^relaunch_start_daemon" "$HERE/install.sh" | head -1 | cut -d: -f1)"
check "install.sh stops the daemon before the TCC reset and starts it after (KeepAlive would respawn a SIGKILLed job)" \
    '[[ -n "$stop_at" && -n "$tcc_at" && -n "$start_at" && "$stop_at" -lt "$tcc_at" && "$tcc_at" -lt "$start_at" ]]'
first_check="$(grep -n "swift_version_ok" "$HERE/install.sh" | head -1 | cut -d: -f1)"
first_build="$(grep -n "swift build -c release" "$HERE/install.sh" | grep -v "^[0-9]*:#" | head -1 | cut -d: -f1)"
check "install.sh checks the version before it runs swift build" \
    '[[ -n "$first_check" && -n "$first_build" && "$first_check" -lt "$first_build" ]]'

if (( failures )); then
    printf '%d case(s) failed\n' "$failures"
    exit 1
fi
echo "all relaunch cases passed"
