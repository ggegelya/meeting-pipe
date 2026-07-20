import Foundation

/// One meeting-app source the scorer evaluates. Flat signal tuple (no nested types) so the scorer computes weights in one expression and tests compose any combination in one line.
struct MeetingSourceCandidate: Equatable {
    let source: AppSource

    /// Lifted out for the sticky-bonus check; lets the scorer stay pure (AppSource equality excludes `meetingTitle`).
    var bundleID: String { source.bundleID }

    var signals: Signals

    /// Which lone-native confidence bar DET5 applies. False only for the Webex/spark bundles.
    ///
    /// The name is historical: it once meant "this native is probed for process audio", the probe
    /// that excluded Webex/spark because they keep the mic open post-call for ultrasound device
    /// discovery. DET2 closed that probe as permanently dead (2026-07-20) and the discovery path
    /// no longer reads process audio at all, so no candidate has an audio leg now. The flag is kept
    /// because the behaviour it gates is still wanted and unrelated to audio: a normal native can
    /// reach two distinct signals in a real call (toolbar + Leave + Mute) so it is held to
    /// `isConfidentNativeMeeting`, while Webex/spark cannot reach that bar as reliably (their
    /// toolbar label is an unreliable English guess), so they keep DET4's single-corroborator bar.
    /// Browsers set true; the browser path ignores it.
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

        /// SCShareableContent lists this bundle as an active source. Reserved; scanner always passes `false` pending async pre-scan wiring.
        var shareableContentActive: Bool

        init(
            callingControlsToolbar: Bool = false,
            leaveButton: Bool = false,
            muteButton: Bool = false,
            titleMatch: Bool = false,
            shareableContentActive: Bool = false
        ) {
            self.callingControlsToolbar = callingControlsToolbar
            self.leaveButton = leaveButton
            self.muteButton = muteButton
            self.titleMatch = titleMatch
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
