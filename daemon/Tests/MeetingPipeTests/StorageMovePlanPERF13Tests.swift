import XCTest
import os
@testable import MeetingPipe

/// PERF13 item 8: planning a library move walked the whole library on main
/// (`LibraryMover.plan` from `@MainActor` `StorageStatsStore.planMove`, straight after the
/// folder picker). It runs off main now, and a second pick while one is measuring plans nothing.
@MainActor
final class StorageMovePlanPERF13Tests: XCTestCase {
    private var dir: URL!

    override func setUpWithError() throws {
        dir = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("mp-perf13-move-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: dir)
    }

    private func plan(_ destination: URL) -> LibraryMover.Plan {
        LibraryMover.Plan(
            source: dir, destination: destination, digestsSource: nil, digestsDestination: nil,
            fileCount: 1, bytes: 1
        )
    }

    func test_planning_runs_off_main_and_a_second_pick_waits_its_turn() async {
        let ranOnMain = OSAllocatedUnfairLock(initialState: true)
        // Released from main only after the second pick has been refused, so the held planner
        // never waits on anything the cooperative pool has to run.
        let release = DispatchSemaphore(value: 0)
        let calls = OSAllocatedUnfairLock(initialState: 0)
        let destination = dir.appendingPathComponent("dest", isDirectory: true)
        let expected = plan(destination)
        let store = StorageStatsStore(
            configStore: ConfigStore(configURL: dir.appendingPathComponent("config.toml")),
            workflowStore: WorkflowStore(directory: dir.appendingPathComponent("workflows", isDirectory: true)),
            planner: { _, _ in
                calls.withLock { $0 += 1 }
                ranOnMain.withLock { $0 = pthread_main_np() != 0 }
                release.wait()
                return expected
            }
        )

        let first = Task { await store.planMove(to: destination) }
        while !store.isPlanningMove { await Task.yield() }

        let second = await store.planMove(to: destination)
        XCTAssertNil(second, "a pick while a plan is measuring must not start a second walk")
        XCTAssertTrue(store.isPlanningMove, "the button stays disabled until the first plan lands")

        release.signal()
        let landed = await first.value
        XCTAssertEqual(landed, expected)
        XCTAssertFalse(store.isPlanningMove)
        XCTAssertEqual(calls.withLock { $0 }, 1)
        XCTAssertFalse(ranOnMain.withLock { $0 }, "LibraryMover.plan must not run on main")
    }

    func test_a_failed_plan_surfaces_its_error_and_re_enables_the_button() async {
        struct Refused: LocalizedError { var errorDescription: String? { "Destination is inside the library" } }
        let store = StorageStatsStore(
            configStore: ConfigStore(configURL: dir.appendingPathComponent("config.toml")),
            workflowStore: WorkflowStore(directory: dir.appendingPathComponent("workflows", isDirectory: true)),
            planner: { _, _ in throw Refused() }
        )
        let result = await store.planMove(to: dir)
        XCTAssertNil(result)
        XCTAssertEqual(store.moveError, "Destination is inside the library")
        XCTAssertFalse(store.isPlanningMove)
    }
}
