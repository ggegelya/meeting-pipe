import XCTest
import CoreAudio
@testable import MeetingPipeCore

/// OBS9: the high-volume rows go through `emitDiagnostic`, which the daemon writes to
/// `diagnostics.jsonl`, so they cannot rotate lifecycle rows out of `events.jsonl`.
final class DiagnosticFamilyTests: XCTestCase {

    private let teamsContext = MeetingLifecycleContext(bundleID: "com.microsoft.teams2", kind: .native, pid: 1234)

    func test_hal_bus_subscribe_rows_are_diagnostic() throws {
        let log = RecordingEventLog()
        let bus = CoreAudioHALBus(backend: CoreAudioHALBusTests.RecordingBackend(), eventLog: log)
        let address = CoreAudioHALBus.Address(
            objectID: AudioObjectID(0xfeed), selector: kAudioProcessPropertyIsRunningInput, scope: kAudioObjectPropertyScopeInput
        )
        let token = try bus.subscribe(address) {}
        bus.unsubscribe(token)
        XCTAssertEqual(log.diagnosticActions, ["subscribe_attempt", "subscribed", "unsubscribed"])
    }

    func test_process_audio_object_resolution_is_diagnostic() throws {
        let log = RecordingEventLog()
        var tick: (() -> Void)?
        let signal = ProcessAudioSignal(
            halBus: CoreAudioHALBus(backend: CoreAudioHALBusTests.RecordingBackend(), eventLog: NoopEventLog()),
            eventLog: log,
            probe: { _, _ in true },
            scheduler: { _, action in tick = action; return { tick = nil } },
            resolver: { _ in .resolved([9999]) }
        )
        try signal.start(context: teamsContext)
        signal.stop()
        XCTAssertTrue(log.diagnosticActions.contains("process_audio_object_resolved"), "\(log.diagnosticActions)")
        XCTAssertFalse(log.diagnosticActions.contains("process_audio_transition"))
        _ = tick
    }
}
