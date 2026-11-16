import os
import XCTest
@testable import MeetingPipe

/// CONC7: `ProcessOutputDrain` finishes a child on exit AND EOF, so the last stderr chunk is never lost
/// to the reap-before-read race the old termination handlers had.
final class ProcessOutputDrainTests: XCTestCase {

    private struct Run {
        var status: Int32 = -999
        var tail = Data()
        var chunks: [(ProcessOutputDrain.Stream, Data)] = []
        var finishes = 0
        var elapsed: TimeInterval = 0
    }

    /// Runs `/bin/sh -c script` under a drain and waits for `onFinished`.
    private func runShell(_ script: String, settle: TimeInterval = 0) throws -> Run {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/bin/sh")
        p.arguments = ["-c", script]
        let out = Pipe(), err = Pipe()
        p.standardOutput = out
        p.standardError = err
        let box = OSAllocatedUnfairLock(initialState: Run())
        let done = DispatchSemaphore(value: 0)
        let started = Date()
        let drain = ProcessOutputDrain(
            process: p, stdout: out, stderr: err, label: "test",
            onChunk: { stream, data in box.withLock { $0.chunks.append((stream, data)) } },
            onFinished: { status, tail in
                box.withLock {
                    $0.status = status
                    $0.tail = tail
                    $0.finishes += 1
                    $0.elapsed = Date().timeIntervalSince(started)
                }
                done.signal()
            }
        )
        try drain.run()
        XCTAssertEqual(done.wait(timeout: .now() + 15), .success, "the drain never finished")
        if settle > 0 { Thread.sleep(forTimeInterval: settle) }
        return box.withLock { $0 }
    }

    func test_the_last_stderr_chunk_survives_the_exit_200_times() throws {
        for i in 0..<200 {
            let run = try runShell("echo x >&2; exit 1")
            XCTAssertEqual(run.status, 1, "run \(i)")
            XCTAssertEqual(String(decoding: run.tail, as: UTF8.self), "x\n", "run \(i) lost its stderr")
        }
    }

    func test_the_stderr_tail_is_bounded_and_keeps_the_end() throws {
        let run = try runShell("head -c 65536 /dev/zero | tr '\\0' 'a' >&2; echo MARKER >&2")
        XCTAssertEqual(run.tail.count, ProcessOutputDrain.stderrLimit)
        XCTAssertTrue(String(decoding: run.tail, as: UTF8.self).hasSuffix("aaaMARKER\n"))
    }

    func test_a_grandchild_holding_the_pipe_does_not_hold_the_result() throws {
        // The grandchild inherits both pipes and outlives the child by far more than the ceiling.
        let run = try runShell("(sleep 10) & echo x >&2; exit 1")
        XCTAssertEqual(run.status, 1)
        XCTAssertEqual(String(decoding: run.tail, as: UTF8.self), "x\n")
        XCTAssertLessThan(run.elapsed, ProcessOutputDrain.postExitCeiling + 4, "finished only when the grandchild did")
    }

    func test_both_streams_are_delivered_and_the_finish_fires_once() throws {
        let run = try runShell("echo out; echo err >&2; exit 0", settle: 0.3)
        XCTAssertEqual(run.finishes, 1)
        XCTAssertEqual(run.status, 0)
        let stdout = run.chunks.filter { $0.0 == .stdout }.map { String(decoding: $0.1, as: UTF8.self) }.joined()
        let stderr = run.chunks.filter { $0.0 == .stderr }.map { String(decoding: $0.1, as: UTF8.self) }.joined()
        XCTAssertEqual(stdout, "out\n")
        XCTAssertEqual(stderr, "err\n")
    }

    /// A spawn that throws never fires a termination handler, so the drain has to undo what `run()` set
    /// up itself: no handler, no descriptor, no `onFinished`.
    func test_a_failed_spawn_leaves_no_descriptors_and_never_finishes() throws {
        func spawnOnce() {
            let p = Process()
            p.executableURL = URL(fileURLWithPath: "/nonexistent/mp")
            let out = Pipe(), err = Pipe()
            p.standardOutput = out
            p.standardError = err
            let finished = OSAllocatedUnfairLock(initialState: 0)
            let drain = ProcessOutputDrain(
                process: p, stdout: out, stderr: err, label: "fail",
                onChunk: { _, _ in }, onFinished: { _, _ in finished.withLock { $0 += 1 } }
            )
            XCTAssertThrowsError(try drain.run())
            XCTAssertEqual(finished.withLock { $0 }, 0)
        }
        spawnOnce()   // warm anything lazily opened
        let before = Self.openDescriptors()
        for _ in 0..<20 { spawnOnce() }
        let after = Self.openDescriptors()
        XCTAssertLessThanOrEqual(after, before + 2, "a failed spawn leaked descriptors (\(before) -> \(after))")
    }

    static func openDescriptors() -> Int {
        (try? FileManager.default.contentsOfDirectory(atPath: "/dev/fd").count) ?? 0
    }
}
