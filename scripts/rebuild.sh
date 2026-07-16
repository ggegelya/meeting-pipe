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

# Full bootout + bootstrap, NOT `kickstart -k`. A rebuild changes the binary's
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
PLIST="$HOME/Library/LaunchAgents/${LAUNCHD_LABEL}.plist"
[[ -f "$PLIST" ]] || die "LaunchAgent plist missing at $PLIST — run scripts/install.sh"
launchctl bootout "gui/$UID/$LAUNCHD_LABEL" 2>/dev/null || true
# bootout returns before the old instance is fully reaped, so bootstrap can lose a
# race with the teardown; retry briefly until launchd accepts the fresh job.
bootstrapped=false
for _ in 1 2 3 4 5; do
    if launchctl bootstrap "gui/$UID" "$PLIST" 2>/dev/null; then
        bootstrapped=true
        break
    fi
    sleep 1
done
[[ "$bootstrapped" == true ]] || die "launchctl bootstrap failed for $PLIST — see 'launchctl print gui/$UID/$LAUNCHD_LABEL'"

# Verify the daemon actually came up. Without this the script reports success
# even when the spawn failed (the very bug this rewrite fixes), so a dead relaunch
# must be loud.
for _ in 1 2 3 4 5; do
    pgrep -f "$APP/Contents/MacOS/MeetingPipe" >/dev/null && break
    sleep 1
done
pgrep -f "$APP/Contents/MacOS/MeetingPipe" >/dev/null \
    || die "daemon did not relaunch. Check ~/Library/Logs/MeetingPipe/launchd.err.log and 'launchctl print gui/$UID/$LAUNCHD_LABEL'"

ELAPSED=$(($(date +%s) - START_TS))
printf "\033[1;32m✓\033[0m Rebuilt + relaunched in %ds\n" "$ELAPSED"
