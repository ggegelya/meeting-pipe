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
# DIST5: the verified stop and relaunch (also used by install.sh).
# shellcheck source=scripts/lib/relaunch.sh
source "$REPO_ROOT/scripts/lib/relaunch.sh"

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
# relaunch_stop_daemon boots the agent out in both branches and stops a copy
# launchd does not own (lib/relaunch.sh), then waits for it to exit, so the
# writes below never race its exit.
relaunch_stop_daemon "$APP" "$LAUNCHD_LABEL" "$LOGIN_AGENT_OFF" \
    || warn "Writing into the app anyway."

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

# Full bootout (done above, before the writes) + bootstrap, NOT `kickstart -k`, then
# a pgrep that proves the new build came up: lib/relaunch.sh carries why. RunAtLoad
# brings it straight back, so there is no 10 s ThrottleInterval penalty (that
# throttles KeepAlive respawns, not a fresh load); TCC grants are keyed on the
# signing identity, not the launchd registration, so they survive this too.
say "Relaunching daemon"
# UX42: the Preferences ▸ General toggle owns login-start, and it expresses "off" as
# a launchd disabled override. Bootstrapping a disabled service fails, and
# re-enabling to get past it would silently undo the toggle, so with it off the app
# is opened directly instead, which is exactly what "off" means.
if [[ "$LOGIN_AGENT_OFF" == 1 ]]; then
    say "Launch at login is off, so launchd is not starting the daemon; relaunching the app directly."
fi
relaunch_start_daemon "$APP" "$PLIST" "$LAUNCHD_LABEL" "$LOGIN_AGENT_OFF" || die "The relaunch failed (above)."
relaunch_verify_daemon "$APP" "$LAUNCHD_LABEL" || die "The relaunch failed (above)."

trap - EXIT
ELAPSED=$(($(date +%s) - START_TS))
printf "\033[1;32m✓\033[0m Rebuilt + relaunched in %ds\n" "$ELAPSED"
