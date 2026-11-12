import XCTest
@testable import MeetingPipe

/// PERF13: `pipeline.log` has one writer per run. The daemon copies the child's output into it
/// with `O_APPEND` writes and tells the child (`MP_PIPELINE_LOG_OWNER=daemon`) not to open the
/// file itself. Python's own FileHandler and the daemon's stale-offset copy used to both write,
/// so a run-all record appeared twice and 5 of 8 real runs ended in a torn fragment.
final class PipelineLogOwnerPERF13Tests: XCTestCase {
    func test_a_spawned_records_stderr_lands_in_pipeline_log_exactly_once() throws {
        let fm = FileManager.default
        let dir = fm.temporaryDirectory
            .appendingPathComponent("mp-perf13-spawn-\(UUID().uuidString)", isDirectory: true)
        try fm.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? fm.removeItem(at: dir) }
        setenv("MEETINGPIPE_LOGS_DIR", dir.path, 1)
        defer { unsetenv("MEETINGPIPE_LOGS_DIR") }

        // A fake `mp`: one logging-formatted record on stderr, and the flag it saw in a file.
        // The pause before exit keeps this test off a separate race CONC7 owns: `runMP`'s
        // termination handler can drop its readability handlers before the last chunk drains.
        let script = dir.appendingPathComponent("fake-mp.sh")
        let owner = dir.appendingPathComponent("owner.txt")
        try """
            echo "2026-11-12 10:00:00,000 ERROR mp.run_all: run-all failed: perf13-marker" >&2
            printf '%s' "$MP_PIPELINE_LOG_OWNER" > "\(owner.path)"
            sleep 0.5
            exit 0
            """.write(to: script, atomically: true, encoding: .utf8)
        let launcher = PipelineLauncher(
            invocation: { .init(shell: "/bin/sh", args: [script.path]) },
            environment: ["PATH": "/usr/bin:/bin"]
        )
        let done = expectation(description: "spawn finished")
        launcher.rosterRename(old: "a", new: "b") { result in
            if case .failure(let error) = result { XCTFail("fake mp failed: \(error)") }
            done.fulfill()
        }
        wait(for: [done], timeout: 20)

        let log = try String(contentsOf: dir.appendingPathComponent("pipeline.log"), encoding: .utf8)
        XCTAssertEqual(log.components(separatedBy: "run-all failed: perf13-marker").count - 1, 1, log)
        XCTAssertEqual(log.split(separator: "\n").count, 1, "no torn fragment, no second copy: \(log)")
        XCTAssertEqual(try String(contentsOf: owner, encoding: .utf8), "daemon",
                       "the child must be told the daemon owns the file")
    }

    func test_the_flag_name_mirrors_the_python_constant() throws {
        let root = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent()
            .deletingLastPathComponent().deletingLastPathComponent()
        let source = try String(
            contentsOf: root.appendingPathComponent("pipeline/src/mp/orchestrate.py"), encoding: .utf8
        )
        XCTAssertTrue(source.contains("PIPELINE_LOG_OWNER_ENV = \"\(PipelineLauncher.pipelineLogOwnerKey)\""))
        XCTAssertTrue(source.contains("== \"\(PipelineLauncher.pipelineLogOwnerDaemon)\""))
    }
}
