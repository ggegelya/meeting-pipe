import Foundation

/// One concrete meeting-app source the scorer is asked to evaluate.
///
/// A scan pass enumerates every running known meeting app plus every
/// browser whose windows host a meeting tab, packages each into a
/// `MeetingSourceCandidate` with its per-signal boolean tuple, and
/// hands the list to `MeetingSourceScorer.pickBest`.
///
/// The signal tuple is intentionally flat (no nested types, no enums)
/// so the scorer can compute weights with a single expression and
/// tests can compose any combination in one line.
///
/// `score` is the weighted sum computed via `MeetingSourceScorer.score`
/// and stored here for easy inspection by Detector's event log.
struct MeetingSourceCandidate: Equatable {
    /// The source the scorer would attribute the meeting to if this
    /// candidate wins. Populated by Detector's `enumerateCandidates`
    /// from `NSWorkspace.runningApplications` and the browser-tab walker.
    let source: AppSource

    /// Bundle ID lifted out for the sticky-bonus check; redundant with
    /// `source.bundleID` but lets the scorer stay pure (no AppSource
    /// equality semantics, which exclude `meetingTitle`).
    var bundleID: String { source.bundleID }

    /// Per-signal flags. False by default so tests can spell out only
    /// the signals that matter for the scenario under test.
    var signals: Signals

    /// The score the scorer assigned this candidate. Populated by
    /// `MeetingSourceScorer.pickBest`. Defaulted to 0 so the candidate
    /// can be constructed before scoring runs.
    var score: Int = 0

    struct Signals: Equatable {
        /// An AXToolbar (or equivalent container) whose title matches
        /// one of the per-bundle toolbar names (e.g. Teams 2 "Calling
        /// controls", Meet "Meeting controls"). Strongest single
        /// signal because non-meeting shell windows lack it entirely.
        var callingControlsToolbar: Bool

        /// At least one AX button satisfying the per-bundle leave
        /// predicate was found in the app's window tree.
        var leaveButton: Bool

        /// At least one AX button satisfying the per-bundle mute
        /// predicate was found in the app's window tree.
        var muteButton: Bool

        /// The app exposes at least one window or tab whose title
        /// matches the meeting pattern. For native apps this comes
        /// from the recognizer; for browsers from the meeting URL
        /// fragments in meeting_apps.toml.
        var titleMatch: Bool

        /// `kAudioProcessPropertyIsRunningInput` reports active input
        /// capture for this PID. Webex is suppressed elsewhere (see
        /// WebexLifecycleAdapter rationale) but the candidate doesn't
        /// suppress it here; the suppression is a Detector-side filter.
        var processAudioActive: Bool

        /// SCShareableContent lists this bundle as an active source.
        /// Slot reserved for the follow-up wiring; Detector currently
        /// always passes `false` so the scorer treats it as no-evidence.
        var shareableContentActive: Bool

        init(
            callingControlsToolbar: Bool = false,
            leaveButton: Bool = false,
            muteButton: Bool = false,
            titleMatch: Bool = false,
            processAudioActive: Bool = false,
            shareableContentActive: Bool = false
        ) {
            self.callingControlsToolbar = callingControlsToolbar
            self.leaveButton = leaveButton
            self.muteButton = muteButton
            self.titleMatch = titleMatch
            self.processAudioActive = processAudioActive
            self.shareableContentActive = shareableContentActive
        }
    }

    init(source: AppSource, signals: Signals = Signals(), score: Int = 0) {
        self.source = source
        self.signals = signals
        self.score = score
    }
}
