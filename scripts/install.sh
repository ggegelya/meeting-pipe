#!/usr/bin/env bash
# meeting-pipe installer.
#
# Idempotent: safe to re-run. Each step checks before acting.
#
# Steps:
#   1. Verify macOS + brew + uv + ffmpeg.
#   2. Build the daemon (swift build -c release).
#   3. Install the pipeline venv at ~/.local/share/meeting-pipe/venv.
#   4. Pre-fetch HF models (pyannote — requires HF token).
#   5. Stage config files at ~/.config/meeting-pipe/.
#   6. Install LaunchAgent for autostart.

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

if ! command -v brew >/dev/null 2>&1; then
    die "Homebrew not found. Install from https://brew.sh first."
fi

for tool in ffmpeg uv; do
    if ! command -v "$tool" >/dev/null 2>&1; then
        say "Installing $tool via brew"
        brew install "$tool"
    fi
done

# BlackHole 2ch is required for system-audio capture. We can't auto-accept its
# kernel-extension prompt, so just remind the user.
if ! brew list --cask blackhole-2ch >/dev/null 2>&1; then
    warn "BlackHole 2ch not installed. Run:  brew install --cask blackhole-2ch"
    warn "After install, open Audio MIDI Setup and create an Aggregate Device"
    warn "combining BlackHole 2ch + your physical mic. Name it 'Aggregate Device'"
    warn "(or whatever you set in config.toml)."
fi

# 2. Daemon build ----------------------------------------------------------

say "Building daemon (release)"
(
    cd "$REPO_ROOT/daemon"
    swift build -c release
)

DAEMON_BIN="$REPO_ROOT/daemon/.build/release/MeetingPipe"
[[ -x "$DAEMON_BIN" ]] || die "Daemon build did not produce $DAEMON_BIN"

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

# 4. HF models -------------------------------------------------------------

if [[ -f "$CONFIG_DIR/secrets.env" ]] && grep -q '^HF_TOKEN=' "$CONFIG_DIR/secrets.env"; then
    say "Pre-fetching pyannote models (one-time, ~1GB)"
    # shellcheck disable=SC1090
    set -a; . "$CONFIG_DIR/secrets.env"; set +a
    "$DATA_DIR/venv/bin/python" - <<'PY' || warn "Model pre-fetch failed; will retry at first run"
import os
from huggingface_hub import snapshot_download
for repo in ("pyannote/speaker-diarization-3.1", "pyannote/segmentation-3.0"):
    try:
        snapshot_download(repo_id=repo, token=os.environ.get("HF_TOKEN"))
        print(f"  ✓ {repo}")
    except Exception as e:
        print(f"  ✗ {repo}: {e}")
        print(f"    Accept the TOS at: https://huggingface.co/{repo}")
PY
else
    warn "No HF_TOKEN found in $CONFIG_DIR/secrets.env — diarization models will"
    warn "download on first run. Accept the TOS at:"
    warn "  https://huggingface.co/pyannote/speaker-diarization-3.1"
    warn "  https://huggingface.co/pyannote/segmentation-3.0"
fi

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
       Microphone, Screen Recording, Accessibility, Notifications.
       (System Settings → Privacy & Security)
  4. Look for the menu bar icon: 〰️  → "MeetingPipe: Idle".

Logs: $LOG_DIR
Uninstall: $REPO_ROOT/scripts/uninstall.sh
EOF
