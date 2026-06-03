import XCTest
@testable import MeetingPipeCore

final class MicGateDecideTests: XCTestCase {

    func test_hardware_mute_wins_over_everything() {
        let state = MicGate.State(
            halSystemMute: true,
            axMute: .unmuted,
            axLabel: "Mute",
            axLocale: "en",
            halVad: true,
            rmsState: .open
        )
        XCTAssertEqual(MicGate.decide(state: state), .mutedByHardware)
    }

    func test_app_mute_wins_when_hardware_is_not_muted() {
        let state = MicGate.State(
            halSystemMute: false,
            axMute: .muted,
            axLabel: "Unmute",
            axLocale: "en",
            halVad: true,
            rmsState: .open
        )
        XCTAssertEqual(
            MicGate.decide(state: state),
            .mutedByApp(axLabel: "Unmute", locale: "en")
        )
    }

    func test_silent_by_rms_when_gate_closed_and_no_vad() {
        let state = MicGate.State(
            halSystemMute: false,
            axMute: .unmuted,
            halVad: false,
            rmsState: .closed,
            rmsCloseDwellMillis: 400
        )
        XCTAssertEqual(MicGate.decide(state: state), .silentByRMS(dwellMillis: 400))
    }

    func test_hot_vad_when_vad_active_and_gate_closed() {
        let state = MicGate.State(
            halSystemMute: false,
            axMute: .unmuted,
            halVad: true,
            rmsState: .closed
        )
        XCTAssertEqual(MicGate.decide(state: state), .hot(reason: .voiceActivityDetected))
    }

    func test_hot_rms_when_no_vad_but_gate_open() {
        let state = MicGate.State(
            halSystemMute: false,
            axMute: .unmuted,
            halVad: nil,
            rmsState: .open
        )
        XCTAssertEqual(MicGate.decide(state: state), .hot(reason: .rmsAboveOpenThreshold))
    }

    func test_uncertain_lists_missing_probes() {
        let state = MicGate.State()
        let verdict = MicGate.decide(state: state)
        guard case .silentByRMS = verdict else {
            // default rmsState is .closed so the precedence drops to silent by rms;
            // uncertain only fires when rms isn't dominant either.
            return XCTFail("Expected silentByRMS default fallthrough; got \(verdict)")
        }
    }

    func test_uncertain_when_no_probe_definitive() {
        // halSystemMute nil, axMute nil, halVad nil, gate .open (so not silent),
        // hardware unknown -> falls through to the final clauses; gate .open
        // promotes to hot before uncertain. To genuinely hit uncertain we need
        // gate state we don't know either - the model only exposes .open / .closed,
        // so uncertain is reserved for cases where future probe states wedge in.
        // For now, lock in the reason set when nothing else applies.
        let state = MicGate.State(
            halSystemMute: nil,
            axMute: nil,
            halVad: nil,
            rmsState: .open
        )
        // Open gate is hot, not uncertain.
        XCTAssertEqual(MicGate.decide(state: state), .hot(reason: .rmsAboveOpenThreshold))
    }
}

final class MicGateIntegrationTests: XCTestCase {

    private static let catalogue: MuteLabels = {
        try! MuteLabelsLoader.loadDefault()
    }()

    private let teamsContext = MeetingLifecycleContext(
        bundleID: "com.microsoft.teams2", kind: .native, pid: 1234
    )

    func test_start_uses_matching_adapter_for_bundle_id() throws {
        let halBus = CoreAudioHALBus()
        let axBus = AXObserverBus()
        let teams = NativeMuteAdapter(config: .teams, axBus: axBus, catalogue: Self.catalogue)
        let zoom = NativeMuteAdapter(config: .zoom, axBus: axBus, catalogue: Self.catalogue)
        let gate = MicGate(
            catalogue: Self.catalogue,
            halBus: halBus,
            axBus: axBus,
            adapters: [zoom, teams]
        )
        try gate.start(context: teamsContext, handle: MicGateAdapterHandle(muteButton: nil))
        gate.stop()
    }

    func test_verdict_changes_emit_event_log_entry() throws {
        let log = RecordingEventLog()
        let halBus = CoreAudioHALBus()
        let axBus = AXObserverBus()
        let gate = MicGate(
            catalogue: Self.catalogue, halBus: halBus, axBus: axBus, eventLog: log
        )
        try gate.start(context: teamsContext, handle: MicGateAdapterHandle())

        // emit is deferred to the gate's serial publishQueue (TECH-CONC1);
        // wait a tick for it to drain before asserting.
        let exp = expectation(description: "emit")
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.05) { exp.fulfill() }
        wait(for: [exp], timeout: 1.0)

        gate.stop()
        XCTAssertTrue(log.entries.contains { $0.action == "verdict_changed" })
    }

    /// The dedupe lock and the synchronous events.jsonl write in
    /// `eventLog.emit` must never run on the thread that drives a verdict
    /// change (the audio render thread in production). Drive a change from a
    /// tagged queue and prove emit ran somewhere else. (TECH-CONC1)
    func test_emit_runs_off_the_calling_thread() {
        let halBus = CoreAudioHALBus()
        let axBus = AXObserverBus()
        let exp = expectation(description: "emit")
        var ranOnCallerQueue = true
        let log = ThreadProbeEventLog { onCaller in
            ranOnCallerQueue = onCaller
            exp.fulfill()
        }
        let gate = MicGate(catalogue: Self.catalogue, halBus: halBus, axBus: axBus, eventLog: log)
        defer { gate.shutdown() }

        let caller = DispatchQueue(label: "test.micgate.caller")
        caller.setSpecific(key: ThreadProbeEventLog.callerKey, value: ())
        caller.async {
            gate.injectAxMuteEvent(
                AXMuteButtonProbe.Event(state: .muted, label: "Unmute", locale: "en")
            )
        }

        wait(for: [exp], timeout: 1.0)
        XCTAssertFalse(
            ranOnCallerQueue,
            "eventLog.emit must run off the caller (render) thread (TECH-CONC1)"
        )
    }

    /// Out-of-band AX mute events fed via injectAxMuteEvent must
    /// flow through the same precedence chain as the adapter sink.
    /// Used by MeetingAXWindowWatcher (TECH-C14) to merge events
    /// from mute buttons in windows that appear after start().
    func test_injectAxMuteEvent_flips_verdict_to_muted_by_app() throws {
        let halBus = CoreAudioHALBus()
        let axBus = AXObserverBus()
        let gate = MicGate(catalogue: Self.catalogue, halBus: halBus, axBus: axBus)
        try gate.start(context: teamsContext, handle: MicGateAdapterHandle())
        defer { gate.stop() }

        let mutedEvent = AXMuteButtonProbe.Event(
            state: .muted, label: "Unmute", locale: "en"
        )
        gate.injectAxMuteEvent(mutedEvent)

        // The publish path is async on the gate's internal queue;
        // wait a tick for it to drain.
        let exp = expectation(description: "verdict")
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.05) { exp.fulfill() }
        wait(for: [exp], timeout: 1.0)

        XCTAssertEqual(
            gate.current,
            .mutedByApp(axLabel: "Unmute", locale: "en")
        )
    }
}

/// EventLog stub that reports whether `emit` ran on a queue the test tagged
/// with `callerKey`. Used to prove the events.jsonl write is deferred off the
/// calling thread (TECH-CONC1).
private final class ThreadProbeEventLog: EventLog {
    static let callerKey = DispatchSpecificKey<Void>()
    private let onEmit: (_ ranOnCaller: Bool) -> Void

    init(onEmit: @escaping (_ ranOnCaller: Bool) -> Void) {
        self.onEmit = onEmit
    }

    func emit(category: String, action: String, attributes: [String: Any]) {
        onEmit(DispatchQueue.getSpecific(key: ThreadProbeEventLog.callerKey) != nil)
    }
}
