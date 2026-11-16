#!/usr/bin/env bash
# Gate matrix for scripts/uninstall.sh (DIST8): a plain uninstall must keep the
# owner's own data (originals/ incl. held/, corrections/, auto_consent.json), and
# --purge must list it and ask before deleting any of it.
#
# Runs the REAL uninstall.sh with HOME pointed at a scratch dir and stubs for
# launchctl, pkill, security, tccutil and killall first on PATH, each recording
# its arguments and doing nothing, so it can never stop the live daemon, clear
# real Keychain tokens or reset real permissions. Touches nothing real; exits
# non-zero if any case fails.

set -u

HERE="$(cd "$(dirname "$0")" && pwd)"
UNINSTALL="$HERE/uninstall.sh"
failures=0
ok()   { printf '  ok    %s\n' "$1"; }
fail() { printf '  FAIL  %s\n' "$1"; failures=$((failures + 1)); }
check() { if eval "$2"; then ok "$1"; else fail "$1"; fi; }

ROOT="$(mktemp -d)"
trap 'rm -rf "$ROOT"' EXIT
STUBS="$ROOT/stubs"
CALLS="$ROOT/calls.log"
mkdir -p "$STUBS"
for cmd in launchctl pkill security tccutil killall; do
    printf '#!/bin/sh\necho "%s $*" >> "%s"\nexit 0\n' "$cmd" "$CALLS" > "$STUBS/$cmd"
    chmod +x "$STUBS/$cmd"
done

# A stub is bypassed by an absolute path or `command -p`/`env -i`, which PATH cannot intercept.
if grep -nE 'command +-p|env +-i' "$UNINSTALL" "$HERE/lib/uninstall-purge.sh" >/dev/null; then
    fail "uninstall.sh bypasses PATH (command -p / env -i)"
elif grep -nE '(^|[^[:alnum:]_.-])/(usr/)?(s?bin)/(launchctl|pkill|security|tccutil|killall)' "$UNINSTALL" "$HERE/lib/uninstall-purge.sh" >/dev/null; then
    fail "uninstall.sh calls a guarded command by absolute path (would bypass the stubs)"
else
    ok "no guarded command is called by absolute path"
fi

# make_home <dir>: a scratch install with the owner's data and the rebuildable parts.
make_home() {
    local h="$1" s="$1/Library/Application Support/MeetingPipe"
    mkdir -p "$s/originals/held" "$s/corrections" "$h/.config/meeting-pipe" \
             "$h/.local/share/meeting-pipe/venv" "$h/Library/Logs/MeetingPipe" \
             "$h/Library/Application Support/FluidAudio" \
             "$h/Applications/MeetingPipe.app/Contents" "$h/Library/LaunchAgents"
    echo audio > "$s/originals/2026-11-01_standup.wav"
    echo held  > "$s/originals/held/2026-11-02_board.wav"
    echo '{}'  > "$s/corrections/2026-11-01_standup.json"
    echo '{}'  > "$s/auto_consent.json"
    echo cfg   > "$h/.config/meeting-pipe/config.yaml"
    echo log   > "$h/Library/Logs/MeetingPipe/daemon.log"
    echo plist > "$h/Library/LaunchAgents/com.meetingpipe.daemon.plist"
}

# run <home> <stdin-mode> args...: stdin-mode is devnull, or a pty answer (y/n).
# Returns the script's exit code in RC and its output in OUT.
run() {
    local h="$1" mode="$2"; shift 2
    : > "$CALLS"
    if [[ "$mode" == devnull ]]; then
        OUT=$(HOME="$h" PATH="$STUBS:$PATH" bash "$UNINSTALL" "$@" </dev/null 2>&1); RC=$?
    else
        OUT=$(HOME="$h" PATH="$STUBS:$PATH" ANSWER="$mode" UNINSTALL="$UNINSTALL" python3 -I - "$@" <<'PY' 2>&1
import os, pty, select, signal, sys, time
answer = os.environ["ANSWER"] + "\n"
pid, fd = pty.fork()
if pid == 0:
    os.execvp("bash", ["bash", os.environ["UNINSTALL"]] + sys.argv[1:])
out = b""
sent = False
deadline = time.time() + 30
timed_out = False
while True:
    left = deadline - time.time()
    if left <= 0 or not select.select([fd], [], [], left)[0]:
        timed_out = True
        os.kill(pid, signal.SIGKILL)
        break
    try:
        chunk = os.read(fd, 4096)
    except OSError:
        break
    if not chunk:
        break
    out += chunk
    if not sent and b"[y/N]" in out:
        os.write(fd, answer.encode()); sent = True
_, status = os.waitpid(pid, 0)
sys.stdout.write(out.decode(errors="replace"))
sys.stdout.write("\nEXIT:%d\n" % (124 if timed_out else os.waitstatus_to_exitcode(status)))
PY
)
        RC=$(printf '%s\n' "$OUT" | sed -n 's/^EXIT:\([0-9]*\)$/\1/p' | tail -1)
    fi
}

S='Library/Application Support/MeetingPipe'
survivors() {
    [[ -f "$1/$S/originals/2026-11-01_standup.wav" && -f "$1/$S/originals/held/2026-11-02_board.wav" \
       && -f "$1/$S/corrections/2026-11-01_standup.json" && -f "$1/$S/auto_consent.json" ]]
}
rebuildable_gone() {
    [[ ! -e "$1/.local/share/meeting-pipe" && ! -e "$1/Library/Logs/MeetingPipe" \
       && ! -e "$1/Applications/MeetingPipe.app" && ! -e "$1/Library/Application Support/FluidAudio" \
       && ! -e "$1/Library/LaunchAgents/com.meetingpipe.daemon.plist" ]]
}
untouched() {
    survivors "$1" && [[ -d "$1/.config/meeting-pipe" && -d "$1/.local/share/meeting-pipe/venv" \
       && -d "$1/Applications/MeetingPipe.app" ]]
}

echo "default run"
H="$ROOT/h1"; make_home "$H"; run "$H" devnull
check "exit 0" '[[ "$RC" == 0 ]]'
check "originals (incl. held/), corrections and consent survive" 'survivors "$H"'
check "venv, logs and app bundle are gone" 'rebuildable_gone "$H"'
check "config dir survives" '[[ -d "$H/.config/meeting-pipe" ]]'
check "output names the kept folder" 'grep -q "Kept .*Application Support/MeetingPipe" <<<"$OUT"'
check "launchctl and pkill stubs were used" 'grep -q "^launchctl " "$CALLS" && grep -q "^pkill " "$CALLS"'
check "tccutil not called without --reset-tcc" '! grep -q "^tccutil " "$CALLS"'

echo "--reset-tcc"
H="$ROOT/h2"; make_home "$H"; run "$H" devnull --reset-tcc
check "exit 0" '[[ "$RC" == 0 ]]'
check "same survivors" 'survivors "$H"'
check "rebuildable parts gone" 'rebuildable_gone "$H"'
check "tccutil stub was called" 'grep -q "^tccutil " "$CALLS"'

echo "--purge --yes"
H="$ROOT/h3"; make_home "$H"; run "$H" devnull --purge --yes
check "exit 0" '[[ "$RC" == 0 ]]'
check "originals, corrections, consent and config are gone" \
    '[[ ! -e "$H/$S" && ! -e "$H/.config/meeting-pipe" ]]'
check "listing named originals with count and size" 'grep -q "originals/ *2 files, " <<<"$OUT"'
check "listing named held/, corrections, consent and config" \
    'grep -q "held/: 1 files" <<<"$OUT" && grep -q "corrections/ *1 files" <<<"$OUT" && grep -q "auto_consent.json *present" <<<"$OUT" && grep -q ".config/meeting-pipe *1 files" <<<"$OUT"'
check "says originals are in no backup" 'grep -q "NO backup" <<<"$OUT"'
check "keychain stub was used" 'grep -q "^security " "$CALLS"'

echo "--purge, no TTY, no --yes"
H="$ROOT/h4"; make_home "$H"; run "$H" devnull --purge
check "exit 2" '[[ "$RC" == 2 ]]'
check "every scratch path still exists" 'untouched "$H"'
check "no stub was called" '[[ ! -s "$CALLS" ]]'
check "says nothing was removed" 'grep -q "nothing was stopped or removed" <<<"$OUT"'

echo "--all, no TTY, no --yes"
H="$ROOT/h5"; make_home "$H"; run "$H" devnull --all
check "exit 2, untouched, no stub called" '[[ "$RC" == 2 ]] && untouched "$H" && [[ ! -s "$CALLS" ]]'

echo "--purge answered n (pseudo-TTY)"
H="$ROOT/h6"; make_home "$H"; run "$H" n --purge
check "prompt was shown and declined (exit 1, not the no-TTY refusal)" '[[ "$RC" == 1 ]] && grep -q "\[y/N\]" <<<"$OUT"'
check "every scratch path still exists" 'untouched "$H"'
check "no stub was called" '[[ ! -s "$CALLS" ]]'

echo "--purge answered y (pseudo-TTY)"
H="$ROOT/h7"; make_home "$H"; run "$H" y --purge
check "exit 0" '[[ "$RC" == 0 ]]'
check "data and config gone" '[[ ! -e "$H/$S" && ! -e "$H/.config/meeting-pipe" ]]'

if (( failures )); then
    printf '%d case(s) failed\n' "$failures"
    exit 1
fi
echo "all cases passed"
