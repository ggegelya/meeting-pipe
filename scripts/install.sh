#!/usr/bin/env bash
# meeting-pipe installer.
#
# Idempotent: safe to re-run. Each step checks before acting.
#
# Steps:
#   1. Verify macOS + brew + uv + ffmpeg.
#   2. Build the daemon (swift build -c release).
#   3. Install the pipeline venv at ~/.local/share/meeting-pipe/venv.
#   4. Pre-fetch sherpa-onnx diarization models (~32 MB, public).
#   5. Stage config files at ~/.config/meeting-pipe/.
#   6. Install LaunchAgent for autostart.
#
# Tier-1 transcription stack: mlx-whisper for ASR (Apple Silicon native,
# ~5-10× faster than faster-whisper-CPU) + sherpa-onnx for diarization
# (CoreML-accelerated, no HuggingFace TOS gate). HF_TOKEN is no longer
# required — kept in secrets.env only for users who deliberately opt
# back into a pyannote workflow.

set -euo pipefail

REPO_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
CONFIG_DIR="$HOME/.config/meeting-pipe"
DATA_DIR="$HOME/.local/share/meeting-pipe"
LAUNCHAGENTS="$HOME/Library/LaunchAgents"
LAUNCHD_LABEL="com.meetingpipe.daemon"
LOG_DIR="$HOME/Library/Logs/MeetingPipe"

say()  { printf "\033[1;34m==>\033[0m %s\n" "$*"; }
warn() { printf "\033[1;33m!!\033[0m %s\n" "$*" >&2; }
die()  { printf "\033[1;31mxx\033[0m %s\n" "$*" >&2; exit 1; }

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

# ffmpeg is used by WhisperX (pipeline) to load audio. The daemon itself
# records natively via ScreenCaptureKit + AVAudioEngine — no external tools.
# uv manages the Python venv.
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
    <key>NSAppleEventsUsageDescription</key>
    <string>MeetingPipe inspects the frontmost browser tab to detect web meetings (Google Meet, Teams Web).</string>
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
# Plain adhoc re-sign with `--identifier` set to the bundle id binds
# the Info.plist, seals the resources, and gives TCC a stable identity
# pair across rebuilds. The cdhash still changes per rebuild (we don't
# have a paid Developer ID to stabilise it), but `(bundle_id,
# identifier)` is now consistent, which is enough for macOS to honor
# the user's grant after they toggle the switch.
#
# Two-pass signing: SPM ships the resource bundle as a directory with
# the `.bundle` suffix but no Info.plist — codesign refuses to treat
# it as a valid macOS bundle. We write a minimal Info.plist into it,
# sign it first with its own identifier, then sign the outer .app.
say "Re-signing app bundle with stable identifier"

# Make the SPM resource bundle codesign-compliant (it lacks an Info.plist).
RESOURCE_BUNDLE="$APP/Contents/MacOS/MeetingPipe_MeetingPipe.bundle"
if [[ -d "$RESOURCE_BUNDLE" && ! -f "$RESOURCE_BUNDLE/Info.plist" ]]; then
    cat >"$RESOURCE_BUNDLE/Info.plist" <<'BUNDLE_PLIST'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>CFBundleIdentifier</key>
    <string>com.meetingpipe.daemon.resources</string>
    <key>CFBundleName</key>
    <string>MeetingPipe_MeetingPipe</string>
    <key>CFBundlePackageType</key>
    <string>BNDL</string>
    <key>CFBundleSupportedPlatforms</key>
    <array>
        <string>MacOSX</string>
    </array>
</dict>
</plist>
BUNDLE_PLIST
fi

if [[ -d "$RESOURCE_BUNDLE" ]]; then
    codesign --force --sign - \
        --identifier com.meetingpipe.daemon.resources \
        "$RESOURCE_BUNDLE"
fi

codesign --force --sign - \
    --identifier com.meetingpipe.daemon \
    "$APP"

# Sanity-check the result so a future codesign incompatibility surfaces
# at install time, not at the next reinstall when the user wonders why
# permissions broke again. `Info.plist=bound` and a stable Identifier
# are the two properties we care about for TCC stability.
SIGN_INFO=$(codesign -dvv "$APP" 2>&1)
if ! grep -q "Identifier=com.meetingpipe.daemon$" <<<"$SIGN_INFO"; then
    warn "codesign Identifier mismatch — permissions may not survive reinstall"
fi
if ! grep -q "Info.plist entries=" <<<"$SIGN_INFO"; then
    warn "codesign Info.plist not bound — permissions may not survive reinstall"
fi

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

# 4. Diarization models ----------------------------------------------------
#
# sherpa-onnx pulls two ONNX models on first use (~32 MB combined):
# pyannote-segmentation-3.0 and NeMo TitaNet-small. Both live on
# k2-fsa's GitHub Releases — no auth, no TOS gate. Pre-fetching them
# here means the first real recording doesn't pay the download latency.

say "Pre-fetching sherpa-onnx diarization models (~34 MB total)"
"$DATA_DIR/venv/bin/python" - <<'PY' || warn "Model pre-fetch failed; will retry at first run"
import sys
try:
    from mp.diarize import (
        _ensure_segmentation_model,
        _ensure_embedding_model,
        _ensure_silero_vad,
    )
    seg = _ensure_segmentation_model()
    emb = _ensure_embedding_model()
    vad = _ensure_silero_vad()
    print(f"  ✓ segmentation: {seg.name}")
    print(f"  ✓ embedding:    {emb.name}")
    print(f"  ✓ vad:          {vad.name}")
except Exception as e:
    print(f"  ✗ pre-fetch failed: {e}", file=sys.stderr)
    sys.exit(1)
PY

# ASR models (mlx-whisper) are large (~1.5 GB for whisper-large-v3-turbo).
# We don't pre-fetch them — first recording downloads them, after which
# they live in ~/.cache/huggingface/hub. Pre-fetching adds ~3 minutes to
# install time and most users tolerate the one-time first-recording wait.
say "Note: Whisper model (~1.5 GB) downloads on first recording"

# 5. Config staging --------------------------------------------------------

mkdir -p "$CONFIG_DIR" "$LOG_DIR"
if [[ ! -f "$CONFIG_DIR/config.toml" ]]; then
    cp "$REPO_ROOT/config.example.toml" "$CONFIG_DIR/config.toml"
    say "Staged $CONFIG_DIR/config.toml — edit before first use"
fi
if [[ ! -f "$CONFIG_DIR/secrets.env" ]]; then
    cat >"$CONFIG_DIR/secrets.env" <<'EOF'
# Required secrets for meeting-pipe.
ANTHROPIC_API_KEY=
NOTION_TOKEN=
# Optional. Only needed if you opt back into pyannote diarization.
# The default sherpa-onnx pipeline does not touch Hugging Face.
HF_TOKEN=
EOF
    chmod 600 "$CONFIG_DIR/secrets.env"
    say "Created $CONFIG_DIR/secrets.env (mode 0600). Fill in keys."
fi

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
launchctl load -w "$PLIST"
say "LaunchAgent installed → $PLIST"

cat <<EOF

✓ Install complete.

Next steps:
  1. Edit $CONFIG_DIR/secrets.env with your API keys.
  2. Edit $CONFIG_DIR/config.toml — particularly notion.database_id.
  3. Grant macOS permissions when prompted:
       Microphone (records your voice via the system default input),
       Screen Recording (lets ScreenCaptureKit capture system audio),
       Notifications, Accessibility (browser tab detection).
       (System Settings → Privacy & Security)
  4. Look for the menu bar icon: 〰️  → "MeetingPipe: Idle".

Logs: $LOG_DIR
Uninstall: $REPO_ROOT/scripts/uninstall.sh
  Add --purge to also remove ~/.config/meeting-pipe.
  Add --reset-tcc if a permission was denied and macOS won't re-prompt
  next install (TCC caches state per bundle id). Or pass --all for both.
EOF
