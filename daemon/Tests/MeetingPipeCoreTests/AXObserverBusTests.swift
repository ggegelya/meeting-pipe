import ApplicationServices
import XCTest
@testable import MeetingPipeCore

final class AXObserverBusTests: XCTestCase {

    /// Backend that records registrations without touching AX. Used in
    /// tests because the real backend needs accessibility-trust and a
    /// live observable app to attach to.
    final class RecordingBackend: AXObserverBus.Backend {
        private(set) var registrations: [(pid: pid_t, notification: String, fire: () -> Void)] = []
        private(set) var teardowns: Int = 0

        func register(
            pid: pid_t,
            element: AXUIElement,
            notification: String,
            handler: @escaping () -> Void
        ) throws -> () -> Void {
            registrations.append((pid, notification, handler))
            return { [weak self] in self?.teardowns += 1 }
        }
    }

    private func stubElement() -> AXUIElement {
        AXUIElementCreateSystemWide()
    }

    func test_subscribe_invokes_backend_and_tracks_subscription() throws {
        let backend = RecordingBackend()
        let log = RecordingEventLog()
        let bus = AXObserverBus(backend: backend, eventLog: log)

        let token = try bus.subscribe(
            pid: 4242,
            element: stubElement(),
            notification: kAXUIElementDestroyedNotification as String
        ) {}

        XCTAssertEqual(backend.registrations.count, 1)
        XCTAssertEqual(backend.registrations[0].notification, kAXUIElementDestroyedNotification as String)
        XCTAssertEqual(bus.activeSubscriptionCount, 1)
        XCTAssertTrue(log.entries.contains { $0.action == "subscribed" })

        bus.unsubscribe(token)
        XCTAssertEqual(bus.activeSubscriptionCount, 0)
        XCTAssertEqual(backend.teardowns, 1)
    }

    func test_reset_tears_down_all_active_subscriptions() throws {
        let backend = RecordingBackend()
        let bus = AXObserverBus(backend: backend)
        _ = try bus.subscribe(
            pid: 1, element: stubElement(), notification: kAXValueChangedNotification as String
        ) {}
        _ = try bus.subscribe(
            pid: 2, element: stubElement(), notification: kAXTitleChangedNotification as String
        ) {}
        XCTAssertEqual(bus.activeSubscriptionCount, 2)

        bus.reset()
        XCTAssertEqual(bus.activeSubscriptionCount, 0)
        XCTAssertEqual(backend.teardowns, 2)
    }

    func test_handler_dispatched_to_main_queue() throws {
        let backend = RecordingBackend()
        let bus = AXObserverBus(backend: backend)
        let expectation = expectation(description: "handler runs on main")
        _ = try bus.subscribe(
            pid: 99,
            element: stubElement(),
            notification: kAXValueChangedNotification as String
        ) {
            XCTAssertTrue(Thread.isMainThread)
            expectation.fulfill()
        }

        DispatchQueue.global().async { backend.registrations[0].fire() }
        wait(for: [expectation], timeout: 1.0)
    }
}
