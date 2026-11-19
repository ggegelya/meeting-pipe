#!/usr/bin/env bash
# Reverse what install.sh did.
#
# Default: removes the app bundle, the LaunchAgents (the daemon's and the digest
# and backup schedules the app adds), venv, logs and the FluidAudio model cache,
# all of which a re-install rebuilds. Keeps your own data:
# ~/Library/Application Support/MeetingPipe (originals/ with any held-back
# recording, which is in no backup; corrections/; auto_consent.json) and
# ~/.config/meeting-pipe (config), so a re-install does not destroy your
# recordings or preferences; API tokens live in the Keychain (SEC8) and also
# survive unless --purge is passed. --reset-tcc deletes none of that either.
#
# Flags:
#   --purge        also remove Application Support/MeetingPipe and
#                  ~/.config/meeting-pipe (config), clear every API token the
#                  app manages from the macOS Keychain, and remove the Hugging
#                  Face models the app downloaded (the local summarizer and the
#                  search embedder, under ~/.cache/huggingface/hub). It lists what it will delete and
#                  asks y/N first; declining aborts before anything is stopped
#                  or removed. Without a terminal it refuses (exit 2) unless
#                  --yes is also given.
#   --yes          answer the --purge confirmation with yes (non-interactive)
#   --reset-tcc    also reset macOS TCC permissions for the bundle ID
#                  (Microphone, ScreenCapture, Accessibility,
#                  plus `tccutil reset All` as a belt-and-suspenders).
#                  Use this when a permission was denied and macOS now
#                  refuses to re-prompt on the next install. Without it,
#                  TCC keeps the old (often denied) state per bundle ID
#                  even after the .app is gone.
#                  Also removes the self-signed "MeetingPipe Dev" signing
#                  identity (SEC17): the grants it was keeping alive are being
#                  reset anyway, so nothing is left for it to preserve, and a
#                  leftover key that can sign as the app is worth removing. A
#                  later install mints a new one and the permissions prompt
#                  again. The default uninstall keeps the identity.
#                  Note: macOS Notifications are NOT under TCC and cannot
#                  be reset from the command line; the script prints a
#                  pointer to the System Settings pane instead.
#   --all          shorthand for --purge --reset-tcc

set -euo pipefail

PURGE=0
RESET_TCC=0
ASSUME_YES=0
for arg in "$@"; do
    case "$arg" in
        --purge)     PURGE=1 ;;
        --reset-tcc) RESET_TCC=1 ;;
        --yes)       ASSUME_YES=1 ;;
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
# Where prefetch_model.py downloads (Hugging Face's default cache).
HF_HUB="$HOME/.cache/huggingface/hub"

# shellcheck source=scripts/lib/uninstall-purge.sh
source "$(cd "$(dirname "$0")" && pwd)/lib/uninstall-purge.sh"
# Read before --purge removes the config it names the local model in.
MODEL_DIRS="$(uninstall_model_dirs "$HF_HUB" "$CONFIG_DIR/config.toml")"
MODEL_LISTING="$(uninstall_model_listing "$HF_HUB" "$CONFIG_DIR/config.toml")"

# DIST8: list and confirm before anything is stopped or removed, so declining
# (or a non-interactive run without --yes) leaves the whole install untouched.
if (( PURGE )); then
    rc=0
    uninstall_confirm_purge "$ASSUME_YES" "$APP_SUPPORT" "$CONFIG_DIR" "$HF_HUB" || rc=$?
    if (( rc != 0 )); then
        echo "Aborted: nothing was stopped or removed."
        exit "$(( rc == 1 ? 1 : 2 ))"
    fi
fi

# DIST5: every agent the app installs, the digest and backup schedules included.
# Booted out by label whether or not its plist is still there (a loaded job outlives
# its file), then the plist removed. Errors are swallowed so a stale plist can still
# be removed.
UID_NUM=$(id -u)
for label in "${UNINSTALL_AGENT_LABELS[@]}"; do
    plist="$LAUNCHAGENTS/${label}.plist"
    launchctl bootout "gui/$UID_NUM/$label" 2>/dev/null \
        || { [[ -f "$plist" ]] && launchctl unload "$plist" 2>/dev/null; } \
        || true
    if [[ -f "$plist" ]]; then
        rm -f "$plist"
        echo "Removed LaunchAgent $label."
    fi
done

# Belt-and-suspenders: if the daemon binary is still resident (LaunchAgent
# already gone but the user launched it manually), kill it before pulling
# the bundle out from under it.
pkill -f "MeetingPipe.app/Contents/MacOS/MeetingPipe" 2>/dev/null || true

# Remove the ~/.local/bin/mp launcher symlink (UX22), but only if it still
# points into our venv, so an unrelated `mp` on the user's PATH is never touched.
LOCAL_BIN_MP="$HOME/.local/bin/mp"
if [[ -L "$LOCAL_BIN_MP" ]]; then
    case "$(readlink "$LOCAL_BIN_MP" 2>/dev/null || true)" in
        "$DATA_DIR"/*) rm -f "$LOCAL_BIN_MP"; echo "Removed mp symlink ($LOCAL_BIN_MP)." ;;
    esac
fi

rm -rf "$DATA_DIR"
rm -rf "$LOG_DIR"
rm -rf "$FLUID_AUDIO_SUPPORT"
rm -rf "$APP_BUNDLE"
echo "Removed venv, logs, FluidAudio model cache, and ~/Applications/MeetingPipe.app."
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
    for service in Microphone ScreenCapture Accessibility \
                    SystemPolicyAllFiles; do
        if tccutil reset "$service" "$BUNDLE_ID" 2>/dev/null; then
            echo "  reset TCC: $service for $BUNDLE_ID"
        fi
    done
    tccutil reset All "$BUNDLE_ID" >/dev/null 2>&1 || true

    # SEC17 (F101): the signing identity goes with the grants. `delete_dev_identity`
    # treats "not found" as fine (an install signed ad-hoc, or with an override
    # identity, never made one).
    # shellcheck source=scripts/lib/dev-cert.sh
    source "$(cd "$(dirname "$0")" && pwd)/lib/dev-cert.sh"
    if delete_dev_identity; then
        echo "  removed the self-signed '$DEV_CERT_CN' signing identity"
    else
        echo "  no '$DEV_CERT_CN' signing identity removed (none found, or the keychain refused: check Keychain Access)"
    fi

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
    # DIST8: the user's own data (originals incl. held-back recordings,
    # corrections corpus, consent list) goes only here, after the confirm above.
    rm -rf "$APP_SUPPORT"
    rm -rf "$CONFIG_DIR"
    # SEC8: API tokens live in the login Keychain, not a file. Clear them too: every
    # account the app manages (DIST5: the list is fenced against the Swift one).
    for key in "${UNINSTALL_KEYCHAIN_ACCOUNTS[@]}"; do
        security delete-generic-password -s com.meetingpipe.daemon -a "$key" >/dev/null 2>&1 || true
    done
    echo "Removed $APP_SUPPORT and $CONFIG_DIR and cleared API tokens from the Keychain (per --purge)."
    if [[ -n "$MODEL_DIRS" ]]; then
        while IFS= read -r dir; do
            [[ -n "$dir" ]] && rm -rf "$dir"
        done <<<"$MODEL_DIRS"
        echo "Removed the downloaded models:"
        printf '%s\n' "$MODEL_LISTING"
    fi
else
    echo "Kept $APP_SUPPORT (originals incl. any held-back recording, corrections, consent), $CONFIG_DIR and Keychain tokens."
    if [[ -n "$MODEL_LISTING" ]]; then
        echo "Kept the models MeetingPipe downloaded (--purge removes them):"
        printf '%s\n' "$MODEL_LISTING"
    fi
    echo "Pass --purge to remove them too (it lists them and asks first), or --reset-tcc to clear permissions."
fi

if (( ! RESET_TCC )); then
    # F184: the signing identity stays on purpose. The next install would mint a new
    # one, and every permission would prompt again.
    echo "Kept the self-signed 'MeetingPipe Dev' signing identity in your login keychain, so a reinstall keeps its permissions."
    echo "To remove it: security delete-identity -c \"MeetingPipe Dev\" (or pass --reset-tcc, which also resets the permissions)."
fi

echo "✓ Uninstalled."
