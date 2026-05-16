import XCTest
@testable import MeetingPipeCore

final class MeetingLifecycleCoordinatorTests: XCTestCase {

    private let teamsContext = MeetingLifecycleContext(
        bundleID: "com.microsoft.teams2",
        kind: .native,
        pid: 1234,
        title: "Weekly sync"
    )

    func test_publish_emits_event_and_advances_current_verdict() {
        let log = RecordingEventLog()
        let coordinator = MeetingLifecycleCoordinator(eventLog: log)
        XCTAssertEqual(coordinator.current, .idle)

        coordinator.publish(.starting(context: teamsContext))
        XCTAssertEqual(coordinator.current, .starting(context: teamsContext))
        XCTAssertTrue(log.entries.contains { $0.action == "starting" })

        coordinator.publish(.inMeeting(context: teamsContext))
        XCTAssertEqual(coordinator.current, .inMeeting(context: teamsContext))
    }

    func test_publish_idempotent_on_repeat() {
        let log = RecordingEventLog()
        let coordinator = MeetingLifecycleCoordinator(eventLog: log)

        coordinator.publish(.inMeeting(context: teamsContext))
        coordinator.publish(.inMeeting(context: teamsContext))

        let inMeetingEvents = log.entries.filter { $0.action == "in_meeting" }
        XCTAssertEqual(inMeetingEvents.count, 1, "Duplicate verdicts must not re-emit events")
    }

    func test_ended_event_includes_leading_signal_and_confirmed_by() {
        let log = RecordingEventLog()
        let coordinator = MeetingLifecycleCoordinator(eventLog: log)
        let reason = EndingReason(
            leadingSignal: "shareable_content_window_gone",
            confirmedBy: ["process_audio_is_running_input_false"]
        )

        coordinator.publish(.ended(context: teamsContext, reason: reason))

        guard let ended = log.entries.first(where: { $0.action == "ended" }) else {
            return XCTFail("Expected ended event")
        }
        XCTAssertEqual(ended.attributes["leading_signal"], "shareable_content_window_gone")
        XCTAssertEqual(ended.attributes["bundle_id"], "com.microsoft.teams2")
        XCTAssertNotNil(ended.attributes["confirmed_by"])
    }

    func test_verdicts_stream_delivers_published_values() async {
        let coordinator = MeetingLifecycleCoordinator()
        let iterator = AsyncStreamIterator(coordinator.verdicts)

        coordinator.publish(.starting(context: teamsContext))
        coordinator.publish(.inMeeting(context: teamsContext))
        coordinator.shutdown()

        let received = await iterator.collect()
        XCTAssertEqual(received.first, .starting(context: teamsContext))
        XCTAssertTrue(received.contains(.inMeeting(context: teamsContext)))
    }

    func test_shutdown_resets_buses() throws {
        let halBackend = CoreAudioHALBusTests.RecordingBackend()
        let axBackend = AXObserverBusTests.RecordingBackend()
        let halBus = CoreAudioHALBus(backend: halBackend)
        let axBus = AXObserverBus(backend: axBackend)
        let coordinator = MeetingLifecycleCoordinator(halBus: halBus, axBus: axBus)

        _ = try halBus.subscribe(.init(
            objectID: 1, selector: 0, scope: 0, element: 0
        )) {}
        XCTAssertEqual(halBus.activeSubscriptionCount, 1)

        coordinator.shutdown()
        XCTAssertEqual(halBus.activeSubscriptionCount, 0)
        XCTAssertEqual(axBus.activeSubscriptionCount, 0)
    }
}

/// Drains the cold `AsyncStream` returned by the coordinator into a
/// flat array. Used because the verdict stream finishes when the
/// coordinator shuts down, so a one-shot collect is the cleanest
/// shape for assertions.
private actor AsyncStreamIterator {
    private let stream: AsyncStream<MeetingLifecycleVerdict>

    init(_ stream: AsyncStream<MeetingLifecycleVerdict>) {
        self.stream = stream
    }

    func collect() async -> [MeetingLifecycleVerdict] {
        var out: [MeetingLifecycleVerdict] = []
        for await verdict in stream { out.append(verdict) }
        return out
    }
}
