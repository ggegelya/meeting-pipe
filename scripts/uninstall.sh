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
#                  (Microphone, ScreenCapture, Accessibility, AppleEvents,
#                  plus `tccutil reset All` as a belt-and-suspenders).
#                  Use this when a permission was denied and macOS now
#                  refuses to re-prompt on the next install. Without it,
#                  TCC keeps the old (often denied) state per bundle ID
#                  even after the .app is gone.
#                  Note: macOS Notifications are NOT under TCC and cannot
#                  be reset from the command line; the script prints a
#                  pointer to the System Settings pane instead.
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
# FluidAudio (Parakeet TDT + pyannote) caches its CoreML models under
# Application Support. The path is owned by the FluidAudio SDK, not by
# MeetingPipe; we remove it on uninstall because nothing else on a user
# Mac touches it. Symbol: ~630 MB on disk per Parakeet v3 install.
FLUID_AUDIO_SUPPORT="$HOME/Library/Application Support/FluidAudio"
# Legacy sherpa-onnx ONNX models from pre-FluidAudio installs; kept on
# uninstall by default because they're small and the user may re-install
# soon. Safe to delete manually if you don't need them.
LEGACY_DIAR_CACHE="$HOME/.cache/meeting-pipe"
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
rm -rf "$FLUID_AUDIO_SUPPORT"
rm -rf "$APP_BUNDLE"
echo "Removed venv, logs, app support, FluidAudio model cache, and ~/Applications/MeetingPipe.app."
if [[ -d "$LEGACY_DIAR_CACHE" ]]; then
    echo "Kept $LEGACY_DIAR_CACHE (legacy sherpa-onnx models). rm -rf manually if you also want them gone."
fi

if (( RESET_TCC )); then
    # Order matters here: if the daemon is still running, its in-process
    # TCC verdict cache will be the last thing macOS sees, and a subsequent
    # `tccutil reset` for ScreenCapture may not actually drop the prior
    # "granted/denied" because the live process keeps re-asserting it.
    # SIGKILL first, then reset. The earlier `pkill` above used SIGTERM,
    # which can leave the daemon mid-shutdown.
    BUNDLE_ID="com.meetingpipe.daemon"
    pkill -KILL -f "MeetingPipe.app/Contents/MacOS/MeetingPipe" 2>/dev/null || true

    # tccutil reset takes (service, bundle_id). The services map to the
    # entitlements declared in install.sh's Info.plist plus any TCC
    # category the daemon's runtime touches. Listing each one explicitly
    # before the catch-all so an unfamiliar reader can see exactly which
    # services the daemon talks to; `reset All` after is belt-and-suspenders
    # for anything macOS may have added that we don't track.
    for service in Microphone ScreenCapture Accessibility AppleEvents \
                    SystemPolicyAllFiles; do
        if tccutil reset "$service" "$BUNDLE_ID" 2>/dev/null; then
            echo "  reset TCC: $service for $BUNDLE_ID"
        fi
    done
    tccutil reset All "$BUNDLE_ID" >/dev/null 2>&1 || true

    # The System Settings panel caches rows in memory and keeps showing
    # a stale toggle even after the underlying TCC.db row is gone.
    # Killing the panel forces it to re-read on next open. No-op if
    # Settings isn't running.
    killall "System Settings" 2>/dev/null || true

    echo "Reset TCC permissions for $BUNDLE_ID."

    # Notifications are not in TCC; they live in a separate authorization
    # store managed by usernoted and cannot be scripted reliably. Tell
    # the user instead of failing silently.
    echo
    echo "Note: macOS Notifications are stored outside TCC and cannot be"
    echo "reset from the command line. To clear MeetingPipe's notification"
    echo "decision, open:"
    echo "    System Settings → Notifications → MeetingPipe → Allow Notifications"
    echo
    echo "Next install will re-prompt for Microphone / Screen Recording / Accessibility."
fi

if (( PURGE )); then
    rm -rf "$CONFIG_DIR"
    echo "Removed $CONFIG_DIR (per --purge)."
else
    echo "Kept $CONFIG_DIR. Pass --purge to remove it too, or --reset-tcc to clear permissions."
fi

echo "✓ Uninstalled."
