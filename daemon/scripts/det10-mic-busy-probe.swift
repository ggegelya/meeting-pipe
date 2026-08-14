#!/usr/bin/env swift
//
// DET10 probe: does the mic-busy detection input exist on this Mac at all?
//
// Read-only. It resolves audio devices and reads properties off them. It opens no capture
// session, records nothing, writes no file, touches no meeting library / config / sidecar, and
// changes no production code, so it is safe to run during a real meeting.
//
// WHY THIS EXISTS. `AVCaptureDevice.isInUseByAnotherApplication` is the only producer of a
// mic-busy sample in the daemon (`MeetingDiscoveryWatcher.sampleMicBusy`), and across the full
// event-log history (2026-05-18 to 2026-08-03) it has produced **zero** `mic_busy_started` rows,
// against 257 `candidate_dropped` rows emitted from the same file on the same commit day. So the
// zero is structural, not a routing artifact: DET1's catch-all tier has never fired and DET3's
// miss auditor has been auditing nothing. Two causes fit that evidence equally well:
//
//   1. `AVCaptureDevice.default(for: .audio)` returns nil at daemon launch, so the observer is
//      never wired. That resolve happens once and is never retried, so one nil disables DET1 and
//      DET3 for the whole process lifetime.
//   2. `isInUseByAnotherApplication` is structurally false for shared macOS audio inputs, in which
//      case the signal choice itself is wrong and needs replacing rather than fixing.
//
// THE PROBE CONTAINS NO FIX, ON PURPOSE, and its verdict table below was written before any
// measurement. DET2 reached a NO-GO by reasoning from a plausible mechanism, and DET8 later
// refuted it by asking a different question; writing the fix for cause 2 without measuring is how
// that repeats. Read `docs/backlog/tasks/DET10.md` before running this, and paste the whole output
// back into it afterwards.
//
// USAGE. One command, run during a real call:
//
//     swift daemon/scripts/det10-mic-busy-probe.swift --watch 240
//
// Start it, then join any call that holds the microphone (Teams, FaceTime, a browser call, all
// fine), stay a minute or so, and leave. It prints a line whenever anything changes and a verdict
// at the end.
//
// REQUIRES Microphone permission for whatever runs it: System Settings -> Privacy & Security ->
// Microphone -> enable Terminal (or your IDE), then re-run. If it is not granted this probe
// REFUSES to watch and REFUSES to print a verdict, rather than reporting a permanently-false flag
// as a real NO-GO: an unauthorized process is exactly the false zero this measurement cannot tell
// from a genuine one (the CAL1 lesson). A script launched from an agent, an IDE task runner, or
// any other disclaimed parent inherits the parent's TCC identity and reports NOT GRANTED even
// when Terminal is ticked, so **open Terminal yourself and paste the command there**.
//
// If Terminal has never asked for the microphone, it will not be listed in that System Settings
// pane at all, and there is nothing to tick. Run it once with `--request-access` to raise the
// one-time system prompt (the only thing this probe does that is not read-only), approve it, then
// run it normally.
//
// PRIVACY. Nothing is written to disk and no meeting content is read. The output names running
// applications and audio device names, so skim it before pasting it anywhere you would not paste
// a list of your open apps.
//
// A developer diagnostic, not shipped in the app.
//
import AVFoundation
import AppKit
import CoreAudio
import Foundation

// MARK: - Arguments

let argv = CommandLine.arguments

func hasFlag(_ name: String) -> Bool { argv.contains(name) }

func doubleArg(_ name: String, default def: Double) -> Double {
    guard let i = argv.firstIndex(of: name), i + 1 < argv.count, let v = Double(argv[i + 1]) else {
        return def
    }
    return v
}

let watchSec = max(10, doubleArg("--watch", default: 240))
let intervalSec = max(0.25, doubleArg("--interval", default: 1))
let requestAccess = hasFlag("--request-access")

// MARK: - CoreAudio reads (the independent corroborator)

/// Whether any process is running an IOProc on this device. Needs no TCC grant and is a different
/// mechanism from the AVFoundation property under test, which is the whole point: it answers "was
/// the microphone actually held during the watch", so a flag that never flips can be told apart
/// from a call that never happened. It cannot say WHICH process, and it counts output devices too,
/// so only the default INPUT device's reading is used below.
func isRunningSomewhere(_ device: AudioDeviceID) -> Bool? {
    var addr = AudioObjectPropertyAddress(
        mSelector: kAudioDevicePropertyDeviceIsRunningSomewhere,
        mScope: kAudioObjectPropertyScopeGlobal,
        mElement: kAudioObjectPropertyElementMain
    )
    var value: UInt32 = 0
    var size = UInt32(MemoryLayout<UInt32>.size)
    guard AudioObjectGetPropertyData(device, &addr, 0, nil, &size, &value) == noErr else { return nil }
    return value != 0
}

func defaultInputDevice() -> AudioDeviceID? {
    var addr = AudioObjectPropertyAddress(
        mSelector: kAudioHardwarePropertyDefaultInputDevice,
        mScope: kAudioObjectPropertyScopeGlobal,
        mElement: kAudioObjectPropertyElementMain
    )
    var device = AudioDeviceID(0)
    var size = UInt32(MemoryLayout<AudioDeviceID>.size)
    let status = AudioObjectGetPropertyData(
        AudioObjectID(kAudioObjectSystemObject), &addr, 0, nil, &size, &device
    )
    guard status == noErr, device != 0 else { return nil }
    return device
}

// MARK: - AVFoundation reads (the property under test)

/// Every audio capture device AVFoundation will list, default first. The daemon only ever looks at
/// the default one; the rest are here so "the default device is not the one the call holds" cannot
/// be mistaken for "the property is structurally false".
func allAudioDevices() -> [AVCaptureDevice] {
    let session = AVCaptureDevice.DiscoverySession(
        deviceTypes: [.microphone, .external],
        mediaType: .audio,
        position: .unspecified
    )
    return session.devices
}

func statusLabel(_ status: AVAuthorizationStatus) -> String {
    switch status {
    case .authorized: return "GRANTED"
    case .denied: return "NOT GRANTED (denied)"
    case .restricted: return "NOT GRANTED (restricted)"
    case .notDetermined: return "NOT GRANTED (never asked)"
    @unknown default: return "NOT GRANTED (unknown)"
    }
}

// MARK: - Preconditions, printed before anything else

print("DET10 mic-busy probe (read-only)")
print("")

if requestAccess {
    print("--request-access: raising the one-time microphone prompt for this process.")
    let sema = DispatchSemaphore(value: 0)
    AVCaptureDevice.requestAccess(for: .audio) { _ in sema.signal() }
    _ = sema.wait(timeout: .now() + 60)
    print("")
}

let tcc = AVCaptureDevice.authorizationStatus(for: .audio)
print("PRECONDITION  Microphone access for this process: \(statusLabel(tcc))")

guard tcc == .authorized else {
    print("")
    print("✗ Refusing to watch, and refusing to emit any verdict.")
    print("  The property under test is exactly the kind a denied grant can pin false, so a")
    print("  measurement taken here would hand you a NO-GO that measures this permission rather")
    print("  than macOS. That false zero is indistinguishable from a real one.")
    print("")
    print("  Fix: System Settings -> Privacy & Security -> Microphone, enable the app running")
    print("  this script (Terminal / iTerm / your IDE), then re-run.")
    print("  If it is not listed there at all, it has never asked: run this once with")
    print("  --request-access, approve the prompt, then re-run without the flag.")
    print("  Note: a script launched from an agent or any other disclaimed parent inherits the")
    print("  parent's TCC identity and reports NOT GRANTED even when Terminal is ticked. Open a")
    print("  normal Terminal window yourself and paste the command there.")
    exit(2)
}

// The daemon's own capture would read as "another application" from here and would flip the flag
// for a reason that has nothing to do with a meeting client, so say whether it is up.
let daemonRunning = NSWorkspace.shared.runningApplications.contains {
    ($0.bundleIdentifier ?? "").hasPrefix("com.meetingpipe")
}
if daemonRunning {
    print("              MeetingPipe is running. Make sure it is NOT recording during the watch:")
    print("              its own capture would flip the flag from a source that is not the call.")
}

// Leg 1, answered before the watch even starts: does the daemon's one resolve resolve?
let defaultDevice = AVCaptureDevice.default(for: .audio)
let devices = allAudioDevices()
print("")
print("LEG 1  AVCaptureDevice.default(for: .audio): \(defaultDevice.map { "\($0.localizedName) [\($0.uniqueID)]" } ?? "nil")")
print("       audio capture devices AVFoundation lists: \(devices.count)")
for d in devices {
    let tag = d.uniqueID == defaultDevice?.uniqueID ? "  <- default" : ""
    print("         \(d.localizedName)  connected=\(d.isConnected)\(tag)")
}

// MARK: - Pre-registered verdict table, printed BEFORE any measurement

print("")
print("PRE-REGISTERED VERDICT (written before this ran; not to be refitted afterwards)")
print("  A  default device is nil                       -> GO (wiring). Cause 1 confirmed.")
print("  B  the flag reads true at any point            -> GO (wiring). The signal works in a")
print("                                                    plain process, so the daemon's own")
print("                                                    wiring is what is broken.")
print("  C  flag never true, and the default input was")
print("     never running anywhere                      -> NO VERDICT. Nothing held the mic during")
print("                                                    the watch. Re-run during a real call.")
print("  D  flag never true, but the default input WAS")
print("     running somewhere                           -> NO-GO. The mic was demonstrably held and")
print("                                                    the property stayed false, so the signal")
print("                                                    choice is wrong: replace or supplement it")
print("                                                    (DET8's kAudioHardwarePropertyProcess-")
print("                                                    ObjectList is the nearest candidate).")
print("")

guard let mic = defaultDevice else {
    print("=== VERDICT: A, GO (wiring) ===")
    print("")
    print("`AVCaptureDevice.default(for: .audio)` returned nil in a process that HAS the microphone")
    print("grant. That is cause 1, and it is the whole explanation for the zero mic-busy spans:")
    print("`MeetingDiscoveryWatcher.wireMicObserver` takes this same branch once at daemon launch")
    print("and never retries, so DET1 and DET3 are dead for the process lifetime.")
    print("")
    print("What it authorizes: fix the wiring. Re-resolve the device rather than resolving once")
    print("(a device-change observer, or a resolve inside the existing backstop poll), and keep")
    print("the `detector.mic_device_unavailable` event so a future nil is still visible.")
    print("It does NOT authorize replacing the signal: this measurement says nothing about whether")
    print("`isInUseByAnotherApplication` works, because there was no device to ask.")
    exit(0)
}

// MARK: - Watch

print("Watching for \(Int(watchSec))s, sampling every \(intervalSec)s.")
print("JOIN A CALL NOW, stay in it about a minute, then leave. Any call works.")
print("Lines print only when something changes.")
print("")

let inputDevice = defaultInputDevice()
if inputDevice == nil {
    print("⚠ No default INPUT device from CoreAudio, so the independent \"was the mic actually")
    print("  held\" corroborator is unavailable and outcome C cannot be told from outcome D.")
    print("")
}

var kvoFires = 0
var flagEverTrue = false
var runningEverTrue = false
var flagTrueWhileFrontmost: [String] = []
var runningHolders: [String] = []
var otherDeviceEverTrue: [String] = []

// The daemon observes exactly this, so the probe does too: if the KVO never fires while the poll
// sees a change, that is its own finding (the daemon's KVO is documented as flaky across macOS
// versions, which is why it also polls).
let observation = mic.observe(\.isInUseByAnotherApplication, options: [.new]) { _, change in
    kvoFires += 1
    let value = change.newValue ?? false
    print(String(format: "  KVO   isInUseByAnotherApplication -> %@", value ? "TRUE" : "false"))
}

func frontmostLabel() -> String {
    let front = NSWorkspace.shared.frontmostApplication
    return front?.localizedName ?? front?.bundleIdentifier ?? "(none)"
}

let started = Date()
var lastLine = ""
while Date().timeIntervalSince(started) < watchSec {
    let at = Date().timeIntervalSince(started)
    let busy = mic.isInUseByAnotherApplication
    let running = inputDevice.flatMap { isRunningSomewhere($0) }
    let front = frontmostLabel()

    if busy {
        flagEverTrue = true
        if !flagTrueWhileFrontmost.contains(front) { flagTrueWhileFrontmost.append(front) }
    }
    if running == true {
        runningEverTrue = true
        if !runningHolders.contains(front) { runningHolders.append(front) }
    }
    for d in devices where d.uniqueID != mic.uniqueID && d.isInUseByAnotherApplication {
        if !otherDeviceEverTrue.contains(d.localizedName) { otherDeviceEverTrue.append(d.localizedName) }
    }

    let runningLabel = running.map { $0 ? "RUNNING" : "idle" } ?? "read-failed"
    let line = "busy=\(busy ? "TRUE" : "false")  input=\(runningLabel)  frontmost=\(front)"
    if line != lastLine {
        print(String(format: "  t=%5.0fs  %@", at, line))
        lastLine = line
    }
    // A run loop slice rather than a sleep: KVO callbacks are delivered through it, and a sleeping
    // thread would starve exactly the mechanism half this probe is measuring.
    RunLoop.current.run(until: Date().addingTimeInterval(intervalSec))
}
observation.invalidate()

// MARK: - Report

print("")
print("MEASURED over \(Int(watchSec))s")
print("  default device resolved:                          YES (\(mic.localizedName))")
print("  isInUseByAnotherApplication ever true:            \(flagEverTrue ? "YES" : "NO")")
print("  KVO fires on that property:                       \(kvoFires)")
print("  default input running somewhere (CoreAudio):      \(runningEverTrue ? "YES" : "NO")")
if !flagTrueWhileFrontmost.isEmpty {
    print("  frontmost while the flag was true:                \(flagTrueWhileFrontmost.joined(separator: ", "))")
}
if !runningHolders.isEmpty {
    print("  frontmost while the input was running:            \(runningHolders.joined(separator: ", "))")
}
if !otherDeviceEverTrue.isEmpty {
    print("  OTHER devices that read busy:                     \(otherDeviceEverTrue.joined(separator: ", "))")
    print("    (the daemon only ever asks the default one, so this is its own finding)")
}
print("")

if flagEverTrue {
    print("=== VERDICT: B, GO (wiring) ===")
    print("")
    print("The property does flip on this Mac, in a plain process, for a real mic holder. So the")
    print("signal choice is sound and the zero mic-busy spans are the daemon's own wiring, not")
    print("macOS. Do NOT replace the signal.")
    print("")
    print("What it authorizes: fix the wiring in `MeetingDiscoveryWatcher`. Start at the once-only")
    print("`AVCaptureDevice.default(for: .audio)` resolve, which is never retried; check the")
    print("`detector.mic_device_unavailable` event in `~/Library/Logs/MeetingPipe/events.jsonl`")
    print("first, since a row there names that branch as the cause outright.")
    if kvoFires == 0 {
        print("")
        print("Note a second finding: the flag was true but the KVO never fired once. The backstop")
        print("poll, not the observation, is what carries this signal, so a fix must not lean on")
        print("the KVO alone.")
    }
} else if runningEverTrue {
    print("=== VERDICT: D, NO-GO ===")
    print("")
    print("Something ran the default input device during the watch and")
    print("`isInUseByAnotherApplication` never once read true. The property does not observe mic")
    print("contention on this Mac, so DET1's catch-all tier and DET3's mic-busy dimension cannot be")
    print("repaired by fixing the wiring: they are built on a signal that does not exist.")
    print("")
    print("This is an ACCEPTABLE, pre-registered outcome, not a failure to engineer around.")
    print("What it authorizes: replace or supplement the signal, starting with DET8's")
    print("`kAudioHardwarePropertyProcessObjectList` enumeration, which is already live for Teams")
    print("and Zoom end-detection and needs no TCC grant. Do NOT reach for a heuristic substitute")
    print("(polling frontmost apps, guessing from window titles): those fire on the wrong app")
    print("silently, which is worse than the current silence.")
} else {
    print("=== NO VERDICT (outcome C) ===")
    print("")
    print("The flag never read true, AND the default input device never read as running anywhere,")
    print("so nothing held the microphone during the watch. That measures the watch, not macOS.")
    print("A NO-GO recorded from this would be exactly the false zero this probe exists to avoid.")
    print("")
    print("Re-run it and join a call while it watches. If you did join one, check that the call")
    print("was on this Mac's default input device (listed above) and that you were unmuted at")
    print("least briefly.")
    exit(3)
}
print("")
print("Paste this whole output into docs/backlog/tasks/DET10.md under \"Measured\", with the date.")
