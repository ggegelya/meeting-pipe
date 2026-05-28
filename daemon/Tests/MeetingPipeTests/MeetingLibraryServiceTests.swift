import XCTest
@testable import MeetingPipe

/// Pins the post-extraction contract for `MeetingLibraryService`
/// (TECH-H1-FINISH): the on-disk meeting operations behave exactly as
/// they did on `Coordinator`, with dependencies injected as closures so
/// the type is testable without a live daemon.
final class MeetingLibraryServiceTests: XCTestCase {

    /// Programmable in-memory pipeline driver. Records the inputs it is
    /// handed and parks each completion so the test resolves it.
    private final class FakeDriver: PipelineDriver {
        private(set) var summarizeInputs: [URL] = []
        private(set) var publishInputs: [URL] = []
        private(set) var publishFromPasteInputs: [URL] = []
        private var summarizeCompletions: [(Result<Void, Error>) -> Void] = []
        private var publishCompletions: [(Result<URL?, Error>) -> Void] = []
        private var publishFromPasteCompletions: [(Result<Void, Error>) -> Void] = []

        func runAll(wav: URL, summaryMode: SummaryMode, completion: @escaping (Result<URL?, Error>) -> Void) {}

        func summarize(transcriptMD: URL, completion: @escaping (Result<Void, Error>) -> Void) {
            summarizeInputs.append(transcriptMD)
            summarizeCompletions.append(completion)
        }

        func publish(summaryJSON: URL, completion: @escaping (Result<URL?, Error>) -> Void) {
            publishInputs.append(summaryJSON)
            publishCompletions.append(completion)
        }

        func publishFromPaste(transcriptMD: URL, completion: @escaping (Result<Void, Error>) -> Void) {
            publishFromPasteInputs.append(transcriptMD)
            publishFromPasteCompletions.append(completion)
        }

        func finishSummarize(_ result: Result<Void, Error>) {
            guard !summarizeCompletions.isEmpty else { return }
            summarizeCompletions.removeFirst()(result)
        }

        func finishPublish(_ result: Result<URL?, Error>) {
            guard !publishCompletions.isEmpty else { return }
            publishCompletions.removeFirst()(result)
        }

        func finishPublishFromPaste(_ result: Result<Void, Error>) {
            guard !publishFromPasteCompletions.isEmpty else { return }
            publishFromPasteCompletions.removeFirst()(result)
        }
    }

    private var dir: URL!
    private var driver: FakeDriver!
    private var enqueued: [(URL, SummaryMode)] = []
    private var errors: [String] = []
    private var service: MeetingLibraryService!

    override func setUpWithError() throws {
        dir = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("mp-library-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        driver = FakeDriver()
        enqueued = []
        errors = []
        service = MeetingLibraryService(
            outputDir: { [unowned self] in self.dir },
            launcher: driver,
            notifyError: { [unowned self] message in self.errors.append(message) },
            enqueue: { [unowned self] file, mode in self.enqueued.append((file, mode)) }
        )
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: dir)
    }

    private func touch(_ name: String, contents: String = "x") throws {
        try contents.write(
            to: dir.appendingPathComponent(name),
            atomically: true, encoding: .utf8
        )
    }

    // MARK: - retry

    func test_retry_missing_wav_fails_without_enqueue() {
        let result = service.retryMeeting(stem: "absent")
        guard case .failure = result else { return XCTFail("expected failure") }
        XCTAssertTrue(enqueued.isEmpty)
    }

    func test_retry_enqueues_existing_wav_as_auto() throws {
        try touch("meeting.wav")
        let result = service.retryMeeting(stem: "meeting")
        guard case .success = result else { return XCTFail("expected success") }
        XCTAssertEqual(enqueued.count, 1)
        XCTAssertEqual(enqueued.first?.0.lastPathComponent, "meeting.wav")
        XCTAssertEqual(enqueued.first?.1, .auto)
    }

    // MARK: - export

    func test_export_copies_present_artifacts_and_skips_missing() throws {
        try touch("m.summary.md")
        try touch("m.md")
        try touch("m.wav")
        let dest = dir.appendingPathComponent("out")
        try FileManager.default.createDirectory(at: dest, withIntermediateDirectories: true)

        let result = service.exportMeeting(stem: "m", to: dest)
        guard case .success(let copied) = result else { return XCTFail("expected success") }
        XCTAssertEqual(copied, 3)
        XCTAssertTrue(FileManager.default.fileExists(atPath: dest.appendingPathComponent("m.summary.md").path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: dest.appendingPathComponent("m.md").path))
        XCTAssertFalse(FileManager.default.fileExists(atPath: dest.appendingPathComponent("m.summary.json").path))
    }

    // MARK: - soft-delete

    func test_softDelete_no_matching_files_fails() {
        let result = service.softDeleteMeeting(stem: "ghost")
        guard case .failure = result else { return XCTFail("expected failure") }
    }

    // MARK: - republish / regenerate guards

    func test_republish_without_summary_json_calls_completion_failure() {
        var captured: Result<URL?, Error>?
        service.republishMeeting(stem: "x") { captured = $0 }
        guard case .failure? = captured else { return XCTFail("expected synchronous failure") }
        XCTAssertTrue(driver.publishInputs.isEmpty)
    }

    func test_regenerate_without_transcript_calls_completion_failure() {
        var captured: Result<URL?, Error>?
        service.regenerateMeeting(stem: "x") { captured = $0 }
        guard case .failure? = captured else { return XCTFail("expected synchronous failure") }
        XCTAssertTrue(driver.summarizeInputs.isEmpty)
    }

    func test_regenerate_success_chains_into_publish() throws {
        try touch("m.md")
        try touch("m.summary.json")
        var captured: Result<URL?, Error>?
        service.regenerateMeeting(stem: "m") { captured = $0 }

        XCTAssertEqual(driver.summarizeInputs.count, 1)
        // Summarize resolves on the main queue inside the service.
        driver.finishSummarize(.success(()))
        let drained = expectation(description: "drain")
        DispatchQueue.main.async { drained.fulfill() }
        wait(for: [drained], timeout: 1.0)

        XCTAssertEqual(driver.publishInputs.count, 1, "regenerate should chain into publish")
        driver.finishPublish(.success(URL(string: "https://notion.example/page")))
        let drained2 = expectation(description: "drain2")
        DispatchQueue.main.async { drained2.fulfill() }
        wait(for: [drained2], timeout: 1.0)
        guard case .success(let url)? = captured else { return XCTFail("expected success") }
        XCTAssertEqual(url?.absoluteString, "https://notion.example/page")
    }

    // MARK: - publish-from-paste (TECH-UX3)

    func test_publishFromPaste_writes_summary_md_and_invokes_driver() throws {
        try touch("m.md")
        var captured: Result<Void, Error>?
        service.publishFromPaste(stem: "m", summaryText: "# Notes\n- a") { captured = $0 }

        let mdPath = dir.appendingPathComponent("m.summary.md").path
        XCTAssertTrue(FileManager.default.fileExists(atPath: mdPath))
        XCTAssertEqual(try String(contentsOfFile: mdPath, encoding: .utf8), "# Notes\n- a")
        XCTAssertEqual(driver.publishFromPasteInputs.count, 1)
        XCTAssertEqual(driver.publishFromPasteInputs.first?.lastPathComponent, "m.md")

        driver.finishPublishFromPaste(.success(()))
        let drained = expectation(description: "drain")
        DispatchQueue.main.async { drained.fulfill() }
        wait(for: [drained], timeout: 1.0)
        guard case .success? = captured else { return XCTFail("expected success") }
    }

    func test_publishFromPaste_missing_transcript_fails_without_invoking_driver() {
        var captured: Result<Void, Error>?
        service.publishFromPaste(stem: "absent", summaryText: "# Notes") { captured = $0 }
        guard case .failure? = captured else { return XCTFail("expected synchronous failure") }
        XCTAssertTrue(driver.publishFromPasteInputs.isEmpty)
        XCTAssertFalse(FileManager.default.fileExists(atPath: dir.appendingPathComponent("absent.summary.md").path))
    }

    func test_publishFromPaste_empty_text_fails() {
        var captured: Result<Void, Error>?
        service.publishFromPaste(stem: "m", summaryText: "   \n ") { captured = $0 }
        guard case .failure? = captured else { return XCTFail("expected failure for empty paste") }
        XCTAssertTrue(driver.publishFromPasteInputs.isEmpty)
    }

    // MARK: - read-only queries

    func test_recentCorrectable_sorts_newest_first_and_honors_limit() throws {
        try touch("old.run.json")
        try touch("new.run.json")
        let fm = FileManager.default
        // Force a deterministic mtime ordering: old < new.
        try fm.setAttributes([.modificationDate: Date(timeIntervalSince1970: 1000)],
                             ofItemAtPath: dir.appendingPathComponent("old.run.json").path)
        try fm.setAttributes([.modificationDate: Date(timeIntervalSince1970: 2000)],
                             ofItemAtPath: dir.appendingPathComponent("new.run.json").path)

        let all = service.recentCorrectableMeetings(limit: 10)
        XCTAssertEqual(all.map { $0.stem }, ["new", "old"])

        let capped = service.recentCorrectableMeetings(limit: 1)
        XCTAssertEqual(capped.map { $0.stem }, ["new"])
    }

    func test_failedMeetingCount_empty_dir_is_zero() {
        XCTAssertEqual(service.failedMeetingCount(), 0)
    }
}
