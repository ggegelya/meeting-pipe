#!/usr/bin/env bash
# Fast rebuild-and-relaunch loop for daily development (TECH-D7).
#
# Refreshes the daemon binary and resource bundles inside the
# already-installed `~/Applications/MeetingPipe.app`, and re-syncs the
# pipeline venv from this checkout (DIST4: the venv is a real install now,
# not a link into the clone, so a Python edit reaches the app only through
# this or install.sh; incremental, well under a second). Skips everything
# in install.sh that doesn't change between edits:
#
#   - prereq checks (brew, ffmpeg, uv, macOS version)
#   - sherpa-onnx model pre-fetch (~32 MB)
#   - config staging
#   - LaunchAgent install
#
# Target: <30 s end-to-end on incremental Swift builds. Run
# `scripts/install.sh` first for the cold-install path.
#
# DIST9: before touching the venv or the app it checks for a recording in
# progress and asks (`--force` skips the question; with no terminal and no
# `--force` it exits 2 having changed nothing). It stops the daemon before
# writing into the app, replaces the binary by rename rather than overwriting
# it in place, and starts the daemon again only after re-signing.
#
# Flags:
#   --force  go on even when a recording may be in progress.

set -euo pipefail

FORCE=0
for arg in "$@"; do
    case "$arg" in
        --force) FORCE=1 ;;
        -h|--help)
            awk '/^set -/{exit}{print}' "$0"
            exit 0
            ;;
        *)
            printf 'unknown flag: %s\n' "$arg" >&2
            exit 2
            ;;
    esac
done

REPO_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
APP="$HOME/Applications/MeetingPipe.app"
DATA_DIR="$HOME/.local/share/meeting-pipe"
LAUNCHD_LABEL="com.meetingpipe.daemon"

say()  { printf "\033[1;34m==>\033[0m %s\n" "$*"; }
warn() { printf "\033[1;33m!!\033[0m %s\n" "$*" >&2; }
die()  { printf "\033[1;31mxx\033[0m %s\n" "$*" >&2; exit 1; }

# Shared app-bundle signing (also used by install.sh).
source "$REPO_ROOT/scripts/lib/sign-app.sh"
# Shared resource-bundle placement and pipeline venv sync (DIST4; also used by
# install.sh and scripts/test-app-relocation.sh).
source "$REPO_ROOT/scripts/lib/resource-bundles.sh"
source "$REPO_ROOT/scripts/lib/pipeline-venv.sh"
# Shared launch-at-login guard (also used by install.sh): UX42's rule that a
# rebuild must not fight a login-start the owner turned off in Preferences.
# shellcheck source=scripts/lib/login-agent.sh
source "$REPO_ROOT/scripts/lib/login-agent.sh"
# DIST9: the live-recording check (also used by install.sh).
# shellcheck source=scripts/lib/live-recording.sh
source "$REPO_ROOT/scripts/lib/live-recording.sh"

if [[ ! -d "$APP" ]]; then
    die "$APP missing. Run scripts/install.sh first for the cold-install path."
fi
PLIST="$HOME/Library/LaunchAgents/${LAUNCHD_LABEL}.plist"

START_TS=$(date +%s)

say "swift build (release)"
(cd "$REPO_ROOT/daemon" && swift build -c release)

NEW_BIN="$REPO_ROOT/daemon/.build/release/MeetingPipe"
[[ -x "$NEW_BIN" ]] || die "Build did not produce $NEW_BIN"

# DIST9: after the build (so the answer is about now, not half a minute ago) and
# before the venv or the app is touched, so a "no" or a refusal leaves both alone.
guard_live_recording "$APP" "$HOME/.config/meeting-pipe/config.toml" "$FORCE" "rebuild"

# Before touching the app, so a sync that fails leaves the installed binary alone
# and the two trees cannot land out of step.
say "Syncing the pipeline venv"
sync_pipeline_venv "$REPO_ROOT/pipeline" "$DATA_DIR/venv" \
    || die "Pipeline sync failed; uv's output above says why. The app was not touched."

# DIST9: stop the daemon before the first write into the app, and start it again
# only after re-signing, so nothing runs or respawns from a half-written bundle.
# The plist launchd's KeepAlive respawns from sets SuccessfulExit false, and the
# audit measured a fresh exec between the old in-place `cp` and the re-sign killed
# at once (exit 137). UX42: the Preferences toggle owns login-start and expresses
# "off" as a launchd disabled override; then launchd is not running the daemon,
# you are, so the stop is a pkill and the start an `open`.
if login_agent_disabled "$LAUNCHD_LABEL"; then
    LOGIN_AGENT_OFF=1
else
    LOGIN_AGENT_OFF=0
    [[ -f "$PLIST" ]] || die "LaunchAgent plist missing at $PLIST - run scripts/install.sh"
fi
say "Stopping the daemon"
# From here until the relaunch is verified, a failure leaves the daemon down, where
# the old order (write first, stop last) left it running. Say so on the way out
# rather than letting the next meeting find it: a `die` below still exits non-zero,
# and this trap runs after it.
trap 'warn "The daemon was stopped and not restarted. Start it with: open \"$APP\" (or re-run this script)."' EXIT
# Both branches boot the agent out. With launch at login off the toggle has only
# disabled the label (UX42 never boots out), so a daemon launchd started earlier
# is still a loaded KeepAlive job, and the SIGTERM path exits non-zero to ask for
# a relaunch: a pkill alone would have launchd respawn it into the bundle being
# written. A bootout of a label that is not loaded is a no-op.
launchctl bootout "gui/$UID/$LAUNCHD_LABEL" 2>/dev/null || true
if [[ "$LOGIN_AGENT_OFF" == 1 ]]; then
    pkill -f "$APP/Contents/MacOS/MeetingPipe" 2>/dev/null || true
fi
# bootout and pkill return before the process is gone; wait for it, so the writes
# below never race its exit.
for _ in 1 2 3 4 5 6 7 8 9 10; do
    pgrep -f "$APP/Contents/MacOS/MeetingPipe" >/dev/null || break
    sleep 1
done
pgrep -f "$APP/Contents/MacOS/MeetingPipe" >/dev/null \
    && warn "The daemon is still running after 10 s; writing into the app anyway."

say "Refreshing $APP"
# DIST9: a new file renamed over the old one, never `cp` onto it: BSD cp truncates
# and rewrites the existing inode, so the installed path was briefly a partly
# written file, and a running image's file changed under it. `mv` within one
# directory is an atomic rename.
NEW_IN_APP="$APP/Contents/MacOS/.MeetingPipe.new.$$"
cp "$NEW_BIN" "$NEW_IN_APP"
mv -f "$NEW_IN_APP" "$APP/Contents/MacOS/MeetingPipe"

# Resource bundles (SwiftPM's `<Package>_<Target>.bundle`) refresh too; they
# change when Resources/ contents change. They live in Contents/Resources, and
# the first rebuild after DIST4 also clears the copies an older install left in
# Contents/MacOS.
install_resource_bundles "$REPO_ROOT/daemon/.build/release" "$APP"

# The user guide the menu bar's "Guide…" reads (DOC11). Refreshed here as well
# as in install.sh, so editing docs/GUIDE.md and rebuilding shows the edit.
if [[ -f "$REPO_ROOT/docs/GUIDE.md" ]]; then
    mkdir -p "$APP/Contents/Resources"
    cp "$REPO_ROOT/docs/GUIDE.md" "$APP/Contents/Resources/GUIDE.md"
fi

# Re-sign with the stable "MeetingPipe Dev" identity (ensure_dev_cert creates
# it on first run; see scripts/lib/dev-cert.sh). The cert gives an
# identity-based designated requirement that does NOT pin the cdhash, so the
# Screen Recording grant survives this rebuild with no re-toggle. Falls back to
# ad-hoc only if the cert could not be created (then Screen Recording needs a
# one-time re-toggle, as before).
say "Re-signing"
ensure_dev_cert
sign_app_with_resources "$APP"

# DIST3: this script writes into ~/Applications/MeetingPipe.app too, so it gets
# the same ask install.sh makes. The marginal value is lower here, since the
# bundle path is unchanged and an already-indexed app stays indexed; it earns
# its fraction of a second because a rebuild is the fast path the owner runs
# most often, so an index that was missing after an install gets another chance
# on every rebuild rather than only on a full reinstall. Non-fatal and quiet on
# success, because a rebuild's output is a progress log rather than a report.
if command -v mdimport >/dev/null 2>&1; then
    mdimport "$APP" >/dev/null 2>&1 \
        || warn "mdimport failed; the app may not appear in Spotlight search ('mp doctor' checks it)."
fi

# Full bootout (done above, before the writes) + bootstrap, NOT `kickstart -k`. A rebuild changes the binary's
# cdhash, which staleifies launchd's cached launch constraint (the LWCR). The
# cheaper `kickstart -k` reuses that stale constraint, so the respawn fails with
# EX_CONFIG (78) — and kickstart still returns 0, so the failure is silent and the
# daemon stays down while the script prints success (the "relaunch did nothing"
# bug). A fresh bootout + bootstrap makes launchd recompute the constraint from
# the new binary. RunAtLoad brings it straight back, so there is no 10 s
# ThrottleInterval penalty (that throttles KeepAlive respawns, not a fresh load);
# TCC grants are keyed on the signing identity, not the launchd registration, so
# they survive this too.
say "Relaunching daemon"
# UX42: the Preferences ▸ General toggle owns login-start now, and it expresses
# "off" as a launchd disabled override. Bootstrapping a disabled service fails,
# so without this branch a rebuild would die on a state the owner chose on
# purpose, and re-enabling to get past it would silently undo the toggle.
# Relaunch the app directly instead, which is exactly what "off" means: launchd
# does not start MeetingPipe, you do. The verification below covers both paths.
if [[ "$LOGIN_AGENT_OFF" == 1 ]]; then
    say "Launch at login is off, so launchd is not starting the daemon; relaunching the app directly."
    open "$APP"
else
    # The bootout above can still be settling in launchd, so bootstrap can lose a
    # race with the teardown; retry briefly until launchd accepts the fresh job.
    bootstrapped=false
    for _ in 1 2 3 4 5; do
        if launchctl bootstrap "gui/$UID" "$PLIST" 2>/dev/null; then
            bootstrapped=true
            break
        fi
        sleep 1
    done
    [[ "$bootstrapped" == true ]] || die "launchctl bootstrap failed for $PLIST. See 'launchctl print gui/$UID/$LAUNCHD_LABEL'"
fi

# Verify the daemon actually came up. Without this the script reports success
# even when the spawn failed (the very bug this rewrite fixes), so a dead relaunch
# must be loud.
for _ in 1 2 3 4 5; do
    pgrep -f "$APP/Contents/MacOS/MeetingPipe" >/dev/null && break
    sleep 1
done
pgrep -f "$APP/Contents/MacOS/MeetingPipe" >/dev/null \
    || die "daemon did not relaunch. Check ~/Library/Logs/MeetingPipe/launchd.err.log and 'launchctl print gui/$UID/$LAUNCHD_LABEL'"

trap - EXIT
ELAPSED=$(($(date +%s) - START_TS))
printf "\033[1;32m✓\033[0m Rebuilt + relaunched in %ds\n" "$ELAPSED"
