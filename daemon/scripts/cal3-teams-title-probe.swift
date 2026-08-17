#!/usr/bin/env swift
//
// CAL3 leg 1 probe: do Microsoft Teams AX window titles carry a stable,
// series-identifying string during a live meeting?
//
// Read-only. It observes the Accessibility tree of the running Teams process and
// writes exactly one file, its own capture log. It never touches the meeting
// library, the config, or any sidecar, and it changes no production code, so it
// is safe to run during a real meeting.
//
// WHY THIS EXISTS. Three shipped features (AI6, CAL2, AI7) answer "what happened
// last time in this series?" with the *workflow*, and the owner's workflows are
// policy buckets: 105 meetings sit in "Personal". The sidecar already has a
// `meeting_title` slot for a real series identity, but coverage is 3% (6 of 179),
// because `MeetingTitleResolver.extractTeamsNativeTitle` matches exactly one
// guessed format and all 21 entries in `window_titles.json` are seeded guesses the
// suite still reports as `0/21 captured`. Building a second regex off a
// plausible-looking title would repeat that defect at higher confidence.
//
// SO THIS PROBE CONTAINS NO TEAMS TITLE PATTERN, ON PURPOSE. It measures two
// things that need no format knowledge:
//   1. does any window title CONTAIN the meeting's own name, which you supply
//      with --label, and
//   2. is at least one whole title byte-identical across separate instances of
//      the same recurring meeting.
// Those are exactly the two pre-registered bars in
// `docs/spikes/cal3-teams-window-title-series.md`. Read that doc before running
// this; the verdict thresholds were written down before any measurement and are
// not to be refitted afterwards.
//
// USAGE. Run it once per meeting, starting it as the meeting starts (the first
// sample approximates the moment the daemon actually resolves the title):
//
//   swift daemon/scripts/cal3-teams-title-probe.swift --label "Weekly sync" --kind series
//   swift daemon/scripts/cal3-teams-title-probe.swift --label "Alice" --kind one-on-one
//   swift daemon/scripts/cal3-teams-title-probe.swift --label "budget call" --kind ad-hoc
//
// The corpus the verdict needs: at least THREE instances of one named recurring
// meeting (same --label each time), plus at least one 1:1 and at least one ad-hoc
// call. Then:
//
//   swift daemon/scripts/cal3-teams-title-probe.swift --report
//
// which prints the verdict against the pre-registered bars, plus a
// `window_titles.json`-shaped block ready to paste into the fixture.
//
// REQUIRES Accessibility permission for whatever runs it: System Settings ->
// Privacy & Security -> Accessibility -> enable Terminal (or your IDE), then
// re-run. If it is not granted this probe REFUSES to capture and REFUSES to
// print a verdict, rather than reporting an empty window list as a real NO-GO.
// An untrusted process sees zero windows, and that false zero is
// indistinguishable from a genuine one (the CAL1 false-zero lesson).
//
// PRIVACY. The capture log holds real meeting names and real colleague names,
// and it lands under `docs/spikes/`, which is a git tree. Redact before
// committing if you want to; redact CONSISTENTLY, because bar B is byte
// identity and an inconsistent redaction breaks it.
//
// RELATED. `scripts/dump_window_titles.swift` also dumps titles and prints a
// fixture entry, and it stays: it is what README's troubleshooting section points
// at for a one-off `reject` row on any vendor. It cannot answer CAL3 because it
// takes a single snapshot (so it cannot separate a format failure from a timing
// one), keeps no corpus (so byte identity across separate meetings is not
// computable), records titles only (no subrole, no AXValue / AXIdentifier), and
// has no bars or verdict. See the spike doc's "Why this is not just
// dump_window_titles.swift".
//
// A developer diagnostic, not shipped in the app.
//
import AppKit
import ApplicationServices
import Foundation

// MARK: - Arguments

let argv = CommandLine.arguments

func hasFlag(_ name: String) -> Bool { argv.contains(name) }

func stringArg(_ name: String) -> String? {
    guard let i = argv.firstIndex(of: name), i + 1 < argv.count else { return nil }
    let v = argv[i + 1]
    return v.hasPrefix("--") ? nil : v
}

func doubleArg(_ name: String, default def: Double) -> Double {
    guard let s = stringArg(name), let v = Double(s) else { return def }
    return v
}

let scriptDir = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
let repoRoot = scriptDir.deletingLastPathComponent().deletingLastPathComponent()

let capturePath: URL = {
    if let override = stringArg("--out") {
        return URL(fileURLWithPath: (override as NSString).expandingTildeInPath)
    }
    return repoRoot.appendingPathComponent("docs/spikes/cal3-title-captures.jsonl")
}()

let reportMode = hasFlag("--report")
let watchSec = doubleArg("--watch", default: 30)
let intervalSec = max(0.5, doubleArg("--interval", default: 2))

let validKinds = ["series", "one-on-one", "ad-hoc"]

// MARK: - Capture model

// Keys are spelled out rather than derived by a key strategy. `convertToSnakeCase`
// and `convertFromSnakeCase` are NOT inverses over an acronym: "bundleID" encodes
// to "bundle_id" but "bundle_id" decodes back to "bundleId", so the strategy pair
// writes a capture log it cannot read. Caught by running --report over a synthetic
// corpus; do not swap these back for a strategy.

struct WindowSnapshot: Codable {
    let role: String?
    let subrole: String?
    let title: String?
    let axValue: String?
    let axIdentifier: String?
    let axDescription: String?
    let frame: String?

    enum CodingKeys: String, CodingKey {
        case role, subrole, title, frame
        case axValue = "ax_value"
        case axIdentifier = "ax_identifier"
        case axDescription = "ax_description"
    }
}

struct Sample: Codable {
    let atSec: Double
    let windows: [WindowSnapshot]

    enum CodingKeys: String, CodingKey {
        case atSec = "at_sec"
        case windows
    }
}

struct Capture: Codable {
    let probeVersion: Int
    let capturedAt: String
    let axTrusted: Bool
    let label: String
    let kind: String
    let bundleID: String
    let appName: String
    let watchSec: Double
    let intervalSec: Double
    let samples: [Sample]
    let distinctTitles: [String]
    let labelPresent: Bool
    let labelPresentExact: Bool
    let labelPresentAtFirstSample: Bool
    let sawCallPanel: Bool
    let anyAXValue: Bool
    let anyAXIdentifier: Bool
    let looksIdle: Bool

    enum CodingKeys: String, CodingKey {
        case label, kind, samples
        case probeVersion = "probe_version"
        case capturedAt = "captured_at"
        case axTrusted = "ax_trusted"
        case bundleID = "bundle_id"
        case appName = "app_name"
        case watchSec = "watch_sec"
        case intervalSec = "interval_sec"
        case distinctTitles = "distinct_titles"
        case labelPresent = "label_present"
        case labelPresentExact = "label_present_exact"
        case labelPresentAtFirstSample = "label_present_at_first_sample"
        case sawCallPanel = "saw_call_panel"
        case anyAXValue = "any_ax_value"
        case anyAXIdentifier = "any_ax_identifier"
        case looksIdle = "looks_idle"
    }
}

// MARK: - Text helpers

/// Lowercased, whitespace-collapsed, trimmed. Used only for "does this title
/// mention the meeting's own name", never to parse a title into parts.
func normalize(_ s: String) -> String {
    s.lowercased()
        .components(separatedBy: .whitespacesAndNewlines)
        .filter { !$0.isEmpty }
        .joined(separator: " ")
}

func jsonLiteral(_ s: String) -> String {
    guard let data = try? JSONSerialization.data(withJSONObject: s, options: [.fragmentsAllowed]),
          let out = String(data: data, encoding: .utf8) else {
        return "\"\""
    }
    return out
}

func pct(_ n: Int, _ d: Int) -> Int { d == 0 ? 0 : Int((Double(n) / Double(d) * 100).rounded()) }

// MARK: - Accessibility reads

func axString(_ el: AXUIElement, _ attr: String) -> String? {
    var value: CFTypeRef?
    guard AXUIElementCopyAttributeValue(el, attr as CFString, &value) == .success else { return nil }
    if let s = value as? String { return s.isEmpty ? nil : s }
    if let n = value as? NSNumber { return n.stringValue }
    return nil
}

func axFrame(_ el: AXUIElement) -> String? {
    var posVal: CFTypeRef?
    var sizeVal: CFTypeRef?
    var pos = CGPoint.zero
    var size = CGSize.zero
    var ok = false
    if AXUIElementCopyAttributeValue(el, kAXPositionAttribute as CFString, &posVal) == .success,
       let p = posVal, CFGetTypeID(p) == AXValueGetTypeID() {
        AXValueGetValue(p as! AXValue, .cgPoint, &pos)
        ok = true
    }
    if AXUIElementCopyAttributeValue(el, kAXSizeAttribute as CFString, &sizeVal) == .success,
       let s = sizeVal, CFGetTypeID(s) == AXValueGetTypeID() {
        AXValueGetValue(s as! AXValue, .cgSize, &size)
        ok = true
    }
    guard ok else { return nil }
    return "(\(Int(pos.x)),\(Int(pos.y)) \(Int(size.width))x\(Int(size.height)))"
}

func axElements(_ el: AXUIElement, _ attr: String) -> [AXUIElement] {
    var value: CFTypeRef?
    guard AXUIElementCopyAttributeValue(el, attr as CFString, &value) == .success else { return [] }
    if let arr = value as? [AXUIElement] { return arr }
    if let one = value, CFGetTypeID(one) == AXUIElementGetTypeID() {
        return [one as! AXUIElement]
    }
    return []
}

/// Every window the app exposes, deduplicated. Deliberately NOT filtered by
/// role: the live in-call surface is the floating compact panel, whose subrole is
/// `AXSystemDialog`, and a filter that keeps only plain windows is how a walk
/// misses it. `AXFocusedWindow` and `AXMainWindow` are unioned in because they are
/// occasionally populated when `AXWindows` is not.
func allWindows(of axApp: AXUIElement) -> [AXUIElement] {
    var out: [AXUIElement] = []
    for attr in [kAXWindowsAttribute as String,
                 kAXFocusedWindowAttribute as String,
                 kAXMainWindowAttribute as String] {
        for el in axElements(axApp, attr) where !out.contains(where: { CFEqual($0, el) }) {
            out.append(el)
        }
    }
    return out
}

func snapshotWindows(pid: pid_t) -> [WindowSnapshot] {
    // Fresh application element per sample: Teams destroys and recreates the
    // compact call panel as the call moves between surfaces, and a handle held
    // across samples can go stale where a re-resolve would find the window.
    let axApp = AXUIElementCreateApplication(pid)
    AXUIElementSetMessagingTimeout(axApp, 2.0)
    return allWindows(of: axApp).map { win in
        WindowSnapshot(
            role: axString(win, kAXRoleAttribute as String),
            subrole: axString(win, kAXSubroleAttribute as String),
            title: axString(win, kAXTitleAttribute as String),
            axValue: axString(win, kAXValueAttribute as String),
            axIdentifier: axString(win, kAXIdentifierAttribute as String),
            axDescription: axString(win, kAXDescriptionAttribute as String),
            frame: axFrame(win)
        )
    }
}

// MARK: - Preconditions, printed before anything else

let teamsBundleIDs = ["com.microsoft.teams2", "com.microsoft.teams"]
let axTrusted = AXIsProcessTrusted()

print("CAL3 Teams window-title probe (leg 1, read-only)")
print("")

if !reportMode {
    print("PRECONDITION  Accessibility access for this process: \(axTrusted ? "GRANTED" : "NOT GRANTED")")
    guard axTrusted else {
        print("")
        print("✗ Refusing to capture, and refusing to emit any verdict.")
        print("  An Accessibility-untrusted process reads ZERO windows from Teams, and that")
        print("  empty read is indistinguishable from a real \"Teams exposes no title\" result.")
        print("  Recording it would hand you a NO-GO that measures this permission, not Teams.")
        print("")
        print("  Fix: System Settings -> Privacy & Security -> Accessibility, enable the app")
        print("  running this script (Terminal / iTerm / your IDE), then re-run.")
        print("  Note: a script launched from an agent or a disclaimed parent process inherits")
        print("  the parent's TCC identity and can report NOT GRANTED even when Terminal is")
        print("  ticked. Run it from a normal Terminal window you opened yourself.")
        exit(2)
    }
}

// MARK: - Capture mode

func runCapture() {
    guard let label = stringArg("--label"), !label.trimmingCharacters(in: .whitespaces).isEmpty else {
        print("")
        print("✗ --label is required. Give the meeting's own name as YOU know it, e.g.")
        print("    --label \"Weekly platform sync\"")
        print("  For a 1:1 use the other person's name; for an ad-hoc call, a short")
        print("  description. The probe measures whether that string shows up in any window")
        print("  title, which is how it avoids guessing at Teams' title format.")
        exit(1)
    }
    guard let kind = stringArg("--kind"), validKinds.contains(kind) else {
        print("")
        print("✗ --kind is required and must be one of: \(validKinds.joined(separator: ", "))")
        print("  Use the same --label for every instance of the same recurring meeting;")
        print("  that is what bar B (byte-identical across instances) is computed over.")
        exit(1)
    }

    guard let app = NSWorkspace.shared.runningApplications.first(where: {
        teamsBundleIDs.contains($0.bundleIdentifier ?? "")
    }) else {
        print("")
        print("✗ Microsoft Teams is not running (looked for \(teamsBundleIDs.joined(separator: ", "))).")
        print("  Run this DURING a live Teams meeting, not before it.")
        exit(1)
    }
    let pid = app.processIdentifier
    let bundleID = app.bundleIdentifier ?? teamsBundleIDs[0]
    let appName = app.localizedName ?? "Microsoft Teams"

    print("              Teams running: pid \(pid), bundle \(bundleID)")
    print("")
    print("Capturing \"\(label)\" (\(kind)) for \(Int(watchSec))s, every \(intervalSec)s.")
    print("Leave this running and carry on with the meeting.")
    print("")

    let started = Date()
    var samples: [Sample] = []
    var lastSignature: String?
    while Date().timeIntervalSince(started) < watchSec {
        let at = Date().timeIntervalSince(started)
        let windows = snapshotWindows(pid: pid)
        // Dedupe consecutive identical window sets so a 30 s watch does not write
        // 15 copies of the same tree; a change is what is interesting.
        let signature = windows.map { "\($0.subrole ?? "-")|\($0.title ?? "-")" }.joined(separator: "\u{1}")
        if signature != lastSignature {
            samples.append(Sample(atSec: (at * 10).rounded() / 10, windows: windows))
            lastSignature = signature
            let titles = windows.compactMap { $0.title }
            print(String(format: "  t=%5.1fs  %d window(s): %@", at, windows.count,
                         titles.isEmpty ? "(no titled windows)" : titles.map { "\"\($0)\"" }.joined(separator: "  ")))
        }
        Thread.sleep(forTimeInterval: intervalSec)
    }

    guard !samples.isEmpty else {
        print("")
        print("✗ No samples taken. Nothing written.")
        exit(1)
    }

    var distinct: [String] = []
    for s in samples {
        for w in s.windows {
            if let t = w.title, !distinct.contains(t) { distinct.append(t) }
        }
    }
    let normLabel = normalize(label)
    let labelPresent = distinct.contains { normalize($0).contains(normLabel) }
    let labelPresentExact = distinct.contains { $0.contains(label) }
    let firstTitles = samples[0].windows.compactMap { $0.title }
    let labelAtFirst = firstTitles.contains { normalize($0).contains(normLabel) }
    let sawPanel = samples.contains { $0.windows.contains { $0.subrole == (kAXSystemDialogSubrole as String) } }
    let anyValue = samples.contains { $0.windows.contains { $0.axValue != nil } }
    let anyIdent = samples.contains { $0.windows.contains { $0.axIdentifier != nil } }
    let looksIdle = distinct.isEmpty || distinct.allSatisfy { normalize($0) == normalize(appName) }

    let capture = Capture(
        probeVersion: 1,
        capturedAt: ISO8601DateFormatter().string(from: started),
        axTrusted: axTrusted,
        label: label,
        kind: kind,
        bundleID: bundleID,
        appName: appName,
        watchSec: watchSec,
        intervalSec: intervalSec,
        samples: samples,
        distinctTitles: distinct,
        labelPresent: labelPresent,
        labelPresentExact: labelPresentExact,
        labelPresentAtFirstSample: labelAtFirst,
        sawCallPanel: sawPanel,
        anyAXValue: anyValue,
        anyAXIdentifier: anyIdent,
        looksIdle: looksIdle
    )

    guard let data = try? JSONEncoder().encode(capture),
          var line = String(data: data, encoding: .utf8) else {
        print("✗ Could not encode the capture. Nothing written.")
        exit(1)
    }
    line += "\n"

    let fm = FileManager.default
    try? fm.createDirectory(at: capturePath.deletingLastPathComponent(), withIntermediateDirectories: true)
    if let handle = try? FileHandle(forWritingTo: capturePath) {
        handle.seekToEndOfFile()
        handle.write(Data(line.utf8))
        try? handle.close()
    } else {
        try? Data(line.utf8).write(to: capturePath)
    }

    print("")
    print("Captured \(samples.count) distinct window-set snapshot(s), \(distinct.count) distinct title(s).")
    print("  meeting name present in a title: \(labelPresent ? "YES" : "NO")\(labelPresent && !labelPresentExact ? " (only after case/whitespace normalization)" : "")")
    print("  present already in the FIRST sample: \(labelAtFirst ? "YES" : "NO")  <- this is the moment the daemon resolves the title")
    print("  compact call panel (AXSystemDialog) seen: \(sawPanel ? "YES" : "NO")")
    print("  any window exposed AXValue / AXIdentifier: \(anyValue ? "YES" : "NO") / \(anyIdent ? "YES" : "NO")")
    if looksIdle {
        print("")
        print("⚠ Every captured title is just the app name, so Teams probably had no meeting")
        print("  window open. This record is written but the report will EXCLUDE it. Re-run")
        print("  during the call, with the meeting actually on screen at least once.")
    }
    print("")
    print("Appended to \(capturePath.path)")
    print("Corpus needed before a verdict: 3+ captures of one named series (same --label),")
    print("plus 1+ one-on-one and 1+ ad-hoc. Then run with --report.")
}

// MARK: - Report mode

func loadCaptures() -> [Capture] {
    guard let text = try? String(contentsOf: capturePath, encoding: .utf8) else {
        print("PRECONDITION  capture log: MISSING (\(capturePath.path))")
        print("")
        print("✗ Nothing to report on, and therefore no verdict.")
        print("  Run the capture mode during real meetings first; see the header of this")
        print("  script or docs/spikes/cal3-teams-window-title-series.md.")
        exit(1)
    }
    let decoder = JSONDecoder()
    var out: [Capture] = []
    for line in text.split(separator: "\n") {
        let trimmed = line.trimmingCharacters(in: .whitespaces)
        guard !trimmed.isEmpty else { continue }
        do {
            out.append(try decoder.decode(Capture.self, from: Data(trimmed.utf8)))
        } catch {
            // Say WHY. A silent skip here reads as "no captures yet" and would send
            // the owner off to re-record meetings that are already on disk.
            print("⚠ Skipping an unreadable capture line: \(error)")
        }
    }
    return out
}

/// The fixture wants `{bundle_id, state, expected, seeded, titles}` in that key
/// order, so this is hand-built rather than encoded, and the result pastes into
/// `daemon/Tests/MeetingPipeTests/Fixtures/window_titles.json` unedited.
///
/// `in_call_one_on_one` already exists in the fixture and is replaced by its
/// capture. The other two are new state names with no seeded counterpart, so
/// they are ADDED; see the paste note in `emitFixtureBlock`.
func fixtureState(for kind: String) -> String {
    switch kind {
    case "series": return "in_meeting_named_series"
    case "one-on-one": return "in_call_one_on_one"
    default: return "in_meeting_ad_hoc"
    }
}

func emitFixtureBlock(_ captures: [Capture]) {
    var used: [String: Int] = [:]
    var seenTitleSets: [[String]] = []
    var blocks: [String] = []
    for c in captures where !c.looksIdle && !c.distinctTitles.isEmpty {
        if seenTitleSets.contains(c.distinctTitles) { continue }
        seenTitleSets.append(c.distinctTitles)
        let base = fixtureState(for: c.kind)
        let n = (used[base] ?? 0) + 1
        used[base] = n
        let state = n == 1 ? base : "\(base)_\(n)"
        let titles = c.distinctTitles.map(jsonLiteral).joined(separator: ", ")
        blocks.append("""
            {
              "bundle_id": \(jsonLiteral(c.bundleID)),
              "state": \(jsonLiteral(state)),
              "expected": "unknown",
              "seeded": false,
              "titles": [\(titles)]
            }
        """)
    }

    print("")
    print("── window_titles.json entries: paste into `entries`. `seeded: false` is what ──")
    print("── flips the suite's captured count. `expected: \"unknown\"` is deliberate.     ──")
    guard !blocks.isEmpty else {
        print("    (no usable captures to emit)")
        print("── end ──")
        print("")
        return
    }
    let joined = blocks.joined(separator: ",\n")
    print(joined)
    print("── end ──")
    // Self-check: the point of this block is that it drops in without hand-editing,
    // so verify it really is valid JSON rather than trusting the string building.
    if (try? JSONSerialization.jsonObject(with: Data("[\(joined)]".utf8))) == nil {
        print("⚠ The block above did NOT parse as JSON. Report this; do not hand-fix it silently.")
    }
    print("")
    print("No trailing comma is emitted, so add one after the last pasted entry if other")
    print("entries follow it in the array.")
    print("")
    print("WHICH ROWS THIS REPLACES. `in_call_one_on_one` is already in the fixture, so its")
    print("capture replaces that seeded row. `in_meeting_named_series` and `in_meeting_ad_hoc`")
    print("are new state names with nothing to replace, so they are ADDED; decide deliberately")
    print("which of the seeded Teams rows they supersede rather than leaving guesses beside")
    print("real captures.")
    print("")
    print("WHY `expected` IS \"unknown\" AND NOT \"recognize\". A live meeting was in progress")
    print("for every one of these, so it is tempting to write \"recognize\". This probe cannot")
    print("know that: it carries no title pattern on purpose (see the header) and never calls")
    print("`MeetingSourceScanner.isActiveMeetingWindow`, so emitting \"recognize\" would assert a")
    print("value it did not compute, and the fixture suite hard-asserts what it is given. A real")
    print("Teams title that the recognizer REJECTS is precisely the outcome CAL3 exists on the")
    print("possibility of, and pasting it as \"recognize\" would turn weeks of capture into a red")
    print("suite on an unrelated commit. An \"unknown\" row is REPORTED by the suite, never")
    print("asserted: run `swift test --filter WindowRecognizerFixtureTests`, read what the")
    print("recognizer actually returned for each title, and only then write \"recognize\" or")
    print("\"reject\" by hand. A `reject` on a real captured title is a DET-band finding about")
    print("`isActiveMeetingWindow`, not a bad capture. File it; never edit a captured title to")
    print("make the suite green.")
}

func runReport() {
    let all = loadCaptures()
    let untrusted = all.filter { !$0.axTrusted }.count
    print("PRECONDITION  captures on file: \(all.count), taken with Accessibility granted: \(all.count - untrusted)")

    guard all.count > 0 else {
        print("")
        print("✗ No usable captures, so no verdict.")
        exit(1)
    }
    guard untrusted == 0 else {
        print("")
        print("✗ \(untrusted) capture(s) were taken WITHOUT Accessibility access. Refusing to")
        print("  emit a verdict: those records read zero windows for a permission reason, and")
        print("  folding them in would manufacture a NO-GO. Delete them from")
        print("  \(capturePath.path) and re-capture.")
        exit(2)
    }

    let idle = all.filter { $0.looksIdle }
    let usable = all.filter { !$0.looksIdle }
    if !idle.isEmpty {
        print("              excluded as idle-Teams captures (title was only the app name): \(idle.count)")
    }

    // Corpus adequacy. Every one of these is a reason to refuse a verdict, not a
    // reason to soften one.
    var seriesGroups: [String: [Capture]] = [:]
    for c in usable where c.kind == "series" {
        seriesGroups[normalize(c.label), default: []].append(c)
    }
    let qualifying = seriesGroups.filter { $0.value.count >= 3 }
    let oneOnOnes = usable.filter { $0.kind == "one-on-one" }
    let adHocs = usable.filter { $0.kind == "ad-hoc" }

    print("")
    print("CORPUS")
    for (label, group) in seriesGroups.sorted(by: { $0.key < $1.key }) {
        print("  series \"\(group[0].label)\": \(group.count) instance(s)\(group.count >= 3 ? "" : "   (needs 3)")")
        _ = label
    }
    print("  one-on-one: \(oneOnOnes.count)\(oneOnOnes.isEmpty ? "   (needs 1)" : "")")
    print("  ad-hoc:     \(adHocs.count)\(adHocs.isEmpty ? "   (needs 1)" : "")")

    var missing: [String] = []
    if qualifying.isEmpty { missing.append("3+ instances of ONE named recurring series (same --label)") }
    if oneOnOnes.isEmpty { missing.append("1+ one-on-one call") }
    if adHocs.isEmpty { missing.append("1+ ad-hoc call") }

    print("")
    print("OBSERVED TITLES  (<- marks the title carrying the meeting name; the subrole says")
    print("                  which window it was on, which is what leg 2's pick-a-title rule")
    print("                  has to key off, since at runtime the daemon sees one meeting and")
    print("                  cannot compute stability for itself)")
    for c in usable.sorted(by: { $0.capturedAt < $1.capturedAt }) {
        print("  [\(c.kind)] \"\(c.label)\"  name-in-title=\(c.labelPresent ? "yes" : "NO")  at-first-sample=\(c.labelPresentAtFirstSample ? "yes" : "no")  panel=\(c.sawCallPanel ? "yes" : "no")")
        let normLabel = normalize(c.label)
        for t in c.distinctTitles {
            var subroles: [String] = []
            for s in c.samples {
                for w in s.windows where w.title == t {
                    let sub = w.subrole ?? w.role ?? "?"
                    if !subroles.contains(sub) { subroles.append(sub) }
                }
            }
            let marker = normalize(t).contains(normLabel) ? "  <-" : ""
            print("        \(jsonLiteral(t))  [\(subroles.joined(separator: ", "))]\(marker)")
        }
    }

    guard missing.isEmpty else {
        print("")
        print("✗ NO VERDICT. The corpus is not big enough to answer either bar, and a verdict")
        print("  off an incomplete corpus is the exact failure this spike exists to avoid.")
        for m in missing { print("    still needed: \(m)") }
        emitFixtureBlock(usable)
        exit(3)
    }

    // The largest qualifying series is the one the bars are computed over.
    let series = qualifying.values.max(by: { $0.count < $1.count })!
    let seriesLabel = series[0].label
    let normSeriesLabel = normalize(seriesLabel)

    // Bar A, coverage. Pre-registered at 80%, reported over all usable captures
    // and over the series captures alone, because the two answer different
    // questions and the gap between them is what MARGINAL means.
    let aAllHits = usable.filter { $0.labelPresent }.count
    let aAllPct = pct(aAllHits, usable.count)
    let seriesCaps = usable.filter { $0.kind == "series" }
    let aSeriesHits = seriesCaps.filter { $0.labelPresent }.count
    let aSeriesPct = pct(aSeriesHits, seriesCaps.count)

    // Bar B, stability. The intersection of raw (byte-identical) title sets
    // across every instance of the series, restricted to titles that actually
    // carry the meeting's name. Without that restriction "Microsoft Teams" would
    // pass the bar and key every meeting to the same series.
    var stable = Set(series[0].distinctTitles)
    for c in series.dropFirst() { stable.formIntersection(c.distinctTitles) }
    let stableIdentifying = stable.filter { normalize($0).contains(normSeriesLabel) }.sorted()
    let barB = !stableIdentifying.isEmpty

    // Bar C, the negative control. If a 1:1 or an ad-hoc call emits a title
    // byte-identical to the series' stable title, an exact-match key merges
    // unrelated meetings, which is the failure AI7 turns into a silently
    // resolved commitment.
    var collisions: [String] = []
    for c in usable where c.kind != "series" {
        for t in c.distinctTitles where stableIdentifying.contains(t) {
            collisions.append("[\(c.kind)] \"\(c.label)\" -> \(jsonLiteral(t))")
        }
    }
    let barC = collisions.isEmpty

    print("")
    print("BARS (pre-registered in docs/spikes/cal3-teams-window-title-series.md, before any capture)")
    print("  A  meeting name present in some window title")
    print("       all captures:    \(aAllHits)/\(usable.count) = \(aAllPct)%   (bar: >= 80%)")
    print("       series captures: \(aSeriesHits)/\(seriesCaps.count) = \(aSeriesPct)%   (fallback bar: >= 80%)")
    print("  B  a name-bearing title byte-identical across all \(series.count) instances of \"\(seriesLabel)\": \(barB ? "PASS" : "FAIL")")
    for t in stableIdentifying { print("       stable: \(jsonLiteral(t))") }
    if !barB && !stable.isEmpty {
        print("       (titles stable across instances but NOT carrying the meeting name, which")
        print("        is why they cannot key a series:)")
        for t in stable.sorted() { print("       \(jsonLiteral(t))") }
    }
    print("  C  no non-series call emits one of those stable titles: \(barC ? "PASS" : "FAIL")")
    for c in collisions { print("       collision: \(c)") }

    let go = aAllPct >= 80 && barB && barC
    let marginal = !go && aSeriesPct >= 80 && barB && barC

    print("")
    if go {
        print("READ: GO. Teams window titles carry a stable series identity at the")
        print("      pre-registered bar. This authorizes CAL3 leg 2 (derive `series_key` in")
        print("      `MeetingMetaSidecar.build` by EXACT normalized match, no fuzzy inference)")
        print("      and then leg 3 in order: CAL2 first, then AI6, then AI7.")
        print("      Write the regex from the captured titles above, not from a guess, and pin")
        print("      one unit test per real captured title.")
    } else if marginal {
        print("READ: MARGINAL. Named recurring meetings carry their name (\(aSeriesPct)%), but across")
        print("      all meetings coverage is \(aAllPct)%, under the 80% bar. That is the")
        print("      pre-registered marginal case, and it authorizes a NARROWED build: leg 2")
        print("      exactly as specced (no title means no series key, which is already its")
        print("      rule), and leg 3's CAL2 leg only. HOLD AI6 and AI7 until the owner has")
        print("      eyeballed CAL2, because at this coverage most meetings still fall back to")
        print("      the workflow key, and the workflow fallback is precisely where AI7's")
        print("      over-merge risk lives.")
    } else {
        print("READ: NO-GO. This is an ACCEPTABLE, pre-registered outcome, not a failure to")
        print("      engineer around. Teams does not hand out a usable series identity here,")
        print("      so do NOT build legs 2 or 3, and do NOT reach for a substitute mechanism")
        print("      (fuzzy title similarity, attendee overlap, time-of-week regularity, or")
        print("      reading Teams' private storage). Each of those merges wrongly and does it")
        print("      silently.")
        print("      What it authorizes instead: narrow CAL2. A \"Last time\" card keyed by a")
        print("      105-meeting workflow shows an unrelated meeting's recap, which costs")
        print("      panel space AND falsely implies the two meetings are related, so showing")
        print("      nothing is strictly better. File that narrowing as its own task.")
    }
    print("")
    print("      Paste this whole output into docs/spikes/cal3-teams-window-title-series.md")
    print("      under \"Measured\", with the date. Do not restate the bars afterwards.")

    emitFixtureBlock(usable)
}

// MARK: - Dispatch

if reportMode {
    runReport()
} else {
    runCapture()
}
