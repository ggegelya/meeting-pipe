import CoreAudio
import XCTest
@testable import MeetingPipeCore

final class CoreAudioHALBusTests: XCTestCase {

    /// Backend that records registrations + teardowns so the bus's
    /// bookkeeping can be asserted without touching CoreAudio.
    final class RecordingBackend: CoreAudioHALBus.Backend {
        private(set) var registrations: [(address: CoreAudioHALBus.Address, fire: () -> Void)] = []
        private(set) var teardowns: Int = 0
        /// What every removal returns; a test sets a failure status to drive `unsubscribe_failed`.
        var removalStatus: OSStatus = noErr

        func register(
            _ address: CoreAudioHALBus.Address,
            handler: @escaping () -> Void
        ) throws -> () -> OSStatus {
            registrations.append((address, handler))
            return { [weak self] in
                guard let self else { return noErr }
                self.teardowns += 1
                return self.removalStatus
            }
        }
    }

    private func systemAddress() -> CoreAudioHALBus.Address {
        CoreAudioHALBus.Address(
            objectID: AudioObjectID(kAudioObjectSystemObject),
            selector: kAudioHardwarePropertyProcessObjectList
        )
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
        _ = try bus.subscribe(systemAddress()) {}
        XCTAssertEqual(bus.activeSubscriptionCount, 3)
        XCTAssertEqual(bus.backendListenerCount, 2, "one backend listener per address (DET21)")

        bus.reset()
        XCTAssertEqual(bus.activeSubscriptionCount, 0)
        XCTAssertEqual(bus.backendListenerCount, 0)
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
        ) throws -> () -> OSStatus {
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

        // Both handlers share the one backend listener on this address (DET21), so firing it fans
        // out to the "device changed" handler, which re-enters the bus from inside the delivery.
        backend.registrations[0].fire()
        wait(for: [done], timeout: 2.0)

        XCTAssertNotNil(newToken, "re-entrant subscribe returned a token")
        // priorToken removed; the device handler + the freshly bound one remain.
        XCTAssertEqual(bus.activeSubscriptionCount, 2)
    }

    // MARK: - DET21

    /// Drains the bus queue: every delivery the backend fired has run its handlers by the time this returns.
    private func drain(_ bus: CoreAudioHALBus) { _ = bus.activeSubscriptionCount }

    func test_a_failed_removal_logs_unsubscribe_failed_and_never_unsubscribed() throws {
        let backend = RecordingBackend()
        backend.removalStatus = 1852797029   // 'nope', kAudioHardwareIllegalOperationError
        let log = RecordingEventLog()
        let bus = CoreAudioHALBus(backend: backend, eventLog: log)

        let token = try bus.subscribe(address()) {}
        bus.unsubscribe(token)

        let failed = log.entries.filter { $0.action == "unsubscribe_failed" }
        XCTAssertEqual(failed.count, 1)
        XCTAssertEqual(failed.first?.attributes["osstatus"], "1852797029")
        XCTAssertEqual(failed.first?.attributes["osstatus_4cc"], "nope")
        XCTAssertFalse(log.entries.contains { $0.action == "unsubscribed" })
        // Kept, inert, and reused: a later subscribe on the address registers nothing new.
        XCTAssertEqual(bus.backendListenerCount, 1)
        _ = try bus.subscribe(address()) {}
        XCTAssertEqual(backend.registrations.count, 1, "a failed removal must not lead to a second HAL registration")
    }

    /// DET21 amendment: a block left over from an earlier registration still reaches the bus, which
    /// drops it at the epoch guard. That drop is the leak the field check looks for, so it counts.
    func test_a_delivery_from_a_superseded_registration_counts_as_stale() throws {
        let backend = RecordingBackend()
        let log = RecordingEventLog()
        let bus = CoreAudioHALBus(backend: backend, eventLog: log)
        let fired = LockedBox(0)

        let token = try bus.subscribe(address()) {}
        bus.unsubscribe(token)
        _ = try bus.subscribe(address()) { fired.mutate { $0 += 1 } }
        XCTAssertEqual(backend.registrations.count, 2, "re-registered under a new epoch")

        backend.registrations[0].fire()   // the removed block, still called by the HAL
        drain(bus)

        XCTAssertEqual(fired.get(), 0, "the current handler does not run for the stale block")
        let rows = log.entries.filter { $0.action == "stale_delivery_count" }
        XCTAssertEqual(rows.count, 1)
        XCTAssertEqual(rows.first?.attributes["bus_epoch"], "1")
    }

    func test_a_successful_removal_logs_unsubscribed() throws {
        let backend = RecordingBackend()
        let log = RecordingEventLog()
        let bus = CoreAudioHALBus(backend: backend, eventLog: log)

        let token = try bus.subscribe(address()) {}
        bus.unsubscribe(token)

        XCTAssertEqual(log.entries.filter { $0.action == "unsubscribed" }.count, 1)
        XCTAssertFalse(log.entries.contains { $0.action == "unsubscribe_failed" })
        XCTAssertEqual(bus.backendListenerCount, 0)
    }

    func test_two_subscribers_share_one_backend_listener_and_survive_each_other() throws {
        let backend = RecordingBackend()
        let bus = CoreAudioHALBus(backend: backend)
        let first = LockedBox(0)
        let second = LockedBox(0)

        let firstToken = try bus.subscribe(address()) { first.mutate { $0 += 1 } }
        _ = try bus.subscribe(address()) { second.mutate { $0 += 1 } }
        XCTAssertEqual(backend.registrations.count, 1, "one backend listener per address")

        backend.registrations[0].fire()
        drain(bus)
        XCTAssertEqual(first.get(), 1)
        XCTAssertEqual(second.get(), 1)

        bus.unsubscribe(firstToken)
        XCTAssertEqual(backend.teardowns, 0, "the listener stays while a handler remains")
        backend.registrations[0].fire()
        drain(bus)
        XCTAssertEqual(first.get(), 1, "an unsubscribed handler ran")
        XCTAssertEqual(second.get(), 2)
    }

    func test_no_handler_runs_after_the_last_one_unsubscribes() throws {
        // A leaked HAL listener (a removal the HAL refused, or a block it still calls after `noErr`)
        // must reach no handler. Both shapes: the system object, whose listener is kept for the
        // daemon's lifetime, and an ordinary object whose removal failed.
        let backend = RecordingBackend()
        backend.removalStatus = 1852797029
        let bus = CoreAudioHALBus(backend: backend)
        let ran = LockedBox(0)

        let objectToken = try bus.subscribe(address()) { ran.mutate { $0 += 1 } }
        let systemToken = try bus.subscribe(systemAddress()) { ran.mutate { $0 += 1 } }
        bus.unsubscribe(objectToken)
        bus.unsubscribe(systemToken)
        XCTAssertEqual(backend.teardowns, 1, "the system-object listener is kept, not removed")

        for registration in backend.registrations { registration.fire() }
        drain(bus)
        XCTAssertEqual(ran.get(), 0)
    }

    func test_a_block_from_an_earlier_registration_reaches_nothing() throws {
        // The removal said noErr but the HAL keeps calling the old block: the fresh registration's
        // handlers must not run twice per change.
        let backend = RecordingBackend()
        let bus = CoreAudioHALBus(backend: backend)
        let ran = LockedBox(0)

        let old = try bus.subscribe(address()) {}
        bus.unsubscribe(old)
        _ = try bus.subscribe(address()) { ran.mutate { $0 += 1 } }
        XCTAssertEqual(backend.registrations.count, 2)

        backend.registrations[0].fire()   // the stale block
        drain(bus)
        XCTAssertEqual(ran.get(), 0)
        backend.registrations[1].fire()
        drain(bus)
        XCTAssertEqual(ran.get(), 1)
    }

    func test_repeat_subscribes_on_a_kept_listener_log_no_halbus_rows() throws {
        let backend = RecordingBackend()
        let log = RecordingEventLog()
        let bus = CoreAudioHALBus(backend: backend, eventLog: log)

        for _ in 0..<5 {
            let token = try bus.subscribe(systemAddress()) {}
            bus.unsubscribe(token)
        }
        XCTAssertEqual(log.entries.filter { $0.action == "subscribe_attempt" }.count, 1)
        XCTAssertEqual(log.entries.filter { $0.action == "subscribed" }.count, 1)
        XCTAssertFalse(log.entries.contains { $0.action == "unsubscribed" })
    }

    func test_reset_logs_each_removal_status() throws {
        let backend = RecordingBackend()
        backend.removalStatus = 1852797029
        let log = RecordingEventLog()
        let bus = CoreAudioHALBus(backend: backend, eventLog: log)
        _ = try bus.subscribe(systemAddress()) {}

        bus.reset()
        XCTAssertEqual(log.entries.filter { $0.action == "unsubscribe_failed" }.count, 1)
    }

    func test_stale_delivery_count_is_emitted_at_most_once_a_minute() {
        let log = RecordingEventLog()
        let clock = LockedBox<TimeInterval>(1_000)
        let bus = CoreAudioHALBus(eventLog: log, now: { clock.get() })
        func rows() -> [RecordingEventLog.Entry] { log.entries.filter { $0.action == "stale_delivery_count" } }

        bus.noteStaleDelivery(source: "process_audio")
        XCTAssertEqual(rows().count, 1, "the first stale delivery is reported at once")
        XCTAssertEqual(rows().last?.attributes["count"], "1")

        clock.set(1_030)
        bus.noteStaleDelivery(source: "process_audio")
        bus.noteStaleDelivery(source: "system_mute")
        XCTAssertEqual(rows().count, 1, "inside the minute nothing more is emitted")

        clock.set(1_061)
        bus.noteStaleDelivery(source: "system_mute")
        XCTAssertEqual(rows().count, 2)
        XCTAssertEqual(rows().last?.attributes["count"], "3")
        XCTAssertEqual(rows().last?.attributes["system_mute"], "2")
        XCTAssertEqual(rows().last?.attributes["process_audio"], "1")

        clock.set(1_090)
        bus.noteStaleDelivery(source: "process_audio")
        bus.reset()
        XCTAssertEqual(rows().count, 3, "reset flushes a pending count")
    }

    /// D057: against the real HAL. The leak's leading guess was that block identity did not survive
    /// the closure bridge, so the removal failed and said so. Measured 2026-11-16 on macOS 27.2: the
    /// removal returns `noErr`, and so does a second removal of the same block, and so does removing
    /// a block that was never registered. Only a dead object gets a status (`!obj`). So the status
    /// cannot tell a removed listener from a leaked one, which is why the bus keeps one listener per
    /// address and fans out itself rather than trusting the removal (DET21). If this test ever sees a
    /// non-zero status for the unknown block, the HAL started reporting it and `unsubscribe_failed`
    /// became evidence; update the gotchas section.
    func test_real_backend_removal_status_cannot_prove_a_removal() throws {
        let backend = RealCoreAudioBackend()
        let system = AudioObjectID(kAudioObjectSystemObject)
        let remove = try backend.register(
            CoreAudioHALBus.Address(objectID: system, selector: kAudioHardwarePropertyDefaultInputDevice),
            handler: {}
        )
        XCTAssertEqual(remove(), noErr)
        XCTAssertEqual(remove(), noErr, "a second removal of the same block")

        var address = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyDefaultInputDevice,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        let neverRegistered: AudioObjectPropertyListenerBlock = { _, _ in }
        let queue = DispatchQueue(label: "CoreAudioHALBusTests.neverRegistered")
        XCTAssertEqual(
            AudioObjectRemovePropertyListenerBlock(system, &address, queue, neverRegistered), noErr,
            "the HAL now refuses a block it never registered; unsubscribe_failed has become evidence"
        )
        XCTAssertEqual(
            AudioObjectRemovePropertyListenerBlock(AudioObjectID(987_654), &address, queue, neverRegistered),
            kAudioHardwareBadObjectError
        )
    }
}
