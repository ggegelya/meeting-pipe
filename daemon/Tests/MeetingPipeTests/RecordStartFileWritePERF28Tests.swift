import AVFoundation
import os
import XCTest
@testable import MeetingPipe

/// PERF28: the record-start file writes run off main under their own bound, a slow create still
/// starts, and an abandoned one cleans up after itself.
///
/// T7 source fence (deliberate) for the recorder half: `start()` cannot run headless past the
/// engine's format read (no injectable engine; see `EngineCallBoundsREC27Tests`), so the claims
/// "a timed-out create fails with `fileCreateFailed` through start()'s one catch without touching
/// the engine" and "the marker is awaited before the mic chain" are pinned on the source. The
/// behaviour they rest on (bound, hand-off, late cleanup, duration line, stem hold) is exercised
/// here through the injected factory.
@MainActor
final class RecordStartFileWritePERF28Tests: XCTestCase {

    private var dir: URL!
    private var logs: URL!

    override func setUpWithError() throws {
        try super.setUpWithError()
        dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("mp-perf28-\(UUID().uuidString)", isDirectory: true)
        logs = dir.appendingPathComponent("logs", isDirectory: true)
        try FileManager.default.createDirectory(at: logs, withIntermediateDirectories: true)
        setenv("MEETINGPIPE_LOGS_DIR", logs.path, 1)
    }

    override func tearDownWithError() throws {
        unsetenv("MEETINGPIPE_LOGS_DIR")
        try? FileManager.default.removeItem(at: dir)
        try super.tearDownWithError()
    }

    private var micURL: URL { dir.appendingPathComponent("20261116-100000.mic.wav") }

    private func recorderLog() -> String {
        (try? String(contentsOf: logs.appendingPathComponent("recorder.log"), encoding: .utf8)) ?? ""
    }

    // MARK: - The bound

    func test_theBudgetIsAboveTheEngineCallBudgetAndTheSlowestMeasuredCreate() {
        XCTAssertGreaterThan(RecordStartFileWrite.budgetSeconds, MeetingRecorder.engineCallBudgetSeconds)
        XCTAssertGreaterThan(RecordStartFileWrite.budgetSeconds, 3.1, "the slowest field create took 3,078 ms and succeeded")
    }

    /// Slower than the old 2.0 s engine budget, inside the new bound: the create succeeds and
    /// hands back a writable file, where routing it through `engineCall` would have failed it.
    func test_aCreateSlowerThanTheEngineBudgetStillSucceeds() async throws {
        let outcome = await RecordStartFileWrite.createMicFile(at: micURL, sampleRate: 48_000) { url, rate in
            Thread.sleep(forTimeInterval: MeetingRecorder.engineCallBudgetSeconds + 0.2)
            return try RecordStartFileWrite.makeMonoMicFile(at: url, sampleRate: rate)
        }
        guard case .created(let file) = outcome else { return XCTFail("expected a created file, got \(outcome)") }
        XCTAssertEqual(file.processingFormat.channelCount, 1)
        XCTAssertEqual(file.processingFormat.sampleRate, 48_000)
        XCTAssertTrue(FileManager.default.fileExists(atPath: micURL.path))
    }

    func test_theCreateRunsOffTheMainThread() async {
        let onMain = OSAllocatedUnfairLock<Bool?>(initialState: nil)
        _ = await RecordStartFileWrite.createMicFile(at: micURL, sampleRate: 48_000) { url, rate in
            onMain.withLock { $0 = Thread.isMainThread }
            return try RecordStartFileWrite.makeMonoMicFile(at: url, sampleRate: rate)
        }
        XCTAssertEqual(onMain.withLock { $0 }, false)
    }

    /// Every start names its own cost in recorder.log.
    func test_everyCreateLogsItsDuration() async throws {
        _ = await RecordStartFileWrite.createMicFile(at: micURL, sampleRate: 48_000) { url, rate in
            Thread.sleep(forTimeInterval: 0.05)
            return try RecordStartFileWrite.makeMonoMicFile(at: url, sampleRate: rate)
        }
        let line = try XCTUnwrap(recorderLog().split(separator: "\n").first { $0.contains("mic file created in ") })
        let ms = try XCTUnwrap(Int(line.components(separatedBy: "mic file created in ").last?
            .components(separatedBy: " ms").first ?? ""))
        XCTAssertGreaterThanOrEqual(ms, 50)
    }

    func test_aFailedCreateReportsItsErrorAndDuration() async {
        struct Refused: Error, LocalizedError { var errorDescription: String? { "disk refused" } }
        let outcome = await RecordStartFileWrite.createMicFile(at: micURL, sampleRate: 48_000) { _, _ in
            throw Refused()
        }
        guard case .failed(let message) = outcome else { return XCTFail("expected a failure, got \(outcome)") }
        XCTAssertEqual(message, "disk refused")
        XCTAssertTrue(recorderLog().contains("mic file create failed in "))
    }

    // MARK: - Abandonment

    /// Past its bound the create is abandoned; when it finally returns it deletes the file it
    /// made, so no header-only `.mic.wav` outlives the failed start.
    func test_aCreateThatReturnsAfterItsBoundDeletesTheFileItMade() async {
        let lateFinish = expectation(description: "the abandoned create returned and cleaned up")
        let abandoned = OSAllocatedUnfairLock(initialState: false)
        let outcome = await RecordStartFileWrite.createMicFile(
            at: micURL,
            sampleRate: 48_000,
            budgetSeconds: 0.1,
            onAbandon: { abandoned.withLock { $0 = true } },
            onLateFinish: { lateFinish.fulfill() }
        ) { url, rate in
            Thread.sleep(forTimeInterval: 0.4)
            return try RecordStartFileWrite.makeMonoMicFile(at: url, sampleRate: rate)
        }
        guard case .timedOut = outcome else { return XCTFail("expected a timeout, got \(outcome)") }
        XCTAssertTrue(abandoned.withLock { $0 }, "the caller learns of the abandonment in the same turn")
        await fulfillment(of: [lateFinish], timeout: 5)
        XCTAssertFalse(FileManager.default.fileExists(atPath: micURL.path), "raw/ holds no <stem>.mic.wav afterwards")
        XCTAssertTrue(recorderLog().contains("WARN: mic file create did not finish within"))
    }

    /// A late create that throws may still have left a partial file; it is removed too.
    func test_anAbandonedCreateThatThrowsStillRemovesWhatItLeft() async throws {
        let lateFinish = expectation(description: "the abandoned create returned")
        let url = micURL
        let outcome = await RecordStartFileWrite.createMicFile(
            at: url, sampleRate: 48_000, budgetSeconds: 0.1, onLateFinish: { lateFinish.fulfill() }
        ) { url, _ in
            Thread.sleep(forTimeInterval: 0.4)
            try Data("RIFF".utf8).write(to: url)
            throw CocoaError(.fileWriteUnknown)
        }
        guard case .timedOut = outcome else { return XCTFail("expected a timeout, got \(outcome)") }
        await fulfillment(of: [lateFinish], timeout: 5)
        XCTAssertFalse(FileManager.default.fileExists(atPath: url.path))
    }

    /// The marker shares the helper: one that lands after the caller gave up (and a failed
    /// start's unwind removed the file) deletes what it wrote.
    func test_aLateMarkerWriteLeavesNothingBehind() async {
        let lateFinish = expectation(description: "the abandoned write returned")
        let marker = dir.appendingPathComponent("20261116-100000.capturemode")
        let outcome = await RecordStartFileWrite.run(
            producing: marker, budgetSeconds: 0.1, onLateFinish: { lateFinish.fulfill() }
        ) {
            Thread.sleep(forTimeInterval: 0.4)
            try? "capture_first".write(to: marker, atomically: true, encoding: .utf8)
        }
        guard case .timedOut = outcome else { return XCTFail("expected a timeout") }
        await fulfillment(of: [lateFinish], timeout: 5)
        XCTAssertFalse(FileManager.default.fileExists(atPath: marker.path))
    }

    /// The manifest's late write is kept: its recording is most likely still live.
    func test_aLateWriteThatKeepsItsResultLeavesItInPlace() async {
        let lateFinish = expectation(description: "the abandoned write returned")
        let manifest = dir.appendingPathComponent("20261116-100000.recovery.json")
        let outcome = await RecordStartFileWrite.run(
            producing: manifest, budgetSeconds: 0.1, keepsLateResult: true, onLateFinish: { lateFinish.fulfill() }
        ) {
            Thread.sleep(forTimeInterval: 0.4)
            try? Data("{}".utf8).write(to: manifest)
        }
        guard case .timedOut = outcome else { return XCTFail("expected a timeout") }
        await fulfillment(of: [lateFinish], timeout: 5)
        XCTAssertTrue(FileManager.default.fileExists(atPath: manifest.path))
    }

    func test_aWriteInsideItsBudgetIsKept() async {
        let marker = dir.appendingPathComponent("20261116-100000.capturemode")
        let outcome = await RecordStartFileWrite.run(producing: marker) {
            try? "capture_first".write(to: marker, atomically: true, encoding: .utf8)
        }
        guard case .finished = outcome else { return XCTFail("expected the write to finish") }
        XCTAssertTrue(FileManager.default.fileExists(atPath: marker.path))
    }

    // MARK: - The stem hold

    /// A failed start releases its stem, but an abandoned create may still be about to make the
    /// file, so the release waits for the hold. Releases with no hold are immediate, as before.
    func test_aReleaseWaitsForAnOutstandingHold() {
        let ownership = RecordingStemOwnership()
        ownership.claim("a")
        ownership.hold("a")
        ownership.release("a")
        XCTAssertTrue(ownership.contains("a"), "still owned while the abandoned create can write")
        ownership.endHold("a")
        XCTAssertFalse(ownership.contains("a"))

        ownership.claim("b")
        ownership.release("b")
        XCTAssertFalse(ownership.contains("b"))
    }

    /// A hold that ends before any release (the create was abandoned but the stem is still in
    /// use, which today cannot happen, since an abandonment fails the start) leaves it owned.
    func test_anEndedHoldWithoutAReleaseKeepsTheStem() {
        let ownership = RecordingStemOwnership()
        ownership.claim("a")
        ownership.hold("a")
        ownership.endHold("a")
        XCTAssertTrue(ownership.contains("a"))
    }

    // MARK: - Recorder wiring (source fence, see the class doc)

    func test_buildMicChainCreatesThroughTheBoundedHelperAndATimeoutIsNotAWedge() throws {
        let code = String(SwiftSourceScan.codeOnly(try daemonSource("Sources/MeetingPipe/MeetingRecorder.swift")))
        let chain = try XCTUnwrap(
            code.components(separatedBy: "private func buildMicChain(voiceProcessing: Bool, micURL: URL) async throws -> MicChainOutcome {")
                .dropFirst().first?.components(separatedBy: "\n    }\n").first
        )
        XCTAssertFalse(chain.contains("AVAudioFile(forWriting:"), "the create must not run on main")
        XCTAssertTrue(chain.contains("RecordStartFileWrite.createMicFile("))
        XCTAssertTrue(chain.contains("onAbandon: { ownership.hold(stem) }"))
        XCTAssertTrue(chain.contains("ownership.endHold(stem)"))
        let timedOut = try XCTUnwrap(
            chain.components(separatedBy: "case .timedOut:").dropFirst().first?
                .components(separatedBy: "\n        }\n").first
        )
        XCTAssertTrue(timedOut.contains("RecorderError.fileCreateFailed("))
        for wedge in ["noteAbandoned(", "replaceEngine(", "failStartOnWedge("] {
            XCTAssertFalse(timedOut.contains(wedge), "a slow file create is not an engine wedge: \(wedge)")
        }
    }

    func test_theMarkerIsAwaitedBeforeTheMicChain() throws {
        let code = String(SwiftSourceScan.codeOnly(try daemonSource("Sources/MeetingPipe/MeetingRecorder.swift")))
        let start = try XCTUnwrap(
            code.components(separatedBy: "func start(outputDir: URL, captureMode: CaptureMode, voiceProcessing: Bool = false) async throws -> URL {")
                .dropFirst().first?.components(separatedBy: "\n    }\n").first
        )
        let marker = try XCTUnwrap(start.range(of: "try await Self.writeModeMarker(captureMode.marker, to: modeMarkerURL)"))
        let mic = try XCTUnwrap(start.range(of: "try await startMicCapture("))
        XCTAssertLessThan(marker.lowerBound, mic.lowerBound)
        XCTAssertFalse(start.contains("marker.write(to:"), "the marker write runs off main, through writeModeMarker")
    }

    private func daemonSource(_ relativePath: String) throws -> String {
        let root = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()   // MeetingPipeTests
            .deletingLastPathComponent()   // Tests
            .deletingLastPathComponent()   // daemon
        return try String(contentsOf: root.appendingPathComponent(relativePath), encoding: .utf8)
    }
}
