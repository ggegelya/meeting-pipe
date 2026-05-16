import Foundation

/// Per-buffer verdict producer for the MicGate subsystem. Fuses HAL
/// system mute, AX mute label, HAL VAD, and the RMS hysteresis gate
/// into a `MicGateVerdict` that the writer (TECH-G-MIC step 5) uses
/// to choose between live mic samples and zero-amplitude frames.
///
/// Precedence (per the TECH-G-MIC spec):
///   1. `.mutedByHardware` wins when HAL system-input mute is true.
///   2. `.mutedByApp` wins when the AX scrape returns a recognised
///      `.muted` label.
///   3. `.silentByRMS` wins when the RMS gate is currently closed.
///   4. `.hot` wins when HAL VAD reports active or the RMS gate is
///      currently open.
///   5. `.uncertain` for any other combination, with reasons listed.
///
/// The `decide(state:)` static is pure; tests cover the precedence
/// matrix without running the timers. `start(...)`, `ingest(rmsDb:)`,
/// and `stop()` wire the live probes.
///
/// Threading: `start` and `stop` must run on the main queue.
/// `ingest(rmsDb:)` is safe to call from the audio render thread
/// because the RMS gate is allocation-free and the publish path goes
/// through a serial dispatch queue that defers the publish off the
/// render thread.
public final class MicGate {

    public struct State: Equatable {
        public var halSystemMute: Bool?
        public var axMute: MuteLabels.State?
        public var axLabel: String?
        public var axLocale: String?
        public var halVad: Bool?
        public var rmsState: RMSGateProbe.State
        public var rmsCloseDwellMillis: Int

        public init(
            halSystemMute: Bool? = nil,
            axMute: MuteLabels.State? = nil,
            axLabel: String? = nil,
            axLocale: String? = nil,
            halVad: Bool? = nil,
            rmsState: RMSGateProbe.State = .closed,
            rmsCloseDwellMillis: Int = 0
        ) {
            self.halSystemMute = halSystemMute
            self.axMute = axMute
            self.axLabel = axLabel
            self.axLocale = axLocale
            self.halVad = halVad
            self.rmsState = rmsState
            self.rmsCloseDwellMillis = rmsCloseDwellMillis
        }
    }

    public let verdicts: AsyncStream<MicGateVerdict>

    private let continuation: AsyncStream<MicGateVerdict>.Continuation
    private let lock = NSLock()
    private var lastVerdict: MicGateVerdict = .uncertain(reasons: ["not_started"])
    private let publishQueue = DispatchQueue(label: "MeetingPipeCore.MicGate")

    private let eventLog: EventLog
    private let catalogue: MuteLabels
    private let halSystemMuteProbe: HALSystemMuteProbe
    private let halVadProbe: HALVoiceActivityProbe
    private let rmsGate: RMSGateProbe
    private let adapters: [MicGateAdapter]

    private var state = State()
    private var activeAdapter: MicGateAdapter?

    public init(
        catalogue: MuteLabels,
        halBus: CoreAudioHALBus,
        axBus: AXObserverBus,
        eventLog: EventLog = NoopEventLog(),
        adapters: [MicGateAdapter] = [],
        halSystemMuteProbe: HALSystemMuteProbe? = nil,
        halVadProbe: HALVoiceActivityProbe? = nil,
        rmsGate: RMSGateProbe = RMSGateProbe()
    ) {
        self.eventLog = eventLog
        self.catalogue = catalogue
        self.halSystemMuteProbe = halSystemMuteProbe
            ?? HALSystemMuteProbe(halBus: halBus, eventLog: eventLog)
        self.halVadProbe = halVadProbe
            ?? HALVoiceActivityProbe(halBus: halBus, eventLog: eventLog)
        self.rmsGate = rmsGate
        self.adapters = adapters
        var sink: AsyncStream<MicGateVerdict>.Continuation!
        self.verdicts = AsyncStream<MicGateVerdict>(
            bufferingPolicy: .unbounded
        ) { continuation in
            sink = continuation
        }
        self.continuation = sink

        self.halSystemMuteProbe.onChange = { [weak self] muted in
            self?.update { $0.halSystemMute = muted }
        }
        self.halVadProbe.onChange = { [weak self] active in
            self?.update { $0.halVad = active }
        }
        self.halVadProbe.onSupportChange = { [weak self] support in
            if support == .unsupported {
                self?.update { $0.halVad = nil }
            }
        }
        self.rmsGate.onChange = { [weak self] gateState in
            self?.update { $0.rmsState = gateState }
        }
    }

    public func start(context: MeetingLifecycleContext, handle: MicGateAdapterHandle) throws {
        stop()
        try halSystemMuteProbe.start()
        try halVadProbe.start()
        rmsGate.reset()
        update { $0.rmsState = .closed }
        if let adapter = adapters.first(where: { $0.bundleIDs.contains(context.bundleID) }) {
            activeAdapter = adapter
            try adapter.start(context: context, handle: handle) { [weak self] event in
                self?.update {
                    $0.axMute = event.state
                    $0.axLabel = event.label
                    $0.axLocale = event.locale
                }
            }
        }
    }

    public func stop() {
        halSystemMuteProbe.stop()
        halVadProbe.stop()
        rmsGate.reset()
        activeAdapter?.stop()
        activeAdapter = nil
        state = State()
    }

    public func shutdown() {
        stop()
        continuation.finish()
    }

    /// Audio-tap entry point. The host computes an RMS reading
    /// per buffer and forwards it here. The gate is allocation-free
    /// and the publish path defers to `publishQueue` off the render
    /// thread.
    public func ingest(rmsDb: Float) {
        rmsGate.ingest(dBFS: rmsDb)
    }

    public var current: MicGateVerdict {
        lock.withLock { lastVerdict }
    }

    // MARK: - Pure precedence

    public static func decide(state: State) -> MicGateVerdict {
        if state.halSystemMute == true { return .mutedByHardware }
        if case .muted = state.axMute {
            return .mutedByApp(
                axLabel: state.axLabel ?? "",
                locale: state.axLocale ?? ""
            )
        }
        if state.rmsState == .closed && state.halVad != true {
            return .silentByRMS(dwellMillis: state.rmsCloseDwellMillis)
        }
        if state.halVad == true {
            return .hot(reason: .voiceActivityDetected)
        }
        if state.rmsState == .open {
            return .hot(reason: .rmsAboveOpenThreshold)
        }
        var reasons: [String] = []
        if state.halSystemMute == nil { reasons.append("hal_system_mute_unknown") }
        if state.axMute == nil { reasons.append("ax_mute_unavailable") }
        if state.halVad == nil { reasons.append("hal_vad_unsupported") }
        return .uncertain(reasons: reasons.isEmpty ? ["no_probe_definitive"] : reasons)
    }

    // MARK: - State plumbing

    private func update(_ mutator: (inout State) -> Void) {
        var newState = state
        mutator(&newState)
        state = newState
        publish(MicGate.decide(state: newState))
    }

    private func publish(_ verdict: MicGateVerdict) {
        let shouldEmit: Bool = lock.withLock {
            if verdict == lastVerdict { return false }
            lastVerdict = verdict
            return true
        }
        guard shouldEmit else { return }
        let attrs = attributes(for: verdict)
        eventLog.emit(category: "micgate", action: "verdict_changed", attributes: attrs)
        publishQueue.async { [continuation] in
            continuation.yield(verdict)
        }
    }

    private func attributes(for verdict: MicGateVerdict) -> [String: Any] {
        var attrs: [String: Any] = ["verdict": verdict.label]
        switch verdict {
        case .hot(let reason):
            attrs["reason"] = reason.rawValue
        case .mutedByApp(let label, let locale):
            attrs["ax_label"] = label
            attrs["locale"] = locale
        case .silentByRMS(let dwell):
            attrs["dwell_ms"] = dwell
        case .uncertain(let reasons):
            attrs["reasons"] = reasons
        case .mutedByHardware:
            break
        }
        return attrs
    }
}

private extension NSLock {
    func withLock<T>(_ body: () throws -> T) rethrows -> T {
        lock()
        defer { unlock() }
        return try body()
    }
}
