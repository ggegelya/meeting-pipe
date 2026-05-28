import Foundation

/// Watches mic + system audio levels to auto-stop a recording the end-detector
/// missed (TECH-C2). Covers browser-tab meetings where a stale "Meet" tab or
/// Slack huddle thread keeps the window-title probe firing after the call ends.
///
/// Both channels must fall below thresholdDb to start a streak. After
/// notifyAfterSec: fire onNotifySilence once ("Still meeting?" notification).
/// After autoStopAfterSec: fire onAutoStopSilence once. Any non-silent sample
/// resets the streak.
///
/// Pure timing logic: no Timer owned here. The Coordinator drives observeMic /
/// observeSystem from the Recorder's ~1×/sec level callbacks; tests inject the
/// clock via the at: parameter.
///
/// If Screen Recording is denied, the system stream never delivers and
/// latestSystemDb stays at -.infinity, reducing the gate to mic-only silence -
/// the correct behaviour for a mic-only recording.
final class SilenceDetector {
    static let defaultThresholdDb: Double = -50.0
    static let defaultNotifyAfterSec: TimeInterval = 90
    static let defaultAutoStopAfterSec: TimeInterval = 300

    private let thresholdDb: Double
    private let notifyAfterSec: TimeInterval
    private let autoStopAfterSec: TimeInterval
    private let onNotifySilence: () -> Void
    private let onAutoStopSilence: () -> Void

    private var latestMicDb: Double = -.infinity
    private var latestSystemDb: Double = -.infinity
    private var silenceStartedAt: Date?
    private var didNotify: Bool = false
    private var didAutoStop: Bool = false

    init(
        thresholdDb: Double = SilenceDetector.defaultThresholdDb,
        notifyAfterSec: TimeInterval = SilenceDetector.defaultNotifyAfterSec,
        autoStopAfterSec: TimeInterval = SilenceDetector.defaultAutoStopAfterSec,
        onNotifySilence: @escaping () -> Void,
        onAutoStopSilence: @escaping () -> Void
    ) {
        self.thresholdDb = thresholdDb
        self.notifyAfterSec = notifyAfterSec
        self.autoStopAfterSec = autoStopAfterSec
        self.onNotifySilence = onNotifySilence
        self.onAutoStopSilence = onAutoStopSilence
    }

    /// Reset streak state for reuse across recordings. Levels reset to -.infinity
    /// so "unknown" counts as silent and the auto-stop path arms (matches no-system-audio).
    func reset() {
        latestMicDb = -.infinity
        latestSystemDb = -.infinity
        silenceStartedAt = nil
        didNotify = false
        didAutoStop = false
    }

    func observeMic(db: Double, at time: Date = Date()) {
        latestMicDb = db
        evaluate(at: time)
    }

    func observeSystem(db: Double, at time: Date = Date()) {
        latestSystemDb = db
        evaluate(at: time)
    }

    private func evaluate(at time: Date) {
        if didAutoStop { return } // recorder is tearing down; stale ticks must not re-fire

        let silent = latestMicDb < thresholdDb && latestSystemDb < thresholdDb
        if !silent {
            silenceStartedAt = nil
            didNotify = false
            return
        }

        let start = silenceStartedAt ?? time
        silenceStartedAt = start
        let elapsed = time.timeIntervalSince(start)

        if elapsed >= autoStopAfterSec {
            didAutoStop = true
            onAutoStopSilence()
            return
        }
        if elapsed >= notifyAfterSec && !didNotify {
            didNotify = true
            onNotifySilence()
        }
    }
}
