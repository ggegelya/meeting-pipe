import ApplicationServices
import Foundation

/// AX references handed from the executable's AX walk into per-app adapters. `MeetingPipeCore` avoids
/// AX-tree traversal itself so it stays testable without accessibility-trust.
/// `leaveButton` is nil for browser adapters (browsers expose tab content as a single window; per-tab AX is unavailable).
public struct LifecycleAdapterHandle {
    public let leaveButton: AXUIElement?
    public let meetingWindow: AXUIElement?
    /// Fresh-tree-walk resolver for the live Leave button, injected by the daemon
    /// (it owns the AX walk). `AXLeaveButtonSignal` calls it before treating a stale
    /// `.invalid` read as a meeting end, so a Teams call-UI re-render recovers a live
    /// control instead of false-ending the call (TECH-END2, mirrors the MIC6 mute seam).
    public let resolveLeaveButton: (() -> AXUIElement?)?

    public init(
        leaveButton: AXUIElement? = nil,
        meetingWindow: AXUIElement? = nil,
        resolveLeaveButton: (() -> AXUIElement?)? = nil
    ) {
        self.leaveButton = leaveButton
        self.meetingWindow = meetingWindow
        self.resolveLeaveButton = resolveLeaveButton
    }
}

/// Per-app lifecycle adapter. Translates PRIMARY signal state changes into `PrimarySignalEvent`s for the coordinator's engine.
public protocol LifecycleAdapter: AnyObject {
    /// Bundle IDs served by this adapter. The coordinator dispatches to the first matching adapter.
    var bundleIDs: Set<String> { get }

    /// `.native` or `.browser`. Used by the coordinator to route contexts.
    var kind: MeetingLifecycleContext.Kind { get }

    /// END27: whether this adapter emits `processAudioIsRunningInput`, the one vetoer. The engine
    /// holds a reliable `.starting` end for that signal's first reading only when this is true, so
    /// an adapter that never emits it (browser, Webex, Slack) keeps ending `.starting` on arrival.
    var publishesProcessAudio: Bool { get }

    /// Whether this adapter handles `bundleID`. Default is exact match; browser adapter overrides to also accept
    /// Chromium PWA IDs whose `<browser>.app.<hash>` form can't be enumerated.
    func handles(bundleID: String) -> Bool

    /// Start observing. The adapter retains `sink` and calls it on every PRIMARY signal flip.
    func start(
        context: MeetingLifecycleContext,
        handle: LifecycleAdapterHandle,
        sink: @escaping (PrimarySignalEvent) -> Void
    ) throws

    func stop()

    /// Late-arm the Leave-button signal with a button re-walked at recording-start.
    /// Discovery-time walk usually misses the button because the call UI hasn't rendered yet.
    /// No-op when already armed; browser adapter's default is a no-op.
    func armLeaveButton(_ element: AXUIElement)

    /// END18: the hold's rescue. Re-assert an armed, healthy Leave button as a fresh live reading,
    /// or re-arm on `element`. Browser adapters have no Leave button; the default is a no-op.
    func rescueLeaveButton(_ element: AXUIElement)
}

public extension LifecycleAdapter {
    func handles(bundleID: String) -> Bool {
        bundleIDs.contains(bundleID)
    }

    var publishesProcessAudio: Bool { false }

    func armLeaveButton(_ element: AXUIElement) {}

    func rescueLeaveButton(_ element: AXUIElement) {}
}

/// Locale-tolerant title matchers for all meeting vendors. Single source of truth; adapters compose these per platform.
public enum MeetingTitlePatterns {

    /// Native Teams window recognizer, the ONE predicate both sides use (END24). The start side
    /// (`MeetingSourceScanner.isActiveMeetingWindow`) and the end side (`NativeLifecycleConfig.teams`,
    /// which uses it only to pick the call window to follow at engage) both call this, so they cannot
    /// drift again. They did: the end side kept a localised-"meeting"-token vocabulary while the
    /// start side went permissive, and from 2026-10-08 Teams' titles carried no token at all, so the
    /// end side read every call window gone (1,264 `shareable_content_no_match` rows, 4 chopped
    /// recordings before END14's veto).
    ///
    /// Permissive by design: Teams (May 2026) dropped the "Meeting in/with <X>" prefix, so a call
    /// window's title is just the topic ("Echo | Microsoft Teams", or bare "Echo"). Only well-known
    /// chrome surfaces are rejected, in both the bare and the "| Microsoft Teams" forms. A
    /// false positive here costs a recording into a stale thread, a false negative a call cut short.
    public static let teamsWindow: (String?) -> Bool = { title in
        guard let title else { return false }
        let lowered = title.lowercased().trimmingCharacters(in: .whitespaces)
        if teamsChrome.contains(lowered) { return false }
        if lowered.hasSuffix(teamsSuffix) {
            let lead = String(lowered.dropLast(teamsSuffix.count)).trimmingCharacters(in: .whitespaces)
            if lead.isEmpty { return false }                     // bare app chrome
            if teamsChrome.contains(lead) { return false }
            return true
        }
        // No suffix: Teams sometimes spawns the call window with just the topic. It cannot be told
        // from chrome by title alone; the chrome list filters the known surfaces, and an empty title
        // is inconclusive (the caller ORs across windows, so it contributes nothing).
        return !lowered.isEmpty
    }

    /// The shape class of a Teams window title, never the title itself (END24). Used to log what was
    /// locked and to rank the lock: `bare_single_segment` (no `|`, the call window's usual shape since
    /// 2026-10-08), `pipe_microsoft_teams_suffix` ("<x> | Microsoft Teams"), `chat_pipe_segment` (any
    /// other piped title, which is mostly the main window's "Chat | ..."), `chrome`, `empty`.
    public static func teamsWindowShape(_ title: String?) -> String {
        let lowered = (title ?? "").lowercased().trimmingCharacters(in: .whitespaces)
        if lowered.isEmpty { return "empty" }
        if !teamsWindow(title) { return "chrome" }
        if lowered.hasSuffix(teamsSuffix) { return "pipe_microsoft_teams_suffix" }
        if lowered.contains("|") { return "chat_pipe_segment" }
        return "bare_single_segment"
    }

    /// How the end side ranks the windows `teamsWindow` accepts when locking the call window (END24),
    /// lowest first: a bare single segment (the call window since 2026-10-08), then the older
    /// "<topic> | Microsoft Teams" call shape, then anything else. The main window's "Chat | ..." also
    /// passes the predicate, and locking it would keep the reading present for as long as Teams is
    /// open, so it is locked only when nothing better is on screen.
    public static let teamsLockRank: (String?) -> Int = { title in
        switch teamsWindowShape(title) {
        case "bare_single_segment": return 0
        case "pipe_microsoft_teams_suffix": return 1
        default: return 2
        }
    }

    private static let teamsSuffix = "| microsoft teams"

    private static let teamsChrome: Set<String> = [
        "microsoft teams", "teams", "calendar", "settings", "activity", "chat",
        "files", "apps", "store", "join meeting", "schedule meeting",
    ]

    /// Zoom: "Zoom Meeting", "Zoom -", localised "Reunion Zoom", or plain "Zoom" (older builds).
    public static let zoom: (String?) -> Bool = { title in
        guard let lowered = title?.lowercased() else { return false }
        return zoomTokens.contains { lowered.contains($0) }
    }

    /// Webex: "Webex Meetings" (classic) or the unified Webex App "Meeting"/"Reunion" stems shared with Teams.
    public static let webex: (String?) -> Bool = { title in
        guard let lowered = title?.lowercased() else { return false }
        for token in webexTokens where lowered.contains(token) {
            return true
        }
        for token in teamsTokens where lowered.contains(token) {
            return true
        }
        return false
    }

    /// Google Meet (browser tab): a live call tab carries the meeting code (`abc-defg-hij`: three-four-three
    /// lowercase letters) or the `meet.google.com` host. The earlier "meet" + "-" heuristic over-admitted any
    /// page title containing the word, e.g. "Level 10 Meeting - Jira" (the 2026-06-30 false prompt). The code is
    /// the distinctive in-room marker; the idle "Google Meet" lobby (no code) correctly reads not-live. Signal
    /// flips on transition off this pattern. Browser-only matcher (no native Meet adapter consumes it).
    public static let googleMeet: (String?) -> Bool = { title in
        guard let lowered = title?.lowercased() else { return false }
        if lowered.contains("meet.google.com") { return true }
        // END5: the bare 3-4-3 code alone over-admitted unrelated slugs ("one-more-day" is a
        // valid 3-4-3), so require the Meet brand alongside it. An ad-hoc room's tab title carries
        // "Meet" beside the code ("Meet - abc-defg-hij", "abc-defg-hij - Google Meet"); a random
        // hyphenated slug does not. A scheduled Meet carries no code at all, which this matcher
        // misses by construction: that shape is `googleMeetNamed` below (DET17), measured on the
        // captured shape classes in `browser_meet_title_shapes.json`. This makes `googleMeet` a strong, stands-alone start matcher (the
        // brand-token matchers below still need a live-audio corroborator at start).
        guard lowered.contains("meet") else { return false }
        return lowered.range(
            of: #"(?<![a-z])[a-z]{3}-[a-z]{4}-[a-z]{3}(?![a-z])"#,
            options: .regularExpression
        ) != nil
    }

    /// Google Meet, the scheduled-meeting shape (DET17): the brand word, a colon, then the meeting's
    /// name ("Meet: <name>", sometimes with Chrome's trailing speaker glyph), and no room code or host.
    /// On the work laptop this was the stable in-call title of 5 of 6 Chrome Meet calls, and
    /// `googleMeet` matched none of the 79 such titles captured on the four miss days.
    ///
    /// Anchored and whole-word on purpose: the title must START with the brand and its colon, so
    /// "Level 10 Meeting - Jira" (the 2026-06-30 false prompt), "Meeting notes", "Meet the team" and
    /// the bare word "Meet" cannot match, and the rest must carry a letter or digit, so a lone glyph
    /// after the colon does not either. A false prompt here costs a dismissal and never a recording:
    /// a browser source is never recorded without a click (DET17 guard 1).
    ///
    /// "Starts with Meet:" is not unique to Meet: a document titled after a meeting carries its
    /// app's suffix ("Meet: <name> - Google Docs", "... - Notion"), so a title ending in a known
    /// document app's suffix is refused. On the end side that matters more than on the start side,
    /// since this matcher is in `defaultTitleMatchers` too and a doc page on screen would otherwise
    /// keep a browser recording live until END17's lone dwell.
    public static let googleMeetNamed: (String?) -> Bool = { title in
        guard let lowered = title?.lowercased().trimmingCharacters(in: .whitespacesAndNewlines),
              lowered.hasPrefix("meet:") else { return false }
        if documentAppSuffixes.contains(where: { lowered.hasSuffix($0) }) { return false }
        return lowered.dropFirst("meet:".count).contains { $0.isLetter || $0.isNumber }
    }

    /// The page-title suffixes of document and tracker apps whose pages can be named "Meet: ...".
    private static let documentAppSuffixes: [String] = [
        " - google docs", " - google sheets", " - google slides", " - google drive",
        " - notion", " - confluence", " - jira", " - dropbox paper", " - quip", " - coda",
    ]

    /// Slack huddles: title contains "huddle" as a whole word, so a "team-huddles" channel name
    /// does not match (the trailing `s` is alphanumeric and fails the boundary). DET5 made this
    /// word-boundary to match the scanner's start-side recognizer, which now routes through this
    /// matcher, so discovery and end-detection cannot diverge.
    public static let slackHuddle: (String?) -> Bool = { title in
        guard let title, !title.isEmpty else { return false }
        return title.range(of: #"\bhuddle\b"#, options: [.regularExpression, .caseInsensitive]) != nil
    }

    /// Browser-tab Teams: keys off the "Microsoft Teams" brand suffix ("<subject> | Microsoft Teams").
    /// Unlike the native `teams` matcher it deliberately omits the bare localized "meeting" stem, which
    /// matches any page whose title merely contains the word (a Jira board named "Level 10 Meeting", a
    /// "Meeting notes" doc). Native Teams can afford the permissive stem because the scorer requires an
    /// in-call corroborator for natives; a browser title-match stands alone, so it must be brand-specific.
    public static let browserTeams: (String?) -> Bool = { title in
        guard let lowered = title?.lowercased() else { return false }
        return lowered.contains("microsoft teams")
    }

    /// Browser-tab Webex: keys off the "webex" brand, never the shared "meeting" stem (see `browserTeams`).
    public static let browserWebex: (String?) -> Bool = { title in
        guard let lowered = title?.lowercased() else { return false }
        return lowered.contains("webex")
    }

    private static let teamsTokens: [String] = [
        "meeting", "besprechung", "reunion", "reuniao", "encuentro",
        "встреча", "kokous", "spotkanie", "moot",
        // Universal " | Microsoft Teams" suffix: matches meeting windows whose subject lacks a meeting stem.
        "microsoft teams"
    ]

    private static let zoomTokens: [String] = [
        "zoom meeting", "zoom -", "reunion zoom", "zoom"
    ]

    private static let webexTokens: [String] = [
        "webex meetings", "webex meeting", "webex"
    ]
}
