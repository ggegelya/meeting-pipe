#!/usr/bin/env bash
#
# DIST1: assemble a self-contained MeetingPipe.app that runs on a CLEAN Mac
# (no Homebrew, no uv, no system Python 3.11+, no ffmpeg) by embedding a
# relocatable Python + the pipeline wheels + a static ffmpeg under
#   MeetingPipe.app/Contents/Resources/pipeline-runtime/
# The daemon already prefers this location: PipelineLauncher.findMP runs the
# embedded interpreter as `python3 -m mp`, and MeetingRecorder.findFFmpeg falls
# back to the embedded ffmpeg (both DIST1).
#
# This is the BUILD step, run on a dev Mac with a network connection. It does NOT
# notarize and it does NOT test a clean-Mac install: both are OWNER-OWED (they
# need Developer ID credentials and a second Mac). See the runbook at
# docs/spikes/dist1-bundle-runtime.md for the notarize + DMG + verify steps.
#
# Usage:
#   scripts/bundle-runtime.sh [--app <path/to/MeetingPipe.app>]
#
# Defaults to ~/Applications/MeetingPipe.app (what scripts/install.sh builds).
# Override the pinned versions / URLs with the env vars below.
set -euo pipefail

# --- pinned inputs (update deliberately; see the runbook) -------------------
# python-build-standalone: the `install_only` variant is relocatable (no absolute
# rpaths baked in). Find the latest release + its date tag at
# https://github.com/astral-sh/python-build-standalone/releases and update both.
PBS_TAG="${PBS_TAG:-20250612}"
PYTHON_VERSION="${PYTHON_VERSION:-3.11.9}"
PBS_URL="${PBS_URL:-https://github.com/astral-sh/python-build-standalone/releases/download/${PBS_TAG}/cpython-${PYTHON_VERSION}+${PBS_TAG}-aarch64-apple-darwin-install_only.tar.gz}"
# A static arm64 macOS ffmpeg. LICENSING: a redistributed ffmpeg must be an
# LGPL- or GPL-compliant build; pick one you can ship and pin it here.
FFMPEG_URL="${FFMPEG_URL:-}"
# Adhoc by default (runs locally, does NOT notarize). For a real release set
# CODESIGN_IDENTITY to a "Developer ID Application: ..." identity.
CODESIGN_IDENTITY="${CODESIGN_IDENTITY:--}"

# --- args -------------------------------------------------------------------
REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
APP="$HOME/Applications/MeetingPipe.app"
while [[ $# -gt 0 ]]; do
    case "$1" in
        --app) APP="$2"; shift 2 ;;
        *) echo "unknown argument: $1" >&2; exit 2 ;;
    esac
done

step() { printf '\n==> %s\n' "$1"; }
die() { echo "error: $1" >&2; exit 1; }

[[ -d "$APP" ]] || die "no app bundle at $APP (run scripts/install.sh first, or pass --app)"
RUNTIME_DIR="$APP/Contents/Resources/pipeline-runtime"
WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT

# --- 1. relocatable Python --------------------------------------------------
step "Fetching relocatable Python ${PYTHON_VERSION} (${PBS_TAG})"
rm -rf "$RUNTIME_DIR"
mkdir -p "$RUNTIME_DIR"
curl -fL "$PBS_URL" -o "$WORK/python.tar.gz" || die "download failed: $PBS_URL"
# The install_only tarball unpacks to a top-level `python/` dir; flatten it into
# RUNTIME_DIR so the interpreter lands at pipeline-runtime/bin/python3.
tar -xzf "$WORK/python.tar.gz" -C "$WORK"
cp -R "$WORK/python/." "$RUNTIME_DIR/"
[[ -x "$RUNTIME_DIR/bin/python3" ]] || die "embedded python3 missing after extract"

# --- 2. install the pipeline into the embedded interpreter ------------------
step "Installing the pipeline (mp) + deps into the embedded runtime"
# --no-warn-script-location: we invoke `python3 -m mp`, never the bin/mp console
# script, precisely because pip bakes an absolute shebang into console scripts
# and this bundle gets relocated to the user's /Applications (DIST1 / findMP).
"$RUNTIME_DIR/bin/python3" -m pip install --upgrade pip >/dev/null
"$RUNTIME_DIR/bin/python3" -m pip install --no-warn-script-location "$REPO_ROOT/pipeline"
step "Verifying mp runs from the embedded runtime"
"$RUNTIME_DIR/bin/python3" -m mp --version || die "embedded mp does not run"

# --- 3. static ffmpeg -------------------------------------------------------
if [[ -n "$FFMPEG_URL" ]]; then
    step "Fetching static ffmpeg"
    curl -fL "$FFMPEG_URL" -o "$WORK/ffmpeg" || die "ffmpeg download failed"
    install -m 0755 "$WORK/ffmpeg" "$RUNTIME_DIR/bin/ffmpeg"
    "$RUNTIME_DIR/bin/ffmpeg" -version >/dev/null || die "bundled ffmpeg does not run"
else
    echo "WARNING: FFMPEG_URL not set; the bundle has NO ffmpeg."
    echo "         findFFmpeg will fall back to a system ffmpeg, so this is not"
    echo "         self-contained. Set FFMPEG_URL to an LGPL/GPL-compliant static"
    echo "         arm64 build to finish the bundle."
fi

# --- 4. sign every embedded mach-O (inside-out) -----------------------------
# Notarization requires every mach-O inside the .app to carry a valid signature.
# `codesign --deep` is unreliable, so sign the leaves first, then the app last.
step "Signing embedded binaries (identity: ${CODESIGN_IDENTITY})"
find "$RUNTIME_DIR" -type f \( -name '*.dylib' -o -name '*.so' -o -perm -111 \) -print0 \
    | while IFS= read -r -d '' f; do
        if file "$f" | grep -q 'Mach-O'; then
            codesign --force --timestamp --options runtime --sign "$CODESIGN_IDENTITY" "$f" 2>/dev/null || true
        fi
    done
codesign --force --timestamp --options runtime --sign "$CODESIGN_IDENTITY" \
    --identifier com.meetingpipe.daemon "$APP"

step "Bundle assembled: $APP"
du -sh "$RUNTIME_DIR" 2>/dev/null || true
cat <<EOF

OWNER-OWED next steps (need Developer ID + a second Mac; see
docs/spikes/dist1-bundle-runtime.md):
  1. Re-sign with a real Developer ID Application identity
     (set CODESIGN_IDENTITY and re-run, or sign in place).
  2. Notarize:  xcrun notarytool submit <zipped .app> --keychain-profile <p> --wait
  3. Staple:    xcrun stapler staple "$APP"
  4. Package a .dmg and test a drag-install on a CLEAN Mac (no brew/uv/ffmpeg):
     the daemon must run mp entirely from the bundle (check events.jsonl).
EOF
