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

    /// Backend that always throws backendFailed with a configurable
    /// OSStatus. Used to verify the per-subscription diagnostic logging
    /// surfaces both the numeric status and its four-char code.
    final class FailingBackend: CoreAudioHALBus.Backend {
        let status: OSStatus
        init(status: OSStatus) { self.status = status }
        func register(
            _ address: CoreAudioHALBus.Address,
            handler: @escaping () -> Void
        ) throws -> () -> Void {
            throw CoreAudioHALBus.BusError.backendFailed(status)
        }
    }

    /// 560947818 decimal is 0x21_6F_62_6A — the four bytes spell '!obj'.
    /// macOS CoreAudio surfaces this status when an AudioObject is
    /// not yet registered for the supplied selector + scope; previously
    /// the bus emitted just `lifecycle_engage_failed` with the numeric
    /// status which made diagnosis hard without the four-char decoding.
    func test_subscribe_failed_logs_osstatus_and_fourcc() {
        let backend = FailingBackend(status: 560947818)
        let log = RecordingEventLog()
        let bus = CoreAudioHALBus(backend: backend, eventLog: log)

        XCTAssertThrowsError(try bus.subscribe(address()) {}) { error in
            guard case CoreAudioHALBus.BusError.backendFailed(let s) = error else {
                return XCTFail("expected backendFailed; got \(error)")
            }
            XCTAssertEqual(s, 560947818)
        }

        XCTAssertTrue(log.entries.contains { $0.action == "subscribe_attempt" })
        let failed = log.entries.first { $0.action == "subscribe_failed" }
        XCTAssertNotNil(failed)
        XCTAssertEqual(failed?.attributes["osstatus"], "560947818")
        XCTAssertEqual(failed?.attributes["osstatus_4cc"], "!obj")

        // No `subscribed` event on the failure path.
        XCTAssertFalse(log.entries.contains { $0.action == "subscribed" })
    }

    func test_subscribe_attempt_logs_address_before_registration() {
        let backend = RecordingBackend()
        let log = RecordingEventLog()
        let bus = CoreAudioHALBus(backend: backend, eventLog: log)

        _ = try? bus.subscribe(address()) {}

        let attempts = log.entries.filter { $0.action == "subscribe_attempt" }
        XCTAssertEqual(attempts.count, 1)
        XCTAssertEqual(attempts.first?.attributes["object_id"], String(0xfeed))
    }

    /// Regression: a handler that re-enters the bus must not dead-lock.
    /// `HALSystemMuteProbe` rebinds its mute listener from inside the
    /// default-input-device-changed handler (unsubscribe old + subscribe new).
    /// Handlers are dispatched on the bus's serial queue, and subscribe/
    /// unsubscribe used a plain `queue.sync`, so the re-entrant call waited on
    /// the queue it was already running on -> `EXC_BREAKPOINT`. This was the
    /// daemon's recurring crash on audio-device changes. The timeout bounds the
    /// hang so a regression fails instead of wedging CI.
    func test_reentrant_subscribe_unsubscribe_from_handler_does_not_deadlock() throws {
        let backend = RecordingBackend()
        let bus = CoreAudioHALBus(backend: backend)
        let priorToken = try bus.subscribe(address()) {}

        let done = expectation(description: "re-entrant calls complete")
        var newToken: CoreAudioHALBus.Token?
        _ = try bus.subscribe(address()) { [weak bus] in
            // Runs on the bus's serial queue. Mirror rebindCurrentDeviceThrowing:
            // drop the stale listener and register a fresh one, both re-entrant.
            guard let bus = bus else { return }
            bus.unsubscribe(priorToken)
            newToken = try? bus.subscribe(self.address()) {}
            done.fulfill()
        }

        // Fire the "device changed" handler (registration index 1).
        backend.registrations[1].fire()
        wait(for: [done], timeout: 2.0)

        XCTAssertNotNil(newToken, "re-entrant subscribe returned a token")
        // priorToken removed; the device listener + the freshly bound one remain.
        XCTAssertEqual(bus.activeSubscriptionCount, 2)
    }
}
