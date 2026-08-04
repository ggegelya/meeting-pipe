import Foundation

/// Per-buffer verdict producer. Fuses HAL system-mute, the app-mute read, HAL VAD, and RMS hysteresis into a `MicGateVerdict` (TECH-G-MIC spec). Precedence: mutedByHardware > mutedByApp > silentByRMS > hot > uncertain. `decide(state:)` is pure for test coverage. The app-mute read itself now has two oracles rather than one (MIC8): the AX label scrape and, for Teams, `LogMuteAdapter` reading the client's own SlimCore log; they share the `axMute` field and `MuteSourceFusion` decides which reading wins, so `decide` is unchanged. Threading: `start`/`stop` on main; `ingest(rmsDb:)` runs on the render thread. The four signal sources funnel into `update`, whose read-modify-write on `state` is serialized under `lock` so a stale snapshot cannot clobber a fresh write from another source (TECH-MIC2). The RMS gate is allocation-free, and a verdict transition defers the dedupe `lock`, the synchronous `eventLog.emit` (an `events.jsonl` write), and the AsyncStream yield all onto `publishQueue`, so nothing touches the file system on the render thread (TECH-CONC1).
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
    /// MIC8 fusion inputs: the clock the freshness comparison reads, and how long a
    /// log reading outranks an AX one. Injected so a test can drive the precedence
    /// without sleeping.
    private let now: () -> Date
    private let logFreshness: TimeInterval

    private var state = State()
    private var activeAdapters: [MicGateAdapter] = []
    /// When the SlimCore log last spoke, i.e. how `MuteSourceFusion` decides whether
    /// the log is "present". Read and written under `lock` with the state itself, so
    /// the gate and the write it guards cannot interleave.
    private var lastLogReadingAt: Date?

    public init(
        catalogue: MuteLabels,
        halBus: CoreAudioHALBus,
        axBus: AXObserverBus,
        eventLog: EventLog = NoopEventLog(),
        adapters: [MicGateAdapter] = [],
        halSystemMuteProbe: HALSystemMuteProbe? = nil,
        halVadProbe: HALVoiceActivityProbe? = nil,
        rmsGate: RMSGateProbe = RMSGateProbe(),
        now: @escaping () -> Date = { Date() },
        logFreshness: TimeInterval = MuteSourceFusion.defaultLogFreshness
    ) {
        self.eventLog = eventLog
        self.catalogue = catalogue
        self.now = now
        self.logFreshness = logFreshness
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
        // One adapter per signal source (MIC8), first match wins within a source.
        // Before MIC8 this was a flat `first(where:)` over the whole list, and for
        // every `.ax` adapter that is still exactly what happens: the two browser
        // no-op adapters share one bundle set, and only the first (`.meet`) starts,
        // so their two distinct `micgate` actions still tell the no-AX surfaces
        // apart. Teams now also matches a `.log` adapter, so both run and
        // `MuteSourceFusion` decides which reading wins.
        for source in MuteReadingSource.allCases {
            guard let adapter = adapters.first(where: {
                $0.source == source && $0.bundleIDs.contains(context.bundleID)
            }) else { continue }
            activeAdapters.append(adapter)
            try adapter.start(context: context, handle: handle) { [weak self] event in
                self?.applyMuteReading(event, source: source)
            }
        }
    }

    public func stop() {
        halSystemMuteProbe.stop()
        halVadProbe.stop()
        rmsGate.reset()
        for adapter in activeAdapters { adapter.stop() }
        activeAdapters.removeAll()
        lock.withLock {
            state = State()
            lastLogReadingAt = nil
        }
    }

    public func shutdown() {
        stop()
        continuation.finish()
    }

    /// Audio-tap entry point. The RMS computation is allocation-free; a state transition's lock, `eventLog.emit`, and verdict-stream yield are all deferred to `publishQueue`, so this stays render-thread-safe regardless of how heavy `eventLog` is (TECH-CONC1).
    public func ingest(rmsDb: Float) {
        rmsGate.ingest(dBFS: rmsDb)
    }

    /// Merge an app-mute event from an out-of-band probe (e.g. Teams 2 compact view, which appears after `start()` returns) into the same precedence chain. Threading: any queue; the read-modify-write is serialised under `lock` (TECH-MIC2). `source` defaults to `.ax`, which is what every caller outside `MicGate` itself is: the window watcher's 1 Hz poll.
    public func injectAxMuteEvent(
        _ event: AXMuteButtonProbe.Event, source: MuteReadingSource = .ax
    ) {
        applyMuteReading(event, source: source)
    }

    /// Discredit the app-mute read: clears `axMute` so `decide` falls through to
    /// the live VAD/RMS signals instead of latching a stale `.muted`. Used by the
    /// window watcher when the live mute control can no longer be read (e.g. Teams
    /// switched to its compact/mini window and the original element went stale).
    ///
    /// Fused like a reading, and for the same reason (MIC8): a blind AX read is not
    /// evidence about the log, so while a log reading is fresh the clear is refused
    /// rather than throwing away the oracle that just answered.
    public func clearAxMute(source: MuteReadingSource = .ax) {
        applyMuteReading(nil, source: source)
    }

    /// The single entry point for every app-mute reading, from either oracle
    /// (MIC8). Applies `MuteSourceFusion`'s precedence, stamps the log's freshness,
    /// and only then performs the same read-modify-write the probes do. A nil event
    /// is a clear.
    private func applyMuteReading(_ event: AXMuteButtonProbe.Event?, source: MuteReadingSource) {
        let timestamp = now()
        var accepted = false
        let snapshot: State = lock.withLock {
            accepted = MuteSourceFusion.accepts(
                source: source, now: timestamp,
                lastLogReadingAt: lastLogReadingAt, freshness: logFreshness
            )
            guard accepted else { return state }
            if source == .log { lastLogReadingAt = timestamp }
            var newState = state
            newState.axMute = event?.state
            newState.axLabel = event?.label
            newState.axLocale = event?.locale
            state = newState
            return newState
        }
        guard accepted else {
            noteSuppressedReading(event, source: source)
            return
        }
        publish(MicGate.decide(state: snapshot))
    }

    /// Record a reading the fusion declined. Rare by construction: both AX producers
    /// dedupe, so this fires at most once per real AX transition that lands inside a
    /// fresh log reading's window, not at the poll rate.
    private func noteSuppressedReading(
        _ event: AXMuteButtonProbe.Event?, source: MuteReadingSource
    ) {
        publishQueue.async { [weak self] in
            guard let self = self else { return }
            self.eventLog.emit(category: "micgate", action: "mute_reading_suppressed", attributes: [
                "source": source.rawValue,
                "winner": MuteReadingSource.log.rawValue,
                "kind": event == nil ? "clear" : "state",
                "state": event.map { $0.state == .muted ? "muted" : ($0.state == .unmuted ? "unmuted" : "unknown") } as Any,
            ])
        }
    }

    public var current: MicGateVerdict {
        lock.withLock { lastVerdict }
    }

    /// The current fused HAL voice-activity state, read under `lock`. The window watcher reads it
    /// to detect a stale app-mute (MIC10 part 2): app says muted while the OS says the user is
    /// speaking. `nil` (VAD unsupported on this input) reads as not-active.
    public var currentVadActive: Bool {
        lock.withLock { state.halVad == true }
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
            // Confidently-unmuted floor (TECH-MIC5): a confident app-unmute keeps
            // audio even when the RMS gate is closed, so a quiet-but-unmuted
            // moment is never dropped. A distinct reason lets the silence
            // backstop still count it as quiet (the user just isn't talking).
            if case .unmuted = state.axMute {
                return .hot(reason: .confidentlyUnmuted)
            }
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
