#!/usr/bin/env bash
# DIST4 fence: an installed MeetingPipe.app must not depend on the git clone.
#
# Assembles a staging MeetingPipe.app from a SwiftPM build dir with the same
# shared functions install.sh uses (scripts/lib/resource-bundles.sh,
# scripts/lib/sign-app.sh), signs and verifies it, moves daemon/.build aside so
# SwiftPM's absolute build-tree fallback is gone, and runs the staged
# `MeetingPipe doctor`. Passes only if doctor did not crash and its
# app.resources probe is OK from the staged app's Contents/Resources. The
# failure this exists for: resource bundles in Contents/MacOS, where
# Bundle.module never looks, so the app only worked while daemon/.build existed
# and launchd restart-looped a fatalError once it moved.
#
# --with-pipeline also syncs a staged venv (scripts/lib/pipeline-venv.sh) from a
# copy of pipeline/, moves the copy away, and requires that venv to run mp the
# two ways it is run: `bin/python3 -m mp` (what findMP invokes) and `bin/mp`
# (the ~/.local/bin/mp symlink). It checks the venv directly rather than through
# the staged doctor because the daemon resolves its home from the user record,
# not $HOME, so the staged app always finds the live venv. CI (scripts/ci-local.sh
# daemon) runs without the flag: on the macOS runner the venv sync would pull the
# darwin-only mlx stack, a download the Swift half does not need.
#
# Touches nothing of a live install: no ~/Applications, no LaunchAgent, no
# ~/.local/share, no keychain (signs ad-hoc). The staged doctor reads this Mac's
# config and logs its probe events like any `MeetingPipe doctor` run.
# daemon/.build is moved back on every exit.
#
# Usage: scripts/test-app-relocation.sh [--with-pipeline] [build_dir]
#   build_dir defaults to daemon/.build/release; CI passes daemon/.build/debug.

set -euo pipefail

REPO_ROOT="$(cd "$(dirname "$0")/.." && pwd -P)"
DAEMON_BUILD="$REPO_ROOT/daemon/.build"
WITH_PIPELINE=0
BUILD_DIR=""
for arg in "$@"; do
    case "$arg" in
        --with-pipeline) WITH_PIPELINE=1 ;;
        -h|--help) awk 'NR == 1 { next } /^#/ { sub(/^# ?/, ""); print; next } { exit }' "$0"; exit 0 ;;
        -*) printf 'unknown flag: %s\n' "$arg" >&2; exit 2 ;;
        *) BUILD_DIR="$arg" ;;
    esac
done

say()  { printf '\033[1;34m==>\033[0m %s\n' "$*"; }
fail() { printf '\033[1;31mFAIL\033[0m %s\n' "$*" >&2; exit 1; }

source "$REPO_ROOT/scripts/lib/sign-app.sh"
source "$REPO_ROOT/scripts/lib/resource-bundles.sh"
source "$REPO_ROOT/scripts/lib/pipeline-venv.sh"

BUILD_DIR="${BUILD_DIR:-$DAEMON_BUILD/release}"
[[ -d "$BUILD_DIR" ]] || fail "no build dir at $BUILD_DIR (run swift build first)"
BUILD_DIR="$(cd "$BUILD_DIR" && pwd -P)"
case "$BUILD_DIR/" in
    "$DAEMON_BUILD"/*) ;;
    *) fail "$BUILD_DIR is not under $DAEMON_BUILD, so moving that aside would prove nothing" ;;
esac
[[ -x "$BUILD_DIR/MeetingPipe" ]] || fail "no MeetingPipe binary in $BUILD_DIR (run swift build first)"

STAGE="$(mktemp -d "${TMPDIR:-/tmp}/mp-relocation.XXXXXX")"
STAGE="$(cd "$STAGE" && pwd -P)"
ASIDE="$DAEMON_BUILD.relocation-smoke-$$"
restore() {
    if [[ -d "$ASIDE" ]]; then
        if [[ -e "$DAEMON_BUILD" ]]; then
            printf '\033[1;33m!!\033[0m %s\n' "$DAEMON_BUILD reappeared during the run; the original is left at $ASIDE" >&2
        else
            mv "$ASIDE" "$DAEMON_BUILD"
        fi
    fi
    rm -rf "$STAGE"
}
trap restore EXIT
trap 'exit 130' INT TERM

APP="$STAGE/MeetingPipe.app"
VENV="$STAGE/venv"

say "Assembling a staging app from $BUILD_DIR"
mkdir -p "$APP/Contents/MacOS"
cp "$BUILD_DIR/MeetingPipe" "$APP/Contents/MacOS/MeetingPipe"
install_resource_bundles "$BUILD_DIR" "$APP"
cat >"$APP/Contents/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>CFBundleIdentifier</key>
    <string>com.meetingpipe.daemon</string>
    <key>CFBundleName</key>
    <string>MeetingPipe</string>
    <key>CFBundleExecutable</key>
    <string>MeetingPipe</string>
    <key>CFBundlePackageType</key>
    <string>APPL</string>
    <key>LSUIElement</key>
    <true/>
</dict>
</plist>
PLIST
compgen -G "$APP/Contents/Resources/MeetingPipe_*.bundle" >/dev/null \
    || fail "install_resource_bundles put no bundle in Contents/Resources"
! compgen -G "$APP/Contents/MacOS/*.bundle" >/dev/null \
    || fail "a resource bundle is still in Contents/MacOS"

say "Signing (ad-hoc) and verifying the staged app"
MEETINGPIPE_SIGN_ID=- sign_app_with_resources "$APP"
codesign --verify --deep --strict "$APP" || fail "the staged app's signature does not verify"

if (( WITH_PIPELINE )); then
    say "Syncing a staged venv from a copy of pipeline/, then moving the copy away"
    mkdir -p "$STAGE/clone"
    rsync -a --exclude .venv --exclude __pycache__ --exclude .pytest_cache --exclude .ruff_cache \
        "$REPO_ROOT/pipeline" "$STAGE/clone/"
    sync_pipeline_venv "$STAGE/clone/pipeline" "$VENV" || fail "sync_pipeline_venv failed"
    mv "$STAGE/clone" "$STAGE/clone-moved"
fi

say "Moving $DAEMON_BUILD aside"
mv "$DAEMON_BUILD" "$ASIDE"

say "Running the staged app's doctor"
set +e
OUT="$("$APP/Contents/MacOS/MeetingPipe" doctor 2>&1)"
STATUS=$?
set -e
printf '%s\n' "$OUT"

# doctor exits 0 or 1 by design (1 = some probe failed, which TCC probes do on a
# staged copy and in CI). Anything above is a crash: SwiftPM's Bundle.module
# fatalError traps (133), a missing dylib aborts (134).
(( STATUS <= 1 )) || fail "doctor exited $STATUS: the staged app crashed with daemon/.build gone"
# Matched on the stage dir's unique name, not the full path: Foundation reports
# /var/folders/... where `pwd -P` gave /private/var/folders/...
grep -F "[ OK ] app.resources: Loaded from " <<<"$OUT" \
    | grep -qF "/$(basename "$STAGE")/MeetingPipe.app/Contents/Resources/" \
    || fail "app.resources is not OK from the staged app's Contents/Resources"
if (( WITH_PIPELINE )); then
    say "Running the staged venv with its pipeline source moved away"
    (cd / && "$VENV/bin/python3" -m mp --help >/dev/null) \
        || fail "\`$VENV/bin/python3 -m mp --help\` failed with the source copy moved away"
    (cd / && "$VENV/bin/mp" --version) \
        || fail "\`$VENV/bin/mp --version\` failed with the source copy moved away"
fi

printf '\033[1;32mPASS\033[0m %s\n' "the staged app runs with daemon/.build gone$( (( WITH_PIPELINE )) && printf ', and its venv with the pipeline source moved')."
