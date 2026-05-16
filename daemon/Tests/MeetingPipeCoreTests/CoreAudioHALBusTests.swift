import CoreAudio
import XCTest
@testable import MeetingPipeCore

final class CoreAudioHALBusTests: XCTestCase {

    /// Backend that records registrations + teardowns so the bus's
    /// bookkeeping can be asserted without touching CoreAudio.
    final class RecordingBackend: CoreAudioHALBus.Backend {
        private(set) var registrations: [(address: CoreAudioHALBus.Address, fire: () -> Void)] = []
        private(set) var teardowns: Int = 0

        func register(
            _ address: CoreAudioHALBus.Address,
            handler: @escaping () -> Void
        ) throws -> () -> Void {
            registrations.append((address, handler))
            return { [weak self] in self?.teardowns += 1 }
        }
    }

    private func address() -> CoreAudioHALBus.Address {
        CoreAudioHALBus.Address(
            objectID: AudioObjectID(0xfeed),
            selector: kAudioProcessPropertyIsRunningInput,
            scope: kAudioObjectPropertyScopeInput
        )
    }

    func test_subscribe_invokes_backend_and_tracks_subscription() throws {
        let backend = RecordingBackend()
        let log = RecordingEventLog()
        let bus = CoreAudioHALBus(backend: backend, eventLog: log)

        let token = try bus.subscribe(address()) {}

        XCTAssertEqual(backend.registrations.count, 1)
        XCTAssertEqual(bus.activeSubscriptionCount, 1)
        XCTAssertTrue(log.entries.contains { $0.action == "subscribed" })

        bus.unsubscribe(token)
        XCTAssertEqual(bus.activeSubscriptionCount, 0)
        XCTAssertEqual(backend.teardowns, 1)
    }

    func test_reset_tears_down_all_active_subscriptions() throws {
        let backend = RecordingBackend()
        let bus = CoreAudioHALBus(backend: backend)
        _ = try bus.subscribe(address()) {}
        _ = try bus.subscribe(address()) {}
        XCTAssertEqual(bus.activeSubscriptionCount, 2)

        bus.reset()
        XCTAssertEqual(bus.activeSubscriptionCount, 0)
        XCTAssertEqual(backend.teardowns, 2)
    }

    func test_handler_dispatched_when_backend_fires() throws {
        let backend = RecordingBackend()
        let bus = CoreAudioHALBus(backend: backend)
        let expectation = expectation(description: "handler fires")
        _ = try bus.subscribe(address()) { expectation.fulfill() }

        backend.registrations[0].fire()
        wait(for: [expectation], timeout: 1.0)
    }

    func test_noop_backend_keeps_bus_bookkeeping_consistent() throws {
        let bus = CoreAudioHALBus()
        let token = try bus.subscribe(address()) {}
        XCTAssertEqual(bus.activeSubscriptionCount, 1)
        bus.unsubscribe(token)
        XCTAssertEqual(bus.activeSubscriptionCount, 0)
    }
}
