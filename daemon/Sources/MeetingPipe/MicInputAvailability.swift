import AVFoundation
import Foundation

/// DET10: the vocabulary for saying out loud that the mic-busy detection input could not be wired.
///
/// `MeetingDiscoveryWatcher.wireMicObserver` resolves `AVCaptureDevice.default(for: .audio)` exactly
/// once, at daemon start, and a nil there is never retried: the KVO is never installed,
/// `sampleMicBusy` returns early on every poll for the rest of the process lifetime, and both
/// `MicBusySpanTracker` (DET3's spans) and `MicInUseTier` (DET1's catch-all) are dead for that whole
/// run. It used to `return` silently, so the only trace of a permanently-dead detection input was an
/// absence, and an absence is exactly what `mp analyze-detection` then rendered as zero mic-busy
/// misses: the instrument built to make silent false-negatives visible reporting clean because its
/// own input was gone. The `detector.mic_device_unavailable` event replaces that silence.
///
/// This is deliberately only the *reporting* half. Whether the nil is the reason the dogfood log
/// holds zero mic-busy spans is unestablished (the other candidate is
/// `isInUseByAnotherApplication` being structurally false for shared macOS inputs), so DET10 is
/// probe-first and neither the retry nor a replacement signal is written here. See
/// `docs/backlog/tasks/DET10.md` and `daemon/scripts/det10-mic-busy-probe.swift`.
///
/// Pure, and separate from the watcher so the vocabulary is testable: the watcher itself needs
/// AVFoundation and NSWorkspace and has no test harness.
enum MicInputAvailability {

    /// Stable snake_case label for a microphone TCC status, stamped on the event's `authorization`
    /// attribute.
    ///
    /// The distinction is load-bearing for whoever reads the log: "this Mac exposes no audio input"
    /// and "the microphone grant is denied or has never been asked for" both surface as the same nil
    /// device, and they take different fixes. A reader that cannot tell them apart is back to
    /// guessing, which is the failure DET10 exists to stop.
    static func authorizationLabel(_ status: AVAuthorizationStatus) -> String {
        switch status {
        case .authorized: return "authorized"
        case .denied: return "denied"
        case .restricted: return "restricted"
        case .notDetermined: return "not_determined"
        @unknown default: return "unknown"
        }
    }
}
