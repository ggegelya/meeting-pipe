import ApplicationServices
import XCTest
@testable import MeetingPipe
@testable import MeetingPipeCore

/// Tests for `MeetingAXWindowWatcher`'s subscribe-retry path. The
/// reactive AX subscription occasionally fails with
/// `BusError.backendFailed(AXError)` when the AX application has
/// just spawned (Teams launches alongside the meeting; the AX tree
/// isn't fully attached on the first call). Without retry, the
/// watcher silently never picks up compact-view mute clicks for
/// the rest of the meeting.
final class MeetingAXWindowWatcherTests: XCTestCase {

    // MARK: - Test doubles

    /// AX backend that fails the next `failuresRemaining` registrations
    /// then succeeds. Records the AX error returned per attempt so
    /// tests can verify retry-cadence + give-up semantics.
    final class FlakyBackend: AXObserverBus.Backend {
        var failuresRemaining: Int
        private(set) var attempts: Int = 0
        private(set) var teardowns: Int = 0

        init(failuresRemaining: Int) {
            self.failuresRemaining = failuresRemaining
        }

        func register(
            pid: pid_t,
            element: AXUIElement,
            notification: String,
            handler: @escaping () -> Void
        ) throws -> () -> Void {
            attempts += 1
            if failuresRemaining > 0 {
                failuresRemaining -= 1
                throw AXObserverBus.BusError.backendFailed(.cannotComplete)
            }
            return { [weak self] in self?.teardowns += 1 }
        }
    }

    /// Manual scheduler so tests drive retry timing instead of waiting
    /// on a Timer. Each `schedule` call records the pending action;
    /// `fire()` invokes the most recent action and clears it.
    final class ManualScheduler {
        private(set) var pending: (() -> Void)?
        private(set) var lastDelay: TimeInterval?
        private(set) var cancellations: Int = 0

        func make() -> MeetingAXWindowWatcher.Scheduler {
            return { [weak self] delay, action in
                self?.lastDelay = delay
                self?.pending = action
                return { [weak self] in
                    if self?.pending != nil {
                        self?.cancellations += 1
                        self?.pending = nil
                    }
                }
            }
        }

        func fire() {
            let action = pending
            pending = nil
            action?()
        }
    }

    // MARK: - Fixtures

    private func makeWatcher(
        bus: AXObserverBus,
        scheduler: @escaping MeetingAXWindowWatcher.Scheduler,
        maxAttempts: Int = 3,
        log: EventLog = NoopEventLog()
    ) -> MeetingAXWindowWatcher {
        MeetingAXWindowWatcher(
            pid: 4242,
            bundleID: "com.microsoft.teams2",
            catalogue: MuteLabels(entries: [:]),
            axBus: bus,
            eventLog: log,
            onMuteEvent: { _ in },
            scheduler: scheduler,
            maxSubscribeAttempts: maxAttempts,
            subscribeRetryDelay: 1.5
        )
    }

    // MARK: - Retry path

    func test_subscribe_succeeds_on_second_attempt_after_one_backendFailed() {
        let backend = FlakyBackend(failuresRemaining: 1)
        let bus = AXObserverBus(backend: backend)
        let scheduler = ManualScheduler()
        let log = RecordingEventLog()
        let watcher = makeWatcher(bus: bus, scheduler: scheduler.make(), log: log)

        watcher.start()

        // First attempt failed; retry was scheduled.
        XCTAssertEqual(backend.attempts, 1)
        XCTAssertNotNil(scheduler.pending)
        XCTAssertEqual(scheduler.lastDelay, 1.5)
        XCTAssertTrue(log.entries.contains {
            $0.action == "ax_watcher_subscribe_retry"
        })

        // Fire the retry; backend now succeeds.
        scheduler.fire()
        XCTAssertEqual(backend.attempts, 2)
        XCTAssertNil(scheduler.pending)
        XCTAssertTrue(log.entries.contains {
            $0.action == "ax_watcher_started"
        })
    }

    func test_subscribe_gives_up_after_max_attempts() {
        let backend = FlakyBackend(failuresRemaining: 99)
        let bus = AXObserverBus(backend: backend)
        let scheduler = ManualScheduler()
        let log = RecordingEventLog()
        let watcher = makeWatcher(
            bus: bus,
            scheduler: scheduler.make(),
            maxAttempts: 3,
            log: log
        )

        watcher.start()

        // 1st attempt fired by start().
        XCTAssertEqual(backend.attempts, 1)
        XCTAssertNotNil(scheduler.pending)

        // 2nd attempt via the scheduled retry.
        scheduler.fire()
        XCTAssertEqual(backend.attempts, 2)
        XCTAssertNotNil(scheduler.pending)

        // 3rd attempt via the scheduled retry. Failure should trigger
        // the give-up event, NOT another retry.
        scheduler.fire()
        XCTAssertEqual(backend.attempts, 3)
        XCTAssertNil(scheduler.pending)

        // give-up event emitted.
        XCTAssertTrue(log.entries.contains {
            $0.action == "ax_watcher_subscribe_gave_up"
        })
        // started event NOT emitted (we never succeeded).
        XCTAssertFalse(log.entries.contains {
            $0.action == "ax_watcher_started"
        })
    }

    func test_stop_cancels_pending_retry() {
        let backend = FlakyBackend(failuresRemaining: 2)
        let bus = AXObserverBus(backend: backend)
        let scheduler = ManualScheduler()
        let log = RecordingEventLog()
        let watcher = makeWatcher(bus: bus, scheduler: scheduler.make(), log: log)

        watcher.start()
        XCTAssertEqual(backend.attempts, 1)
        XCTAssertNotNil(scheduler.pending)

        watcher.stop()

        // Pending retry should be cancelled; firing it (if we still
        // could) would have no further effect because cancel ran.
        XCTAssertEqual(scheduler.cancellations, 1)
        XCTAssertNil(scheduler.pending)
    }

    func test_first_attempt_success_does_not_schedule_a_retry() {
        let backend = FlakyBackend(failuresRemaining: 0)
        let bus = AXObserverBus(backend: backend)
        let scheduler = ManualScheduler()
        let log = RecordingEventLog()
        let watcher = makeWatcher(bus: bus, scheduler: scheduler.make(), log: log)

        watcher.start()

        XCTAssertEqual(backend.attempts, 1)
        XCTAssertNil(scheduler.pending)
        XCTAssertTrue(log.entries.contains { $0.action == "ax_watcher_started" })
        XCTAssertFalse(log.entries.contains {
            $0.action == "ax_watcher_subscribe_retry"
        })
    }
}
