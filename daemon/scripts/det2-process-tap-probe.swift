#!/usr/bin/env swift
//
// Diagnostic for DET2: which mechanism (if any) makes per-process mic attribution
// resolve on this Mac?
//
// `ProcessAudioSignal` is dead in production because the PID-to-HAL translation
// (`kAudioHardwarePropertyTranslatePIDToProcessObject`) returns object 0 and
// `kAudioProcessPropertyIsRunningInput` never reads (0 successful reads in 19.8
// days). The revival hinges on ONE empirical question that can only be answered on
// real hardware during a live call: does the read resolve with (A) the Screen
// Recording grant alone, (B) a bare CoreAudio process tap held live, or only with
// (C) a full private aggregate device around the tap, or none of the above? The
// answer decides whether DET2 is a trivial zero-setup flip, a small held-tap
// wrapper, a heavy aggregate subsystem, or a close. See
// docs/spikes/det2-process-tap-attribution.md for the decision tree.
//
// ANSWERED 2026-07-20: none of A / B / C. The owner ran this on a real Mac against
// a live Teams call with the grant line reading `granted`, and all three mechanisms
// returned object 0 (OSStatus noErr) with tap and aggregate construction both
// succeeding. DET2 is closed NO-GO and `usesProcessAudio` stays false everywhere.
// This script is kept only to re-measure if a future macOS changes process-object
// authorization; it is no longer a pending question. Re-running is cheap, but read
// the grant line first (see below) or the verdict is void.
//
// It reads only (its tap + aggregate are private, muted, and torn down
// immediately); it is not part of the app. Run it on the owner's Mac DURING a
// live meeting where the client is holding the mic:
//
//     swift daemon/scripts/det2-process-tap-probe.swift
//     swift daemon/scripts/det2-process-tap-probe.swift --pid 1234
//
// It needs the same Screen Recording TCC grant the daemon uses (System Settings
// -> Privacy & Security -> Screen & System Audio Recording -> enable Terminal /
// your IDE). Requires macOS 14.2+ (the repo floor).
//
// CHECK THE `screen-recording grant:` LINE THIS PRINTS BEFORE TRUSTING A VERDICT.
// Granting the grant to MeetingPipe.app does nothing for this script: the process
// that actually executes is `swift-frontend`, which holds no grant of its own and
// relies on TCC responsible-process inheritance from the terminal that launched it.
// An ordinary granted terminal inherits fine. A TCC-*disclaimed* parent does not:
// agent harnesses spawn their shell through a `disclaimer` helper that deliberately
// severs that inheritance, so running this through one reports NOT granted and
// silently measures nothing. That produced one void "close the leg" run before the
// real one. If the line says NOT granted, the SUMMARY below is meaningless.
//
import AppKit
import CoreAudio
import Foundation

// MARK: - HAL reads (mirrors ProcessAudioSignal's resolver + probe)

/// Translate a PID to its HAL process AudioObject. Returns nil (object 0) when the
/// HAL has no process object for this PID, the exact production failure.
func translatePIDToProcessObject(_ pid: pid_t) -> (object: AudioObjectID?, status: OSStatus) {
    var pidVar = pid
    var addr = AudioObjectPropertyAddress(
        mSelector: kAudioHardwarePropertyTranslatePIDToProcessObject,
        mScope: kAudioObjectPropertyScopeGlobal,
        mElement: kAudioObjectPropertyElementMain
    )
    var object = AudioObjectID(0)
    var size = UInt32(MemoryLayout<AudioObjectID>.size)
    let status = AudioObjectGetPropertyData(
        AudioObjectID(kAudioObjectSystemObject),
        &addr,
        UInt32(MemoryLayout<pid_t>.size),
        &pidVar,
        &size,
        &object
    )
    return ((status == noErr && object != 0) ? object : nil, status)
}

/// Read `kAudioProcessPropertyIsRunningInput` on a resolved process object.
func readIsRunningInput(_ object: AudioObjectID) -> (value: Bool?, status: OSStatus) {
    var addr = AudioObjectPropertyAddress(
        mSelector: kAudioProcessPropertyIsRunningInput,
        mScope: kAudioObjectPropertyScopeGlobal,
        mElement: kAudioObjectPropertyElementMain
    )
    var running: UInt32 = 0
    var size = UInt32(MemoryLayout<UInt32>.size)
    let status = AudioObjectGetPropertyData(object, &addr, 0, nil, &size, &running)
    return (status == noErr ? (running != 0) : nil, status)
}

/// One resolution attempt: translate the PID, then read isRunningInput. Prints the
/// outcome and returns whether the read resolved (the thing DET2 needs).
@discardableResult
func attemptResolution(_ label: String, pid: pid_t) -> Bool {
    let (object, translateStatus) = translatePIDToProcessObject(pid)
    guard let object = object else {
        print("  [\(label)] translate PID \(pid) -> process object FAILED (OSStatus \(translateStatus), object 0)")
        return false
    }
    let (value, readStatus) = readIsRunningInput(object)
    guard let value = value else {
        print("  [\(label)] translate OK (object \(object)) but isRunningInput read FAILED (OSStatus \(readStatus))")
        return false
    }
    print("  [\(label)] RESOLVED: object \(object), isRunningInput = \(value)")
    return true
}

// MARK: - Tap read (kAudioTapPropertyUID) for the aggregate step

func tapUID(_ tapID: AudioObjectID) -> String? {
    var addr = AudioObjectPropertyAddress(
        mSelector: kAudioTapPropertyUID,
        mScope: kAudioObjectPropertyScopeGlobal,
        mElement: kAudioObjectPropertyElementMain
    )
    var uid: Unmanaged<CFString>?
    var size = UInt32(MemoryLayout<Unmanaged<CFString>?>.size)
    let status = AudioObjectGetPropertyData(tapID, &addr, 0, nil, &size, &uid)
    guard status == noErr, let uid = uid else { return nil }
    return uid.takeRetainedValue() as String
}

// MARK: - Target PID selection

let knownMeetingBundles: Set<String> = [
    "com.microsoft.teams2", "com.microsoft.teams", "us.zoom.xos",
    "com.cisco.webexmeetingsapp", "com.cisco.spark", "com.tinyspeck.slackmacgap",
    "com.apple.FaceTime", "com.hnc.Discord",
    "com.google.Chrome", "com.apple.Safari", "org.mozilla.firefox",
    "com.microsoft.edgemac", "company.thebrowser.Browser",
]

func targetPID() -> (pid: pid_t, name: String)? {
    if let i = CommandLine.arguments.firstIndex(of: "--pid"),
       i + 1 < CommandLine.arguments.count,
       let pid = Int32(CommandLine.arguments[i + 1]) {
        let name = NSRunningApplication(processIdentifier: pid)?.localizedName ?? "pid \(pid)"
        return (pid, name)
    }
    let running = NSWorkspace.shared.runningApplications
    if let frontmost = running.first(where: { $0.isActive }),
       let bundle = frontmost.bundleIdentifier, knownMeetingBundles.contains(bundle) {
        return (frontmost.processIdentifier, frontmost.localizedName ?? bundle)
    }
    if let match = running.first(where: { knownMeetingBundles.contains($0.bundleIdentifier ?? "") }) {
        return (match.processIdentifier, match.localizedName ?? (match.bundleIdentifier ?? "?"))
    }
    if let frontmost = running.first(where: { $0.isActive }) {
        return (frontmost.processIdentifier, "\(frontmost.localizedName ?? "frontmost") (not a known meeting app)")
    }
    return nil
}

// MARK: - Run

guard #available(macOS 14.2, *) else {
    print("DET2 probe needs macOS 14.2+ (AudioHardwareCreateProcessTap).")
    exit(1)
}

guard let (pid, name) = targetPID() else {
    print("Could not pick a target app. Pass one with --pid <n> during a live call.")
    exit(1)
}

print("DET2 process-tap attribution probe")
print("  target:    \(name) (PID \(pid))")
print("  screen-recording grant: \(CGPreflightScreenCaptureAccess() ? "granted" : "NOT granted (enable it and re-run)")")
print("")

// Mechanism A: baseline, no tap, current grant only (the zero-setup ideal).
print("A. Baseline (grant only, no tap):")
let resolvedA = attemptResolution("A", pid: pid)
print("")

// Mechanism B: a bare global private muted process tap held live (still no user setup).
print("B. Bare process tap held live (no aggregate device):")
let descB = CATapDescription(monoGlobalTapButExcludeProcesses: [])
descB.name = "MeetingPipe DET2 probe"
descB.muteBehavior = .mutedWhenTapped
descB.isPrivate = true
var tapB = AudioObjectID(0)
let createB = AudioHardwareCreateProcessTap(descB, &tapB)
var resolvedB = false
var tapUIDForC: String?
if createB == noErr, tapB != 0 {
    tapUIDForC = tapUID(tapB)
    resolvedB = attemptResolution("B", pid: pid)
    AudioHardwareDestroyProcessTap(tapB)
} else {
    print("  AudioHardwareCreateProcessTap FAILED (OSStatus \(createB))")
}
print("")

// Mechanism C: a full private aggregate device around the tap (the heavy path).
print("C. Private aggregate device around the tap:")
var resolvedC = false
let descC = CATapDescription(monoGlobalTapButExcludeProcesses: [])
descC.name = "MeetingPipe DET2 probe (aggregate)"
descC.muteBehavior = .mutedWhenTapped
descC.isPrivate = true
var tapC = AudioObjectID(0)
let createC = AudioHardwareCreateProcessTap(descC, &tapC)
if createC == noErr, tapC != 0, let uid = tapUID(tapC) {
    let subTap: [String: Any] = [kAudioSubTapUIDKey: uid]
    let aggDesc: [String: Any] = [
        kAudioAggregateDeviceNameKey: "MeetingPipe DET2 probe aggregate",
        kAudioAggregateDeviceUIDKey: "com.meetingpipe.det2.probe.aggregate",
        kAudioAggregateDeviceIsPrivateKey: 1,
        kAudioAggregateDeviceTapListKey: [subTap],
    ]
    var aggID = AudioObjectID(0)
    let createAgg = AudioHardwareCreateAggregateDevice(aggDesc as CFDictionary, &aggID)
    if createAgg == noErr, aggID != 0 {
        resolvedC = attemptResolution("C", pid: pid)
        AudioHardwareDestroyAggregateDevice(aggID)
    } else {
        print("  AudioHardwareCreateAggregateDevice FAILED (OSStatus \(createAgg))")
    }
    AudioHardwareDestroyProcessTap(tapC)
} else {
    print("  tap create / UID read FAILED (OSStatus \(createC); uid \(tapUIDForC ?? "nil"))")
}
print("")

// MARK: - READ

print("SUMMARY: A(grant only)=\(resolvedA ? "RESOLVED" : "no")  B(bare tap)=\(resolvedB ? "RESOLVED" : "no")  C(aggregate)=\(resolvedC ? "RESOLVED" : "no")")
print("")
if resolvedA {
    print("READ: the Screen Recording grant alone revives the read. GO, and the cleanest")
    print("      possible one: ProcessAudioSignal works with NO tap at all. Flip")
    print("      usesProcessAudio true (with the corroboration safety rail on the end leg)")
    print("      and the scanner's defaultProbe resolves for free. Zero setup, zero new TCC.")
} else if resolvedB {
    print("READ: a bare held tap object revives the read (no aggregate needed). GO with a")
    print("      small ProcessAudioTap wrapper that holds a private muted tap during a")
    print("      native recording, still invisible to the user (no device selection).")
} else if resolvedC {
    print("READ: only the full private aggregate device revives the read. This is the heavy")
    print("      path; weigh it hard: DET2 needs a boolean, not audio capture, so a whole")
    print("      capture aggregate for an is-on-the-mic flag is a large blind build. Likely")
    print("      DEFER unless start-side coverage proves worth it.")
} else {
    print("READ: no mechanism revived the read on this Mac. Confirm ProcessAudioSignal stays")
    print("      dead and close the process-audio leg (DET1's frontmost attribution stands);")
    print("      revisit only if a future macOS changes the process-object authorization.")
}
