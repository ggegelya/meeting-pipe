import Foundation
import XCTest
@testable import MeetingPipe
@testable import MeetingPipeCore

/// T7: the headless seam behind `Coordinator.start()`'s watchers. `CoordinatorWiringFenceTests`
/// pins the one call into it; these pin what that call does.
final class SessionWatchersTests: XCTestCase {

    private final class FakeWatcher: Startable {
        private(set) var startCount = 0
        func start() { startCount += 1 }
    }

    func testStartAllStartsEveryMemberOnce() {
        let (discovery, teardown, refresh) = (FakeWatcher(), FakeWatcher(), FakeWatcher())
        let watchers = SessionWatchers(discovery: discovery, callTeardown: teardown, configRefresh: refresh)
        XCTAssertFalse(watchers.hasStarted)

        watchers.startAll()

        XCTAssertTrue(watchers.hasStarted)
        XCTAssertEqual(discovery.startCount, 1, "discovery")
        XCTAssertEqual(teardown.startCount, 1, "call teardown")
        XCTAssertEqual(refresh.startCount, 1, "config refresh")
    }

    /// `CallTeardownWatcher.start()` ignores a second call; the other two would double-register
    /// observers and sinks. The set takes the teardown watcher's behaviour for all three.
    func testASecondStartAllIsANoOp() {
        let (discovery, teardown, refresh) = (FakeWatcher(), FakeWatcher(), FakeWatcher())
        let watchers = SessionWatchers(discovery: discovery, callTeardown: teardown, configRefresh: refresh)

        watchers.startAll()
        watchers.startAll()

        XCTAssertEqual([discovery, teardown, refresh].map(\.startCount), [1, 1, 1])
    }

    /// The production set holds the three watchers END10 proved can be forgotten, by identity. Built
    /// from real instances and never started, so nothing here touches NSWorkspace or the Teams log.
    func testProductionMembersAreTheThreeSessionWatchers() {
        let discovery = MeetingDiscoveryWatcher()
        let teardown = CallTeardownWatcher(
            directory: URL(fileURLWithPath: NSTemporaryDirectory()),
            family: "MSTeamsNM_SlimCore_",
            scheduler: { _, _ in {} },
            readQueue: nil
        )
        let refresh = ConfigRefreshCoordinator(configStore: nil, onModelDownloadState: { _ in }, onRegulatedMode: { _ in })

        let watchers = SessionWatchers.production(discovery: discovery, callTeardown: teardown, configRefresh: refresh)

        XCTAssertEqual(watchers.members.count, 3)
        XCTAssertTrue(watchers.members[0] === discovery, "discovery watcher")
        XCTAssertTrue(watchers.members[1] === teardown, "call-teardown watcher")
        XCTAssertTrue(watchers.members[2] === refresh, "config refresh")
        XCTAssertFalse(teardown.isRunning, "building the set must not start anything")
    }

    /// The real teardown watcher through the seam: `startAll()` is what makes it observable as
    /// running, which is the state END9 never reached.
    func testStartAllRunsTheRealCallTeardownWatcher() {
        let teardown = CallTeardownWatcher(
            directory: URL(fileURLWithPath: NSTemporaryDirectory()),
            family: "MSTeamsNM_SlimCore_",
            scheduler: { _, _ in {} },
            readQueue: nil
        )
        let watchers = SessionWatchers(discovery: FakeWatcher(), callTeardown: teardown, configRefresh: FakeWatcher())

        watchers.startAll()

        XCTAssertTrue(teardown.isRunning)
        teardown.stop()
    }
}
