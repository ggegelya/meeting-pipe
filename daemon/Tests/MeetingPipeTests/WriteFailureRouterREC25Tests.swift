import XCTest
@testable import MeetingPipe

/// REC25: a capture writer's failures count against its own recording and no other.
///
/// The recorder used to hold one tracker per channel and replace it at `start()`, while a writer
/// abandoned by the previous stop's drain kept reporting into whichever tracker was current: its
/// failures could force-stop the next, healthy recording, or post "Recording stopped" with nothing
/// recording. These drive the seam with no engine, no disk and no run loop: the main hop is
/// synchronous and events land in an array.
final class WriteFailureRouterREC25Tests: XCTestCase {

    private var events: [(action: String, attributes: [String: Any])] = []
    private var delivered: [RecordingWriteFailure.Decision] = []
    private var freeSpaceReads = 0
    private let dir = URL(fileURLWithPath: "/nonexistent/rec25")

    private func makeRouter() -> WriteFailureRouter {
        let router = WriteFailureRouter(
            mainHop: { $0() },
            freeSpace: { [unowned self] _ in
                self.freeSpaceReads += 1
                return (50_000_000_000, "Test Volume")
            },
            emit: { [unowned self] action, attributes in self.events.append((action, attributes)) }
        )
        router.onWriteFailure = { [unowned self] decision in self.delivered.append(decision) }
        return router
    }

    private func actions() -> [String] { events.map(\.action) }

    private func fail(_ handler: (Bool) -> Void, times: Int) {
        for _ in 0..<times { handler(false) }
    }

    func test_thirty_two_failures_inside_the_recording_escalate_once() {
        let router = makeRouter()
        router.beginRecording()
        let mic = router.makeOutcomeHandler(channel: .mic, directory: dir)

        fail(mic, times: WriteFailureTracker.defaultThreshold + 20)

        XCTAssertEqual(delivered.count, 1)
        XCTAssertEqual(delivered.first?.channel, "mic")
        XCTAssertEqual(delivered.first?.cause, .unknown)
        XCTAssertEqual(actions(), ["recording_error"])
        XCTAssertEqual(events.first?.attributes["consecutive_failures"] as? Int, WriteFailureTracker.defaultThreshold)
    }

    /// The abandoned writer of recording 1 fails its whole run after recording 2 started. Nothing
    /// reaches `onWriteFailure`, the row says stale, and recording 2's own tracker still needs its
    /// full 32: had the old writer fed it, the 32nd failure below would be its 64th.
    func test_a_previous_recordings_writer_never_reaches_onWriteFailure() {
        let router = makeRouter()
        router.beginRecording()
        let oldMic = router.makeOutcomeHandler(channel: .mic, directory: dir)
        router.endRecording()
        router.beginRecording()
        let newMic = router.makeOutcomeHandler(channel: .mic, directory: dir)

        fail(oldMic, times: WriteFailureTracker.defaultThreshold)

        XCTAssertTrue(delivered.isEmpty)
        XCTAssertEqual(actions(), ["write_failure_stale"])
        let stale = events[0].attributes
        XCTAssertEqual(stale["channel"] as? String, "mic")
        XCTAssertEqual(stale["generation"] as? Int, 1)
        XCTAssertEqual(stale["live_generation"] as? Int, 2)

        fail(newMic, times: WriteFailureTracker.defaultThreshold - 1)
        XCTAssertTrue(delivered.isEmpty, "recording 2's tracker started from zero")
        newMic(false)
        XCTAssertEqual(delivered.count, 1)
        XCTAssertEqual(actions(), ["write_failure_stale", "recording_error"])
    }

    /// Between recordings there is nothing to stop, so a late escalation must not post "Recording
    /// stopped" over an idle app, nor force-stop whatever state the session is in (a `.prompting`
    /// force-stop dismisses the prompt).
    func test_an_escalation_after_the_recording_ended_is_stale() {
        let router = makeRouter()
        router.beginRecording()
        let system = router.makeOutcomeHandler(channel: .system, directory: dir)
        router.endRecording()

        fail(system, times: WriteFailureTracker.defaultThreshold)

        XCTAssertTrue(delivered.isEmpty)
        XCTAssertEqual(actions(), ["write_failure_stale"])
        XCTAssertTrue(events[0].attributes["live_generation"] is NSNull, "null in the row: no recording is live")
    }

    /// Two writers of the same recording keep separate counts: a mic failing every other buffer
    /// never escalates on the system channel's failures.
    func test_each_writer_counts_its_own_failures() {
        let router = makeRouter()
        router.beginRecording()
        let mic = router.makeOutcomeHandler(channel: .mic, directory: dir)
        let system = router.makeOutcomeHandler(channel: .system, directory: dir)

        for _ in 0..<WriteFailureTracker.defaultThreshold {
            system(false)
            mic(true)
        }
        XCTAssertEqual(delivered.map(\.channel), ["system"])
    }

    /// The backlog cap escalates on main through the same `onWriteFailure`, as `writer_stalled`,
    /// without reading free space: the volume it would ask is the one that stopped answering.
    func test_the_backlog_cap_escalates_as_writer_stalled_without_reading_free_space() {
        let router = makeRouter()
        router.beginRecording()

        router.escalateBacklog(channel: .system, pendingBytes: WriterBacklogPolicy.hardCapBytes + 1)

        XCTAssertEqual(delivered.count, 1)
        XCTAssertEqual(delivered.first?.cause, .writerStalled)
        XCTAssertNil(delivered.first?.freeBytes)
        XCTAssertEqual(freeSpaceReads, 0)
        XCTAssertEqual(actions(), ["recording_error"])
        XCTAssertEqual(events[0].attributes["cause"] as? String, "writer_stalled")
        XCTAssertEqual(events[0].attributes["pending_bytes"] as? Int, WriterBacklogPolicy.hardCapBytes + 1)
    }

    func test_the_backlog_cap_does_nothing_between_recordings() {
        let router = makeRouter()
        router.escalateBacklog(channel: .mic, pendingBytes: WriterBacklogPolicy.hardCapBytes + 1)
        XCTAssertTrue(delivered.isEmpty)
        XCTAssertTrue(events.isEmpty)
    }

    // MARK: - Fences

    /// The recorder no longer holds trackers it could reset under a live writer, and both writers
    /// get their handler from the router rather than a recorder method.
    func test_the_recorder_holds_no_tracker_of_its_own() throws {
        let recorder = try source("Sources/MeetingPipe/MeetingRecorder.swift")
        let system = try source("Sources/MeetingPipe/SystemAudioChannel.swift")
        XCTAssertFalse(recorder.contains("WriteFailureTracker()"), "a recorder-held tracker is the race REC25 removed")
        XCTAssertFalse(recorder.contains("func noteWriteOutcome"))
        XCTAssertTrue(recorder.contains("writeFailures.makeOutcomeHandler(\n            channel: .mic"))
        XCTAssertTrue(system.contains("writeFailures?.makeOutcomeHandler(\n                channel: .system"))
        XCTAssertTrue(recorder.contains("writeFailures.beginRecording()"))
        XCTAssertTrue(recorder.contains("writeFailures.endRecording()"))
    }

    /// Both system-channel seams are optionals, so deleting either assignment would compile, keep
    /// every other test green, and silently end REC3's escalation and REC25's backlog check for
    /// system audio (the END9 shape). Fence the calling, and that each tick checks the backlog
    /// before its own capture guards.
    func test_both_ticks_are_wired_to_the_backlog_check_ahead_of_their_guards() throws {
        let recorder = try source("Sources/MeetingPipe/MeetingRecorder.swift")
        let system = try source("Sources/MeetingPipe/SystemAudioChannel.swift")
        let recovery = try source("Sources/MeetingPipe/InputDeviceRecovery.swift")

        XCTAssertTrue(recorder.contains("systemChannel.writeFailures = writeFailures"))
        XCTAssertTrue(recorder.contains("systemChannel.checkWriterBacklog = { [weak self] in self?.checkWriterBacklog(tick: .system) }"))
        XCTAssertTrue(recorder.contains("checkWriterBacklog(tick: .mic)"))

        let systemCheck = try XCTUnwrap(system.range(of: "checkWriterBacklog?()"))
        let systemGuard = try XCTUnwrap(system.range(of: "guard systemCapture != nil, systemFires > systemFiresAtArm"))
        XCTAssertLessThan(systemCheck.lowerBound, systemGuard.lowerBound)

        let tick = try XCTUnwrap(recovery.range(of: "func checkTapLiveness() {"))
        let tickBody = recovery[tick.upperBound...]
        let micCheck = try XCTUnwrap(tickBody.range(of: "host.checkMicWriterBacklog()"))
        let micGuard = try XCTUnwrap(tickBody.range(of: "guard !micCaptureAbandoned else { return }"))
        XCTAssertLessThan(micCheck.lowerBound, micGuard.lowerBound)
    }

    private func source(_ relativePath: String) throws -> String {
        let root = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()   // MeetingPipeTests
            .deletingLastPathComponent()   // Tests
            .deletingLastPathComponent()   // daemon
        return try String(contentsOf: root.appendingPathComponent(relativePath), encoding: .utf8)
    }
}
