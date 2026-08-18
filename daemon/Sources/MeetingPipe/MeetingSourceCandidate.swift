import Foundation

/// One meeting-app source the scorer evaluates. Flat signal tuple (no nested types) so the scorer computes weights in one expression and tests compose any combination in one line.
struct MeetingSourceCandidate: Equatable {
    let source: AppSource

    /// Lifted out for the sticky-bonus check; lets the scorer stay pure (AppSource equality excludes `meetingTitle`).
    var bundleID: String { source.bundleID }

    var signals: Signals

    /// Which lone-native confidence bar DET5 applies. False only for the Webex/spark bundles.
    ///
    /// The name is historical and stays that way even now that the discovery scan reads process
    /// audio again. It once meant "this native is probed for process audio", the probe that excluded
    /// Webex/spark because they keep the mic open post-call for ultrasound device discovery; the DET2
    /// cleanup removed that probe (2026-07-20), DET8 revived the signal end-side (2026-08-05), and
    /// DET12 revived it start-side. So some candidates do carry an audio read again, but this flag is
    /// still not that set: `MeetingSourceScanner.readsProcessAudio` is, and it answers false for Slack
    /// while this flag is true for it. Renaming was left alone rather than folded into DET12.
    ///
    /// What the flag actually gates is unrelated to audio and still wanted: a normal native can reach
    /// two distinct signals in a real call (toolbar + Leave + Mute) so it is held to
    /// `isConfidentNativeMeeting`, while Webex/spark cannot reach that bar as reliably (their toolbar
    /// label is an unreliable English guess), so they keep DET4's single-corroborator bar. Browsers
    /// set true; the browser path ignores it.
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

        /// `kAudioProcessPropertyIsRunningInput` reads true for at least one HAL process object
        /// carrying this app's audio (DET12). The same property `ProcessAudioSignal` watches
        /// end-side, read here once per scan through `ProcessAudioScanProbe`.
        ///
        /// Set for natives only, and only for the bundles `NativeLifecycleConfig.usesProcessAudio`
        /// names (Teams and Zoom today). Browsers and PWAs never carry it: a browser holding the mic
        /// names the browser and not the tab. Webex never carries it either, because Cisco holds the
        /// mic open post-call for ultrasound device discovery, so a true read there says nothing
        /// about whether a call is live. `MeetingSourceScanner.readsProcessAudio` is the one gate,
        /// which is what lets the scorer OR this in without re-asking about kind.
        ///
        /// An unknown read (list unreadable, nothing matched) degrades to false like every other
        /// signal here. Unlike every other signal it needs no Accessibility grant, so it is the one
        /// signal a native still carries when AX is denied (DET11's blackout).
        var processAudioIsRunningInput: Bool

        /// SCShareableContent lists this bundle as an active source. Reserved; scanner always passes `false` pending async pre-scan wiring.
        var shareableContentActive: Bool

        init(
            callingControlsToolbar: Bool = false,
            leaveButton: Bool = false,
            muteButton: Bool = false,
            titleMatch: Bool = false,
            processAudioIsRunningInput: Bool = false,
            shareableContentActive: Bool = false
        ) {
            self.callingControlsToolbar = callingControlsToolbar
            self.leaveButton = leaveButton
            self.muteButton = muteButton
            self.titleMatch = titleMatch
            self.processAudioIsRunningInput = processAudioIsRunningInput
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
