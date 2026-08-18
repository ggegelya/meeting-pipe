#!/usr/bin/env swift
//
// DET6 probe: can a browser tab's real URL be read through an accessible channel,
// and is a live browser call's window title distinguishable from a document about
// the same product?
//
// Read-only. It observes the Accessibility tree of whatever registered browsers are
// running and writes exactly one file, its own capture log. It never touches the
// meeting library, the config, or any sidecar, and it changes no production code, so
// it is safe to run during a real meeting.
//
// WHY THIS EXISTS. A meeting held in a plain browser tab is only detected if it is
// Google Meet. `MeetingSourceScanner.decideBrowserAdmission` admits on a URL fragment
// or a strong title, and neither reaches the other products:
// `BrowserMeetingLifecycleAdapter.strongTitleMatchers` holds exactly one entry
// (`MeetingTitlePatterns.googleMeet`), and the fragment disjunct is checked against the
// AX WINDOW TITLE, which browsers fill with the page title and never the URL. So a
// browser tab running Teams, Webex or a Slack huddle matches weakly and is refused.
//
// THE FIX IS UNKNOWN UNTIL SOMETHING IS MEASURED, WHICH IS THE WHOLE POINT. Widening
// the strong matchers to a bare `contains("webex")` reopens the doc-title false start
// END5 closed on purpose, so the two questions below have to be answered against real
// browsers before any widening. Read
// `docs/spikes/det6-browser-url-readability.md` before running this; the verdict
// thresholds were written down before any measurement and are not to be refitted
// afterwards.
//
// THE TWO QUESTIONS, and neither can be answered from inside a coding harness:
//
//   LEG 1, URL READABILITY. Does any accessible channel carry the tab's real URL?
//     Three candidates, probed in this order: the address bar's AXValue, the web
//     area's AXURL, and the web area's AXDocument. If any of them yields the URL for
//     the registered browsers, then the fragment check can be repointed at the URL it
//     was always meant to read, and the existing `browserURLFragments` list fixes
//     Teams, Zoom and Webex in one move with no new title heuristics. This is the
//     outcome to hope for.
//
//   LEG 2, TITLE DISTINGUISHABILITY. Is a live call's window title separable from a
//     page about the same product? Capture titles during a real browser call, then
//     capture titles on a doc page mentioning the same brand, and compare. If calls
//     carry a stable structural marker the docs never do, a strong matcher can be
//     added per product the way `googleMeet` has one.
//
// SO THIS PROBE CARRIES NO CANDIDATE TITLE PATTERN AND NO CANDIDATE URL SELECTOR, ON
// PURPOSE. It does not know what a Teams call tab is called and does not guess at the
// address bar's AXIdentifier. It dumps every text field it finds in the window chrome
// with its role, subrole, identifier and description, and it reports which of them held
// something URL-shaped. Choosing the selector is the analysis doc's job, from what this
// prints, and not this file's.
//
// USAGE. Capture once per situation, naming the product and whether this is a live call
// or a page about the product:
//
//   swift daemon/scripts/det6-browser-url-probe.swift --product teams --kind call
//   swift daemon/scripts/det6-browser-url-probe.swift --product teams --kind doc
//   swift daemon/scripts/det6-browser-url-probe.swift --product webex --kind call
//
// Run the `call` captures with the call actually joined and the meeting tab frontmost,
// and the `doc` captures with an ordinary page about that product frontmost (a vendor
// marketing page, a comparison article, a "meeting notes" doc). Then:
//
//   swift daemon/scripts/det6-browser-url-probe.swift --report
//
// which prints both legs against the pre-registered bars.
//
// REQUIRES Accessibility permission for whatever runs it: System Settings ->
// Privacy & Security -> Accessibility -> enable Terminal (or your IDE), then re-run. If
// it is not granted this probe REFUSES to capture and REFUSES to print a verdict,
// rather than reporting an empty read as a real NO-GO. An untrusted process reads zero
// windows and zero attributes from every browser, and that false zero is
// indistinguishable from a genuine "the URL is not exposed" (the CAL1 false-zero lesson,
// restated by DET2: a void measurement that agrees with the expected answer is the
// easiest kind to bank by mistake). Note that a script launched from an agent or any
// other disclaimed parent inherits that parent's TCC identity and can report NOT GRANTED
// even when Terminal is ticked, so run it from a Terminal window you opened yourself.
//
// PRIVACY. Browser URLs and page titles are the most sensitive thing on the machine, and
// the capture log lands under `docs/spikes/`, which is a git tree. By default the log
// records a URL's scheme, host and FIRST path segment only, which is all either bar
// needs (`teams.microsoft.com`, `zoom.us/j/`). The full string is printed to your own
// terminal as it is read, so you can see what was there without it being written down.
// `--full-urls` opts into recording whole URLs; use it only if a near-miss needs
// diagnosing, and redact before committing. Window titles are recorded in full, because
// leg 2 is a question about their exact shape.
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
    return repoRoot.appendingPathComponent("docs/spikes/det6-browser-captures.jsonl")
}()

let reportMode = hasFlag("--report")
let recordFullURLs = hasFlag("--full-urls")
let watchSec = doubleArg("--watch", default: 20)
let intervalSec = max(0.5, doubleArg("--interval", default: 2))

/// Products the two bars are computed per. `other` exists so a capture is never blocked
/// on this list being right; it just does not participate in a per-product verdict.
let validProducts = ["meet", "teams", "webex", "slack", "zoom", "other"]
let validKinds = ["call", "doc"]

/// The browsers `meeting_apps.toml [browser.bundles]` registers, which is exactly the set
/// the admission gate applies to. Copied here rather than parsed, so the probe needs no app
/// bundle and no TOMLKit. Nothing fences this copy against the TOML, so if a browser is
/// added there and a capture finds it missing here, fix this list; the production pair is
/// fenced by `MeetingAppRegistryFenceTests` and is the side that is right.
let browserBundleIDs: [String] = [
    "com.apple.Safari",
    "com.google.Chrome",
    "com.google.Chrome.canary",
    "com.brave.Browser",
    "company.thebrowser.Browser",
    "com.microsoft.edgemac",
    "org.mozilla.firefox",
    "com.vivaldi.Vivaldi",
    "com.operasoftware.Opera",
    "com.kagi.kagimacOS",
]

/// `browser.url_fragments` from `meeting_apps.toml`, the list the fragment check already
/// holds. Leg 1's bar is whether a readable URL would match one of THESE, not whether a
/// URL is readable in the abstract, because a readable URL that matches nothing fixes
/// nothing.
let registeredURLFragments: [String] = [
    "meet.google.com",
    "teams.microsoft.com",
    "teams.live.com",
    "zoom.us/j/",
    "zoom.us/wc/",
    "webex.com/meet",
    "webex.com/wbxmjs",
]

// MARK: - Capture model

// Keys are spelled out rather than derived by a key strategy. `convertToSnakeCase` and
// `convertFromSnakeCase` are NOT inverses over an acronym ("bundleID" encodes to
// "bundle_id" but decodes back to "bundleId"), so the strategy pair writes a capture log
// it cannot read. The CAL3 probe carries the same note for the same reason.

/// One accessible channel that might carry a URL, and what it actually held.
struct URLChannel: Codable {
    /// `address_bar_value`, `web_area_url`, or `web_area_document`.
    let channel: String
    /// AX role of the element the value came off, for identifying it later.
    let role: String?
    let subrole: String?
    let axIdentifier: String?
    let axDescription: String?
    /// True when the attribute resolved to a non-empty string at all.
    let resolved: Bool
    /// The value, redacted to scheme + host + first path segment unless `--full-urls`.
    let value: String?
    /// True when the value looks like a URL (has a scheme and a host).
    let looksLikeURL: Bool
    /// The registered `browser.url_fragments` entry this value contains, if any. This is
    /// the field leg 1's bar is computed over.
    let matchedFragment: String?

    enum CodingKeys: String, CodingKey {
        case channel, role, subrole, resolved, value
        case axIdentifier = "ax_identifier"
        case axDescription = "ax_description"
        case looksLikeURL = "looks_like_url"
        case matchedFragment = "matched_fragment"
    }
}

/// One running browser at one moment.
struct BrowserSnapshot: Codable {
    let bundleID: String
    let appName: String
    let isFrontmost: Bool
    let windowTitles: [String]
    /// Every text field found in the bounded chrome walk, whether or not it held a URL.
    /// Present so a NO-GO on leg 1 can be told apart from "the walk never found the
    /// address bar", which are different findings with different follow-ups.
    let textFieldsSeen: Int
    let channels: [URLChannel]

    enum CodingKeys: String, CodingKey {
        case channels
        case bundleID = "bundle_id"
        case appName = "app_name"
        case isFrontmost = "is_frontmost"
        case windowTitles = "window_titles"
        case textFieldsSeen = "text_fields_seen"
    }
}

struct Sample: Codable {
    let atSec: Double
    let browsers: [BrowserSnapshot]

    enum CodingKeys: String, CodingKey {
        case browsers
        case atSec = "at_sec"
    }
}

struct Capture: Codable {
    let probeVersion: Int
    let capturedAt: String
    let axTrusted: Bool
    let product: String
    let kind: String
    let fullURLsRecorded: Bool
    let watchSec: Double
    let intervalSec: Double
    let samples: [Sample]
    /// Union of every window title seen across the samples, deduplicated.
    let distinctTitles: [String]
    /// True when any channel in any sample matched a registered URL fragment. Leg 1's
    /// per-capture result.
    let anyFragmentMatch: Bool
    /// The channel names that resolved to a URL-shaped string at least once. Leg 1's
    /// "which channel" answer.
    let resolvingChannels: [String]

    enum CodingKeys: String, CodingKey {
        case product, kind, samples
        case probeVersion = "probe_version"
        case capturedAt = "captured_at"
        case axTrusted = "ax_trusted"
        case fullURLsRecorded = "full_urls_recorded"
        case watchSec = "watch_sec"
        case intervalSec = "interval_sec"
        case distinctTitles = "distinct_titles"
        case anyFragmentMatch = "any_fragment_match"
        case resolvingChannels = "resolving_channels"
    }
}

// MARK: - Text helpers

func normalize(_ s: String) -> String {
    s.lowercased()
        .components(separatedBy: .whitespacesAndNewlines)
        .filter { !$0.isEmpty }
        .joined(separator: " ")
}

/// Scheme + host + first path segment, which is everything either bar needs and nothing
/// more. `https://teams.microsoft.com/l/meetup-join/19:abc@thread/0?context=…` becomes
/// `https://teams.microsoft.com/l/…`.
func redactURL(_ raw: String) -> String {
    guard let comps = URLComponents(string: raw), let host = comps.host else {
        // Not parseable as a URL: keep only the leading run, never the whole string.
        return String(raw.prefix(24)) + (raw.count > 24 ? "…" : "")
    }
    let scheme = comps.scheme.map { "\($0)://" } ?? ""
    let segments = comps.path.split(separator: "/")
    guard let first = segments.first else { return scheme + host }
    let tail = segments.count > 1 ? "/…" : ""
    return scheme + host + "/" + first + tail
}

func looksLikeURL(_ raw: String) -> Bool {
    guard let comps = URLComponents(string: raw), let host = comps.host, !host.isEmpty else {
        return false
    }
    return comps.scheme != nil
}

func matchedFragment(in raw: String) -> String? {
    let lowered = raw.lowercased()
    return registeredURLFragments.first { lowered.contains($0) }
}

// MARK: - AX helpers

/// AX reads are synchronous IPC into another process and a wedged browser can hang the
/// caller indefinitely. Every element this probe creates gets a short messaging timeout,
/// so a stuck browser costs a second and a missing value rather than the whole run.
let axTimeoutSec: Float = 1.0

func axString(_ element: AXUIElement, _ attribute: String) -> String? {
    var ref: CFTypeRef?
    guard AXUIElementCopyAttributeValue(element, attribute as CFString, &ref) == .success else {
        return nil
    }
    if let s = ref as? String, !s.isEmpty { return s }
    if let u = ref as? URL { return u.absoluteString }
    return nil
}

func axChildren(_ element: AXUIElement) -> [AXUIElement] {
    var ref: CFTypeRef?
    guard AXUIElementCopyAttributeValue(element, kAXChildrenAttribute as CFString, &ref) == .success,
          let kids = ref as? [AXUIElement] else {
        return []
    }
    return kids
}

/// A browser's AX tree contains the entire rendered page, which for a busy tab is tens of
/// thousands of nodes and minutes of IPC. Both walks below are bounded twice, by depth and
/// by a node budget, and a hit on the budget is reported rather than swallowed: an
/// exhausted budget is "not found here", never "not present".
struct WalkBudget {
    var nodesVisited = 0
    let maxNodes: Int
    let maxDepth: Int

    mutating func spend() -> Bool {
        nodesVisited += 1
        return nodesVisited <= maxNodes
    }
}

/// Collect elements matching `predicate` in a bounded breadth-first walk from `root`.
func bfs(
    from root: AXUIElement,
    budget: inout WalkBudget,
    matching predicate: (AXUIElement, String?) -> Bool
) -> [AXUIElement] {
    var found: [AXUIElement] = []
    var frontier: [(AXUIElement, Int)] = [(root, 0)]
    while !frontier.isEmpty {
        var next: [(AXUIElement, Int)] = []
        for (element, depth) in frontier {
            guard budget.spend() else { return found }
            let role = axString(element, kAXRoleAttribute as String)
            if predicate(element, role) { found.append(element) }
            guard depth < budget.maxDepth else { continue }
            for child in axChildren(element) {
                next.append((child, depth + 1))
            }
        }
        frontier = next
    }
    return found
}

/// The address bar lives in the window chrome, a handful of levels below the window, and
/// never inside the page. A shallow walk keeps this off the rendered content entirely.
let chromeWalk = (maxDepth: 6, maxNodes: 3_000)

/// The web area is the root of the rendered page and sits just below the chrome. Found by
/// role, so the walk can stop the moment it is reached without descending into the page.
let webAreaWalk = (maxDepth: 12, maxNodes: 8_000)

func describe(_ element: AXUIElement) -> (role: String?, subrole: String?, identifier: String?, description: String?) {
    (
        axString(element, kAXRoleAttribute as String),
        axString(element, kAXSubroleAttribute as String),
        axString(element, kAXIdentifierAttribute as String),
        axString(element, kAXDescriptionAttribute as String)
    )
}

func channel(
    _ name: String,
    from element: AXUIElement,
    raw: String?
) -> URLChannel {
    let meta = describe(element)
    guard let raw = raw, !raw.isEmpty else {
        return URLChannel(
            channel: name,
            role: meta.role,
            subrole: meta.subrole,
            axIdentifier: meta.identifier,
            axDescription: meta.description,
            resolved: false,
            value: nil,
            looksLikeURL: false,
            matchedFragment: nil
        )
    }
    return URLChannel(
        channel: name,
        role: meta.role,
        subrole: meta.subrole,
        axIdentifier: meta.identifier,
        axDescription: meta.description,
        resolved: true,
        value: recordFullURLs ? raw : redactURL(raw),
        looksLikeURL: looksLikeURL(raw),
        matchedFragment: matchedFragment(in: raw)
    )
}

/// Read every URL-bearing channel this browser process exposes right now.
///
/// It deliberately probes by SHAPE rather than by a known selector: every text field in
/// the window chrome is read, not just one whose AXIdentifier matches a value this file
/// guessed. If Chrome's omnibox identifier changes, or Safari's differs, or Firefox has
/// none at all, the probe still finds the field and the report says which identifier it
/// carried. That is the measurement; hardcoding the identifier would be the assumption.
func readURLChannels(pid: pid_t) -> (channels: [URLChannel], textFieldsSeen: Int) {
    let axApp = AXUIElementCreateApplication(pid)
    AXUIElementSetMessagingTimeout(axApp, axTimeoutSec)

    var windowsRef: CFTypeRef?
    guard AXUIElementCopyAttributeValue(axApp, kAXWindowsAttribute as CFString, &windowsRef) == .success,
          let windows = windowsRef as? [AXUIElement] else {
        return ([], 0)
    }

    var channels: [URLChannel] = []
    var textFieldsSeen = 0

    for window in windows {
        AXUIElementSetMessagingTimeout(window, axTimeoutSec)

        var chromeBudget = WalkBudget(maxNodes: chromeWalk.maxNodes, maxDepth: chromeWalk.maxDepth)
        let textFields = bfs(from: window, budget: &chromeBudget) { _, role in
            role == (kAXTextFieldRole as String) || role == "AXComboBox"
        }
        textFieldsSeen += textFields.count
        for field in textFields {
            channels.append(channel(
                "address_bar_value",
                from: field,
                raw: axString(field, kAXValueAttribute as String)
            ))
        }

        var pageBudget = WalkBudget(maxNodes: webAreaWalk.maxNodes, maxDepth: webAreaWalk.maxDepth)
        let webAreas = bfs(from: window, budget: &pageBudget) { _, role in
            role == "AXWebArea"
        }
        for area in webAreas {
            channels.append(channel(
                "web_area_url",
                from: area,
                raw: axString(area, "AXURL")
            ))
            channels.append(channel(
                "web_area_document",
                from: area,
                raw: axString(area, kAXDocumentAttribute as String)
            ))
        }
    }

    return (channels, textFieldsSeen)
}

func collectWindowTitles(pid: pid_t) -> [String] {
    let axApp = AXUIElementCreateApplication(pid)
    AXUIElementSetMessagingTimeout(axApp, axTimeoutSec)
    var windowsRef: CFTypeRef?
    guard AXUIElementCopyAttributeValue(axApp, kAXWindowsAttribute as CFString, &windowsRef) == .success,
          let windows = windowsRef as? [AXUIElement] else {
        return []
    }
    return windows.compactMap { axString($0, kAXTitleAttribute as String) }
}

// MARK: - Preconditions, printed before anything else

let axTrusted = AXIsProcessTrusted()

print("DET6 browser URL + title probe (read-only)")
print("")

if !reportMode {
    print("PRECONDITION  Accessibility access for this process: \(axTrusted ? "GRANTED" : "NOT GRANTED")")
    guard axTrusted else {
        print("")
        print("✗ Refusing to capture, and refusing to emit any verdict.")
        print("  An Accessibility-untrusted process reads ZERO windows and ZERO attributes from")
        print("  every browser, so both legs would come back empty. That empty read is")
        print("  indistinguishable from a real \"the URL is not exposed\" result, and it agrees")
        print("  with the answer this task half expects, which is exactly the kind of void")
        print("  measurement that gets banked by mistake (the DET2 lesson).")
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
    guard let product = stringArg("--product"), validProducts.contains(product) else {
        print("")
        print("✗ --product is required and must be one of: \(validProducts.joined(separator: ", "))")
        print("  It names which meeting product the frontmost tab is about, so leg 2 can compare")
        print("  a live call against a document for the SAME product. Comparing across products")
        print("  measures nothing.")
        exit(1)
    }
    guard let kind = stringArg("--kind"), validKinds.contains(kind) else {
        print("")
        print("✗ --kind is required and must be one of: \(validKinds.joined(separator: ", "))")
        print("  Use `call` with the meeting actually joined and its tab frontmost. Use `doc`")
        print("  with an ordinary page ABOUT that product frontmost (a vendor page, a comparison")
        print("  article, a meeting-notes doc). Leg 2's whole question is whether those two are")
        print("  separable, so a corpus with only one of them cannot produce a verdict.")
        exit(1)
    }

    let running = NSWorkspace.shared.runningApplications.filter {
        browserBundleIDs.contains($0.bundleIdentifier ?? "")
    }
    guard !running.isEmpty else {
        print("")
        print("✗ No registered browser is running.")
        print("  Looked for: \(browserBundleIDs.joined(separator: ", "))")
        print("  The admission gate this probe measures applies to exactly those bundle IDs, so")
        print("  a capture with none of them running would measure nothing. Open the browser")
        print("  holding the call (or the document) and re-run.")
        exit(1)
    }

    print("              browsers running: \(running.compactMap(\.bundleIdentifier).joined(separator: ", "))")
    print("")
    print("Capturing \(product) / \(kind) for \(Int(watchSec))s, every \(intervalSec)s.")
    if kind == "call" {
        print("Join the call and leave its tab frontmost. Carry on with the meeting.")
    } else {
        print("Leave the page about \(product) frontmost.")
    }
    if !recordFullURLs {
        print("URLs are printed here in full and recorded redacted (scheme + host + first path")
        print("segment). Pass --full-urls to record them whole.")
    }
    print("")

    let start = Date()
    var samples: [Sample] = []
    while Date().timeIntervalSince(start) < watchSec {
        let frontmost = NSWorkspace.shared.frontmostApplication?.bundleIdentifier
        var snapshots: [BrowserSnapshot] = []
        for app in NSWorkspace.shared.runningApplications
        where browserBundleIDs.contains(app.bundleIdentifier ?? "") {
            let pid = app.processIdentifier
            let bundleID = app.bundleIdentifier ?? "?"
            let read = readURLChannels(pid: pid)
            let titles = collectWindowTitles(pid: pid)
            snapshots.append(BrowserSnapshot(
                bundleID: bundleID,
                appName: app.localizedName ?? bundleID,
                isFrontmost: bundleID == frontmost,
                windowTitles: titles,
                textFieldsSeen: read.textFieldsSeen,
                channels: read.channels
            ))
        }
        samples.append(Sample(atSec: Date().timeIntervalSince(start), browsers: snapshots))

        let hits = samples.last?.browsers.flatMap(\.channels).filter(\.looksLikeURL) ?? []
        print("  t=\(Int(Date().timeIntervalSince(start)))s  "
            + "titles=\(samples.last?.browsers.flatMap(\.windowTitles).count ?? 0)  "
            + "url-shaped reads=\(hits.count)")
        for hit in hits {
            print("      \(hit.channel) [\(hit.axIdentifier ?? hit.role ?? "?")] -> \(hit.value ?? "")")
        }

        Thread.sleep(forTimeInterval: intervalSec)
    }

    let allChannels = samples.flatMap { $0.browsers.flatMap(\.channels) }
    let allTitles = samples.flatMap { $0.browsers.flatMap(\.windowTitles) }
    var seenTitles = Set<String>()
    let distinctTitles = allTitles.filter { seenTitles.insert($0).inserted }
    var seenChannels = Set<String>()
    let resolvingChannels = allChannels
        .filter(\.looksLikeURL)
        .map(\.channel)
        .filter { seenChannels.insert($0).inserted }

    let capture = Capture(
        probeVersion: 1,
        capturedAt: ISO8601DateFormatter().string(from: start),
        axTrusted: axTrusted,
        product: product,
        kind: kind,
        fullURLsRecorded: recordFullURLs,
        watchSec: watchSec,
        intervalSec: intervalSec,
        samples: samples,
        distinctTitles: distinctTitles,
        anyFragmentMatch: allChannels.contains { $0.matchedFragment != nil },
        resolvingChannels: resolvingChannels
    )

    let encoder = JSONEncoder()
    encoder.outputFormatting = [.sortedKeys]
    guard let data = try? encoder.encode(capture),
          let line = String(data: data, encoding: .utf8) else {
        print("")
        print("✗ Could not encode the capture. Nothing written.")
        exit(1)
    }

    let fm = FileManager.default
    try? fm.createDirectory(
        at: capturePath.deletingLastPathComponent(),
        withIntermediateDirectories: true
    )
    if let handle = try? FileHandle(forWritingTo: capturePath) {
        handle.seekToEndOfFile()
        handle.write(Data((line + "\n").utf8))
        try? handle.close()
    } else {
        try? Data((line + "\n").utf8).write(to: capturePath)
    }

    print("")
    print("Wrote 1 capture to \(capturePath.path)")
    print("  distinct window titles: \(distinctTitles.count)")
    print("  channels that resolved to a URL: "
        + (resolvingChannels.isEmpty ? "none" : resolvingChannels.joined(separator: ", ")))
    print("  matched a registered browser.url_fragments entry: \(capture.anyFragmentMatch ? "YES" : "no")")
    print("")
    print("Capture the other side too (`--kind \(kind == "call" ? "doc" : "call")`), then run --report.")
}

// MARK: - Report mode

func loadCaptures() -> [Capture] {
    guard let text = try? String(contentsOf: capturePath, encoding: .utf8) else {
        print("PRECONDITION  capture log: MISSING (\(capturePath.path))")
        print("")
        print("✗ Refusing to emit a verdict with no captures.")
        print("  Run the probe during a live browser call first; see the usage header.")
        exit(1)
    }
    let decoder = JSONDecoder()
    return text
        .split(separator: "\n")
        .compactMap { try? decoder.decode(Capture.self, from: Data($0.utf8)) }
}

/// Leg 1's bar, pre-registered in `docs/spikes/det6-browser-url-readability.md`:
/// at least one accessible channel yields a string that contains a registered
/// `browser.url_fragments` entry, in at least TWO separate captures, on at least one
/// browser. Two captures rather than one because a single read cannot separate a real
/// channel from a transient (a focused omnibox showing the typed text, say).
let leg1MinimumCaptures = 2

/// Leg 2's bar: for one product, a token appears in EVERY `call` title and in NO `doc`
/// title, with at least two captures on each side. One call and one doc cannot tell a
/// marker apart from a coincidence of that particular page.
let leg2MinimumPerSide = 2

func tokens(of title: String) -> Set<String> {
    Set(
        normalize(title)
            .components(separatedBy: CharacterSet.alphanumerics.inverted)
            .filter { $0.count >= 3 }
    )
}

func runReport() {
    let all = loadCaptures()
    let untrusted = all.filter { !$0.axTrusted }.count
    print("PRECONDITION  captures on file: \(all.count), taken with Accessibility granted: \(all.count - untrusted)")
    if untrusted > 0 {
        print("              \(untrusted) capture(s) were taken WITHOUT Accessibility and are excluded.")
    }
    let usable = all.filter(\.axTrusted)
    print("")

    guard !usable.isEmpty else {
        print("✗ Refusing to emit a verdict: no capture was taken with Accessibility granted.")
        print("  Every such capture reads zero windows, so the corpus measures the permission")
        print("  rather than the browsers.")
        exit(1)
    }

    // ---- LEG 1: URL readability ----
    print("LEG 1  Is the tab's real URL readable through an accessible channel?")
    print("")
    var perChannelHits: [String: Int] = [:]
    var identifiersSeen: [String: Set<String>] = [:]
    for capture in usable {
        var channelsHitHere = Set<String>()
        for sample in capture.samples {
            for browser in sample.browsers {
                for ch in browser.channels where ch.matchedFragment != nil {
                    channelsHitHere.insert(ch.channel)
                    identifiersSeen[ch.channel, default: []].insert(ch.axIdentifier ?? ch.role ?? "?")
                }
            }
        }
        for name in channelsHitHere { perChannelHits[name, default: 0] += 1 }
    }
    if perChannelHits.isEmpty {
        print("  No channel ever produced a string containing a registered url_fragments entry.")
    }
    for (name, count) in perChannelHits.sorted(by: { $0.key < $1.key }) {
        let ids = identifiersSeen[name]?.sorted().joined(separator: ", ") ?? "?"
        print("  \(name): matched in \(count) capture(s)  [\(ids)]")
    }
    let leg1Pass = perChannelHits.values.contains { $0 >= leg1MinimumCaptures }
    print("")
    print("  Bar: a channel matches a registered fragment in >= \(leg1MinimumCaptures) captures.")
    print("  LEG 1 VERDICT: \(leg1Pass ? "GO, the URL is readable" : "NO-GO, no channel carries it")")
    print("")

    // ---- LEG 2: title distinguishability ----
    print("LEG 2  Is a live call's title separable from a document about the same product?")
    print("")
    var leg2Pass = false
    var leg2Detail: [String] = []
    let products = Set(usable.map(\.product)).sorted()
    for product in products where product != "other" {
        let calls = usable.filter { $0.product == product && $0.kind == "call" }
        let docs = usable.filter { $0.product == product && $0.kind == "doc" }
        guard calls.count >= leg2MinimumPerSide, docs.count >= leg2MinimumPerSide else {
            print("  \(product): \(calls.count) call / \(docs.count) doc captures, "
                + "below the \(leg2MinimumPerSide)-each bar. No verdict for this product.")
            continue
        }
        let callTokenSets = calls.map { capture in
            capture.distinctTitles.reduce(into: Set<String>()) { $0.formUnion(tokens(of: $1)) }
        }
        let docTokens = docs.reduce(into: Set<String>()) { acc, capture in
            for title in capture.distinctTitles { acc.formUnion(tokens(of: title)) }
        }
        var common = callTokenSets.first ?? []
        for set in callTokenSets.dropFirst() { common.formIntersection(set) }
        let discriminating = common.subtracting(docTokens).sorted()
        if discriminating.isEmpty {
            print("  \(product): no token is in every call title and absent from every doc title.")
        } else {
            leg2Pass = true
            leg2Detail.append("\(product): \(discriminating.joined(separator: ", "))")
            print("  \(product): discriminating tokens -> \(discriminating.joined(separator: ", "))")
        }
    }
    print("")
    print("  Bar: >= \(leg2MinimumPerSide) call and \(leg2MinimumPerSide) doc captures for one product,")
    print("       and a token in every call title that is in no doc title.")
    print("  LEG 2 VERDICT: \(leg2Pass ? "GO, a per-product strong matcher is buildable" : "NO-GO, no stable marker")")
    print("")

    // ---- The pre-registered verdict tree ----
    print("VERDICT TREE (pre-registered in docs/spikes/det6-browser-url-readability.md)")
    print("")
    if leg1Pass {
        print("  BRANCH A. The URL is readable, so repoint the fragment check at the URL it was")
        print("  always meant to read. `MeetingSourceScanner.decideBrowserAdmission` takes the")
        print("  URL alongside the titles, the existing browser.url_fragments list fixes Teams,")
        print("  Zoom and Webex in one move, and no new title heuristic is invented. Add the")
        print("  missing Slack fragment while there.")
        print("  Channel to read: \(perChannelHits.filter { $0.value >= leg1MinimumCaptures }.keys.sorted().joined(separator: ", "))")
    } else if leg2Pass {
        print("  BRANCH B. The URL is not readable but the title is discriminating, so add a")
        print("  per-product entry to `BrowserMeetingLifecycleAdapter.strongTitleMatchers`, one")
        print("  per product that cleared the bar, keyed on the discriminating structure below")
        print("  and never on the bare brand token. Add the missing Zoom defaultTitleMatchers")
        print("  entry while there.")
        for detail in leg2Detail { print("  \(detail)") }
    } else {
        print("  BRANCH C. Neither leg cleared. Close the widening leg and document the")
        print("  limitation as permanent: a browser tab hosting Teams, Webex, Slack or Zoom")
        print("  cannot be told from a page about that product by any signal available here,")
        print("  and admitting it would reopen END5's doc-title false start. The")
        print("  `browser_tab_rejected` event stays as the record of what is being missed.")
    }
    print("")
    print("Neither leg is refittable after the fact: the bars above are the ones written down")
    print("before any capture existed. If a bar looks wrong, say so in the doc rather than")
    print("moving it.")

    // Exit 0 when a branch of the tree is actionable (A or B), 3 when the answer is
    // branch C. A NO-GO is a pre-registered acceptable outcome, so 3 marks it rather
    // than failing.
    exit(leg1Pass || leg2Pass ? 0 : 3)
}

// MARK: - Entry

if reportMode {
    runReport()
} else {
    runCapture()
}
