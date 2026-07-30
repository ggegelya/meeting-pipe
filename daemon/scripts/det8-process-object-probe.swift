#!/usr/bin/env swift
//
// DET8 probe: per-process mic attribution via HAL process-object ENUMERATION.
//
// DET2 (closed NO-GO 2026-07-20) translated the meeting app's MAIN pid to a HAL
// process object and got object 0 from every mechanism. DET8's 2026-07-30 finding:
// that answer was true and irrelevant, because the MSTeams shell process never
// registers as a CoreAudio client at all. The media stack lives in the helper
// "Microsoft Teams ModuleHost" (--module_name=SlimCore, a direct child of the
// shell), and enumerating kAudioHardwarePropertyProcessObjectList shows it holding
// a live process object whose pid translates fine. So the read DET2 wanted exists;
// it was aimed at the wrong process. See docs/backlog/tasks/DET8.md.
//
// This probe is read-only (no taps, no aggregates, no audio capture): it reads
// HAL metadata booleans only. Two modes:
//
//   swift daemon/scripts/det8-process-object-probe.swift
//       One-shot: dump every HAL process object (pid, name, bundle, isRunning,
//       input, output) plus the translate contrast for Teams processes.
//
//   swift daemon/scripts/det8-process-object-probe.swift --watch [seconds]
//       Sample at 1 Hz (default 900 s) and print a timestamped line on every
//       isRunningInput / isRunningOutput transition and on any process object
//       appearing or vanishing. Run it across a live Teams call: join, stay
//       unmuted ~15 s, MUTE for at least 15 s, unmute, then leave and let it
//       run 60 s more. Ctrl+C is fine; transitions are printed as they happen.
//
// Pre-registered bars (fixed 2026-07-30, before any live-call data; judge the
// run against these, do not adjust them afterwards):
//   B1 resolve:  within 5 s of joining, at least one com.microsoft.teams2*
//                object reads isRunningInput=true.
//   B2 mute:     isRunningInput STAYS true across a >= 15 s in-call mute
//                (expected: client mute is a transmit gate, the OS mic stays
//                live; record whatever happens, a flip is informative not fatal).
//   B3 end:      within 60 s of leaving, every com.microsoft.teams2* object
//                reads isRunningInput=false.
// GO = B1 and B3 hold. B2 decides nothing but is recorded in the build notes.
//
// Grant note: the 2026-07-30 enumeration resolved WITH NO screen-recording grant
// (the harness's disclaimed parent), so a positive result needs no TCC and cannot
// be a false positive. The det2 TCC caveat (a disclaimed parent voids the verdict)
// applies only to NEGATIVE results: if this probe prints an empty list, re-run it
// from an ordinary Terminal before believing it.
//
import CoreAudio
import CoreGraphics
import Foundation

guard #available(macOS 14.2, *) else {
    print("DET8 probe needs macOS 14.2+ (HAL process objects).")
    exit(1)
}

let teamsPrefix = "com.microsoft.teams2"

func processObjectList() -> [AudioObjectID] {
    var addr = AudioObjectPropertyAddress(
        mSelector: kAudioHardwarePropertyProcessObjectList,
        mScope: kAudioObjectPropertyScopeGlobal,
        mElement: kAudioObjectPropertyElementMain
    )
    var size: UInt32 = 0
    guard AudioObjectGetPropertyDataSize(AudioObjectID(kAudioObjectSystemObject), &addr, 0, nil, &size) == noErr, size > 0 else { return [] }
    var objects = [AudioObjectID](repeating: 0, count: Int(size) / MemoryLayout<AudioObjectID>.size)
    guard AudioObjectGetPropertyData(AudioObjectID(kAudioObjectSystemObject), &addr, 0, nil, &size, &objects) == noErr else { return [] }
    return objects.filter { $0 != 0 }
}

func readPID(_ o: AudioObjectID) -> pid_t? {
    var addr = AudioObjectPropertyAddress(mSelector: kAudioProcessPropertyPID, mScope: kAudioObjectPropertyScopeGlobal, mElement: kAudioObjectPropertyElementMain)
    var pid: pid_t = -1
    var sz = UInt32(MemoryLayout<pid_t>.size)
    return AudioObjectGetPropertyData(o, &addr, 0, nil, &sz, &pid) == noErr ? pid : nil
}

func readBundleID(_ o: AudioObjectID) -> String {
    var addr = AudioObjectPropertyAddress(mSelector: kAudioProcessPropertyBundleID, mScope: kAudioObjectPropertyScopeGlobal, mElement: kAudioObjectPropertyElementMain)
    var cf: Unmanaged<CFString>?
    var sz = UInt32(MemoryLayout<Unmanaged<CFString>?>.size)
    let st = AudioObjectGetPropertyData(o, &addr, 0, nil, &sz, &cf)
    guard st == noErr, let cf = cf else { return "" }
    return cf.takeRetainedValue() as String
}

func readBool(_ o: AudioObjectID, _ sel: AudioObjectPropertySelector) -> Bool? {
    var addr = AudioObjectPropertyAddress(mSelector: sel, mScope: kAudioObjectPropertyScopeGlobal, mElement: kAudioObjectPropertyElementMain)
    var v: UInt32 = 0
    var sz = UInt32(MemoryLayout<UInt32>.size)
    guard AudioObjectGetPropertyData(o, &addr, 0, nil, &sz, &v) == noErr else { return nil }
    return v != 0
}

func procName(_ pid: pid_t) -> String {
    var buf = [CChar](repeating: 0, count: 4096)
    let n = proc_pidpath(pid, &buf, UInt32(buf.count))
    guard n > 0 else { return "?" }
    return (String(cString: buf) as NSString).lastPathComponent
}

func translate(_ pid: pid_t) -> (AudioObjectID, OSStatus) {
    var pidVar = pid
    var addr = AudioObjectPropertyAddress(mSelector: kAudioHardwarePropertyTranslatePIDToProcessObject, mScope: kAudioObjectPropertyScopeGlobal, mElement: kAudioObjectPropertyElementMain)
    var object = AudioObjectID(0)
    var sz = UInt32(MemoryLayout<AudioObjectID>.size)
    let st = AudioObjectGetPropertyData(AudioObjectID(kAudioObjectSystemObject), &addr, UInt32(MemoryLayout<pid_t>.size), &pidVar, &sz, &object)
    return (object, st)
}

let stamp: () -> String = {
    let f = DateFormatter()
    f.dateFormat = "HH:mm:ss.SSS"
    return { f.string(from: Date()) }
}()

print("DET8 process-object probe")
print("  screen-recording grant: \(CGPreflightScreenCaptureAccess() ? "granted" : "NOT granted (fine for a positive result; a NEGATIVE from a harness-spawned shell is void, re-run from Terminal)")")
print("")

struct Row {
    let object: AudioObjectID
    let pid: pid_t
    let name: String
    let bundle: String
    let input: Bool
    let output: Bool
}

func snapshot() -> [AudioObjectID: Row] {
    var out: [AudioObjectID: Row] = [:]
    for o in processObjectList() {
        guard let pid = readPID(o) else { continue }
        out[o] = Row(
            object: o, pid: pid, name: procName(pid), bundle: readBundleID(o),
            input: readBool(o, kAudioProcessPropertyIsRunningInput) ?? false,
            output: readBool(o, kAudioProcessPropertyIsRunningOutput) ?? false
        )
    }
    return out
}

func dumpTable(_ rows: [AudioObjectID: Row]) {
    print("process objects in HAL list: \(rows.count)")
    for r in rows.values.sorted(by: { $0.object < $1.object }) {
        let mark = r.bundle.hasPrefix(teamsPrefix) ? " <-- teams" : ""
        print(String(format: "  obj %6d  pid %6d  %-40s bundle=%@  input=%@ output=%@%@",
                     r.object, r.pid, (r.name as NSString).utf8String!, r.bundle,
                     r.input ? "true " : "false", r.output ? "true " : "false", mark))
    }
    let teams = rows.values.filter { $0.bundle.hasPrefix(teamsPrefix) }
    print("")
    if teams.isEmpty {
        print("no \(teamsPrefix)* process objects present (is Teams running?)")
    } else {
        for t in teams.sorted(by: { $0.object < $1.object }) {
            let (obj, st) = translate(t.pid)
            print("translate \(t.name) (pid \(t.pid)) -> object \(obj), OSStatus \(st)")
        }
    }
}

let args = CommandLine.arguments
if let i = args.firstIndex(of: "--watch") {
    let seconds = (i + 1 < args.count ? Int(args[i + 1]) : nil) ?? 900
    print("watch mode: \(seconds) s at 1 Hz. Join the call, hold a >= 15 s mute mid-call, leave, then give it 60 s.")
    print("bars: B1 input=true on a teams object within 5 s of join; B2 input stays true across the mute; B3 all teams objects false within 60 s of leave.")
    print("")
    var prev = snapshot()
    dumpTable(prev)
    print("")
    let end = Date().addingTimeInterval(TimeInterval(seconds))
    while Date() < end {
        Thread.sleep(forTimeInterval: 1.0)
        let cur = snapshot()
        for (id, row) in cur {
            if let p = prev[id] {
                if p.input != row.input {
                    print("\(stamp())  \(row.name) (pid \(row.pid), \(row.bundle))  isRunningInput \(p.input) -> \(row.input)")
                }
                if p.output != row.output, row.bundle.hasPrefix(teamsPrefix) {
                    print("\(stamp())  \(row.name) (pid \(row.pid), \(row.bundle))  isRunningOutput \(p.output) -> \(row.output)")
                }
            } else if row.bundle.hasPrefix(teamsPrefix) || row.input {
                print("\(stamp())  APPEARED \(row.name) (pid \(row.pid), \(row.bundle))  obj \(row.object) input=\(row.input) output=\(row.output)")
            }
        }
        for (id, row) in prev where cur[id] == nil {
            if row.bundle.hasPrefix(teamsPrefix) || row.input {
                print("\(stamp())  VANISHED \(row.name) (pid \(row.pid), \(row.bundle))  obj \(row.object)")
            }
        }
        prev = cur
    }
    print("")
    print("watch finished. Judge the transitions above against B1/B2/B3 (header of this script).")
} else {
    dumpTable(snapshot())
}
