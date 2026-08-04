import Foundation

/// Which oracle an app-mute reading came from. `MicGate` fuses the two rather than picking one (MIC8, owner decision 2026-08-04).
public enum MuteReadingSource: String, CaseIterable, Equatable {
    /// The Accessibility label scrape: `AXMuteButtonProbe` (the foreground
    /// fast-path) and `MeetingAXWindowWatcher`'s 1 Hz re-resolving poll, which
    /// both land on `MicGate.injectAxMuteEvent`.
    case ax
    /// A meeting client's own diagnostic log, read by `LogMuteAdapter`. Teams only:
    /// Zoom's logs are stale/opt-in and the corpus has no Zoom calls.
    case log
}

/// MIC8: which app-mute reading wins when the SlimCore log and the AX scrape both speak. Pure, so the precedence is testable without a meeting, a log file, or an AX tree.
///
/// **The rule is "log wins when present, AX carries when absent".** The measurement
/// is what chose fusion over the spike's assumed supersede: over 11 days of dogfood
/// the log led the AX read on 59 of 61 paired transitions (p50 50 ms), three of the
/// four imperfect pairs were AX-side defects, and the fourth was a single unexplained
/// log gap that only a fusion covers. Fusing costs one comparison and does not bet
/// the whole Teams mute oracle on one undocumented string.
///
/// "Present" has to mean *recently spoke*, not *the file exists*. The log is a
/// transition stream, so it says nothing at all until the first toggle: at join time
/// only the AX read knows whether you are already muted, and a rule keyed on the
/// file's existence would blind the gate for the first half of every call and would
/// not cover the one gap fusion exists for. So a log reading wins outright, and an AX
/// reading is honoured whenever the log has been quiet for `defaultLogFreshness`.
public enum MuteSourceFusion {

    /// How long a log reading suppresses AX readings.
    ///
    /// Five seconds is a deliberate compromise, and the trade is worth stating.
    /// Longer favours the log's accuracy: measured, the log leads by p50 46 ms and
    /// p90 ~900 ms, so anything past ~1 s already covers the normal lead, and a
    /// longer window would also swallow the AX side's known defects (a notification
    /// that fired 16.8 s late, a transition AX invented 68 s after the fact).
    /// Shorter favours recovery: while a log reading is fresh the AX read cannot
    /// correct it, so a genuine log miss latches for exactly this long, and a latched
    /// `.muted` that is wrong is the failure mode that cost this project two
    /// incidents (MIC9, MIC10). Five seconds is >5x the measured p90 lead, so it
    /// costs the log nothing in the normal case, and it bounds the un-correctable
    /// window to five seconds in the bad one. The AX defects it declines to swallow
    /// are all cases where AX reported the state that was already true, so honouring
    /// them changes nothing.
    public static let defaultLogFreshness: TimeInterval = 5.0

    /// True when a reading from `source` may be applied.
    ///
    /// `lastLogReadingAt` is when the log last spoke (nil: never, which is the state
    /// every meeting starts in). A clock that jumped backwards reads as fresh, which
    /// is the same side as "the log just spoke".
    public static func accepts(
        source: MuteReadingSource,
        now: Date,
        lastLogReadingAt: Date?,
        freshness: TimeInterval = defaultLogFreshness
    ) -> Bool {
        switch source {
        case .log:
            return true
        case .ax:
            guard let last = lastLogReadingAt else { return true }
            return now.timeIntervalSince(last) > freshness
        }
    }
}
