#!/usr/bin/env bash
# meeting-pipe installer.
#
# Idempotent: safe to re-run. Each step checks before acting.
#
# Steps:
#   1. Verify macOS + brew + uv + ffmpeg.
#   2. Build the daemon (swift build -c release). Fetches FluidAudio
#      Swift package (Parakeet TDT + pyannote on Apple Neural Engine).
#   3. Install the pipeline venv at ~/.local/share/meeting-pipe/venv.
#      Per ADR 0007 the Python pipeline is summarize + publish only;
#      ASR + diarization run in-process via FluidAudio.
#   4. Pre-fetch FluidAudio CoreML models (~630 MB) so the first real
#      recording does not pay download latency.
#   5. Stage config files at ~/.config/meeting-pipe/.
#   6. Install LaunchAgent for autostart.
#   7. (Optional, --reset-tcc) reset macOS TCC grants for
#      com.meetingpipe.daemon. Default is to KEEP them: the bundle is signed
#      with the stable self-signed "MeetingPipe Dev" cert (ensure_dev_cert),
#      whose identity-based requirement does not pin the cdhash, so ALL grants
#      including Screen Recording survive a reinstall (granted once, then
#      stable). Only the ad-hoc fallback (no cert) leaves Screen Recording
#      cdhash-strict and needing a one-time re-toggle. Resetting by default
#      needlessly re-prompted, so keeping grants is the better default for a
#      single-user dev install.
#
# Flags:
#   --reset-tcc  clear all TCC grants for the bundle, forcing a fresh prompt
#                per service. Use for a clean slate or if a grant looks stuck.
#   --keep-tcc   no-op alias (keeping grants is now the default).
#
# Transcription stack: FluidAudio runs Parakeet TDT v3 + pyannote
# Community-1 in-process on the Apple Neural Engine. Models live in
# ~/Library/Application Support/FluidAudio/Models and download lazily on
# first recording (~600 MB Parakeet + ~30 MB diarizer). No Python ASR
# fallback; a FluidAudio failure fails the pipeline job loudly. HF_TOKEN
# is not required; it is kept in secrets.env only for users who
# deliberately opt back into a pyannote-token workflow.

set -euo pipefail

# Default: KEEP existing TCC grants. The bundle is signed with the stable
# self-signed "MeetingPipe Dev" cert (ensure_dev_cert), whose identity-based
# requirement does not pin the cdhash, so every grant including Screen
# Recording survives a reinstall (granted once, then stable). The ad-hoc
# fallback (no cert) is the only case where Screen Recording needs a one-time
# re-toggle. Pass --reset-tcc for a clean slate. --keep-tcc kept as a no-op
# alias for muscle memory.
RESET_TCC=0
for arg in "$@"; do
    case "$arg" in
        --keep-tcc)  RESET_TCC=0 ;;
        --reset-tcc) RESET_TCC=1 ;;
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
CONFIG_DIR="$HOME/.config/meeting-pipe"
DATA_DIR="$HOME/.local/share/meeting-pipe"
LAUNCHAGENTS="$HOME/Library/LaunchAgents"
LAUNCHD_LABEL="com.meetingpipe.daemon"
LOG_DIR="$HOME/Library/Logs/MeetingPipe"

say()  { printf "\033[1;34m==>\033[0m %s\n" "$*"; }
warn() { printf "\033[1;33m!!\033[0m %s\n" "$*" >&2; }
die()  { printf "\033[1;31mxx\033[0m %s\n" "$*" >&2; exit 1; }

# Shared two-pass app-bundle signing (also used by rebuild.sh).
source "$REPO_ROOT/scripts/lib/sign-app.sh"

# 1. Prereqs ---------------------------------------------------------------

[[ "$(uname -s)" == "Darwin" ]] || die "macOS only."

# macOS 14+ required for ScreenCaptureKit's `excludesCurrentProcessAudio`.
SW_VERS=$(sw_vers -productVersion)
SW_MAJOR=${SW_VERS%%.*}
if (( SW_MAJOR < 14 )); then
    die "macOS 14 (Sonoma) or newer required. Detected: $SW_VERS"
fi

if ! command -v brew >/dev/null 2>&1; then
    die "Homebrew not found. Install from https://brew.sh first."
fi

# ffmpeg merges the daemon's mic + system WAVs into the final stereo
# recording (MeetingRecorder.mergeViaFFmpeg). The daemon captures natively
# via ScreenCaptureKit + AVAudioEngine; ffmpeg is only invoked at stop
# time for the merge. uv manages the Python venv.
for tool in ffmpeg uv; do
    if ! command -v "$tool" >/dev/null 2>&1; then
        say "Installing $tool via brew"
        brew install "$tool"
    fi
done

# 2. Daemon build ----------------------------------------------------------

say "Building daemon (release)"
(
    cd "$REPO_ROOT/daemon"
    swift build -c release
)

DAEMON_BIN="$REPO_ROOT/daemon/.build/release/MeetingPipe"
[[ -x "$DAEMON_BIN" ]] || die "Daemon build did not produce $DAEMON_BIN"

# 2b. Wrap in .app bundle --------------------------------------------------
#
# UNUserNotificationCenter — and the modern macOS notification subsystem
# in general — refuses to run from a bare executable. It looks up
# CFBundleIdentifier from the surrounding bundle and throws
# NSInternalInconsistencyException ("bundleProxyForCurrentProcess is nil")
# if there isn't one. We wrap the SPM build product in a minimal .app:
#
#   MeetingPipe.app/
#     Contents/
#       Info.plist
#       MacOS/
#         MeetingPipe                       (the SPM binary)
#         MeetingPipe_MeetingPipe.bundle/   (resources, side-by-side
#                                            so Bundle.module still works)
#
# LSUIElement=true keeps it Dock-less. The NSMicrophoneUsageDescription
# string drives the first-launch permission prompt.

APP_BUILD="$REPO_ROOT/daemon/.build/release/MeetingPipe.app"
say "Assembling $APP_BUILD"
rm -rf "$APP_BUILD"
mkdir -p "$APP_BUILD/Contents/MacOS" "$APP_BUILD/Contents/Resources"

cp "$DAEMON_BIN" "$APP_BUILD/Contents/MacOS/MeetingPipe"
# Side-by-side resource bundle (SwiftPM convention: <Target>_<Target>.bundle).
for bundle in "$REPO_ROOT/daemon/.build/release/"*.bundle; do
    [[ -e "$bundle" ]] && cp -R "$bundle" "$APP_BUILD/Contents/MacOS/"
done

# Generate AppIcon.icns. Failure is non-fatal — Spotlight still indexes
# the .app, just without a custom icon.
ICON_PATH="$APP_BUILD/Contents/Resources/AppIcon.icns"
if "$REPO_ROOT/scripts/gen-icon.swift" "$ICON_PATH" >/dev/null 2>&1; then
    say "Generated $ICON_PATH"
else
    warn "AppIcon generation failed; .app will use generic system icon"
fi

cat >"$APP_BUILD/Contents/Info.plist" <<'PLIST'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>CFBundleIdentifier</key>
    <string>com.meetingpipe.daemon</string>
    <key>CFBundleName</key>
    <string>MeetingPipe</string>
    <key>CFBundleDisplayName</key>
    <string>MeetingPipe</string>
    <key>CFBundleExecutable</key>
    <string>MeetingPipe</string>
    <key>CFBundleIconFile</key>
    <string>AppIcon</string>
    <key>CFBundlePackageType</key>
    <string>APPL</string>
    <key>CFBundleShortVersionString</key>
    <string>0.1.0</string>
    <key>CFBundleVersion</key>
    <string>1</string>
    <key>LSUIElement</key>
    <true/>
    <key>LSMinimumSystemVersion</key>
    <string>13.0</string>
    <key>NSMicrophoneUsageDescription</key>
    <string>MeetingPipe records meeting audio for transcription. Audio never leaves your Mac.</string>
    <key>NSScreenCaptureUsageDescription</key>
    <string>MeetingPipe captures system audio (other participants' voices) directly via Apple's process-tap API on macOS 14.2+. The same TCC entitlement gates audio process taps; no screen pixels are read.</string>
</dict>
</plist>
PLIST

# 2c. Place .app in ~/Applications so Spotlight indexes it ----------------
#
# ~/Applications wins over /Applications here: it doesn't need admin, it
# doesn't conflict with package managers, and Spotlight indexes it the
# same way. mdimport at the end forces the index to refresh immediately
# instead of waiting for the next housekeeping pass.
APPS_DIR="$HOME/Applications"
APP="$APPS_DIR/MeetingPipe.app"
mkdir -p "$APPS_DIR"
say "Installing app bundle → $APP"
rm -rf "$APP"
ditto "$APP_BUILD" "$APP"
mdimport "$APP" >/dev/null 2>&1 || true

# Re-sign the assembled bundle with a stable signing identifier and
# bind the Info.plist into the signature.
#
# swift-build's release output is linker-signed adhoc with
# `Identifier=<SPM-target-name>` (so `Identifier=MeetingPipe`) and
# `Info.plist=not bound`. The bundle id in Info.plist is
# `com.meetingpipe.daemon`. TCC keys grants on `(bundle_id, signing
# identifier, cdhash)` — when the identifier disagrees with the
# bundle id AND the Info.plist isn't sealed, reinstall flows silently
# drop the prior grants (Screen Recording shows "Needed" while the
# System Settings toggle is on; Notifications won't accept
# requestAuthorization because the bundle identity isn't trusted).
#
# `ensure_dev_cert` creates a self-signed "MeetingPipe Dev" code-signing
# cert (see scripts/lib/dev-cert.sh) and `signing_identity` selects it.
# A real cert gives an identity-based designated requirement that does
# NOT pin the cdhash, so the user's Screen Recording grant survives every
# rebuild (granted once, then stable). Without the cert we fall back to
# ad-hoc, where the cdhash changes per build and Screen Recording needs a
# one-time re-toggle; `--identifier` keeps `(bundle_id, identifier)` stable
# either way so Mic / Notifications / Accessibility survive regardless.
#
# Two-pass signing: SPM ships each target's resource bundle as a
# directory with the `.bundle` suffix but no Info.plist, and codesign
# refuses to treat it as a valid macOS bundle. We write a minimal
# Info.plist into each one, sign each with its own identifier, then
# sign the outer .app. Loops because the package now produces one
# bundle per target with resources (MeetingPipe_MeetingPipe.bundle
# for the SVG glyphs + meeting_apps.toml, and
# MeetingPipe_MeetingPipeCore.bundle for the MicGate MuteLabels.toml).
say "Re-signing app bundle with stable identity"
ensure_dev_cert
sign_app_with_resources "$APP"

# Re-point DAEMON_BIN at the installed bundle so the LaunchAgent points
# at the long-lived ~/Applications copy, not the .build/release one
# (which gets blown away on every clean build).
DAEMON_BIN="$APP/Contents/MacOS/MeetingPipe"
[[ -x "$DAEMON_BIN" ]] || die "Bundled daemon missing at $DAEMON_BIN"

# 3. Pipeline venv ---------------------------------------------------------

say "Installing pipeline at $DATA_DIR/venv"
mkdir -p "$DATA_DIR"
(
    cd "$REPO_ROOT/pipeline"
    # Lets us launch `mp` directly via $DATA_DIR/venv/bin/mp.
    uv sync --frozen 2>/dev/null || uv sync
    # uv places the env in .venv next to pyproject; copy a stable launcher.
    rm -rf "$DATA_DIR/venv"
    cp -R "$REPO_ROOT/pipeline/.venv" "$DATA_DIR/venv"
)
[[ -x "$DATA_DIR/venv/bin/mp" ]] || die "mp launcher not at $DATA_DIR/venv/bin/mp"

# 4. Diarization + ASR models ---------------------------------------------
#
# Pre-fetch the FluidAudio CoreML models (Parakeet TDT v3 ~600 MB +
# pyannote diarizer ~30 MB) into ~/Library/Application Support/FluidAudio
# so the user's first recording isn't a multi-minute download wait.
# Idempotent: the SDK skips re-downloading already-cached files.
# Non-fatal: a flaky network here just falls back to the existing
# lazy-load path on first recording. FluidAudio is the only ASR path
# (no Python fallback, per ADR 0007).
say "Pre-fetching FluidAudio models (~630 MB total) → ~/Library/Application Support/FluidAudio"
if "$DAEMON_BIN" prefetch-models; then
    say "FluidAudio models cached."
else
    warn "FluidAudio prefetch failed; the daemon will retry lazily on first recording"
fi

# 5. Config staging --------------------------------------------------------

mkdir -p "$CONFIG_DIR" "$LOG_DIR"
if [[ ! -f "$CONFIG_DIR/config.toml" ]]; then
    cp "$REPO_ROOT/config.example.toml" "$CONFIG_DIR/config.toml"
    say "Staged $CONFIG_DIR/config.toml — edit before first use"
fi
# 5b. API tokens -> macOS Keychain (SEC8) ---------------------------------
#
# Tokens live in the login Keychain, not a plaintext file. install.sh, the
# daemon, and the Python pipeline all read/write the same generic-password
# items through /usr/bin/security, so a single stable accessor means no
# per-access Keychain prompt. Migrate a legacy secrets.env if one exists,
# then prompt for any required token still missing.
KEYCHAIN_SERVICE="com.meetingpipe.daemon"
kc_get() { security find-generic-password -s "$KEYCHAIN_SERVICE" -a "$1" -w 2>/dev/null; }
kc_set() { security add-generic-password -U -s "$KEYCHAIN_SERVICE" -a "$1" -w "$2" >/dev/null 2>&1; }

LEGACY_SECRETS="$CONFIG_DIR/secrets.env"
if [[ -f "$LEGACY_SECRETS" ]]; then
    say "Migrating $LEGACY_SECRETS into the Keychain"
    while IFS='=' read -r raw_key raw_val; do
        key="${raw_key//[[:space:]]/}"
        [[ -z "$key" || "$key" == \#* ]] && continue
        val="${raw_val#\"}"; val="${val%\"}"
        case "$key" in
            ANTHROPIC_API_KEY|NOTION_TOKEN|HF_TOKEN)
                if [[ -n "$val" && -z "$(kc_get "$key")" ]]; then
                    kc_set "$key" "$val" && say "  migrated $key"
                fi
                ;;
        esac
    done < "$LEGACY_SECRETS"
    rm -f "$LEGACY_SECRETS"
    say "Removed $LEGACY_SECRETS (tokens now in the Keychain)."
fi

for key in ANTHROPIC_API_KEY NOTION_TOKEN; do
    if [[ -n "$(kc_get "$key")" ]]; then
        say "$key already in the Keychain."
    elif [[ -t 0 ]]; then
        printf '   Enter %s (blank to skip, set later in Preferences): ' "$key"
        read -rs val || val=""
        echo
        if [[ -n "$val" ]]; then
            kc_set "$key" "$val" && say "Stored $key in the Keychain."
        else
            warn "$key left unset; add it in Preferences -> Integrations or re-run install.sh."
        fi
    else
        warn "$key not set and no TTY to prompt; set it in Preferences -> Integrations."
    fi
done

# 6. LaunchAgent -----------------------------------------------------------

mkdir -p "$LAUNCHAGENTS"
PLIST="$LAUNCHAGENTS/${LAUNCHD_LABEL}.plist"

# Substitute template. We don't bundle a .app — point the agent at the SPM binary.
sed \
    -e "s|{{HOME}}|$HOME|g" \
    -e "s|{{INSTALL_PREFIX}}/MeetingPipe.app/Contents/MacOS/MeetingPipe|$DAEMON_BIN|g" \
    "$REPO_ROOT/scripts/launchd.plist.template" >"$PLIST"

# Reload if already running.
if launchctl list | grep -q "$LAUNCHD_LABEL"; then
    launchctl unload "$PLIST" || true
fi

# 7. TCC reset (opt-in, --reset-tcc) ---------------------------------------
#
# Skipped by default (the stable `--identifier` lets Mic / Accessibility /
# Notifications survive a reinstall; only Screen Recording's cdhash-keyed
# grant may need one manual re-toggle). When --reset-tcc is passed, run it
# BEFORE the LaunchAgent loads the new bundle: if the daemon is already
# running with the previous cdhash, its live TCC verdict cache can re-assert
# the prior grant against the freshly-reset DB, so SIGKILL first. A reset
# forces one fresh prompt per service, useful when a grant looks stuck (a
# stale ON toggle that macOS silently denies because the cdhash changed).
if (( RESET_TCC )); then
    BUNDLE_ID="com.meetingpipe.daemon"
    pkill -KILL -f "MeetingPipe.app/Contents/MacOS/MeetingPipe" 2>/dev/null || true

    # tccutil reset takes (service, bundle_id). Listing the services the
    # daemon uses plus the catch-all `All` for anything macOS may have
    # added that we don't track here. (AppleEvents dropped in TECH-SEC9:
    # browser detection uses Accessibility, not Apple Events.)
    for service in Microphone ScreenCapture Accessibility \
                    SystemPolicyAllFiles; do
        if tccutil reset "$service" "$BUNDLE_ID" 2>/dev/null; then
            say "reset TCC: $service for $BUNDLE_ID"
        fi
    done
    tccutil reset All "$BUNDLE_ID" >/dev/null 2>&1 || true

    # The System Settings panel caches rows in memory and keeps showing
    # a stale toggle even after the underlying TCC.db row is gone.
    # Killing the panel forces it to re-read on next open. No-op if
    # Settings isn't running.
    killall "System Settings" 2>/dev/null || true

    say "TCC permissions reset. Next launch re-prompts for Mic / Screen Recording / Accessibility."
fi

launchctl load -w "$PLIST"
say "LaunchAgent installed → $PLIST"

cat <<EOF

✓ Install complete.

Next steps:
  1. API keys are stored in your macOS Keychain (you were prompted above).
     Change them any time in Preferences -> Integrations, or re-run this script.
  2. Edit $CONFIG_DIR/config.toml — particularly notion.database_id.
  3. Grant macOS permissions when prompted:
       Microphone (records your voice via the system default input),
       Screen Recording (lets ScreenCaptureKit capture system audio),
       Notifications, Accessibility (browser tab detection).
       (System Settings → Privacy & Security)
  4. Look for the menu bar icon: 〰️  → "MeetingPipe: Idle".

Logs: $LOG_DIR
Reinstall: $REPO_ROOT/scripts/install.sh
  Keeps your TCC grants by default. The self-signed "MeetingPipe Dev" cert
  gives a stable identity, so all grants including Screen Recording survive a
  rebuild (granted once, then stable). Pass --reset-tcc for a clean slate.
Uninstall: $REPO_ROOT/scripts/uninstall.sh
  Add --purge to also remove ~/.config/meeting-pipe.
  Add --reset-tcc to clear TCC for the bundle. Or pass --all for both.
EOF
