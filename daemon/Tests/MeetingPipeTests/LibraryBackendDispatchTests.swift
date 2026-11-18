import XCTest
@testable import MeetingPipe
import MeetingPipeTestSupport

/// PIPE52: the Library's re-runs dispatch on the meeting's effective backend (`EffectiveBackend`),
/// not the global setting. An Apple meeting re-summarizes through the Swift summarizer and then
/// publishes, instead of spawning an `mp summarize` whose Apple builder can only raise; and the
/// on-device preview stays on-device whatever the workflow pins.
final class LibraryBackendDispatchTests: XCTestCase {

    private var dir: URL!
    private var driver: FakePipelineDriver!
    private var errors: [String] = []

    override func setUpWithError() throws {
        dir = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("pipe52-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        driver = FakePipelineDriver()
        errors = []
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: dir)
    }

    private func service(global: String, regulated: Bool = false) -> MeetingLibraryService {
        MeetingLibraryService(
            outputDir: { [unowned self] in self.dir },
            launcher: driver,
            notifyError: { [unowned self] message, _, _ in self.errors.append(message) },
            enqueue: { _, _, _ in XCTFail("no transcription expected") },
            summarizationBackend: { global },
            regulatedMode: { regulated }
        )
    }

    private func write(_ name: String, _ contents: String) throws {
        try contents.write(to: dir.appendingPathComponent(name), atomically: true, encoding: .utf8)
    }

    private func pin(_ backend: String, nda: Bool = false) throws {
        try write("m.meta.json", #"{"schema_version": 1, "workflow_backend": "\#(backend)", "workflow_nda_mode": \#(nda)}"#)
    }

    private func reusableTranscript() throws {
        try write("m.md", "# Transcript\n\nSpeaker: A synthetic sentence.")
        try write("m.json", #"{"segments":[{"start":0,"end":2,"text":"A synthetic sentence.","speaker":"ME"}],"finalized":true}"#)
    }

    private var md: URL { dir.appendingPathComponent("m.md") }

    // MARK: - Apple re-summarize

    func test_regenerate_of_an_apple_pinned_meeting_runs_the_apple_summarizer_then_publishes() throws {
        try reusableTranscript()
        try pin("apple_intelligence")
        var captured: Result<URL?, Error>?
        service(global: "anthropic").regenerateMeeting(stem: "m") { captured = $0 }

        XCTAssertEqual(driver.appleSummarizeInputs, [md])
        XCTAssertTrue(driver.summarizeInputs.isEmpty, "no mp summarize: it has no Apple path")
        try write("m.summary.json", #"{"title":"new"}"#)   // what the real summarizer leaves
        driver.finishAppleSummarize(.success(()))
        XCTAssertTrue(drainMainSync())
        XCTAssertEqual(driver.publishInputs, [dir.appendingPathComponent("m.summary.json")])
        driver.finishPublish(.success(nil))
        XCTAssertTrue(drainMainSync())
        guard case .success? = captured else { return XCTFail("expected success") }
        XCTAssertTrue(errors.isEmpty)
    }

    func test_retry_with_a_reusable_transcript_takes_the_apple_route() throws {
        try reusableTranscript()
        try pin("apple_intelligence")
        PipelineFailureSidecar.write(stem: "m", in: dir, stage: .pipeline, reason: "model not ready")
        XCTAssertNoThrow(try service(global: "anthropic").retryMeeting(stem: "m").get())

        XCTAssertEqual(driver.appleSummarizeInputs, [md])
        XCTAssertTrue(driver.summarizeInputs.isEmpty)
        try write("m.summary.json", #"{"title":"new"}"#)
        driver.finishAppleSummarize(.success(()))
        XCTAssertTrue(drainMainSync())
        XCTAssertEqual(driver.publishInputs.count, 1)
        XCTAssertNil(PipelineFailureSidecar.read(stem: "m", in: dir), "a landed summarize clears the failure")
    }

    func test_a_global_apple_backend_with_no_pin_takes_the_apple_route() throws {
        try reusableTranscript()
        service(global: "apple_intelligence").regenerateMeeting(stem: "m") { _ in }
        XCTAssertEqual(driver.appleSummarizeInputs, [md])
        XCTAssertTrue(driver.summarizeInputs.isEmpty)
    }

    func test_an_nda_meeting_never_takes_the_apple_route() throws {
        // Regulated and NDA force local, as the pipeline's `effective_backend` does.
        try reusableTranscript()
        try pin("apple_intelligence", nda: true)
        service(global: "apple_intelligence").regenerateMeeting(stem: "m") { _ in }
        XCTAssertTrue(driver.appleSummarizeInputs.isEmpty)
        XCTAssertEqual(driver.summarizeInputs, [md])
    }

    func test_an_explicit_backend_beats_an_apple_pin() throws {
        // PIPE6's "Re-summarize with Anthropic" on an Apple-pinned meeting is still mp summarize.
        try reusableTranscript()
        try pin("apple_intelligence")
        service(global: "anthropic").regenerateMeeting(stem: "m", backend: "anthropic") { _ in }
        XCTAssertTrue(driver.appleSummarizeInputs.isEmpty)
        XCTAssertEqual(driver.summarizeBackends, ["anthropic"])
    }

    func test_a_failed_apple_summarize_writes_the_failure_and_spawns_no_publish() throws {
        try reusableTranscript()
        try pin("apple_intelligence")
        var captured: Result<URL?, Error>?
        service(global: "anthropic").regenerateMeeting(stem: "m") { captured = $0 }
        driver.finishAppleSummarize(.failure(AppleIntelligenceError.unavailable("model not ready")))
        XCTAssertTrue(drainMainSync())

        guard case .failure? = captured else { return XCTFail("expected failure") }
        XCTAssertTrue(driver.publishInputs.isEmpty)
        XCTAssertNotNil(PipelineFailureSidecar.read(stem: "m", in: dir))
    }

    func test_a_cancelled_apple_summarize_keeps_the_summary_and_spawns_no_publish() throws {
        try reusableTranscript()
        try pin("apple_intelligence")
        let previous = #"{"title":"previous"}"#
        try write("m.summary.json", previous)
        service(global: "anthropic").regenerateMeeting(stem: "m") { _ in }
        driver.finishAppleSummarize(.failure(CancellationError()))
        XCTAssertTrue(drainMainSync())

        XCTAssertTrue(driver.publishInputs.isEmpty)
        XCTAssertTrue(errors.isEmpty, "a Cancel is not a failure")
        XCTAssertNil(PipelineFailureSidecar.read(stem: "m", in: dir))
        XCTAssertEqual(try String(contentsOf: dir.appendingPathComponent("m.summary.json"), encoding: .utf8), previous)
    }

    // MARK: - The on-device preview (A16) and the reprocess (FEAT7)

    func test_an_anthropic_pinned_meeting_under_a_local_global_previews_with_an_explicit_local_backend() throws {
        try write("m.md", "t")
        try pin("anthropic")
        let service = service(global: "local")
        XCTAssertEqual(service.localPreviewEngine(stem: "m"), "local", "offered")
        service.previewSummary(stem: "m", mode: .onDevice) { _ in }
        XCTAssertEqual(driver.previewInputs, [md])
        XCTAssertEqual(driver.previewBackends, ["local"], "--backend local, so the pin cannot carry it to the cloud")
        XCTAssertTrue(driver.applePreviewInputs.isEmpty)
    }

    func test_a_local_pinned_meeting_under_a_cloud_global_offers_the_preview() throws {
        try write("m.md", "t")
        try pin("local")
        XCTAssertEqual(service(global: "anthropic").localPreviewEngine(stem: "m"), "local")
    }

    func test_an_apple_pinned_meeting_under_a_local_global_previews_through_apple() throws {
        try write("m.md", "t")
        try pin("apple_intelligence")
        let service = service(global: "local")
        XCTAssertEqual(service.localPreviewEngine(stem: "m"), "apple_intelligence")
        service.previewSummary(stem: "m", mode: .onDevice) { _ in }
        XCTAssertEqual(driver.applePreviewInputs, [md])
        XCTAssertTrue(driver.previewInputs.isEmpty)
    }

    func test_no_on_device_engine_means_no_preview_and_no_spawn() throws {
        try write("m.md", "t")
        let service = service(global: "anthropic")
        XCTAssertNil(service.localPreviewEngine(stem: "m"))
        var captured: Result<Void, Error>?
        service.previewSummary(stem: "m", mode: .onDevice) { captured = $0 }
        guard case .failure(let error)? = captured else { return XCTFail("expected failure") }
        XCTAssertEqual(error as? MeetingLibraryService.LibraryError, .noLocalPreview)
        XCTAssertTrue(driver.previewInputs.isEmpty)
        XCTAssertTrue(driver.applePreviewInputs.isEmpty)
    }

    func test_the_reprocess_runs_the_meetings_own_engine() throws {
        try write("m.md", "t")
        try pin("anthropic")
        service(global: "local").previewSummary(stem: "m", contextOverride: "Lead with decisions.", mode: .meetingBackend) { _ in }
        XCTAssertEqual(driver.previewBackends, [nil], "the workflow's own backend, no override")

        try pin("apple_intelligence")
        service(global: "anthropic").previewSummary(stem: "m", mode: .meetingBackend) { _ in }
        XCTAssertEqual(driver.applePreviewInputs, [md], "an Apple pin no longer reaches mp summarize")
    }
}
