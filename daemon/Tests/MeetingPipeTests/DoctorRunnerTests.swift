import os
import XCTest
@testable import MeetingPipe

/// PERF24: the in-app doctor ran its self-check probes inline on the main actor, under a comment
/// calling them fast. With a hung meeting app each AX probe waits out the process-wide 2 s
/// messaging timeout, so the Preferences window froze for the length of the check. The probes now
/// run on a utility queue and hand each line back to main in order.
///
/// `invocation: { nil }` throughout, so no test ever spawns a real `mp doctor`; the run ends on
/// the "mp launcher not found" line instead, which is also what makes `finished` observable.
@MainActor
final class DoctorRunnerTests: XCTestCase {

    /// A probe that says it started, then waits to be released, and records whether it ran on
    /// main.
    private final class Gate: Sendable {
        let started = DispatchSemaphore(value: 0)
        let release = DispatchSemaphore(value: 0)
        let finished = DispatchSemaphore(value: 0)
        private let ranOnMain = OSAllocatedUnfairLock(initialState: [Bool]())
        func note() { ranOnMain.withLock { $0.append(Thread.isMainThread) } }
        var threads: [Bool] { ranOnMain.withLock { $0 } }
    }

    private func blocking(_ gate: Gate) -> DoctorCommand.Probe {
        DoctorCommand.Probe(name: "slow") {
            gate.note()
            gate.started.signal()
            gate.release.wait()
            gate.finished.signal()
            return DoctorCommand.ProbeResult(name: "slow", status: .ok, message: "done")
        }
    }

    private func canned(_ name: String, _ status: DoctorCommand.Status, gate: Gate) -> DoctorCommand.Probe {
        DoctorCommand.Probe(name: name) {
            gate.note()
            return DoctorCommand.ProbeResult(name: name, status: status, message: "m")
        }
    }

    private func waitUntilFinished(_ runner: DoctorRunner, file: StaticString = #filePath, line: UInt = #line) {
        let deadline = Date().addingTimeInterval(5)
        while case .running = runner.state, Date() < deadline {
            RunLoop.main.run(until: Date().addingTimeInterval(0.01))
        }
        XCTAssertNotEqual(runner.state, .running, "the run never finished", file: file, line: line)
    }

    func test_run_returns_before_a_blocked_probe_finishes_and_keeps_probe_order() {
        let gate = Gate()
        let runner = DoctorRunner(
            probes: [blocking(gate), canned("next", .warn, gate: gate)],
            invocation: { nil }
        )

        runner.run()

        // run() is back while the first probe is still blocked, so it never waited on it.
        XCTAssertEqual(gate.started.wait(timeout: .now() + 5), .success, "the probe never started")
        XCTAssertEqual(runner.state, .running)
        XCTAssertEqual(runner.output, "== Daemon self-check ==\n", "no probe line before the probe finishes")

        gate.release.signal()
        waitUntilFinished(runner)

        XCTAssertEqual(gate.threads, [false, false], "every probe runs off main")
        XCTAssertEqual(runner.output.components(separatedBy: "\n"), [
            "== Daemon self-check ==",
            "[ OK ] slow: done",
            "[WARN] next: m",
            "",
            "doctor: all probes passed.",
            "",
            "== mp doctor ==",
            "mp launcher not found. Did you run scripts/install.sh?",
            "",
        ])
        XCTAssertEqual(runner.state, .finished(exitCode: -1))
    }

    /// The verdict line still counts failures, as `DoctorCommand.execute` does for the CLI.
    func test_a_failed_probe_is_counted_in_the_verdict() {
        let gate = Gate()
        let runner = DoctorRunner(
            probes: [canned("a", .fail, gate: gate), canned("b", .ok, gate: gate)],
            invocation: { nil }
        )
        runner.run()
        waitUntilFinished(runner)
        XCTAssertTrue(runner.output.contains("[FAIL] a: m\n[ OK ] b: m\n\ndoctor: 1 probe failed.\n"), runner.output)
    }

    /// Closing the sheet mid-check stands the run down: the late result lands nowhere and no
    /// `mp doctor` is spawned behind a sheet that is gone.
    func test_cancel_mid_check_drops_late_results_and_spawns_nothing() {
        let gate = Gate()
        let looked = OSAllocatedUnfairLock(initialState: 0)
        // Serial and the test's own, so it can be drained: once `sync` returns, every main hop
        // the probe loop queued is already on the main queue ahead of the block below.
        let probeQueue = DispatchQueue(label: "perf24.test.doctor")
        let runner = DoctorRunner(
            probes: [blocking(gate)],
            probeQueue: probeQueue,
            invocation: { looked.withLock { $0 += 1 }; return nil }
        )

        runner.run()
        XCTAssertEqual(gate.started.wait(timeout: .now() + 5), .success)
        runner.cancel()
        XCTAssertEqual(runner.state, .finished(exitCode: -1))

        gate.release.signal()
        probeQueue.sync {}
        let drained = expectation(description: "main hops ran")
        DispatchQueue.main.async { drained.fulfill() }
        wait(for: [drained], timeout: 5)

        XCTAssertEqual(runner.output, "== Daemon self-check ==\n")
        XCTAssertEqual(looked.withLock { $0 }, 0, "no mp doctor lookup after a cancel")
    }
}
