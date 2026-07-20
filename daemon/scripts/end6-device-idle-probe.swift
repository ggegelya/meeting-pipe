#!/usr/bin/env swift
//
// Diagnostic for END6: can `kAudioDevicePropertyDeviceIsRunningSomewhere` ever be an
// end corroborator, given that our own recorder holds the input device?
//
// END6 inherited a design-time claim (docs/architecture/signal-fusion-and-mic-gating.md,
// PART A): the device-scope read "fires only when the last client on the input device
// releases it", so it could corroborate a meeting end. The claim never accounted for the
// daemon itself being one of those clients. This probe measures the confound directly, and
// it needs no live meeting to do it: the blocking question is what OUR OWN capture does to
// the read, not what Teams does.
//
// Three snapshots of every audio device on the machine:
//
//   1. BASELINE, nothing of ours capturing.
//   2. WHILE an `AVAudioEngine` input tap runs (the exact shape `MeetingRecorder` uses).
//   3. AFTER stop.
//
// The verdict line says whether the default input and the default output stayed readable
// (the signal could exist) or were pinned RUNNING by our own capture (it cannot). Read the
// measured 2026-07-14 result and the decision in docs/spikes/end6-device-idle-corroborator.md.
//
// Read-only: it installs a tap that counts buffers and writes nothing, records nothing, and
// tears the engine down before it exits. It is not part of the app. Run it with no meeting
// in progress and no other app holding the mic (the baseline must be all-idle to be clean):
//
//     swift daemon/scripts/end6-device-idle-probe.swift
//
// Mic TCC is not required: the flag tracks whether an IOProc is running on the device, not
// whether real samples flow, so an unauthorized engine (silent buffers) pins it exactly the
// same way. The probe prints the TCC status so the reading is interpretable either way.
//
import AVFoundation
import CoreAudio
import Foundation

// MARK: - HAL reads

func allDevices() -> [AudioDeviceID] {
    var addr = AudioObjectPropertyAddress(
        mSelector: kAudioHardwarePropertyDevices,
        mScope: kAudioObjectPropertyScopeGlobal,
        mElement: kAudioObjectPropertyElementMain
    )
    var size: UInt32 = 0
    guard AudioObjectGetPropertyDataSize(
        AudioObjectID(kAudioObjectSystemObject), &addr, 0, nil, &size
    ) == noErr else { return [] }
    let count = Int(size) / MemoryLayout<AudioDeviceID>.size
    guard count > 0 else { return [] }
    var devices = [AudioDeviceID](repeating: 0, count: count)
    guard AudioObjectGetPropertyData(
        AudioObjectID(kAudioObjectSystemObject), &addr, 0, nil, &size, &devices
    ) == noErr else { return [] }
    return devices
}

func deviceName(_ device: AudioDeviceID) -> String {
    var addr = AudioObjectPropertyAddress(
        mSelector: kAudioObjectPropertyName,
        mScope: kAudioObjectPropertyScopeGlobal,
        mElement: kAudioObjectPropertyElementMain
    )
    var ref: CFString?
    var size = UInt32(MemoryLayout<CFString?>.size)
    let status = withUnsafeMutablePointer(to: &ref) {
        AudioObjectGetPropertyData(device, &addr, 0, nil, &size, $0)
    }
    guard status == noErr, let name = ref as String? else { return "(unnamed \(device))" }
    return name
}

/// Channel count in one scope. Zero means the device has no streams in that direction.
func channelCount(_ device: AudioDeviceID, scope: AudioObjectPropertyScope) -> Int {
    var addr = AudioObjectPropertyAddress(
        mSelector: kAudioDevicePropertyStreamConfiguration,
        mScope: scope,
        mElement: kAudioObjectPropertyElementMain
    )
    var size: UInt32 = 0
    guard AudioObjectGetPropertyDataSize(device, &addr, 0, nil, &size) == noErr, size > 0 else { return 0 }
    let raw = UnsafeMutableRawPointer.allocate(
        byteCount: Int(size), alignment: MemoryLayout<AudioBufferList>.alignment
    )
    defer { raw.deallocate() }
    guard AudioObjectGetPropertyData(device, &addr, 0, nil, &size, raw) == noErr else { return 0 }
    let list = UnsafeMutableAudioBufferListPointer(raw.assumingMemoryBound(to: AudioBufferList.self))
    return list.reduce(0) { $0 + Int($1.mNumberChannels) }
}

/// The property END6 rests on. nil when the read fails.
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

func defaultDevice(_ selector: AudioObjectPropertySelector) -> AudioDeviceID? {
    var addr = AudioObjectPropertyAddress(
        mSelector: selector,
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

// MARK: - Snapshot

func pad(_ s: String, _ width: Int) -> String {
    s.count >= width ? s : s + String(repeating: " ", count: width - s.count)
}

/// Every device with at least one stream, and whether it currently reads RUNNING.
/// Returns the running state keyed by device so the caller can diff two snapshots.
@discardableResult
func snapshot(_ label: String) -> [AudioDeviceID: Bool] {
    let defaultIn = defaultDevice(kAudioHardwarePropertyDefaultInputDevice)
    let defaultOut = defaultDevice(kAudioHardwarePropertyDefaultOutputDevice)
    var states: [AudioDeviceID: Bool] = [:]
    print("--- \(label) ---")
    for device in allDevices() {
        let ins = channelCount(device, scope: kAudioObjectPropertyScopeInput)
        let outs = channelCount(device, scope: kAudioObjectPropertyScopeOutput)
        guard ins > 0 || outs > 0 else { continue }
        let running = isRunningSomewhere(device)
        if let running { states[device] = running }
        let state = running.map { $0 ? "RUNNING" : "idle" } ?? "read-failed"
        let tags = [
            device == defaultIn ? "DEFAULT-IN" : nil,
            device == defaultOut ? "DEFAULT-OUT" : nil,
        ].compactMap { $0 }.joined(separator: "/")
        print("  \(pad(deviceName(device), 34)) in:\(ins) out:\(outs)  \(pad(state, 12))\(tags)")
    }
    return states
}

// MARK: - Probe

let tcc = AVCaptureDevice.authorizationStatus(for: .audio)
let tccName: String
switch tcc {
case .authorized: tccName = "authorized"
case .denied: tccName = "denied"
case .restricted: tccName = "restricted"
case .notDetermined: tccName = "notDetermined"
@unknown default: tccName = "unknown"
}
print("mic TCC for this process: \(tccName)")
print("(the flag tracks a running IOProc, not real samples, so the reading holds either way)\n")

let before = snapshot("BASELINE (nothing of ours capturing)")
let baselineIdle = before.values.allSatisfy { !$0 }
if !baselineIdle {
    print("\nNOTE: something already holds a device. Close other audio apps and re-run,")
    print("      or the WHILE snapshot cannot be attributed to our own capture.\n")
}

let engine = AVAudioEngine()
let input = engine.inputNode
let format = input.inputFormat(forBus: 0)
print("\ninput node format: \(format.sampleRate) Hz, \(format.channelCount) ch")
var buffers = 0
input.installTap(onBus: 0, bufferSize: 1024, format: format) { _, _ in buffers += 1 }
do {
    try engine.start()
    print("engine started: \(engine.isRunning)\n")
} catch {
    print("engine FAILED to start: \(error)\n")
}
Thread.sleep(forTimeInterval: 2.0)

let during = snapshot("WHILE OUR OWN AVAudioEngine INPUT TAP RUNS")
print("  (buffers delivered in 2 s: \(buffers))")

engine.stop()
input.removeTap(onBus: 0)
Thread.sleep(forTimeInterval: 1.5)
print()
snapshot("AFTER STOP")

// MARK: - Verdict

let defaultIn = defaultDevice(kAudioHardwarePropertyDefaultInputDevice)
let defaultOut = defaultDevice(kAudioHardwarePropertyDefaultOutputDevice)
let inPinned = defaultIn.map { (before[$0] == false) && (during[$0] == true) } ?? false
let outPinned = defaultOut.map { (before[$0] == false) && (during[$0] == true) } ?? false

print("\n=== VERDICT ===")
print("default input pinned RUNNING by our own capture:  \(inPinned)")
print("default output pinned RUNNING by our own capture: \(outPinned)")
if inPinned && outPinned {
    print("""

    REFUTED, as measured on 2026-07-14 (macOS 26.x). Our own capture pins BOTH the default
    input and the default output, because `AVAudioEngine.inputNode` instantiates a
    `CADefaultDeviceAggregate` that spans both directions. While the daemon records, no
    device on the machine can read idle, so `kAudioDevicePropertyDeviceIsRunningSomewhere`
    carries no information about the meeting client, in either direction. END6's device-idle
    leg cannot exist. The PER-PROCESS read (DET2) would be unconfounded, but it does
    not resolve under any mechanism either: DET2 closed NO-GO on 2026-07-20.
    """)
} else if inPinned {
    print("""

    Input pinned, output free. The input leg is dead (the daemon is always a client), but the
    OUTPUT device reads independently on this macOS, unlike the 2026-07-14 measurement. That
    re-opens a narrow question END6 closed: a call client renders remote audio, so an idle
    output could corroborate an end. Before building it, note the two objections in the spike
    doc that stand regardless: the read is device-GLOBAL (any app's audio marks it running,
    so only the idle direction informs, and any other app playing audio blinds it), and a new
    cross-class end signal instant-promotes a provisional end, so a misread chops a recording.
    """)
} else {
    print("""

    NOT REPRODUCED. Our own capture did not pin the device readings on this macOS, which
    contradicts the 2026-07-14 measurement. Re-read the spike doc's reasoning against a fresh
    trace before acting on this: the correlated-pair gate and the AX re-walk are what actually
    hold native end detection together, and they measured a 0.17 s median confirmation.
    """)
}
