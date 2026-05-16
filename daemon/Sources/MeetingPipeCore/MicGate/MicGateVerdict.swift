import Foundation

/// Per-buffer verdict from `MicGate`. Determines whether the writer
/// should emit live mic samples or zero-amplitude frames for the
/// current capture buffer.
///
/// Each case carries the reasoning chain that justifies it; the
/// reasons are written into events.jsonl so post-hoc analysis can
/// reconstruct why the gate flipped.
public enum MicGateVerdict: Equatable {
    /// Mic is hot: live samples pass through. The reason names which
    /// PRIMARY probe satisfied (VAD vs RMS-above-open-threshold).
    case hot(reason: Reason)

    /// Meeting app reports mute via AX. The writer emits zero-amp
    /// frames and the audit attribute records the localised label
    /// that matched.
    case mutedByApp(axLabel: String, locale: String)

    /// System input mute (Control Center / hardware key / per-device
    /// property) is engaged. Highest precedence.
    case mutedByHardware

    /// RMS gate is in the closed state. Used when no other PRIMARY
    /// signal flips and the user is simply silent.
    case silentByRMS(dwellMillis: Int)

    /// No probe gave a confident verdict. The writer still emits
    /// zero-amp frames (safer than risking ambient capture) and the
    /// audit log lists every probe's reasoning so the gap can be
    /// investigated.
    case uncertain(reasons: [String])

    public enum Reason: String, Equatable {
        case voiceActivityDetected = "vad_active"
        case rmsAboveOpenThreshold = "rms_above_open_threshold"
    }

    /// Whether the writer should pass live mic samples for this
    /// verdict. The only case that admits live audio is `.hot`.
    public var passesLiveAudio: Bool {
        if case .hot = self { return true }
        return false
    }

    public var label: String {
        switch self {
        case .hot: return "hot"
        case .mutedByApp: return "muted_by_app"
        case .mutedByHardware: return "muted_by_hardware"
        case .silentByRMS: return "silent_by_rms"
        case .uncertain: return "uncertain"
        }
    }
}
