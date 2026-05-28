import Foundation

/// One meeting-app source the scorer evaluates. Flat signal tuple (no nested types) so the scorer computes weights in one expression and tests compose any combination in one line.
struct MeetingSourceCandidate: Equatable {
    let source: AppSource

    /// Lifted out for the sticky-bonus check; lets the scorer stay pure (AppSource equality excludes `meetingTitle`).
    var bundleID: String { source.bundleID }

    var signals: Signals

    /// Assigned by `MeetingSourceScorer.pickBest`; defaults to 0 pre-scoring.
    var score: Int = 0

    struct Signals: Equatable {
        /// AXToolbar matching a per-bundle name (e.g. "Calling controls", "Meeting controls"). Strongest signal: non-meeting shell windows never have it.
        var callingControlsToolbar: Bool

        /// At least one AX button matching the per-bundle leave predicate.
        var leaveButton: Bool

        /// At least one AX button matching the per-bundle mute predicate.
        var muteButton: Bool

        /// At least one window/tab title matches the meeting pattern. For natives: per-bundle recognizer. For browsers: meeting URL fragments from meeting_apps.toml.
        var titleMatch: Bool

        /// `kAudioProcessPropertyIsRunningInput` reports active input for this PID. Webex suppression is a scanner-side filter, not applied here.
        var processAudioActive: Bool

        /// SCShareableContent lists this bundle as an active source. Reserved; scanner always passes `false` pending async pre-scan wiring.
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
