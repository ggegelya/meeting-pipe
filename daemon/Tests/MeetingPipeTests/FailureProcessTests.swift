import XCTest
@testable import MeetingPipe

final class FailureProcessTests: XCTestCase {
    func test_python_catch_boundaries_survive_long_diagnostics_and_overlapping_processes() throws {
        let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        let python = root.appendingPathComponent("pipeline/.venv/bin/python3")
        guard FileManager.default.isExecutableFile(atPath: python.path) else {
            throw XCTSkip("Requires the pipeline development environment for the cross-process check")
        }
        let script = try XCTUnwrap(Bundle.module.url(forResource: "failure-process", withExtension: "py"))
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let md = dir.appendingPathComponent("synthetic.md")
        let wav = dir.appendingPathComponent("synthetic.wav")
        try "synthetic".write(to: md, atomically: true, encoding: .utf8)
        try Data().write(to: wav)
        let launcher = PipelineLauncher(invocation: { .init(shell: python.path, args: [script.path]) },
            environment: ["PATH": "/usr/bin:/bin", "PYTHONPATH": root.appendingPathComponent("pipeline/src").path,
                          "MEETINGPIPE_LOGS_DIR": dir.path])
        let summary = expectation(description: "summary"), ask = expectation(description: "ask"), runAll = expectation(description: "run-all")
        func check(_ error: Error?, request: String, operation: FailureMetadata.Operation) {
            guard let error else { return XCTFail("expected a failure") }
            XCTAssertEqual(FailureMetadata.from(error)?.cause, .credits)
            XCTAssertEqual(FailureMetadata.from(error)?.requestID, request)
            XCTAssertEqual(FailureMetadata.from(error)?.operation, operation)
            XCTAssertTrue(PipelineLauncher.diagnostics(for: error).contains("diagnostic-end"))
            XCTAssertLessThan(error.localizedDescription.count, 100)
        }
        launcher.summarize(transcriptMD: md) { result in
            if case .failure(let error) = result { check(error, request: "req_summary0123456789", operation: .summary) }
            else { XCTFail("expected summarize failure") }
            summary.fulfill()
        }
        launcher.ask(question: "synthetic question") { result in
            if case .failure(let error) = result {
                check(error, request: "req_ask0123456789", operation: .ask)
                // Ask writes the complete error to its result JSON, even when its
                // leading cause has already fallen out of the bounded stderr tail.
                let diagnostics = PipelineLauncher.diagnostics(for: error)
                XCTAssertTrue(diagnostics.hasPrefix("Your credit balance is too low"))
                XCTAssertEqual(diagnostics.components(separatedBy: "synthetic frame\n").count, 2001)
            }
            else { XCTFail("expected ask failure") }
            ask.fulfill()
        }
        wait(for: [summary, ask], timeout: 20)
        launcher.runAll(wav: wav) { result in
            if case .failure(let error) = result { check(error, request: "req_summary0123456789", operation: .summary) }
            else { XCTFail("expected run-all failure") }
            runAll.fulfill()
        }
        wait(for: [runAll], timeout: 20)
        XCTAssertFalse(FileManager.default.fileExists(atPath: dir.appendingPathComponent("synthetic.error.json").path))
    }
}
