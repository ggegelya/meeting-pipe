import AppKit
import ApplicationServices
import Foundation
import MeetingPipeCore
import TOMLKit

/// Cold-start discovery scan: enumerate every concurrently-running
/// meeting-app contender, score them, and return the winner.
///
/// Lifted out of `Detector` (TECH-C13 step 5) so the discovery scan has
/// a single home that both `Detector` and `MeetingDiscoveryWatcher` can
/// drive. The scan is impure (NSWorkspace + AX + HAL reads) but carries
/// no timing or state-machine concerns; the owner forwards it onto its
/// own queue. The only retained state is the sticky-winner pin for the
/// scorer's recency tie-break.
final class MeetingSourceScanner {

    /// Outcome of one scan pass.
    struct Result {
        /// The highest-scoring candidate above the disambiguation floor,
        /// or nil when nothing cleared it.
        let winner: MeetingSourceCandidate?
        /// Number of contenders enumerated this pass.
        let candidateCount: Int
        /// True when `winner` differs from the previous pass's winner,
        /// so callers can log a winner-change event without re-deriving it.
        let winnerChanged: Bool
    }

    /// Known native meeting-app bundle IDs from `meeting_apps.toml`.
    let nativeBundles: Set<String>
    /// Known browser bundle IDs that can host a meeting tab.
    let browserBundles: Set<String>
    /// Meeting-URL fragments used to recognise a browser meeting tab.
    let browserURLFragments: [String]

    /// Cached MuteLabels catalogue for the scorer's mute-button signal.
    /// Loaded once per process; resolution failure degrades the
    /// `muteButton` flag to false (other signals carry).
    private static let muteCatalogue: MuteLabels? = {
        do {
            return try MuteLabelsLoader.loadDefault()
        } catch {
            return nil
        }
    }()

    /// Last scan's winning source, used by the scorer for the
    /// sticky-bonus tie-break (TECH-C15).
    private var lastScorerWinner: AppSource?

    init() {
        let apps = MeetingSourceScanner.loadMeetingApps()
        self.nativeBundles = apps.native
        self.browserBundles = apps.browsers
        self.browserURLFragments = apps.urlFragments
    }

    /// Drop the sticky-winner pin so the next scan starts unbiased.
    /// Called by the owner when it tears down (e.g. `Detector.stop()`).
    func resetStickyWinner() {
        lastScorerWinner = nil
    }

    /// Run one discovery pass: enumerate contenders, score them, and
    /// return the winner.
    ///
    /// - Parameter keepStickyOnEmpty: when true, a pass that finds no
    ///   winner keeps the sticky pin (the owner is mid-recording and a
    ///   transient empty scan must not unbias the next pass). When
    ///   false, an empty pass clears the pin.
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

    /// Walk `NSWorkspace.runningApplications` and produce one
    /// `MeetingSourceCandidate` per concurrent meeting-app contender.
    /// Native bundles always become candidates (signals may be all
    /// false; the scorer will reject them). Browsers become candidates
    /// only when at least one of their windows has a meeting-pattern
    /// title (matches the existing scanBrowserTab filter so we don't
    /// drag in every running browser).
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
                // Browsers are candidates only when at least one of
                // their windows has a meeting-pattern title. The probe
                // needs AX trust; without it we can't tell whether a
                // browser is in a meeting, so it doesn't become a
                // candidate (native still does because they can win on
                // audio + button signals alone via the AX walk attempt).
                guard axTrusted,
                      anyWindowMatchesMeetingFragment(pid: pid) else { continue }
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
            }
        }

        return candidates
    }

    /// Populate the per-candidate signal tuple. Each signal degrades
    /// to `false` on AX denied / read failed, so the scorer naturally
    /// down-weights a candidate whose evidence couldn't be gathered.
    ///
    /// `preTitleMatch` short-circuits the per-bundle recognizer:
    ///   - For browser candidates the caller already filtered by the
    ///     meeting URL fragment, so we set it true rather than re-walk.
    ///   - For native candidates pass nil so the recognizer runs.
    private func collectSignals(
        bundleID: String,
        kind: AppSourceKind,
        pid: pid_t,
        axTrusted: Bool,
        preTitleMatch: Bool?
    ) -> MeetingSourceCandidate.Signals {
        var signals = MeetingSourceCandidate.Signals()

        if axTrusted {
            let axApp = AXUIElementCreateApplication(pid)

            // titleMatch: browsers were already filtered; natives run
            // the per-bundle recognizer against every window title.
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

        // Process-audio: HAL per-PID query via ProcessAudioSignal's
        // default probe. Webex is excluded because Cisco documents
        // Webex holding the mic open after meetings for ultrasound
        // device discovery; rewarding it for that would push Webex
        // above threshold long after the call ended.
        if bundleID != "com.cisco.webexmeetingsapp",
           bundleID != "com.cisco.spark" {
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

        // ShareableContent slot reserved; SCShareableContent is async
        // and the scan path is synchronous. Left false until a
        // follow-up adds an async pre-scan that caches the latest
        // shareable-content set for the synchronous scorer to read.
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

    // MARK: Window-title recognizer

    /// Recognize whether a window title belongs to an *active meeting
    /// window* for the given app. Distinct from the per-app extractors
    /// (`extractZoomNativeTitle` etc.): those try to pull a usable topic
    /// and return nil for valid-but-bare meeting windows. Recognition
    /// must be permissive about the bare case, because a false negative
    /// here cuts the recording mid-call.
    ///
    /// Returns `true` on positive match. The probe upstream returns true
    /// if ANY title in the app's window list recognizes; this function
    /// alone never ends recording.
    static func isActiveMeetingWindow(bundleID: String, kind: AppSourceKind, title: String) -> Bool {
        let lowered = title.lowercased().trimmingCharacters(in: .whitespaces)

        switch (bundleID, kind) {
        case ("us.zoom.xos", _):
            // Active meeting windows always end in "zoom meeting" (with
            // or without topic prefix). Idle launcher and chrome dialogs
            // are explicitly rejected so a future title format change
            // can't sneak through.
            if lowered == "zoom" { return false }                    // launcher
            if lowered.hasPrefix("schedule meeting") { return false } // dialog
            if lowered.hasPrefix("join meeting") { return false }     // dialog
            return lowered.contains("zoom meeting")

        case ("com.microsoft.teams2", .native), ("com.microsoft.teams", .native):
            // Teams (May 2026) drops the "Meeting in <X>" / "Meeting with
            // <X>" lead in favour of just the meeting topic in the title.
            // Examples observed in the wild:
            //   - "Echo | Microsoft Teams"   (topic = "Echo")
            //   - "Standup | Microsoft Teams"
            //   - Just "Echo" with no suffix (rare; some Teams versions)
            // The old prefix-based recognizer was too strict and rejected
            // real meetings, leading to recordings being auto-stopped a
            // few seconds in. The new contract favours false-positives
            // (recording continues into a stale chat thread; user clicks
            // stop or the silence detector catches it after 5 min) over
            // false-negatives (recording dies mid-call, audio lost).
            //
            // Reject only well-known chrome / non-meeting surfaces. Both
            // the bare "<X>" form and the "<X> | Microsoft Teams" form
            // share the same chrome blacklist.
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
            // No suffix — Teams sometimes spawns the meeting window with
            // just the topic. We can't distinguish that from chrome by
            // title alone, so we trust the blacklist above to filter
            // chrome and accept everything else as a meeting candidate.
            // An unknown / empty title is treated as inconclusive (the
            // upstream probe ORs results across windows; this title
            // contributes nothing rather than a misleading false).
            return !lowered.isEmpty

        case ("com.cisco.webexmeetingsapp", _):
            // Webex active meeting always contains "webex meeting".
            // Idle is "Webex" or "Cisco Webex".
            return lowered.contains("webex meeting")

        case ("com.tinyspeck.slackmacgap", _):
            // Slack huddles: "huddle" as a whole word, not as substring
            // of channel name. Word-boundary regex so "team-huddles"
            // (plural channel name) does not match: `s` after `huddle`
            // is alphanumeric, so the trailing word boundary fails.
            return title.range(of: #"\bhuddle\b"#, options: [.regularExpression, .caseInsensitive]) != nil

        case ("com.skype.skype", _):
            return lowered.contains("call with") || lowered.contains("group call")

        case ("com.google.meet", _):
            return lowered.contains("google meet")

        default:
            // Unknown native bundle. The probe upstream short-circuits
            // before reaching the recognizer for unknown shapes, so this
            // path is dead under normal operation; kept as a safety net.
            return false
        }
    }

    /// Walk the AX windows of `pid` and return every non-empty window
    /// title. Returns `nil` when AX reads fail outright (Accessibility
    /// revoked, process gone), distinct from "found zero windows".
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
        // Bundled inside the SPM resource bundle.
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
