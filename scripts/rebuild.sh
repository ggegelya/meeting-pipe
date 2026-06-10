#!/usr/bin/env bash
# Fast rebuild-and-relaunch loop for daily development (TECH-D7).
#
# Touches ONLY the daemon binary inside the already-installed
# `~/Applications/MeetingPipe.app`. Skips everything in install.sh
# that doesn't change between Swift edits:
#
#   - prereq checks (brew, ffmpeg, uv, macOS version)
#   - pipeline venv install (uv sync)
#   - sherpa-onnx model pre-fetch (~32 MB)
#   - config staging
#   - LaunchAgent install
#
# Target: <30 s end-to-end on incremental Swift builds. Run
# `scripts/install.sh` first for the cold-install path.

set -euo pipefail

REPO_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
APP="$HOME/Applications/MeetingPipe.app"
LAUNCHD_LABEL="com.meetingpipe.daemon"

say()  { printf "\033[1;34m==>\033[0m %s\n" "$*"; }
warn() { printf "\033[1;33m!!\033[0m %s\n" "$*" >&2; }
die()  { printf "\033[1;31mxx\033[0m %s\n" "$*" >&2; exit 1; }

# Shared two-pass app-bundle signing (also used by install.sh).
source "$REPO_ROOT/scripts/lib/sign-app.sh"

if [[ ! -d "$APP" ]]; then
    die "$APP missing. Run scripts/install.sh first for the cold-install path."
fi

START_TS=$(date +%s)

say "swift build (release)"
(cd "$REPO_ROOT/daemon" && swift build -c release)

NEW_BIN="$REPO_ROOT/daemon/.build/release/MeetingPipe"
[[ -x "$NEW_BIN" ]] || die "Build did not produce $NEW_BIN"

say "Refreshing $APP/Contents/MacOS"
cp "$NEW_BIN" "$APP/Contents/MacOS/MeetingPipe"

# Resource bundles (SwiftPM's `<Target>_<Target>.bundle`) refresh too —
# they change when Resources/ contents change.
for bundle in "$REPO_ROOT/daemon/.build/release/"*.bundle; do
    [[ -e "$bundle" ]] || continue
    DEST="$APP/Contents/MacOS/$(basename "$bundle")"
    rm -rf "$DEST"
    ditto "$bundle" "$DEST"
done

# Re-sign with the stable "MeetingPipe Dev" identity (ensure_dev_cert creates
# it on first run; see scripts/lib/dev-cert.sh). The cert gives an
# identity-based designated requirement that does NOT pin the cdhash, so the
# Screen Recording grant survives this rebuild with no re-toggle. Falls back to
# ad-hoc only if the cert could not be created (then Screen Recording needs a
# one-time re-toggle, as before).
say "Re-signing"
ensure_dev_cert
sign_app_with_resources "$APP"

# `kickstart -k` sends SIGTERM and immediately respawns under the same
# LaunchAgent label, bypassing the 10 s ThrottleInterval that would
# otherwise add a fixed wall-clock cost to every iteration. Falls back
# to a manual load when the agent isn't currently bootstrapped (e.g.
# the user previously ran `launchctl unload`).
say "Kickstarting daemon"
if ! launchctl kickstart -k "gui/$UID/$LAUNCHD_LABEL" 2>/dev/null; then
    PLIST="$HOME/Library/LaunchAgents/${LAUNCHD_LABEL}.plist"
    [[ -f "$PLIST" ]] || die "LaunchAgent plist missing at $PLIST — run scripts/install.sh"
    launchctl load -w "$PLIST"
fi

ELAPSED=$(($(date +%s) - START_TS))
printf "\033[1;32m✓\033[0m Rebuilt + relaunched in %ds\n" "$ELAPSED"
