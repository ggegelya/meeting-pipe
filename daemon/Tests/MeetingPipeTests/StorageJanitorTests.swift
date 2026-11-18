import os
import XCTest
@testable import MeetingPipe

/// CONC5: the storage sweep runs one at a time on its own queue, coalesces a burst into one follow-up,
/// and takes the cheap local-server reaper before the slow retention step.
@MainActor
final class StorageJanitorTests: XCTestCase {

    private final class Probe: Sendable {
        let log = OSAllocatedUnfairLock(initialState: [String]())
        let inFlight = OSAllocatedUnfairLock(initialState: 0)
        let overlapped = OSAllocatedUnfairLock(initialState: false)
        let gate = DispatchSemaphore(value: 0)
        let blocksFirst: Bool
        init(blocksFirst: Bool = false) { self.blocksFirst = blocksFirst }

        func steps() -> StorageJanitor.Steps {
            StorageJanitor.Steps(
                reapServer: { [self] in
                    if inFlight.withLock({ $0 += 1; return $0 }) > 1 { overlapped.withLock { $0 = true } }
                    log.withLock { $0.append("server") }
                },
                reapOriginals: { [self] in log.withLock { $0.append("originals") } },
                retention: { [self] _ in
                    let first = log.withLock { $0.filter { $0 == "retention" }.isEmpty }
                    if blocksFirst && first { _ = gate.wait(timeout: .now() + 10) }
                    log.withLock { $0.append("retention") }
                    inFlight.withLock { $0 -= 1 }
                }
            )
        }
    }

    private func snapshot() -> StorageJanitor.Snapshot {
        .init(directory: URL(fileURLWithPath: "/tmp"), policies: [:], defaultWorkflowID: nil, liveStems: [])
    }

    private func waitForSweep(_ janitor: StorageJanitor) {
        let deadline = Date().addingTimeInterval(10)
        while janitor.isRunning, Date() < deadline { RunLoop.main.run(until: Date().addingTimeInterval(0.01)) }
        XCTAssertFalse(janitor.isRunning, "the sweep never finished")
    }

    func test_one_sweep_runs_the_server_reaper_before_retention() {
        let probe = Probe()
        let janitor = StorageJanitor(snapshot: { self.snapshot() }, steps: probe.steps())
        janitor.request()
        waitForSweep(janitor)
        XCTAssertEqual(probe.log.withLock { $0 }, ["server", "originals", "retention"])
    }

    func test_back_to_back_requests_never_overlap() {
        let probe = Probe()
        let janitor = StorageJanitor(snapshot: { self.snapshot() }, steps: probe.steps())
        janitor.request()
        janitor.request()
        waitForSweep(janitor)
        XCTAssertFalse(probe.overlapped.withLock { $0 })
        XCTAssertEqual(probe.log.withLock { $0.filter { $0 == "retention" }.count }, 2, "the second request is one follow-up")
    }

    func test_five_requests_during_a_running_sweep_produce_exactly_one_follow_up() {
        let probe = Probe(blocksFirst: true)
        let snapshots = OSAllocatedUnfairLock(initialState: 0)
        let janitor = StorageJanitor(
            snapshot: { snapshots.withLock { $0 += 1 }; return self.snapshot() }, steps: probe.steps()
        )
        janitor.request()
        for _ in 0..<5 { janitor.request() }
        probe.gate.signal()
        waitForSweep(janitor)
        XCTAssertEqual(probe.log.withLock { $0.filter { $0 == "retention" }.count }, 2)
        XCTAssertFalse(probe.overlapped.withLock { $0 })
        XCTAssertEqual(snapshots.withLock { $0 }, 2, "the follow-up takes its own fresh snapshot")
    }
}
