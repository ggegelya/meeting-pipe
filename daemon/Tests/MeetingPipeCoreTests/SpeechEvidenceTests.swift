import XCTest
@testable import MeetingPipeCore

/// MIC21: the gate feeds its speech detector into the VAD input only where HAL has none, and
/// accounts which evidence held the verdict for the `speech_evidence` row.
final class SpeechEvidenceTests: XCTestCase {

    private static let catalogue: MuteLabels = { try! MuteLabelsLoader.loadDefault() }()

    private final class Clock {
        var now = Date(timeIntervalSince1970: 1_800_000_000)
    }

    private func drain(_ gate: MicGate) {
        gate.debugDrainPublishQueue()
    }

    private func makeGate(_ clock: Clock, vad: HALVoiceActivityProbe, log: EventLog = NoopEventLog()) -> MicGate {
        MicGate(
            catalogue: Self.catalogue, halBus: CoreAudioHALBus(), axBus: AXObserverBus(), eventLog: log,
            halVadProbe: vad,
            rmsGate: RMSGateProbe(clock: { clock.now }),
            speechDetector: FloorSpeechDetector(clock: { clock.now }),
            now: { clock.now }
        )
    }

    /// Speech at about -50 dBFS over a -70 floor, under the RMS gate's -45 open threshold.
    private func feedQuietSpeech(_ gate: MicGate, _ clock: Clock, seconds: TimeInterval) {
        var t: TimeInterval = 0
        while t < seconds {
            let inGap = t.truncatingRemainder(dividingBy: 2) > 1.6
            gate.ingest(rmsDb: t < 3 || inGap ? -70 : -50 + 4 * Float(sin(2 * .pi * 4 * t)))
            clock.now += FloorSpeechDetectorTests.step
            t += FloorSpeechDetectorTests.step
        }
    }

    /// Acceptance 1 through the gate: with HAL VAD unsupported, quiet speech reads hot.
    func test_quietSpeech_readsHotThroughTheGate_whenHALHasNoVAD() {
        let clock = Clock()
        let vad = HALVoiceActivityProbe(halBus: CoreAudioHALBus())
        let gate = makeGate(clock, vad: vad)
        feedQuietSpeech(gate, clock, seconds: 4.5)
        drain(gate)
        XCTAssertEqual(gate.debugStateSnapshot().detectedVoice, true)
        XCTAssertEqual(gate.current, .hot(reason: .speechDetected))
        XCTAssertFalse(gate.currentVadActive,
                       "never the detector: MIC10's contradiction would clear a mute the user set, un-redacting muted asides")
    }

    /// HAL VAD on: the detector stands down and never writes the VAD input.
    func test_whenHALSupportsVAD_theDetectorStandsDown() {
        let clock = Clock()
        let vad = HALVoiceActivityProbe(halBus: CoreAudioHALBus())
        let gate = makeGate(clock, vad: vad)
        vad.onSupportChange?(.supported)
        feedQuietSpeech(gate, clock, seconds: 4.5)
        drain(gate)
        XCTAssertNil(gate.debugStateSnapshot().detectedVoice)
        XCTAssertEqual(gate.current, .silentByRMS(dwellMillis: 0), "quiet speech is silent to the RMS gate alone")
    }

    func test_theGateWritesOneEvidenceRow_naming_theDetector() {
        let clock = Clock()
        let log = RecordingEventLog()
        let gate = makeGate(clock, vad: HALVoiceActivityProbe(halBus: CoreAudioHALBus()), log: log)
        gate.beginSpeechEvidence()
        feedQuietSpeech(gate, clock, seconds: 6)
        drain(gate)
        gate.emitSpeechEvidence(bundleID: nil)
        gate.emitSpeechEvidence(bundleID: nil)
        drain(gate)
        let rows = log.entries.filter { $0.action == "speech_evidence" }
        XCTAssertEqual(rows.count, 1, "a second emit without a begin writes nothing")
        let row = rows[0].attributes
        XCTAssertEqual(row["speech_detector_available"], "true")
        XCTAssertEqual(row["hal_vad_available"], "false")
        XCTAssertEqual(row["bundle_id"], "manual")
        XCTAssertGreaterThan(Double(row["speech_detector_sec"] ?? "0") ?? 0, 0)
        XCTAssertGreaterThan(Double(row["total_sec"] ?? "0") ?? 0, 5)
    }

    // MARK: - The ledger

    func test_theLedgerGivesEachSourceTheTimeItHeldTheVerdict() {
        let t0 = Date(timeIntervalSince1970: 0)
        var ledger = SpeechEvidenceLedger(startedAt: t0)
        func see(_ state: MicGate.State, _ at: TimeInterval) {
            ledger.observe(state: state, halVadSupported: false, verdict: MicGate.decide(state: state), at: t0.addingTimeInterval(at))
        }
        see(.init(rmsState: .closed), 0)                                          // rms_gate: silent
        see(.init(rmsState: .closed, detectedVoice: true), 10)                    // detector: hot
        see(.init(axMute: .muted, rmsState: .closed, axMuteSource: .log), 25)     // log mute
        see(.init(axMute: .unmuted, rmsState: .closed, axMuteSource: .ax), 40)    // ax unmuted floor
        see(.init(halSystemMute: true, rmsState: .closed), 50)                    // other
        ledger.close(at: t0.addingTimeInterval(55))
        XCTAssertEqual(ledger.seconds[.rmsGate], 10)
        XCTAssertEqual(ledger.seconds[.speechDetector], 15)
        XCTAssertEqual(ledger.seconds[.appMuteLog], 15)
        XCTAssertEqual(ledger.seconds[.appMuteAX], 10)
        XCTAssertEqual(ledger.seconds[.other], 5)
        let row = ledger.attributes
        XCTAssertEqual(row["total_sec"] as? Double, 55)
        for source in ["app_mute_ax", "app_mute_log", "hal_vad", "rms_gate", "speech_detector"] {
            XCTAssertNotNil(row["\(source)_available"], source)
            XCTAssertNotNil(row["\(source)_sec"], source)
        }
        XCTAssertEqual(row["hal_vad_available"] as? Bool, false)
        XCTAssertEqual(row["app_mute_log_available"] as? Bool, true)
    }
}
