#!/usr/bin/env bash
# Reverse what install.sh did. Leaves config + secrets in place by default;
# pass --purge to wipe them too.

set -euo pipefail

PURGE=0
[[ "${1:-}" == "--purge" ]] && PURGE=1

CONFIG_DIR="$HOME/.config/meeting-pipe"
DATA_DIR="$HOME/.local/share/meeting-pipe"
LAUNCHAGENTS="$HOME/Library/LaunchAgents"
LAUNCHD_LABEL="com.meetingpipe.daemon"
LOG_DIR="$HOME/Library/Logs/MeetingPipe"
APP_SUPPORT="$HOME/Library/Application Support/MeetingPipe"

PLIST="$LAUNCHAGENTS/${LAUNCHD_LABEL}.plist"
if [[ -f "$PLIST" ]]; then
    launchctl unload "$PLIST" 2>/dev/null || true
    rm -f "$PLIST"
    echo "Removed LaunchAgent."
fi

rm -rf "$DATA_DIR"
rm -rf "$LOG_DIR"
rm -rf "$APP_SUPPORT"
echo "Removed venv, logs, and app support."

if (( PURGE )); then
    rm -rf "$CONFIG_DIR"
    echo "Removed $CONFIG_DIR (per --purge)."
else
    echo "Kept $CONFIG_DIR — pass --purge to remove it too."
fi

echo "✓ Uninstalled."
