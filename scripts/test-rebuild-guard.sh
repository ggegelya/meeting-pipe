#!/usr/bin/env bash
# Gate matrix for DIST9: rebuild.sh's live-recording guard, its stop-before-write
# order, and its rename-not-overwrite binary swap.
#
# Two halves. The first pins the predicates in scripts/lib/live-recording.sh on
# canned input, the way test-login-agent-guard.sh pins its helper. The second runs
# a copy of the real rebuild.sh inside a scratch tree with every external command
# it reaches (swift, uv, launchctl, pgrep, pkill, open, codesign, mdimport, sleep)
# stubbed on PATH to log its call, HOME pointed at a fake installed app and
# recordings directory, and stdin not a terminal.
#
# Never invokes the real launchctl, never touches the installed app, the real
# recordings directory or the login keychain. Exits non-zero if any case fails.

set -u

HERE="$(cd "$(dirname "$0")" && pwd)"
# shellcheck source=scripts/lib/live-recording.sh
source "$HERE/lib/live-recording.sh"

failures=0
ok()   { printf '  ok    %s\n' "$1"; }
fail() { printf '  FAIL  %s\n' "$1"; failures=$((failures + 1)); }
expect_eq() { if [[ "$2" == "$3" ]]; then ok "$1"; else fail "$1 (got '$2', want '$3')"; fi; }

SCRATCH="$(mktemp -d "${TMPDIR:-/tmp}/mp-rebuild-guard.XXXXXX")"
trap 'rm -rf "$SCRATCH"' EXIT

# ---------------------------------------------------------------------------
# Half 1: the predicates, on canned input
# ---------------------------------------------------------------------------

echo "predicates"
H="/Users/someone"
expect_eq "no config is the default directory" \
    "$(live_recording_output_dir "$SCRATCH/absent.toml" "$H")" "$H/Documents/Meetings/raw"

cat >"$SCRATCH/c1.toml" <<'TOML'
[filesystem]
output_dir = "~/Documents/Meetings/published"

[recording]
min_duration_seconds = 30
output_dir = "~/Elsewhere/raw"   # where the WAVs go
TOML
expect_eq "[recording] output_dir wins, ~ expanded, comment dropped" \
    "$(live_recording_output_dir "$SCRATCH/c1.toml" "$H")" "$H/Elsewhere/raw"

cat >"$SCRATCH/c2.toml" <<'TOML'
[filesystem]
output_dir = "/not/this/one"
TOML
expect_eq "another table's output_dir is not the recordings directory" \
    "$(live_recording_output_dir "$SCRATCH/c2.toml" "$H")" "$H/Documents/Meetings/raw"

cat >"$SCRATCH/c3.toml" <<'TOML'
[ recording ]
output_dir='/Volumes/Meet/raw'
TOML
expect_eq "a literal string and a spaced table header still resolve" \
    "$(live_recording_output_dir "$SCRATCH/c3.toml" "$H")" "/Volumes/Meet/raw"

REC="$SCRATCH/rec"
mkdir -p "$REC"
expect_eq "an empty directory has no manifests" "$(live_recording_manifests "$REC")" ""
expect_eq "an absent directory has no manifests" "$(live_recording_manifests "$SCRATCH/nope")" ""
touch "$REC/20261117-162938.recovery.json" "$REC/20261117-162938.mic.wav" "$REC/20261116-090000.recovery.json"
expect_eq "manifests are listed, sorted, and nothing else" \
    "$(live_recording_manifests "$REC" | tr '\n' ' ')" "20261116-090000.recovery.json 20261117-162938.recovery.json "

M="x.recovery.json"
expect_eq "not running: proceed"                 "$(live_recording_verdict 0 "$M" 0 0)" proceed
expect_eq "running, no manifest: proceed"        "$(live_recording_verdict 1 "" 0 0)" proceed
expect_eq "running + manifest, terminal: ask"     "$(live_recording_verdict 1 "$M" 1 0)" ask
expect_eq "running + manifest, no terminal: refuse" "$(live_recording_verdict 1 "$M" 0 0)" refuse
expect_eq "running + manifest, --force: proceed"  "$(live_recording_verdict 1 "$M" 0 1)" proceed

# ---------------------------------------------------------------------------
# Half 2: the real rebuild.sh in a scratch tree, every external command stubbed
# ---------------------------------------------------------------------------

# make_tree <dir> <login-agent off: 0|1>
make_tree() {
    local t="$1" off="$2"
    mkdir -p "$t/repo/scripts/lib" "$t/repo/daemon/.build/release" "$t/repo/pipeline" "$t/repo/docs" \
        "$t/home/Applications/MeetingPipe.app/Contents/MacOS" \
        "$t/home/Library/LaunchAgents" "$t/home/Documents/Meetings/raw" "$t/bin" "$t/state"
    cp "$HERE/rebuild.sh" "$t/repo/scripts/"
    cp "$HERE/lib/"*.sh "$t/repo/scripts/lib/"
    cp "$HERE/MeetingPipe.entitlements" "$t/repo/scripts/" 2>/dev/null || true
    printf 'new build\n' >"$t/repo/daemon/.build/release/MeetingPipe"
    chmod +x "$t/repo/daemon/.build/release/MeetingPipe"
    printf '# guide\n' >"$t/repo/docs/GUIDE.md"
    printf 'old build\n' >"$t/home/Applications/MeetingPipe.app/Contents/MacOS/MeetingPipe"
    : >"$t/home/Library/LaunchAgents/com.meetingpipe.daemon.plist"
    : >"$t/state/running"
    printf '%s\n' "$off" >"$t/state/login_off"

    local log="$t/calls.log" running="$t/state/running"
    : >"$log"
    stub() { printf '#!/usr/bin/env bash\n%s\n' "$2" >"$t/bin/$1"; chmod +x "$t/bin/$1"; }
    stub swift    "echo \"swift \$*\" >>'$log'"
    stub mdimport "echo \"mdimport \$*\" >>'$log'"
    stub sleep    ":"
    stub open     "echo \"open \$*\" >>'$log'; : >'$running'"
    stub pkill    "echo \"pkill \$*\" >>'$log'; rm -f '$running'"
    stub pgrep    "[[ -e '$running' ]]"
    stub codesign "echo \"codesign \$*\" >>'$log'
if [[ \"\$1\" == -dvv ]]; then
    printf 'Identifier=com.meetingpipe.daemon\nInfo.plist entries=1\nflags=0x10000(runtime)\n' >&2
fi"
    stub launchctl "case \"\$1\" in
    print-disabled)
        if [[ \$(cat '$t/state/login_off') == 1 ]]; then
            printf 'disabled services = {\n\t\t\"com.meetingpipe.daemon\" => disabled\n}\n'
        fi ;;
    bootout)   echo \"launchctl \$*\" >>'$log'; rm -f '$running' ;;
    bootstrap) echo \"launchctl \$*\" >>'$log'; : >'$running' ;;
    *)         echo \"launchctl \$*\" >>'$log' ;;
esac"
    # uv sync builds a venv whose mp points at itself and whose python imports from it.
    stub uv "echo \"uv \$*\" >>'$log'
v=\"\$UV_PROJECT_ENVIRONMENT\"
mkdir -p \"\$v/bin\"
printf '#!/bin/sh\n# %s/bin/python\n' \"\$v\" >\"\$v/bin/mp\"
printf '#!/bin/sh\necho %s/lib/mp/__init__.py\n' \"\$v\" >\"\$v/bin/python3\"
chmod +x \"\$v/bin/mp\" \"\$v/bin/python3\""
}

# run_rebuild <tree> [flags...]: no terminal on stdin, everything else stubbed.
run_rebuild() {
    local t="$1"; shift
    HOME="$t/home" PATH="$t/bin:/usr/bin:/bin:/usr/sbin:/sbin" MEETINGPIPE_SIGN_ID="-" \
        bash "$t/repo/scripts/rebuild.sh" "$@" </dev/null >"$t/out.log" 2>&1
}

app_bin() { echo "$1/home/Applications/MeetingPipe.app/Contents/MacOS/MeetingPipe"; }
inode() { ls -i "$1" | awk '{print $1}'; }
# line number of the first log line matching a pattern, or 0
first_line() { grep -n -m1 -E "$2" "$1/calls.log" | cut -d: -f1 || true; }

echo "rebuild.sh, live recording, no terminal, no --force"
T="$SCRATCH/t1"; make_tree "$T" 0
touch "$T/home/Documents/Meetings/raw/20261117-162938.recovery.json"
before="$(cat "$(app_bin "$T")")"
run_rebuild "$T"; code=$?
expect_eq "exits 2" "$code" 2
expect_eq "the installed binary is untouched" "$(cat "$(app_bin "$T")")" "$before"
if grep -qE '^(launchctl (bootout|bootstrap)|pkill|uv )' "$T/calls.log"; then
    fail "nothing was stopped, synced or relaunched"
else
    ok "nothing was stopped, synced or relaunched"
fi
grep -q "20261117-162938.recovery.json" "$T/out.log" && ok "names the manifest it found" || fail "names the manifest it found"

echo "rebuild.sh, live recording, --force"
T="$SCRATCH/t2"; make_tree "$T" 0
touch "$T/home/Documents/Meetings/raw/20261117-162938.recovery.json"
old_inode="$(inode "$(app_bin "$T")")"
run_rebuild "$T" --force; code=$?
expect_eq "exits 0" "$code" 0
expect_eq "the new binary is installed" "$(cat "$(app_bin "$T")")" "new build"

echo "rebuild.sh, no manifest, launch at login on"
T="$SCRATCH/t3"; make_tree "$T" 0
old_inode="$(inode "$(app_bin "$T")")"
run_rebuild "$T"; code=$?
expect_eq "exits 0 without asking" "$code" 0
grep -q "recording may be in progress" "$T/out.log" && fail "did not ask" || ok "did not ask"
expect_eq "the new binary is installed" "$(cat "$(app_bin "$T")")" "new build"
[[ "$(inode "$(app_bin "$T")")" != "$old_inode" ]] && ok "the binary was renamed into place (new inode)" \
    || fail "the binary was renamed into place (new inode)"
compgen -G "$T/home/Applications/MeetingPipe.app/Contents/MacOS/.MeetingPipe.new*" >/dev/null \
    && fail "no temp file is left behind" || ok "no temp file is left behind"
stop="$(first_line "$T" '^launchctl bootout')"
uv_at="$(first_line "$T" '^uv ')"
sign="$(first_line "$T" '^codesign --force')"
start="$(first_line "$T" '^launchctl bootstrap')"
[[ "$uv_at" -gt 0 && "$stop" -gt "$uv_at" ]] && ok "the venv sync runs before the stop" || fail "the venv sync runs before the stop ($uv_at, $stop)"
[[ "$stop" -gt 0 && "$sign" -gt "$stop" ]] && ok "bootout precedes the app writes and the signing" || fail "bootout precedes the app writes and the signing ($stop, $sign)"
[[ "$start" -gt "$sign" ]] && ok "bootstrap follows the signing" || fail "bootstrap follows the signing ($sign, $start)"
grep -q '^pkill' "$T/calls.log" && fail "no pkill with launch at login on" || ok "no pkill with launch at login on"

echo "rebuild.sh, no manifest, launch at login off"
T="$SCRATCH/t4"; make_tree "$T" 1
run_rebuild "$T"; code=$?
expect_eq "exits 0" "$code" 0
stop="$(first_line "$T" '^pkill')"
sign="$(first_line "$T" '^codesign --force')"
start="$(first_line "$T" '^open ')"
[[ "$stop" -gt 0 && "$sign" -gt "$stop" ]] && ok "pkill precedes the signing" || fail "pkill precedes the signing ($stop, $sign)"
[[ "$start" -gt "$sign" ]] && ok "open follows the signing" || fail "open follows the signing ($sign, $start)"
grep -q '^launchctl bootstrap' "$T/calls.log" && fail "no bootstrap when the toggle is off" \
    || ok "no bootstrap when the toggle is off"
boot="$(first_line "$T" '^launchctl bootout')"
[[ "$boot" -gt 0 && "$sign" -gt "$boot" ]] && ok "a still-loaded KeepAlive job is booted out before the writes" \
    || fail "a still-loaded KeepAlive job is booted out before the writes ($boot, $sign)"

echo "rebuild.sh, signing fails after the stop"
T="$SCRATCH/t6"; make_tree "$T" 0
printf '#!/usr/bin/env bash\necho "codesign $*" >>%q\n[[ "$1" == --force ]] && exit 1\nexit 0\n' "$T/calls.log" >"$T/bin/codesign"
run_rebuild "$T"; code=$?
[[ "$code" -ne 0 ]] && ok "the script fails" || fail "the script fails"
grep -q "stopped and not restarted" "$T/out.log" && ok "it says the daemon is down and how to start it" \
    || fail "it says the daemon is down and how to start it"

echo "rebuild.sh, daemon not running, stale manifest"
T="$SCRATCH/t5"; make_tree "$T" 0
touch "$T/home/Documents/Meetings/raw/20261101-100000.recovery.json"
rm -f "$T/state/running"
run_rebuild "$T"; code=$?
expect_eq "a manifest with no daemon running is not live: exits 0" "$code" 0

if [[ $failures -gt 0 ]]; then
    printf '\n%d case(s) failed. Last run output (%s):\n' "$failures" "$T"
    cat "$T/out.log"
    exit 1
fi
printf '\nall rebuild guard cases passed\n'
