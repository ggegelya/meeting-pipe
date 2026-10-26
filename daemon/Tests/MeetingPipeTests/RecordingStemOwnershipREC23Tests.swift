import XCTest
@testable import MeetingPipe

/// REC23: the after-job orphan sweep could merge a recording that was still starting, because
/// its only guard was `libraryModel.liveRecordingStem`, a UI mirror set after `start()` returned,
/// while `<stem>.mic.wav` existed from before the engine start. The recorder now says which stems
/// it owns, and the sweep asks it.
///
/// The owner set's drain-abandon release is pinned against real `SerialBufferWriter`s. The
/// recorder's own claim and release need a live engine to reach, so they are pinned by source
/// fences in `SystemCaptureStartREC17Tests`' shape.
/// T7 source fence (pins implementation): three tests grep MeetingRecorder and Coordinator for where the stem is claimed, where stop releases it, and that the sweep no longer reads the UI mirror. Missing seam: an injectable engine in MeetingRecorder, without which start() cannot run headless past buildMicChain.
@MainActor
final class RecordingStemOwnershipREC23Tests: XCTestCase {

    // MARK: - The owner set

    func test_aClaimedStemIsOwnedUntilReleased() {
        let owned = RecordingStemOwnership()
        owned.claim("20261026-100000")
        XCTAssertTrue(owned.contains("20261026-100000"))
        owned.release("20261026-100000")
        XCTAssertFalse(owned.contains("20261026-100000"))
        XCTAssertTrue(owned.stems.isEmpty)
    }

    /// An abandoned drain's stem and the next recording's stem coexist.
    func test_twoStemsCanBeOwnedAtOnce() {
        let owned = RecordingStemOwnership()
        owned.claim("a")
        owned.claim("b")
        owned.release("a")
        XCTAssertEqual(owned.stems, ["b"])
    }

    func test_aStemWithNoWriterToWaitForIsReleasedAtOnce() {
        let owned = RecordingStemOwnership()
        owned.claim("s")
        owned.releaseWhenDrained("s", writers: [SerialBufferWriter<Int>]())
        XCTAssertFalse(owned.contains("s"))
    }

    /// The stop path REC7 bounded: the drain timed out and was abandoned, the backlog keeps
    /// writing into the intermediates, and the stem must stay out of the sweep until it ends.
    func test_aStemWhoseDrainWasAbandonedIsReleasedOnlyWhenTheDrainFinishes() async {
        let gate = DispatchSemaphore(value: 0)
        let writer = SerialBufferWriter<Int>(label: "test.rec23.abandoned") { _ in gate.wait() }
        writer.enqueue(1)
        let drained = await writer.drain(timeout: 0.1)
        XCTAssertFalse(drained, "the precondition: stop's bounded drain gave up")

        let owned = RecordingStemOwnership()
        owned.claim("s")
        owned.releaseWhenDrained("s", writers: [writer])

        try? await Task.sleep(nanoseconds: 150_000_000)
        XCTAssertTrue(owned.contains("s"), "still owned while the abandoned drain is wedged")

        gate.signal()
        let released = await waitUntil { !owned.contains("s") }
        XCTAssertTrue(released, "released once the abandoned drain finished")
    }

    /// Both channels' writers can wedge; the stem waits for the last of them.
    func test_aStemWaitsForEveryAbandonedWriter() async {
        let micGate = DispatchSemaphore(value: 0)
        let systemGate = DispatchSemaphore(value: 0)
        let mic = SerialBufferWriter<Int>(label: "test.rec23.mic") { _ in micGate.wait() }
        let system = SerialBufferWriter<Int>(label: "test.rec23.system") { _ in systemGate.wait() }
        mic.enqueue(1)
        system.enqueue(1)

        let owned = RecordingStemOwnership()
        owned.claim("s")
        owned.releaseWhenDrained("s", writers: [mic, system])

        micGate.signal()
        try? await Task.sleep(nanoseconds: 150_000_000)
        XCTAssertTrue(owned.contains("s"), "one writer finished, the other is still writing")

        systemGate.signal()
        let released = await waitUntil { !owned.contains("s") }
        XCTAssertTrue(released)
    }

    // MARK: - Source fences on the wiring

    /// The claim has to precede every file the start creates: the `.capturemode` marker and the
    /// `.mic.wav` that `buildMicChain` opens. Claiming after them reopens the window.
    func test_startClaimsTheStemBeforeItsFirstFile() throws {
        let body = try functionBody(
            in: "daemon/Sources/MeetingPipe/MeetingRecorder.swift",
            from: "func start(outputDir: URL, captureMode: CaptureMode",
            to: "private func unwindFailedEngineStart("
        )
        let claim = try XCTUnwrap(body.range(of: "stemOwnership.claim(stamp)"), "start() must claim its stem")
        let stamp = try XCTUnwrap(body.range(of: "let stamp = formatter.string(from: Date())"))
        let marker = try XCTUnwrap(body.range(of: ".capturemode\")"))
        let micChain = try XCTUnwrap(body.range(of: "buildMicChain(voiceProcessing:"))
        XCTAssertLessThan(stamp.lowerBound, claim.lowerBound)
        XCTAssertLessThan(claim.lowerBound, marker.lowerBound, "claimed before the .capturemode write")
        XCTAssertLessThan(claim.lowerBound, micChain.lowerBound, "claimed before buildMicChain opens .mic.wav")
        XCTAssertNotNil(
            body.range(of: "defer { if !started { stemOwnership.release(stamp) } }"),
            "every throwing exit after the claim releases it"
        )
    }

    /// Stop releases only after the merge, and a wedged drain hands the release to the writers.
    func test_stopReleasesAfterTheMergeAndAWedgedDrainWaits() throws {
        let stop = try functionBody(
            in: "daemon/Sources/MeetingPipe/MeetingRecorder.swift",
            from: "func stop(limitSeconds: Double? = nil) async -> Bool {",
            to: "private struct StopSnapshot"
        )
        let merge = try XCTUnwrap(stop.range(of: "await mergeIntermediates("))
        let release = try XCTUnwrap(stop.range(of: "releaseOwnership(of: final, writerWedged: writerWedged"))
        XCTAssertLessThan(merge.lowerBound, release.lowerBound)

        let helper = try functionBody(
            in: "daemon/Sources/MeetingPipe/MeetingRecorder.swift",
            from: "private func releaseOwnership(",
            to: "func flushIntermediatesForTermination()"
        )
        XCTAssertNotNil(helper.range(of: "stemOwnership.releaseWhenDrained(stem, writers: writers)"))
    }

    /// The storage paths ask the recorder, never the UI mirror.
    func test_coordinatorNoLongerReadsTheUIMirror() throws {
        let source = try repoFile("daemon/Sources/MeetingPipe/Coordinator.swift")
        XCTAssertNil(source.range(of: "liveRecordingStem"), "the row pulse's mirror is not a storage guard (REC23)")
        XCTAssertNotNil(source.range(of: "recorder.ownedStems"))
        XCTAssertNotNil(source.range(of: "isOwned:"), "the sweep re-asks per stem, not only at scan")
    }

    // MARK: - Helpers

    private func waitUntil(_ condition: @MainActor () -> Bool) async -> Bool {
        for _ in 0..<200 {
            if condition() { return true }
            try? await Task.sleep(nanoseconds: 10_000_000)
        }
        return condition()
    }

    private func repoFile(_ relative: String) throws -> String {
        try String(
            contentsOf: URL(fileURLWithPath: #filePath)
                .deletingLastPathComponent().deletingLastPathComponent()
                .deletingLastPathComponent().deletingLastPathComponent()
                .appendingPathComponent(relative),
            encoding: .utf8
        )
    }

    private func functionBody(in relative: String, from start: String, to end: String) throws -> String {
        let source = try repoFile(relative)
        let head = try XCTUnwrap(source.range(of: start), "\(start) not found in \(relative)")
        let tail = try XCTUnwrap(
            source.range(of: end, range: head.upperBound..<source.endIndex),
            "\(end) not found after \(start) in \(relative)"
        )
        return String(source[head.lowerBound..<tail.lowerBound])
    }
}
