#!/usr/bin/env swift
//
// Diagnostic for CAL1: does the owner's calendar actually carry their meetings?
//
// ADR 0011 deleted the calendar end-corroboration signal partly on the
// assumption that "meetings are not reliably calendar-bound" for this user. That
// was never measured. CAL1's hints-only idea (pre-title the prompt, feed an
// expected-end horizon, warn pre-meeting) only pays off if the assumption is
// wrong. This script measures it: for every recorded meeting, it looks for a
// covering EventKit calendar event and reports the match rate + how often the
// recorded title resembles the event title.
//
// It reads only; it never writes, and it is not part of the app. Run it on the
// owner's Mac:
//
//     swift daemon/scripts/cal1-calendar-probe.swift
//     swift daemon/scripts/cal1-calendar-probe.swift --days 60 --tolerance 15
//
// First run prompts for Calendar access (System Settings -> Privacy & Security
// -> Calendars -> enable Terminal / your IDE). Override the library location with
// MEETINGPIPE_RECORDINGS if it is not ~/Documents/Meetings/raw.
//
import EventKit
import Foundation

// MARK: - Args

func intArg(_ flag: String, default def: Int) -> Int {
    guard let i = CommandLine.arguments.firstIndex(of: flag),
          i + 1 < CommandLine.arguments.count,
          let v = Int(CommandLine.arguments[i + 1]) else { return def }
    return v
}
let lookbackDays = intArg("--days", default: 30)
let toleranceMin = intArg("--tolerance", default: 10)

let recordingsDir: URL = {
    if let override = ProcessInfo.processInfo.environment["MEETINGPIPE_RECORDINGS"] {
        return URL(fileURLWithPath: (override as NSString).expandingTildeInPath)
    }
    return FileManager.default.homeDirectoryForCurrentUser
        .appendingPathComponent("Documents/Meetings/raw")
}()

// MARK: - Recorded meetings (stems are `yyyyMMdd-HHmmss`)

struct Recorded {
    let stem: String
    let start: Date
    let title: String?
}

let stemFormatter: DateFormatter = {
    let f = DateFormatter()
    f.dateFormat = "yyyyMMdd-HHmmss"
    f.locale = Locale(identifier: "en_US_POSIX")
    return f
}()

func loadRecorded() -> [Recorded] {
    let fm = FileManager.default
    guard let entries = try? fm.contentsOfDirectory(at: recordingsDir, includingPropertiesForKeys: nil) else {
        print("No recordings directory at \(recordingsDir.path). Set MEETINGPIPE_RECORDINGS.")
        return []
    }
    var starts: [String: Date] = [:]
    var titles: [String: String] = [:]
    for url in entries {
        let stem = url.lastPathComponent.split(separator: ".").first.map(String.init) ?? ""
        if let start = stemFormatter.date(from: stem) {
            starts[stem] = start
        }
        if url.lastPathComponent == "\(stem).meta.json",
           let data = try? Data(contentsOf: url),
           let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
           let title = obj["meeting_title"] as? String, !title.isEmpty {
            titles[stem] = title
        }
    }
    return starts
        .map { Recorded(stem: $0.key, start: $0.value, title: titles[$0.key]) }
        .sorted { $0.start < $1.start }
}

// MARK: - Title similarity (token overlap, normalized)

func tokens(_ s: String) -> Set<String> {
    let lowered = s.lowercased()
    let cleaned = lowered.unicodeScalars.map { CharacterSet.alphanumerics.contains($0) ? Character($0) : " " }
    return Set(String(cleaned).split(separator: " ").map(String.init).filter { $0.count > 2 })
}

func titlesResemble(_ a: String?, _ b: String?) -> Bool {
    guard let a = a, let b = b else { return false }
    let ta = tokens(a), tb = tokens(b)
    guard !ta.isEmpty, !tb.isEmpty else { return false }
    return !ta.intersection(tb).isEmpty
}

// MARK: - EventKit

let store = EKEventStore()
let sem = DispatchSemaphore(value: 0)
var granted = false
let handler: (Bool, Error?) -> Void = { ok, err in
    granted = ok
    if let err = err { print("Calendar access error: \(err.localizedDescription)") }
    sem.signal()
}
if #available(macOS 14.0, *) {
    store.requestFullAccessToEvents(completion: handler)
} else {
    store.requestAccess(to: .event, completion: handler)
}
sem.wait()

guard granted else {
    print("✗ Calendar access not granted. Enable it for Terminal / your IDE in")
    print("  System Settings -> Privacy & Security -> Calendars, then re-run.")
    exit(1)
}

let recorded = loadRecorded()
guard !recorded.isEmpty else {
    print("No recorded meetings found under \(recordingsDir.path).")
    exit(0)
}

let now = Date()
let cutoff = now.addingTimeInterval(-Double(lookbackDays) * 86_400)
let windowStart = min(recorded.first!.start, cutoff).addingTimeInterval(-86_400)
let predicate = store.predicateForEvents(withStart: windowStart, end: now.addingTimeInterval(86_400), calendars: nil)
let events = store.events(matching: predicate).filter { !$0.isAllDay }

let tol = Double(toleranceMin) * 60

func coveringEvent(for start: Date) -> EKEvent? {
    events.first { ev in
        guard let s = ev.startDate, let e = ev.endDate else { return false }
        return start >= s.addingTimeInterval(-tol) && start <= e.addingTimeInterval(tol)
    }
}

// MARK: - Report

let considered = recorded.filter { $0.start >= cutoff }
var matched = 0
var titleMatched = 0

print("CAL1 calendar-coverage probe")
print("  library:   \(recordingsDir.path)")
print("  window:    last \(lookbackDays) days, ±\(toleranceMin) min tolerance")
print("  recorded:  \(considered.count) meetings   calendar events in window: \(events.count)")
print("")
print(String(format: "%-17@  %-7@  %@", "recorded start" as NSString, "covered" as NSString, "titles"))
for m in considered {
    let ev = coveringEvent(for: m.start)
    let covered = ev != nil
    if covered { matched += 1 }
    let titleHit = titlesResemble(m.title, ev?.title)
    if titleHit { titleMatched += 1 }
    let when = DateFormatter.localizedString(from: m.start, dateStyle: .short, timeStyle: .short)
    let flag = covered ? (titleHit ? "yes+title" : "yes") : "no"
    print(String(format: "%-17@  %-7@  %@", when as NSString, covered ? "yes" : "no" as NSString,
                 "\(flag): rec=\(m.title ?? "?") ev=\(ev?.title ?? "-")" as NSString))
}

let pct = considered.isEmpty ? 0 : Int(Double(matched) / Double(considered.count) * 100)
print("")
print("SUMMARY: \(matched)/\(considered.count) recorded meetings had a covering calendar event (\(pct)%).")
print("         \(titleMatched) of those also had a resembling title.")
print("")
if events.isEmpty {
    // Guard the false zero: an empty EventKit store makes the % meaningless. This
    // is what CAL1 actually hit on 2026-07-17 (0/55, but Calendar.app was empty
    // because the owner's Outlook/Teams calendar was never connected to macOS), and
    // the original READ line below reported it as a spurious "close CAL1". Do not
    // read a 0% here as evidence about calendar-boundness.
    print("READ: FALSE ZERO, not a measurement. There are 0 calendar events in the")
    print("      window, so EventKit had nothing to match against and the \(pct)% above is")
    print("      meaningless. This almost always means your calendar is not connected to")
    print("      macOS Calendar. Open Calendar.app: if your meetings are not there, add the")
    print("      account (Outlook / Teams / Google) so EventKit can see them, then re-run.")
    print("      Do NOT read this as \"meetings are not calendar-bound\" or close CAL1 on it.")
    print("      If you deliberately keep your calendar out of macOS, CAL1 is a no-go for")
    print("      that setup: an EventKit read is structurally blind to your meetings.")
} else if pct >= 60 {
    print("READ: meetings look calendar-bound. CAL1's hints (pre-title, expected-end,")
    print("      preflight) would pay off. Worth a GO ADR that accepts the Calendar TCC cost.")
} else if pct >= 30 {
    print("READ: partial coverage. Hints would help sometimes; weigh the Calendar TCC")
    print("      prompt against a hint that fires on only ~\(pct)% of meetings.")
} else {
    print("READ: meetings are NOT reliably calendar-bound (confirms ADR 0011's assumption),")
    print("      PROVIDED the \(events.count) events in the window are your real calendar. If")
    print("      Calendar.app looks empty, re-read the FALSE ZERO note (this is that case).")
    print("      Otherwise close CAL1: the hints would rarely fire, not worth a new TCC prompt.")
}
