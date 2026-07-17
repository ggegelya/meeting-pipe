#!/usr/bin/env bash
#
# Diagnostic for AUTO1: can native App Intents be made Shortcuts-discoverable off the
# plain SwiftPM build, without migrating the daemon to an Xcode project?
#
# The a-priori blocker (docs/spikes/auto1-app-intents-metadata.md, and the AUTO1 spec)
# is that a plain `swift build` never runs appintentsmetadataprocessor, the phase
# Shortcuts needs to discover App Intents, so shipping intents on the SwiftPM bundle
# alone would be undiscoverable dead code. This probe measures the escape hatch: a
# supplementary `swift-frontend` const-values pass over the App Intents sources, fed to
# appintentsmetadataprocessor, produced and run by hand (exactly what install.sh would
# do after `swift build`). If that emits a valid Metadata.appintents bundle that names
# the intent + its Shortcuts phrase, the install.sh mechanism is viable and only the
# final "does Shortcuts.app actually surface the action" eyeball is owner-owed.
#
# It is a SELF-CONTAINED mechanism check, not a live-call probe: it writes a minimal
# App Intent into a mktemp dir, runs the two tools, asserts on the emitted bundle, and
# cleans up. Nothing in the repo or the installed app is touched. It reproduces cleanly
# on Xcode 17F42 / macOS 26 SDK (25F70); re-run it after any Xcode bump, because the
# swift-frontend const-extraction flags and the processor arg surface are private and
# could shift, which is precisely the fragility this spike flags.
#
# Run it on the owner's Mac (full Xcode required, not just Command Line Tools):
#
#     bash daemon/scripts/auto1-app-intents-probe.sh
#
# Read the SUMMARY line:
#   - MECHANISM GO  -> the const-values + processor path works on this toolchain; the
#                      install.sh step is buildable. Do the ONE remaining owner step:
#                      the Shortcuts-discovery eyeball on the installed app (below), then
#                      promote AUTO1's App Intents leg to a real build.
#   - MECHANISM NO-GO -> the standalone extraction broke on this toolchain (a private
#                      flag or the processor moved). The durable answer is then an Xcode
#                      project or an Apple-provided SwiftPM plugin; converge with DIST1's
#                      build-system decision rather than hand-rolling install.sh.
#
# The eyeball the probe CANNOT do (needs an interactive Mac with the app installed):
# build the daemon with the App Intents leg lit, open Shortcuts.app, and confirm a
# "Toggle Meeting Recording" action appears and toggles a recording end-to-end. That is
# the last mile; this probe only proves the metadata bundle that feeds it can be built.

set -uo pipefail

fail_notool() {
  echo "SUMMARY: SKIPPED -- $1"
  echo "  This probe needs full Xcode (swift-frontend + appintentsmetadataprocessor)."
  echo "  If Xcode is installed: sudo xcode-select -s /Applications/Xcode.app, then re-run."
  exit 2
}

command -v xcrun >/dev/null 2>&1 || fail_notool "xcrun not found"
PROC="$(xcrun --find appintentsmetadataprocessor 2>/dev/null)" || true
[ -n "${PROC:-}" ] && [ -x "$PROC" ] || fail_notool "appintentsmetadataprocessor not found (Command Line Tools only?)"
FRONTEND="$(xcrun -f swift-frontend 2>/dev/null)" || true
[ -n "${FRONTEND:-}" ] && [ -x "$FRONTEND" ] || fail_notool "swift-frontend not found"

SDK="$(xcrun --show-sdk-path 2>/dev/null)"
[ -d "$SDK" ] || fail_notool "no macOS SDK path"
# Toolchain dir is .../XcodeDefault.xctoolchain (strip usr/bin/swift-frontend).
TOOLCHAIN="$(dirname "$(dirname "$(dirname "$FRONTEND")")")"
ARCH="$(uname -m)"                              # arm64 or x86_64
TRIPLE="${ARCH}-apple-macosx14.0"               # 14.0 = the repo's macOS floor
XCV="$(xcodebuild -version 2>/dev/null | awk '/Build version/{print $3}')"
[ -n "$XCV" ] || XCV="$(xcrun --show-sdk-build-version 2>/dev/null)"

echo "AUTO1 App Intents metadata-processor probe"
echo "  toolchain : $TOOLCHAIN"
echo "  processor : $PROC"
echo "  sdk       : $SDK"
echo "  triple    : $TRIPLE   xcode-build: ${XCV:-unknown}"
echo

WORK="$(mktemp -d "${TMPDIR:-/tmp}/auto1-appintents.XXXXXX")"
trap 'rm -rf "$WORK"' EXIT
cd "$WORK"

# A minimal App Intent + AppShortcutsProvider, the shape AUTO1's GO build would ship
# (one intent here stands in for the six meetingpipe:// verbs). No app runtime is linked;
# the probe only exercises the compile-time metadata extraction.
cat > Intents.swift <<'SWIFT'
import AppIntents

@available(macOS 13.0, *)
struct ToggleRecordingIntent: AppIntent {
    static var title: LocalizedStringResource = "Toggle Meeting Recording"
    static var description = IntentDescription("Start or stop a MeetingPipe recording.")
    static var openAppWhenRun: Bool = false
    func perform() async throws -> some IntentResult { .result() }
}

@available(macOS 13.0, *)
struct MeetingPipeShortcuts: AppShortcutsProvider {
    static var appShortcuts: [AppShortcut] {
        AppShortcut(
            intent: ToggleRecordingIntent(),
            phrases: ["Toggle recording in \(.applicationName)"],
            shortTitle: "Toggle Recording",
            systemImageName: "record.circle"
        )
    }
}
SWIFT

# The protocols the const-extractor gathers. Bare names (NOT module-qualified) is what
# the Swift frontend matches; module-qualified names silently gather nothing (an empty
# [] const-values file), which is the trap that makes this look impossible at first.
echo '["AppIntent","AppShortcutsProvider"]' > protocols.json

echo "== 1. swift-frontend const-values pass (what install.sh would add after swift build) =="
# Single primary file; -parse-as-library so a top-level-code-free file still compiles.
# -const-gather-protocols-file MUST go straight to the frontend (via -Xfrontend from the
# driver it reaches the wrong stage and yields []). The source path MUST be absolute:
# the processor matches each const-value's `file` field against --source-file-list, so a
# relative primary-file makes it fail with "Unable to find matching source file". Xcode
# always passes absolute source paths; the probe does the same.
SRC="$WORK/Intents.swift"
"$FRONTEND" -c -primary-file "$SRC" \
  -target "$TRIPLE" -sdk "$SDK" -module-name MeetingPipe -parse-as-library \
  -emit-const-values-path "$WORK/Intents.swiftconstvalues" \
  -const-gather-protocols-file protocols.json \
  -o "$WORK/Intents.o"
rc=$?
if [ $rc -ne 0 ] || [ ! -s Intents.swiftconstvalues ]; then
  echo "SUMMARY: MECHANISM NO-GO -- const-values pass failed or emitted nothing (rc=$rc)."
  echo "  The private -emit-const-values / -const-gather-protocols-file surface likely moved."
  echo "  Durable path: an Xcode project or a SwiftPM plugin; converge with DIST1."
  exit 1
fi
ENTRIES="$(python3 -c 'import json,sys;print(len(json.load(open("Intents.swiftconstvalues"))))' 2>/dev/null || echo 0)"
echo "   const-values entries gathered: $ENTRIES"
if [ "$ENTRIES" -lt 1 ]; then
  echo "SUMMARY: MECHANISM NO-GO -- 0 conformances gathered (protocol-name format changed?)."
  exit 1
fi

echo "== 2. appintentsmetadataprocessor -> Metadata.appintents =="
echo "$SRC"                           > sources.txt
echo "$WORK/Intents.swiftconstvalues" > constvals.txt
mkdir -p Payload.app/Contents
"$PROC" \
  --output Payload.app/Contents \
  --toolchain-dir "$TOOLCHAIN" \
  --module-name MeetingPipe \
  --sdk-root "$SDK" \
  --xcode-version "${XCV:-17A000}" \
  --platform-family macOS \
  --deployment-target 14.0 \
  --target-triple "$TRIPLE" \
  --source-file-list sources.txt \
  --swift-const-vals-list constvals.txt \
  --force 2>&1 | sed 's/^/   /'

BUNDLE="Payload.app/Contents/Metadata.appintents"
DATA="$BUNDLE/extract.actionsdata"
echo
echo "== 3. assert the bundle emitted and names the intent + its Shortcuts phrase =="
ok=1
[ -f "$DATA" ] && echo "   [ok] $DATA present" || { echo "   [MISS] no extract.actionsdata"; ok=0; }
if [ -f "$DATA" ]; then
  grep -q "ToggleRecordingIntent"  "$DATA" && echo "   [ok] intent named"            || { echo "   [MISS] intent not named"; ok=0; }
  grep -q "Toggle recording in"    "$DATA" && echo "   [ok] App Shortcut phrase kept" || { echo "   [MISS] phrase not extracted"; ok=0; }
fi

echo
if [ "$ok" -eq 1 ]; then
  echo "SUMMARY: MECHANISM GO -- Metadata.appintents built off a SwiftPM-style compile on this toolchain."
  echo "  install.sh CAN light native App Intents (const-values pass + processor, post swift build)."
  echo "  Remaining owner step (not scriptable): build the daemon with the App Intents leg,"
  echo "  open Shortcuts.app, confirm the 'Toggle Meeting Recording' action appears and toggles"
  echo "  a recording end-to-end. Then promote AUTO1's App Intents leg to a real build."
else
  echo "SUMMARY: MECHANISM NO-GO -- the processor ran but the bundle did not name the intent."
  echo "  The actionsdata schema or extraction moved; prefer an Xcode project / SwiftPM plugin (DIST1)."
fi
