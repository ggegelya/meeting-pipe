import Foundation

/// Per-buffer verdict producer. Fuses HAL system-mute, AX mute label, HAL VAD, and RMS hysteresis into a `MicGateVerdict` (TECH-G-MIC spec). Precedence: mutedByHardware > mutedByApp > silentByRMS > hot > uncertain. `decide(state:)` is pure for test coverage. Threading: `start`/`stop` on main; `ingest(rmsDb:)` runs on the render thread. The four signal sources funnel into `update`, whose read-modify-write on `state` is serialized under `lock` so a stale snapshot cannot clobber a fresh write from another source (TECH-MIC2). The RMS gate is allocation-free, and a verdict transition defers the dedupe `lock`, the synchronous `eventLog.emit` (an `events.jsonl` write), and the AsyncStream yield all onto `publishQueue`, so nothing touches the file system on the render thread (TECH-CONC1).
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
    // Serial queue that owns the dedupe lock, the eventLog.emit, and the
    // verdict-stream yield. Tagged with a specific key so a DEBUG assertion can
    // prove the events.jsonl write never runs on the audio render thread.
    private static let publishQueueKey = DispatchSpecificKey<Void>()
    private let publishQueue: DispatchQueue = {
        let queue = DispatchQueue(label: "MeetingPipeCore.MicGate")
        queue.setSpecific(key: MicGate.publishQueueKey, value: ())
        return queue
    }()

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
        lock.withLock { state = State() }
    }

    public func shutdown() {
        stop()
        continuation.finish()
    }

    /// Audio-tap entry point. The RMS computation is allocation-free; a state transition's lock, `eventLog.emit`, and verdict-stream yield are all deferred to `publishQueue`, so this stays render-thread-safe regardless of how heavy `eventLog` is (TECH-CONC1).
    public func ingest(rmsDb: Float) {
        rmsGate.ingest(dBFS: rmsDb)
    }

    /// Merge an AX mute event from an out-of-band probe (e.g. Teams 2 compact view, which appears after `start()` returns) into the same precedence chain. Threading: any queue; `update` serialises the state read-modify-write under `lock` (TECH-MIC2).
    public func injectAxMuteEvent(_ event: AXMuteButtonProbe.Event) {
        update {
            $0.axMute = event.state
            $0.axLabel = event.label
            $0.axLocale = event.locale
        }
    }

    /// Discredit the app-mute read: clears `axMute` so `decide` falls through to
    /// the live VAD/RMS signals instead of latching a stale `.muted`. Used by the
    /// window watcher when the live mute control can no longer be read (e.g. Teams
    /// switched to its compact/mini window and the original element went stale).
    public func clearAxMute() {
        update {
            $0.axMute = nil
            $0.axLabel = nil
            $0.axLocale = nil
        }
    }

    public var current: MicGateVerdict {
        lock.withLock { lastVerdict }
    }

    #if DEBUG
    /// Test-only: drive the same serialized state read-modify-write the probes
    /// use, so a concurrency test can interleave independent field writes from
    /// many threads and prove none is clobbered (TECH-MIC2).
    func debugUpdate(_ mutator: (inout State) -> Void) {
        update(mutator)
    }

    /// Test-only: a consistent snapshot of the fused state, read under `lock`.
    func debugStateSnapshot() -> State {
        lock.withLock { state }
    }
    #endif

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
        // Serialize the read-modify-write. Four signal sources call this off
        // different threads (AX probe, window watcher, RMS gate on the render
        // thread, HAL probes). An unsynchronized RMW let a thread that
        // snapshotted `state` early write the whole struct back later and
        // clobber a field a concurrent source had just set, so a fresh
        // `.unmuted` could be reverted to a stale `.muted` (TECH-MIC2). The
        // snapshot used for `decide` is taken under the lock so the verdict
        // always reflects a consistent state.
        let snapshot: State = lock.withLock {
            var newState = state
            mutator(&newState)
            state = newState
            return newState
        }
        publish(MicGate.decide(state: snapshot))
    }

    private func publish(_ verdict: MicGateVerdict) {
        // Everything here, the dedupe lock and the synchronous events.jsonl
        // write in eventLog.emit, must stay off the audio render thread
        // (TECH-CONC1). Hop to the serial publishQueue, which also keeps the
        // emit ordered ahead of the verdict-stream yield as before.
        publishQueue.async { [weak self, continuation] in
            guard let self else { return }
            let shouldEmit: Bool = self.lock.withLock {
                if verdict == self.lastVerdict { return false }
                self.lastVerdict = verdict
                return true
            }
            guard shouldEmit else { return }
            #if DEBUG
            assert(
                DispatchQueue.getSpecific(key: MicGate.publishQueueKey) != nil,
                "MicGate.eventLog.emit must run on publishQueue, never the audio render thread (TECH-CONC1)"
            )
            #endif
            let attrs = self.attributes(for: verdict)
            self.eventLog.emit(category: "micgate", action: "verdict_changed", attributes: attrs)
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
