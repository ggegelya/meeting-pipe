import XCTest
@testable import MeetingPipe

/// CONC7: `runMP` rides `ProcessOutputDrain`, so a failing child's last stderr line reaches the
/// failure text, and a spawn that never started leaves nothing behind.
final class PipelineLauncherDrainTests: XCTestCase {

    private func transcript() throws -> (URL, URL) {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("conc7-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let md = dir.appendingPathComponent("t.md")
        try "t".write(to: md, atomically: true, encoding: .utf8)
        return (dir, md)
    }

    private func launcher(_ invocation: @escaping () -> PipelineLauncher.MPInvocation?) -> PipelineLauncher {
        PipelineLauncher(invocation: invocation, environment: ["PATH": "/usr/bin:/bin"],
                         tokenSource: { [:] }, reapOrphanedServer: {})
    }

    private func summarizeAndWait(_ l: PipelineLauncher, _ md: URL) -> Error? {
        let done = expectation(description: "summarize")
        var failure: Error?
        l.summarize(transcriptMD: md) { result in
            if case .failure(let e) = result { failure = e }
            done.fulfill()
        }
        wait(for: [done], timeout: 15)
        return failure
    }

    func test_the_last_stderr_line_reaches_the_diagnostics_50_times() throws {
        let (dir, md) = try transcript()
        defer { try? FileManager.default.removeItem(at: dir) }
        let l = launcher { .init(shell: "/bin/sh", args: ["-c", "printf 'diag-end\\n' >&2; exit 1", "sh"]) }
        var dropped = 0
        for _ in 0..<50 {
            let error = summarizeAndWait(l, md)
            let text = error.map(PipelineLauncher.diagnostics(for:)) ?? ""
            if !text.hasSuffix("diag-end") && !text.hasSuffix("diag-end\n") { dropped += 1 }
        }
        XCTAssertEqual(dropped, 0, "\(dropped) of 50 runs lost the last stderr line")
    }

    func test_a_spawn_that_cannot_start_leaks_no_descriptors_and_frees_the_slot() throws {
        let (dir, md) = try transcript()
        defer { try? FileManager.default.removeItem(at: dir) }
        let notExecutable = dir.appendingPathComponent("not-executable")
        try "#!/bin/sh\n".write(to: notExecutable, atomically: true, encoding: .utf8)
        let l = launcher { .init(shell: notExecutable.path, args: []) }

        ProcessOutputDrainTests.assertNoPerSpawnLeak("a spawn that cannot start") {
            XCTAssertNotNil(summarizeAndWait(l, md))
        }
        // No handle is left in the `.run` slot, so a Cancel has nothing to stop.
        XCTAssertNil(l.slots.markCancelled(.run), "a spawn that never ran left a handle in the .run slot")
    }
}
