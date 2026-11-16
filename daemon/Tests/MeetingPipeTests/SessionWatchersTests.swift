import AppKit
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
        let (discovery, teardown, refresh, teams, micHolder) = (FakeWatcher(), FakeWatcher(), FakeWatcher(), FakeWatcher(), FakeWatcher())
        let watchers = SessionWatchers(
            discovery: discovery, callTeardown: teardown, teamsRunning: teams, configRefresh: refresh, micHolder: micHolder
        )
        XCTAssertFalse(watchers.hasStarted)

        watchers.startAll()

        XCTAssertTrue(watchers.hasStarted)
        XCTAssertEqual(discovery.startCount, 1, "discovery")
        XCTAssertEqual(teardown.startCount, 1, "call teardown")
        XCTAssertEqual(refresh.startCount, 1, "config refresh")
        XCTAssertEqual(teams.startCount, 1, "teams running observer")
        XCTAssertEqual(micHolder.startCount, 1, "mic-holder monitor (DET23)")
    }

    /// `CallTeardownWatcher.start()` ignores a second call; the other two would double-register
    /// observers and sinks. The set takes the teardown watcher's behaviour for all three.
    func testASecondStartAllIsANoOp() {
        let (discovery, teardown, refresh, teams, micHolder) = (FakeWatcher(), FakeWatcher(), FakeWatcher(), FakeWatcher(), FakeWatcher())
        let watchers = SessionWatchers(
            discovery: discovery, callTeardown: teardown, teamsRunning: teams, configRefresh: refresh, micHolder: micHolder
        )

        watchers.startAll()
        watchers.startAll()

        XCTAssertEqual([discovery, teardown, refresh, teams, micHolder].map(\.startCount), [1, 1, 1, 1, 1])
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

        let teams = TeamsRunningObserver(runningBundleIDs: { [] }, onChange: { _ in })
        let micHolder = MicHolderMonitor(halBus: CoreAudioHALBus(), familyIDs: [], scheduler: { _, _ in {} })
        let watchers = SessionWatchers.production(
            discovery: discovery, callTeardown: teardown, teamsRunning: teams, configRefresh: refresh, micHolder: micHolder
        )

        XCTAssertEqual(watchers.members.count, 5)
        XCTAssertTrue(watchers.members[0] === discovery, "discovery watcher")
        XCTAssertTrue(watchers.members[1] === teardown, "call-teardown watcher")
        XCTAssertTrue(watchers.members[2] === teams, "teams running observer, after the watcher it drives")
        XCTAssertTrue(watchers.members[3] === refresh, "config refresh")
        XCTAssertTrue(watchers.members[4] === micHolder, "mic-holder monitor (DET23)")
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
        let watchers = SessionWatchers(
            discovery: FakeWatcher(), callTeardown: teardown, teamsRunning: FakeWatcher(), configRefresh: FakeWatcher(),
            micHolder: FakeWatcher()
        )

        watchers.startAll()

        XCTAssertTrue(teardown.isRunning)
        teardown.stop()
    }

    // MARK: - END16: the Teams-running observer

    /// Main-queue only in these tests, so no lock is needed.
    private final class Box<Value> {
        var value: Value
        init(_ value: Value) { self.value = value }
        func get() -> Value { value }
        func set(_ newValue: Value) { value = newValue }
        func mutate(_ body: (inout Value) -> Void) { body(&value) }
    }

    func testTeamsRunningObserverReportsLaunchesAndQuits() {
        let center = NotificationCenter()
        let running = Box<[String?]>(["com.apple.finder"])
        let reports = Box<[Bool]>([])
        let observer = TeamsRunningObserver(
            center: center, runningBundleIDs: { running.get() }, onChange: { value in reports.mutate { $0.append(value) } }
        )
        observer.start()
        XCTAssertEqual(reports.get(), [false], "the initial read reports")

        running.set(["com.microsoft.teams2"])
        center.post(name: NSWorkspace.didLaunchApplicationNotification, object: nil)
        let launched = expectation(description: "launch delivered")
        DispatchQueue.main.async { launched.fulfill() }
        wait(for: [launched], timeout: 1)
        XCTAssertEqual(reports.get(), [false, true])

        center.post(name: NSWorkspace.didLaunchApplicationNotification, object: nil)
        let unrelated = expectation(description: "unrelated launch delivered")
        DispatchQueue.main.async { unrelated.fulfill() }
        wait(for: [unrelated], timeout: 1)
        XCTAssertEqual(reports.get(), [false, true], "a launch while Teams already runs reports nothing")

        running.set([])
        center.post(name: NSWorkspace.didTerminateApplicationNotification, object: nil)
        let quit = expectation(description: "quit delivered")
        DispatchQueue.main.async { quit.fulfill() }
        wait(for: [quit], timeout: 1)
        XCTAssertEqual(reports.get(), [false, true, false], "a quit reports")
    }

    func testTeamsRunningDrivesTheWatcherCadence() {
        let teardown = CallTeardownWatcher(
            directory: URL(fileURLWithPath: NSTemporaryDirectory()),
            family: "MSTeamsNM_SlimCore_",
            scheduler: { _, _ in {} },
            readQueue: nil
        )
        teardown.start()
        let observer = TeamsRunningObserver(center: NotificationCenter(), runningBundleIDs: { [] }) {
            teardown.setTeamsRunning($0)
        }
        observer.start()
        XCTAssertEqual(teardown.currentPollInterval, CallTeardownWatcher.idlePollInterval)
        teardown.stop()
    }
}
