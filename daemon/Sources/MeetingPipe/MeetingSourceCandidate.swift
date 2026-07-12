import Foundation

/// One meeting-app source the scorer evaluates. Flat signal tuple (no nested types) so the scorer computes weights in one expression and tests compose any combination in one line.
struct MeetingSourceCandidate: Equatable {
    let source: AppSource

    /// Lifted out for the sticky-bonus check; lets the scorer stay pure (AppSource equality excludes `meetingTitle`).
    var bundleID: String { source.bundleID }

    var signals: Signals

    /// Whether this native has a live process-audio leg. False for the audio-excluded bundles
    /// (Webex/spark, which keep the mic open post-call for ultrasound device discovery, so a
    /// positive audio read cannot distinguish a live call from an idle post-call state). DET5 uses
    /// it to pick the lone-native confidence bar: an audio-probed native can reach two distinct
    /// signals in a real call (toolbar + Leave + Mute), so it is held to `isConfidentNativeMeeting`;
    /// an audio-excluded native structurally cannot, and its toolbar label is an unreliable English
    /// guess, so it keeps the single-corroborator bar (its DET4 behaviour, since DET5's walk-gate
    /// change never applied to it — it always walked). Browsers set true; the browser path ignores it.
    var hasAudioLeg: Bool = true

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

    init(source: AppSource, signals: Signals = Signals(), hasAudioLeg: Bool = true, score: Int = 0) {
        self.source = source
        self.signals = signals
        self.hasAudioLeg = hasAudioLeg
        self.score = score
    }
}
