import Foundation

/// MIC21: which speech evidence a recording had, and how long each held MicGate's verdict, for the
/// one `micgate` / `speech_evidence` row written at the stop. Pure: the gate feeds it every verdict
/// it publishes, with the state that produced it, on its publish queue.
///
/// The five sources the row names, and the verdicts each holds:
/// - `app_mute_ax`, `app_mute_log`: `muted_by_app`, and the confidently-unmuted floor, from
///   whichever oracle wrote the mute reading (MIC8's fusion);
/// - `hal_vad`: hot on the OS's voice activity;
/// - `rms_gate`: hot on the level alone (`rms_above_open_threshold`, `rms_stationary_noise`) and
///   `silent_by_rms`;
/// - `speech_detector`: hot on the daemon's own detector.
/// `muted_by_hardware` and `uncertain` belong to none of them and count as `other`.
public struct SpeechEvidenceLedger: Equatable {

    public enum Source: String, CaseIterable, Sendable {
        case appMuteAX = "app_mute_ax"
        case appMuteLog = "app_mute_log"
        case halVad = "hal_vad"
        case rmsGate = "rms_gate"
        case speechDetector = "speech_detector"
        case other
    }

    public let startedAt: Date
    public private(set) var seconds: [Source: TimeInterval] = [:]
    public private(set) var available: Set<Source> = [.rmsGate]
    private var holder: Source?
    private var since: Date

    public init(startedAt: Date) {
        self.startedAt = startedAt
        self.since = startedAt
    }

    /// The source that holds `verdict`, given the state that produced it.
    public static func holder(of verdict: MicGateVerdict, state: MicGate.State) -> Source {
        let appMute: Source = state.axMuteSource == .log ? .appMuteLog : .appMuteAX
        switch verdict {
        case .mutedByApp:
            return appMute
        case .hot(let reason):
            switch reason {
            case .confidentlyUnmuted: return appMute
            case .voiceActivityDetected: return .halVad
            case .speechDetected: return .speechDetector
            case .rmsAboveOpenThreshold, .rmsStationaryNoise: return .rmsGate
            }
        case .silentByRMS:
            return .rmsGate
        case .mutedByHardware, .uncertain:
            return .other
        }
    }

    /// One published verdict. Time since the last change goes to the source that held it.
    public mutating func observe(state: MicGate.State, halVadSupported: Bool, verdict: MicGateVerdict, at now: Date) {
        if let source = state.axMuteSource, state.axMute != nil {
            available.insert(source == .log ? .appMuteLog : .appMuteAX)
        }
        if halVadSupported { available.insert(.halVad) }
        if state.detectedVoice != nil, !halVadSupported { available.insert(.speechDetector) }
        let next = Self.holder(of: verdict, state: state)
        guard next != holder else { return }
        accrue(until: now)
        holder = next
    }

    /// The recording stopped: the last holder's time is counted.
    public mutating func close(at now: Date) {
        accrue(until: now)
        holder = nil
    }

    private mutating func accrue(until now: Date) {
        if let holder {
            seconds[holder, default: 0] += max(0, now.timeIntervalSince(since))
        }
        since = now
    }

    /// The row: per source whether it was available and the seconds it held the verdict, plus the
    /// total, so shares are computable.
    public var attributes: [String: Any] {
        var attrs: [String: Any] = [:]
        var total: TimeInterval = 0
        for source in Source.allCases {
            let held = (seconds[source] ?? 0).rounded(toPlaces: 1)
            total += seconds[source] ?? 0
            attrs["\(source.rawValue)_sec"] = held
            if source != .other { attrs["\(source.rawValue)_available"] = available.contains(source) }
        }
        attrs["total_sec"] = total.rounded(toPlaces: 1)
        return attrs
    }
}

private extension Double {
    func rounded(toPlaces places: Int) -> Double {
        let scale = pow(10, Double(places))
        return (self * scale).rounded() / scale
    }
}
