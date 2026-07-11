import AppKit
import ApplicationServices
import Foundation
import MeetingPipeCore
import TOMLKit

/// Cold-start discovery scan: enumerate every concurrent meeting-app contender, score them, return the winner (TECH-C13 step 5). Lifted out of `Detector` so `Detector` and `MeetingDiscoveryWatcher` share one scan path. Carries no timing or state; owner provides the queue. Only retained state is the sticky-winner pin for the scorer's recency tie-break.
final class MeetingSourceScanner {

    /// Outcome of one scan pass.
    struct Result {
        /// Highest-scoring candidate above the disambiguation floor, or nil.
        let winner: MeetingSourceCandidate?
        let candidateCount: Int
        /// True when `winner` differs from the previous pass, so callers can log a winner-change without re-deriving it.
        let winnerChanged: Bool
    }

    /// Known native meeting-app bundle IDs from `meeting_apps.toml`.
    let nativeBundles: Set<String>
    /// Known browser bundle IDs that can host a meeting tab.
    let browserBundles: Set<String>
    /// Meeting-URL fragments used to recognise a browser meeting tab.
    let browserURLFragments: [String]

    /// Loaded once per process; failure degrades `muteButton` to false (other signals carry).
    private static let muteCatalogue: MuteLabels? = {
        do {
            return try MuteLabelsLoader.loadDefault()
        } catch {
            return nil
        }
    }()

    /// Last scan's winner for the scorer's sticky-bonus tie-break (TECH-C15).
    private var lastScorerWinner: AppSource?

    init() {
        let apps = MeetingSourceScanner.loadMeetingApps()
        self.nativeBundles = apps.native
        self.browserBundles = apps.browsers
        self.browserURLFragments = apps.urlFragments
    }

    /// Run one discovery pass and return the winner.
    /// - Parameter keepStickyOnEmpty: when true, an empty pass leaves the sticky pin intact (owner is mid-recording; a transient empty scan must not unbias the next pass).
    func scan(keepStickyOnEmpty: Bool) -> Result {
        var candidates = enumerateCandidates()
        let winner = MeetingSourceScorer.pickBest(&candidates, lastWinner: lastScorerWinner)
        let count = candidates.count
        guard let winner = winner else {
            if !keepStickyOnEmpty {
                lastScorerWinner = nil
            }
            return Result(winner: nil, candidateCount: count, winnerChanged: false)
        }
        let changed = lastScorerWinner?.bundleID != winner.source.bundleID
        lastScorerWinner = winner.source
        return Result(winner: winner, candidateCount: count, winnerChanged: changed)
    }

    // MARK: Candidate enumeration

    /// Produce one candidate per concurrent meeting-app contender. Native bundles are always included (scorer rejects those with zero signals). Browsers only qualify when at least one window matches a meeting-pattern title.
    private func enumerateCandidates() -> [MeetingSourceCandidate] {
        let axTrusted = AXIsProcessTrusted()
        var candidates: [MeetingSourceCandidate] = []

        for app in NSWorkspace.shared.runningApplications {
            guard let bid = app.bundleIdentifier else { continue }
            let pid = app.processIdentifier

            if nativeBundles.contains(bid) {
                let source = AppSource(
                    bundleID: bid,
                    displayName: app.localizedName ?? bid,
                    kind: .native
                )
                let signals = collectSignals(
                    bundleID: bid,
                    kind: .native,
                    pid: pid,
                    axTrusted: axTrusted,
                    preTitleMatch: nil
                )
                candidates.append(MeetingSourceCandidate(source: source, signals: signals))
                continue
            }

            if browserBundles.contains(bid) {
                // Requires AX trust: without it we can't read window titles to confirm a meeting tab.
                // Natives are still enqueued without AX because they can win on audio + button signals alone.
                // START2/AUD-3: browsers put the PAGE TITLE in the window title, never the URL, so a
                // plain-tab Meet/Teams-web meeting is matched against the same page-title patterns the
                // browser lifecycle adapter owns (as the PWA branch below already does), keeping the URL
                // fragment as a bonus signal for any browser that does surface the URL in the title.
                guard axTrusted,
                      anyWindowMatchesMeetingTitle(pid: pid)
                        || anyWindowMatchesMeetingFragment(pid: pid) else { continue }
                let source = AppSource(
                    bundleID: bid,
                    displayName: app.localizedName ?? "Browser",
                    kind: .browser
                )
                let signals = collectSignals(
                    bundleID: bid,
                    kind: .browser,
                    pid: pid,
                    axTrusted: axTrusted,
                    preTitleMatch: true
                )
                candidates.append(MeetingSourceCandidate(source: source, signals: signals))
                continue
            }

            if BrowserMeetingLifecycleAdapter.isPWABundleID(bid) {
                // Chromium "installed PWA" (e.g. Google Meet as a desktop app): own process with a per-install bundle ID absent from both TOML lists (TECH-I5). No address bar, so windows carry page titles; match meeting-title patterns rather than URL fragments. Treated as `.browser` so existing browser end-detection and MicGate fallback apply.
                // Title matcher is strict and rejects transient solo-start titles; fall back to the PWA's localizedName, which the web manifest sets at install time and keeps stable across the meeting lifecycle (e.g. "Google Meet", "Microsoft Teams").
                guard axTrusted else { continue }
                let titleMatched = anyWindowMatchesMeetingTitle(pid: pid)
                let nameMatched = BrowserMeetingLifecycleAdapter
                    .matchesKnownMeetingPWA(localizedName: app.localizedName)
                guard titleMatched || nameMatched else { continue }
                let source = AppSource(
                    bundleID: bid,
                    displayName: app.localizedName ?? "Meeting",
                    kind: .browser
                )
                // START3/AUD-4: pass the REAL title match, not a synthetic `true`. A meeting-named PWA
                // idling on its landing page matches on `localizedName` alone, with no meeting-titled
                // window; stamping `titleMatch = true` there fabricated evidence that let the scorer
                // prompt on an idle PWA. With the honest value a name-only admission carries
                // `titleMatch = false`, so it must earn its place via an in-call corroborator
                // (the scorer's lone-candidate gate) or be dropped as zero-evidence.
                let signals = collectSignals(
                    bundleID: bid,
                    kind: .browser,
                    pid: pid,
                    axTrusted: axTrusted,
                    preTitleMatch: titleMatched
                )
                candidates.append(MeetingSourceCandidate(source: source, signals: signals))
            }
        }

        return candidates
    }

    /// Cisco Webex keeps the mic open after a call for ultrasound device discovery, so its
    /// process-audio signal cannot distinguish an active call from an idle post-call state.
    private static let webexBundleIDs: Set<String> = ["com.cisco.webexmeetingsapp", "com.cisco.spark"]

    /// PERF6: whether the three control-button AX walks (toolbar / leave / mute) are worth
    /// running for a candidate. They are recursive AX-tree IPC and dominate idle discovery CPU,
    /// so skip them for a backgrounded app that shows no cheap sign of a live meeting: no
    /// meeting-titled window and no active process audio. Webex is exempt because it is excluded
    /// from the audio probe (see `webexBundleIDs`), so it has no audio leg and must keep walking
    /// rather than gate on title alone.
    static func shouldWalkControlAX(titleMatch: Bool, processAudioActive: Bool, bundleID: String) -> Bool {
        if webexBundleIDs.contains(bundleID) { return true }
        return titleMatch || processAudioActive
    }

    /// Populate the signal tuple. Each signal degrades to false on AX denied / read failure.
    /// `preTitleMatch` short-circuits the per-bundle recognizer: browsers pass the already-computed
    /// browser title/URL match (`true` for a plain tab vetted by URL/title; the real per-window result
    /// for a PWA, which is `false` on a name-only admission, START3/AUD-4); natives pass `nil` so the recognizer runs.
    private func collectSignals(
        bundleID: String,
        kind: AppSourceKind,
        pid: pid_t,
        axTrusted: Bool,
        preTitleMatch: Bool?
    ) -> MeetingSourceCandidate.Signals {
        var signals = MeetingSourceCandidate.Signals()

        // Cheap process-audio probe first: it is one of the two gate preconditions for the
        // expensive AX walks below (PERF6) and needs no AX access. Webex excluded (see
        // `webexBundleIDs`): a positive audio signal would push it above threshold long after
        // the call ends.
        if !MeetingSourceScanner.webexBundleIDs.contains(bundleID) {
            let context = MeetingLifecycleContext(
                bundleID: bundleID,
                kind: kind == .browser ? .browser : .native,
                pid: pid,
                title: nil
            )
            if let active = ProcessAudioSignal.defaultProbe(context) {
                signals.processAudioActive = active
            }
        }

        if axTrusted {
            let axApp = AXUIElementCreateApplication(pid)

            if let pre = preTitleMatch {
                signals.titleMatch = pre
            } else if let titles = MeetingSourceScanner.collectAXWindowTitles(pid: pid) {
                signals.titleMatch = titles.contains { title in
                    MeetingSourceScanner.isActiveMeetingWindow(
                        bundleID: bundleID,
                        kind: kind,
                        title: title
                    )
                }
            }

            // PERF6: only descend the recursive control-button trees when a cheap precondition
            // says a live meeting is plausible. An idle backgrounded app skips the walk and keeps
            // the default (false) control signals, which the scorer treats identically to
            // "walked and found nothing".
            if MeetingSourceScanner.shouldWalkControlAX(
                titleMatch: signals.titleMatch,
                processAudioActive: signals.processAudioActive,
                bundleID: bundleID
            ) {
                signals.callingControlsToolbar = MeetingAXHandleBuilder
                    .findCallingControlsToolbar(in: axApp, bundleID: bundleID) != nil

                signals.leaveButton = !MeetingAXHandleBuilder
                    .findAllLeaveButtons(in: axApp, bundleID: bundleID).isEmpty

                if let catalogue = MeetingSourceScanner.muteCatalogue {
                    signals.muteButton = !MeetingAXHandleBuilder
                        .findAllMuteButtons(
                            in: axApp,
                            bundleID: bundleID,
                            catalogue: catalogue
                        ).isEmpty
                }
            }
        }

        // shareableContentActive left false: SCShareableContent is async and the scan path is synchronous; needs an async pre-scan cache before it can be wired in.
        return signals
    }

    private func anyWindowMatchesMeetingFragment(pid: pid_t) -> Bool {
        let axApp = AXUIElementCreateApplication(pid)
        var windowsRef: CFTypeRef?
        guard AXUIElementCopyAttributeValue(axApp, kAXWindowsAttribute as CFString, &windowsRef) == .success,
              let windows = windowsRef as? [AXUIElement] else { return false }
        for win in windows {
            var titleRef: CFTypeRef?
            guard AXUIElementCopyAttributeValue(win, kAXTitleAttribute as CFString, &titleRef) == .success,
                  let title = titleRef as? String,
                  !title.isEmpty else { continue }
            if titleMatchesMeetingFragment(title) { return true }
        }
        return false
    }

    private func titleMatchesMeetingFragment(_ title: String) -> Bool {
        let lowered = title.lowercased()
        return browserURLFragments.contains(where: { lowered.contains($0) })
    }

    /// True when any AX window of `pid` matches a browser meeting-title pattern. Counterpart of `anyWindowMatchesMeetingFragment`: a browser/PWA window carries the page title, not the URL, so it matches title patterns from the browser lifecycle adapter. Used for both Chromium PWAs and (START2/AUD-3) plain browser tabs.
    private func anyWindowMatchesMeetingTitle(pid: pid_t) -> Bool {
        guard let titles = MeetingSourceScanner.collectAXWindowTitles(pid: pid) else {
            return false
        }
        return titles.contains { MeetingSourceScanner.browserWindowIndicatesMeeting(title: $0) }
    }

    /// True when a browser/PWA window `title` looks like an active meeting. Pure (no AX), so the
    /// browser-discovery contract is unit-testable. START2/AUD-3: browsers put the page title, never
    /// the URL, in the window title, so a plain-tab Meet/Teams-web meeting is admitted by these
    /// patterns rather than the URL fragment. Shares the browser lifecycle adapter's matchers so
    /// discovery and end-detection agree on what a meeting window looks like.
    static func browserWindowIndicatesMeeting(title: String) -> Bool {
        BrowserMeetingLifecycleAdapter.defaultTitleMatchers.contains { $0(title) }
    }

    // MARK: Window-title recognizer

    /// True when `title` belongs to an active meeting window for the given app. Distinct from the per-app title extractors: those return nil for bare valid windows; this recognizer must be permissive about bare windows because a false negative here cuts the recording mid-call. Upstream caller ORs across all windows, so a single true is enough.
    static func isActiveMeetingWindow(bundleID: String, kind: AppSourceKind, title: String) -> Bool {
        let lowered = title.lowercased().trimmingCharacters(in: .whitespaces)

        switch (bundleID, kind) {
        case ("us.zoom.xos", _):
            // Active meeting windows always contain "zoom meeting". Idle launcher and dialogs explicitly rejected.
            if lowered == "zoom" { return false }                    // launcher
            if lowered.hasPrefix("schedule meeting") { return false } // dialog
            if lowered.hasPrefix("join meeting") { return false }     // dialog
            return lowered.contains("zoom meeting")

        case ("com.microsoft.teams2", .native), ("com.microsoft.teams", .native):
            // Teams (May 2026) dropped the "Meeting in/with <X>" prefix - title is now just the topic (e.g. "Echo | Microsoft Teams", "Standup | Microsoft Teams", or bare "Echo").
            // Old prefix-based recognizer was too strict and killed recordings mid-call. New contract prefers false-positives (recording into a stale thread; silence detector catches it at 5 min) over false-negatives (audio lost).
            // Reject only well-known chrome surfaces; both the bare and "| Microsoft Teams" forms share the same blacklist.
            let chrome: Set<String> = [
                "microsoft teams",
                "teams",
                "calendar",
                "settings",
                "activity",
                "chat",
                "files",
                "apps",
                "store",
                "join meeting",
                "schedule meeting",
            ]
            if chrome.contains(lowered) { return false }
            if lowered.hasSuffix("| microsoft teams") {
                let lead = String(lowered.dropLast("| microsoft teams".count))
                    .trimmingCharacters(in: .whitespaces)
                if lead.isEmpty { return false }                     // bare app chrome
                if chrome.contains(lead) { return false }
                return true
            }
            // No suffix - Teams sometimes spawns the meeting window with just the topic. Can't distinguish from chrome by title alone; blacklist above filters known chrome; empty title is inconclusive (upstream ORs across windows so it contributes nothing).
            return !lowered.isEmpty

        case ("com.cisco.webexmeetingsapp", _):
            // Active meeting contains "webex meeting"; idle is "Webex" or "Cisco Webex".
            return lowered.contains("webex meeting")

        case ("com.tinyspeck.slackmacgap", _):
            // Word-boundary match so "team-huddles" (plural channel name) doesn't match: trailing `s` is alphanumeric and fails the boundary.
            return title.range(of: #"\bhuddle\b"#, options: [.regularExpression, .caseInsensitive]) != nil

        case ("com.skype.skype", _):
            return lowered.contains("call with") || lowered.contains("group call")

        case ("com.google.meet", _):
            return lowered.contains("google meet")

        default:
            // Unknown native bundle; probe upstream short-circuits before reaching here under normal operation.
            return false
        }
    }

    /// Walk AX windows of `pid` and return all non-empty titles. Returns `nil` (not `[]`) when AX reads fail outright (Accessibility revoked, process gone).
    static func collectAXWindowTitles(pid: pid_t) -> [String]? {
        let axApp = AXUIElementCreateApplication(pid)
        var windowsRef: CFTypeRef?
        guard AXUIElementCopyAttributeValue(axApp, kAXWindowsAttribute as CFString, &windowsRef) == .success,
              let windows = windowsRef as? [AXUIElement] else {
            return nil
        }
        var titles: [String] = []
        for win in windows {
            var titleRef: CFTypeRef?
            guard AXUIElementCopyAttributeValue(win, kAXTitleAttribute as CFString, &titleRef) == .success,
                  let title = titleRef as? String, !title.isEmpty else { continue }
            titles.append(title)
        }
        return titles
    }

    // MARK: Resource loading

    private struct MeetingApps {
        let native: Set<String>
        let browsers: Set<String>
        let urlFragments: [String]
    }

    private static func loadMeetingApps() -> MeetingApps {
        let bundle = Bundle.module
        guard let url = bundle.url(forResource: "meeting_apps", withExtension: "toml"),
              let data = try? String(contentsOf: url, encoding: .utf8),
              let toml = try? TOMLTable(string: data) else {
            Log.detector.warning("meeting_apps.toml not found; using empty lists")
            return MeetingApps(native: [], browsers: [], urlFragments: [])
        }

        let nativeArr = toml["native"]?.table?["bundle_ids"]?.array?.compactMap { $0.string } ?? []
        let urlArr = toml["browser"]?.table?["url_fragments"]?.array?.compactMap { $0.string } ?? []
        let browserArr = toml["browser"]?.table?["bundles"]?.table?["ids"]?.array?.compactMap { $0.string } ?? []

        return MeetingApps(
            native: Set(nativeArr),
            browsers: Set(browserArr),
            urlFragments: urlArr.map { $0.lowercased() }
        )
    }
}
