import Foundation

/// How a recording treats the microphone, resolved once at `beginRecording` and
/// threaded into `MeetingRecorder.start` with no default so every call site must
/// choose (TECH-MIC4, ratified by ADR 0016).
///
/// The architectural root cause of the "talking unmuted, recorded nothing"
/// failure was a real-time destructive gate that depended on a mute reading that
/// does not exist for most tools and is fragile where it does. The cure is to
/// stop deciding destructively in real time: capture losslessly and redact muted
/// spans offline, keeping the full recording for recovery. The only path that
/// still gates in real time is regulated / NDA, where no audio at rest is
/// permitted and the data-loss risk is an accepted trade.
enum CaptureMode: Equatable {
    /// Capture the mic losslessly; never zero it at capture. Muted spans are
    /// recorded as a timeline and redacted from the consumed artifact offline
    /// (TECH-MIC5). The full recording is kept locally for recovery. The default.
    case captureFirst

    /// Real-time destructive gate: muted spans are zeroed in place at capture so
    /// no muted audio is ever written to disk. Used under regulated (global) or
    /// NDA (per-workflow) where no audio at rest is permitted. Carries the
    /// residual data-loss risk ADR 0016 documents; its only lever is the oracle
    /// hardening in TECH-MIC6.
    case regulatedGate

    /// Resolve the mode for a recording. Regulated or NDA forces the no-audio-at-rest
    /// gate; everything else captures first. This is the only resolution rule, so an
    /// ambiguous caller that cannot read the flags should pass `.regulatedGate`
    /// explicitly (the privacy-safe path), per ADR 0016.
    static func resolve(regulated: Bool, nda: Bool) -> CaptureMode {
        (regulated || nda) ? .regulatedGate : .captureFirst
    }

    /// True when the mic is captured losslessly (no real-time zeroing).
    var capturesLosslessly: Bool { self == .captureFirst }

    /// Stable on-disk token written at recording start (`<stem>.capturemode`) so
    /// orphan recovery, after a crash where `stop()` never wrote the mute
    /// timeline, can still apply the right privacy posture (TECH-MIC5 review).
    var marker: String {
        switch self {
        case .captureFirst: return "capture_first"
        case .regulatedGate: return "regulated_gate"
        }
    }

    init?(marker: String) {
        switch marker.trimmingCharacters(in: .whitespacesAndNewlines) {
        case "capture_first": self = .captureFirst
        case "regulated_gate": self = .regulatedGate
        default: return nil
        }
    }
}
