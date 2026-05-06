#!/usr/bin/env bash
# Reverse what install.sh did.
#
# Default: removes the app bundle, LaunchAgent, venv, logs, and
# Application Support data. Keeps config + secrets so a re-install
# does not destroy your Notion token / model preferences.
#
# Flags:
#   --purge        also remove ~/.config/meeting-pipe (config + secrets)
#   --reset-tcc    also reset macOS TCC permissions for the bundle ID
#                  (Microphone, ScreenCapture, Accessibility, AppleEvents).
#                  Use this when a permission was denied and macOS now
#                  refuses to re-prompt on the next install. Without it,
#                  TCC keeps the old (often denied) state per bundle ID
#                  even after the .app is gone.
#   --all          shorthand for --purge --reset-tcc

set -euo pipefail

PURGE=0
RESET_TCC=0
for arg in "$@"; do
    case "$arg" in
        --purge)     PURGE=1 ;;
        --reset-tcc) RESET_TCC=1 ;;
        --all)       PURGE=1; RESET_TCC=1 ;;
        -h|--help)
            # Print the leading comment block (lines up to the first
            # `set -...`). awk does this without GNU-only `head -n -1`,
            # which BSD head on macOS does not support.
            awk '/^set -/{exit}{print}' "$0"
            exit 0
            ;;
        *)
            printf 'unknown flag: %s\n' "$arg" >&2
            exit 2
            ;;
    esac
done

CONFIG_DIR="$HOME/.config/meeting-pipe"
DATA_DIR="$HOME/.local/share/meeting-pipe"
LAUNCHAGENTS="$HOME/Library/LaunchAgents"
LAUNCHD_LABEL="com.meetingpipe.daemon"
LOG_DIR="$HOME/Library/Logs/MeetingPipe"
APP_SUPPORT="$HOME/Library/Application Support/MeetingPipe"
APP_BUNDLE="$HOME/Applications/MeetingPipe.app"

PLIST="$LAUNCHAGENTS/${LAUNCHD_LABEL}.plist"
if [[ -f "$PLIST" ]]; then
    # Use bootout if the user-domain handle is available; falls back to
    # the legacy unload form. Either way, swallow errors so a stale plist
    # can still be removed.
    UID_NUM=$(id -u)
    launchctl bootout "gui/$UID_NUM" "$PLIST" 2>/dev/null \
        || launchctl unload "$PLIST" 2>/dev/null \
        || true
    rm -f "$PLIST"
    echo "Removed LaunchAgent."
fi

# Belt-and-suspenders: if the daemon binary is still resident (LaunchAgent
# already gone but the user launched it manually), kill it before pulling
# the bundle out from under it.
pkill -f "MeetingPipe.app/Contents/MacOS/MeetingPipe" 2>/dev/null || true

rm -rf "$DATA_DIR"
rm -rf "$LOG_DIR"
rm -rf "$APP_SUPPORT"
rm -rf "$APP_BUNDLE"
echo "Removed venv, logs, app support, and ~/Applications/MeetingPipe.app."

if (( RESET_TCC )); then
    # tccutil reset takes (service, bundle_id). The services map to the
    # entitlements declared in install.sh's Info.plist plus any TCC
    # category the daemon's runtime touches. Listing each one explicitly
    # rather than `tccutil reset All <bundle>` so an unfamiliar reader
    # can see exactly what is being reset.
    BUNDLE_ID="com.meetingpipe.daemon"
    for service in Microphone ScreenCapture Accessibility AppleEvents \
                    SystemPolicyAllFiles; do
        if tccutil reset "$service" "$BUNDLE_ID" 2>/dev/null; then
            echo "  reset TCC: $service for $BUNDLE_ID"
        fi
    done
    echo "Reset TCC permissions for $BUNDLE_ID."
    echo "Next install will re-prompt for Microphone / Screen Recording / Accessibility."
fi

if (( PURGE )); then
    rm -rf "$CONFIG_DIR"
    echo "Removed $CONFIG_DIR (per --purge)."
else
    echo "Kept $CONFIG_DIR. Pass --purge to remove it too, or --reset-tcc to clear permissions."
fi

echo "✓ Uninstalled."
