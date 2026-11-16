import Foundation

/// Per-bundle hold on the meeting prompt, bound to the call's span rather than to the bundle
/// (DET18). Pure value type; tests drive it without a state-machine fake, the same way
/// `RepromptCooldown` is driven.
///
/// Two things hold a prompt off, and both live here because both answer the same question, "is the
/// call this entry was made for still up?":
///
/// - **`.skipped`**: the owner dismissed the prompt (Skip, the × close, force-stop while
///   prompting). The prompt stays away for the rest of that call.
/// - **`.offered`**: the prompt timed out with the `skip` default. Before DET18 that was a skip
///   too, and on the work laptop all 32 timeouts became skips and 19 Teams calls went wholly
///   unrecorded. Now the panel collapses into a one-click offer ("Record this <app> meeting") that
///   lives exactly as long as a skip would, and suppresses nothing the owner did not choose.
///
/// **What a span is.** DET7 to DET9 anchored the latch on the bundle and refreshed it from a
/// confident discovery winner, which was both too long and too short: a *different* call starting
/// in the same app inside the grace inherited the latch (no prompt for 25.6 minutes on
/// 2026-10-21), and a live call whose controls went dark for a minute lost it (D016, D067). The
/// span is now read per scan from the evidence that the call itself is up (`Liveness`):
///
/// - `.processAudio` (Teams, Zoom: `NativeLifecycleConfig.usesProcessAudio`): live while the app's
///   own microphone read is true, or while it is the scan's confident winner. Two scans in a row
///   that read the microphone positively false *and* find no confident winner end the span (the
///   second is the spec's one poll of grace, and it is what a single DET8-style blip under DET9's
///   hidden controls cannot satisfy); an app the scan no longer sees at all has quit, which ends it
///   at once. That both-absent read is what lets the next call in the same app prompt.
/// - `.title` (other natives, browsers): live while the meeting title reads present or the bundle
///   wins the scan; there is no positive end, because a page retitling itself is not an end (D005).
/// - `.micBusy` (the DET1 mic-in-use tier): live while the debounced mic-busy span names this
///   bundle, ended when it names anything else. Those sources are never scanner candidates.
///
/// An unknown read (`processAudio == nil`, no candidate for a browser) is ignorance, not absence.
/// DET8 measured an audio client re-registering mid-call, so the read collapsing unknown to false
/// would end a skipped live call's span on a blip. Ignorance lapses the entry only after
/// `ignoranceGraceSec` of it, measured across feeds and capped per gap at one idle poll, so time
/// spent outside `.idle` (no scans run there, PERF17) is never counted as silence: a 30 s prompt for
/// another app does not expire a skipped Teams call.
struct SkippedMeetingLatch {

    enum Mode: Equatable {
        case skipped
        case offered
    }

    enum Liveness: Equatable {
        case processAudio
        case title
        case micBusy
    }

    /// One scan's reading of one candidate bundle.
    struct Reading: Equatable {
        /// The app's own microphone read: true, false, or nil when it was not read or did not
        /// resolve. Only meaningful for `.processAudio` entries.
        var processAudio: Bool?
        var titleMatch: Bool
        /// The scan's confident winner was this bundle.
        var isWinner: Bool

        init(processAudio: Bool? = nil, titleMatch: Bool = false, isWinner: Bool = false) {
            self.processAudio = processAudio
            self.titleMatch = titleMatch
            self.isWinner = isWinner
        }
    }

    struct Entry: Equatable {
        let source: AppSource
        var mode: Mode
        let liveness: Liveness
        /// Accumulated seconds of ignorance since the last live reading.
        var unseenSec: TimeInterval = 0
        /// Consecutive positive-absent reads (microphone off, no confident winner).
        var absentStreak = 0
        /// DET17 guard 2: for a browser source, the tab the hold was made for. A sighting of a
        /// different tab in the same browser is not held. Nil holds the whole bundle.
        var tabKey: Int? = nil
        var lastFedAt: Date
    }

    /// How long ignorance (no reading either way) holds an entry. DET9's measured control blackout
    /// (48 s between confident winners on 2026-07-27, 21-33 s in END9) is why it is five polls.
    let ignoranceGraceSec: TimeInterval
    /// The most one gap between feeds may add to `unseenSec`. A scan runs at least every idle poll
    /// while the session is idle, so a longer gap is time the scans were gated, not silence.
    let maxGapSec: TimeInterval

    private(set) var entries: [String: Entry] = [:]

    init(
        ignoranceGraceSec: TimeInterval = DiscoveryScanCadence.discoveryDefault.idle * 5,
        maxGapSec: TimeInterval = DiscoveryScanCadence.discoveryDefault.idle
    ) {
        self.ignoranceGraceSec = ignoranceGraceSec
        self.maxGapSec = maxGapSec
    }

    /// Arm (or re-arm) the hold for `source`. A Skip after a timeout turns an offer into a skip and
    /// keeps its span.
    mutating func arm(source: AppSource, mode: Mode, liveness: Liveness, tabKey: Int? = nil, at: Date = Date()) {
        entries[source.bundleID] = Entry(source: source, mode: mode, liveness: liveness, absentStreak: 0, tabKey: tabKey, lastFedAt: at)
    }

    func entry(bundleID: String) -> Entry? { entries[bundleID] }

    /// Either hold: the prompt stays away for this bundle. With a `tabKey` (DET17, a browser
    /// sighting), a hold made for a different tab does not apply; an unknown tab on either side is
    /// treated as the same one.
    func isHeld(bundleID: String, tabKey: Int? = nil) -> Bool {
        guard let entry = entries[bundleID] else { return false }
        guard let held = entry.tabKey, let tabKey else { return true }
        return held == tabKey
    }

    /// An explicit Skip only.
    func isSkipped(bundleID: String) -> Bool { entries[bundleID]?.mode == .skipped }

    func isOffered(bundleID: String) -> Bool { entries[bundleID]?.mode == .offered }

    /// Drop the hold so an explicit start (hotkey, "Always for {App}") is never blocked by it.
    mutating func clear(bundleID: String) {
        entries.removeValue(forKey: bundleID)
    }

    /// Feed one completed discovery scan. `readings` holds every candidate the scan enumerated,
    /// keyed by bundle id. Returns the entries whose span ended on this feed, already removed.
    mutating func feedScan(_ readings: [String: Reading], at now: Date) -> [Entry] {
        var ended: [Entry] = []
        for (bundleID, var entry) in entries where entry.liveness != .micBusy {
            let reading = readings[bundleID]
            switch Self.verdict(liveness: entry.liveness, kind: entry.source.kind, reading: reading) {
            case .live:
                entry.unseenSec = 0
                entry.absentStreak = 0
            case .gone:
                entries.removeValue(forKey: bundleID)
                ended.append(entry)
                continue
            case .absent:
                entry.absentStreak += 1
                if entry.absentStreak >= Self.absentReadsToEnd {
                    entries.removeValue(forKey: bundleID)
                    ended.append(entry)
                    continue
                }
            case .unknown:
                entry.absentStreak = 0
                entry.unseenSec += min(max(0, now.timeIntervalSince(entry.lastFedAt)), maxGapSec)
            }
            entry.lastFedAt = now
            if entry.unseenSec >= ignoranceGraceSec {
                entries.removeValue(forKey: bundleID)
                ended.append(entry)
            } else {
                entries[bundleID] = entry
            }
        }
        return ended
    }

    /// Feed one mic-busy sample (`busyBundle` nil when the microphone is free). Only `.micBusy`
    /// entries read it. The tracker that produces it already debounces a release, so a change of
    /// holder is a real end.
    mutating func feedMicBusy(busyBundle: String?, at now: Date) -> [Entry] {
        var ended: [Entry] = []
        for (bundleID, var entry) in entries where entry.liveness == .micBusy {
            if busyBundle == bundleID {
                entry.unseenSec = 0
                entry.lastFedAt = now
                entries[bundleID] = entry
            } else {
                entries.removeValue(forKey: bundleID)
                ended.append(entry)
            }
        }
        return ended
    }

    /// Positive-absent reads in a row that end a microphone span: the read, plus one poll of grace.
    static let absentReadsToEnd = 2

    enum Verdict: Equatable {
        case live
        /// A positive "not live" read: counts toward `absentReadsToEnd`.
        case absent
        /// The app is not running at all: ends the span at once.
        case gone
        case unknown
    }

    /// The one rule for what a scan says about a span. Pure.
    static func verdict(liveness: Liveness, kind: AppSourceKind, reading: Reading?) -> Verdict {
        switch liveness {
        case .processAudio:
            // A running native is always a candidate, so a missing one has quit.
            guard let reading else { return kind == .native ? .gone : .unknown }
            if reading.processAudio == true || reading.isWinner { return .live }
            if reading.processAudio == false { return .absent }
            return .unknown
        case .title:
            guard let reading else { return .unknown }
            return reading.titleMatch || reading.isWinner ? .live : .unknown
        case .micBusy:
            return .unknown
        }
    }
}
