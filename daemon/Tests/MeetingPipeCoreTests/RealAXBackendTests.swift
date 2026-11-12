import ApplicationServices
import XCTest
@testable import MeetingPipeCore

/// PERF16. `RealAXBackend`'s cache bookkeeping, driven through its `Calls` seam so no
/// test needs Accessibility trust, a live client, or a real `AXObserver`.
final class RealAXBackendTests: XCTestCase {

    private let element = AXUIElementCreateSystemWide()
    private let value = kAXValueChangedNotification as String
    private let title = kAXTitleChangedNotification as String

    func test_last_teardown_removes_the_observer_and_its_source() throws {
        let fake = FakeAXCalls()
        let backend = RealAXBackend(calls: fake.calls)

        let first = try backend.register(pid: 7, element: element, notification: value) {}
        let second = try backend.register(pid: 7, element: element, notification: title) {}
        XCTAssertEqual(fake.created.count, 1, "one observer per PID")
        XCTAssertEqual(fake.attachedSources, 1)

        first()
        XCTAssertEqual(backend.cachedObserverCount, 1, "a handler is still live")
        XCTAssertEqual(fake.attachedSources, 1)
        second()
        XCTAssertEqual(backend.cachedObserverCount, 0)
        XCTAssertEqual(fake.attachedSources, 0)
    }

    /// The leak: a failed first add left the observer cached and its source on the
    /// main run loop, with nothing that would ever release it.
    func test_a_failed_first_add_leaves_no_observer_and_no_source() {
        let fake = FakeAXCalls()
        fake.addResults = [.cannotComplete]
        let backend = RealAXBackend(calls: fake.calls)

        XCTAssertThrowsError(try backend.register(pid: 7, element: element, notification: value) {})
        XCTAssertEqual(backend.cachedObserverCount, 0)
        XCTAssertEqual(fake.attachedSources, 0, "no main-run-loop source may outlive the failed add")
    }

    func test_a_register_after_a_failed_first_add_creates_a_fresh_observer() throws {
        let fake = FakeAXCalls()
        fake.addResults = [.cannotComplete]
        let backend = RealAXBackend(calls: fake.calls)
        XCTAssertThrowsError(try backend.register(pid: 7, element: element, notification: value) {})

        let teardown = try backend.register(pid: 7, element: element, notification: value) {}
        XCTAssertEqual(fake.created.count, 2, "the failed observer was discarded, not reused")
        XCTAssertEqual(backend.cachedObserverCount, 1)
        XCTAssertEqual(fake.attachedSources, 1)

        teardown()
        XCTAssertEqual(fake.attachedSources, 0)
    }

    /// The real failure `MeetingAXWindowWatcher` documents: a second registration of a
    /// notification the primary probe already holds returns `AlreadyRegistered`. That
    /// failure must not take the primary's observer down with it.
    func test_a_failed_add_beside_a_live_handler_keeps_the_observer() throws {
        let fake = FakeAXCalls()
        let backend = RealAXBackend(calls: fake.calls)
        let primary = try backend.register(pid: 7, element: element, notification: value) {}

        fake.addResults = [.notificationAlreadyRegistered]
        XCTAssertThrowsError(try backend.register(pid: 7, element: element, notification: value) {})
        XCTAssertEqual(backend.cachedObserverCount, 1)
        XCTAssertEqual(fake.attachedSources, 1)
        XCTAssertEqual(fake.created.count, 1)

        primary()
        XCTAssertEqual(backend.cachedObserverCount, 0)
        XCTAssertEqual(fake.attachedSources, 0)
    }

    /// PIDs change on every client restart and can be reused. An observer cached for a
    /// dead PID is replaced, and the dead one's late teardown must not touch the new one.
    func test_a_cached_observer_for_a_dead_pid_is_replaced() throws {
        let fake = FakeAXCalls()
        let backend = RealAXBackend(calls: fake.calls)
        let stale = try backend.register(pid: 7, element: element, notification: value) {}

        fake.dead.insert(7)
        let fresh = try backend.register(pid: 7, element: element, notification: value) {}
        XCTAssertEqual(fake.created.count, 2, "a dead PID's observer is not reused")
        XCTAssertEqual(backend.cachedObserverCount, 1)
        XCTAssertEqual(fake.attachedSources, 1, "the dead observer's source left with it")

        stale()
        XCTAssertEqual(backend.cachedObserverCount, 1, "the stale teardown left the fresh entry alone")
        XCTAssertEqual(fake.attachedSources, 1)
        XCTAssertEqual(fake.sourceRemovals, 1, "the dead source was removed exactly once")

        fresh()
        XCTAssertEqual(backend.cachedObserverCount, 0)
        XCTAssertEqual(fake.attachedSources, 0)
    }

    /// The one test through `Calls.live`, so its casts and the real create, add and
    /// run-loop calls execute. The target is a reaped child, so the add fails fast
    /// whether or not this process holds Accessibility trust; either way no observer
    /// may stay cached once the call (and any teardown) is done.
    func test_live_calls_leave_nothing_cached_against_a_gone_process() throws {
        let child = Process()
        child.executableURL = URL(fileURLWithPath: "/usr/bin/true")
        try child.run()
        child.waitUntilExit()
        let pid = child.processIdentifier
        let backend = RealAXBackend()

        let teardown = try? backend.register(
            pid: pid, element: AXUIElementCreateApplication(pid), notification: value, handler: {}
        )
        teardown?()
        XCTAssertEqual(backend.cachedObserverCount, 0)
    }

    func test_process_liveness_reads_only_esrch_as_dead() throws {
        XCTAssertTrue(RealAXBackend.processIsAlive(getpid()))
        // launchd: alive, and `kill(1, 0)` answers EPERM to an unprivileged caller.
        XCTAssertTrue(RealAXBackend.processIsAlive(1))

        let child = Process()
        child.executableURL = URL(fileURLWithPath: "/usr/bin/true")
        try child.run()
        child.waitUntilExit()
        XCTAssertFalse(RealAXBackend.processIsAlive(child.processIdentifier), "a reaped child is gone")
    }
}

/// Records what `RealAXBackend` asks of AX and the run loop. Observers are plain
/// objects; sources are tracked by observer identity.
private final class FakeAXCalls {
    final class Observer {}

    private(set) var created: [Observer] = []
    private var attached: Set<ObjectIdentifier> = []
    private(set) var sourceRemovals = 0
    /// Consumed one per add; empty means success.
    var addResults: [AXError] = []
    var dead: Set<pid_t> = []

    var attachedSources: Int { attached.count }

    var calls: RealAXBackend.Calls {
        RealAXBackend.Calls(
            createObserver: { [unowned self] _ in
                let observer = Observer()
                self.created.append(observer)
                return (.success, observer)
            },
            addNotification: { [unowned self] _, _, _, _ in
                self.addResults.isEmpty ? .success : self.addResults.removeFirst()
            },
            removeNotification: { _, _, _ in },
            addSource: { [unowned self] observer in
                self.attached.insert(ObjectIdentifier(observer))
            },
            removeSource: { [unowned self] observer in
                self.sourceRemovals += 1
                self.attached.remove(ObjectIdentifier(observer))
            },
            isAlive: { [unowned self] pid in !self.dead.contains(pid) }
        )
    }
}
