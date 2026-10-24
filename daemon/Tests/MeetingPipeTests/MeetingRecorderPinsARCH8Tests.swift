import XCTest
@testable import MeetingPipe

/// ARCH8 step 1: the recorder behaviour the extraction moves, pinned before anything moved.
///
/// Every test here runs on an idle `MeetingRecorder` and never reaches `engine.inputNode`, for
/// the reason `MicLevelMonitorTests` gives: touching the HAL from a test is itself in the raise
/// class REC12 is about. What needs a live recording (a change that schedules a recovery, a stop
/// that drains one) is pinned on `InputDeviceRecovery` against a fake host instead, in
/// `InputDeviceRecoveryTests`.
/// T7 source fence (pins implementation): one test greps MeetingRecorder for stop()'s step order. Missing seam: an injectable engine and capture in MeetingRecorder, without which stop() cannot run headless past its first guard.
final class MeetingRecorderPinsARCH8Tests: XCTestCase {

    // MARK: - stop() with nothing recording (END11 item 3)

    /// The early return used to skip the release, so a start that never produced a file held idle
    /// sleep off for the life of the process.
    @MainActor
    func test_stopWithNoRecordingReleasesAHeldIdleSleepAssertion() async {
        let recorder = MeetingRecorder()
        recorder.acquireIdleSleepAssertion()
        XCTAssertTrue(recorder.holdsIdleSleepAssertion, "the precondition: an assertion is held")

        let produced = await recorder.stop()

        XCTAssertFalse(produced, "nothing was recording, so nothing was produced")
        XCTAssertFalse(recorder.holdsIdleSleepAssertion, "the early return has to release it")
    }

    @MainActor
    func test_stopWithNoRecordingIsRepeatableAndHoldsNothing() async {
        let recorder = MeetingRecorder()
        let first = await recorder.stop()
        let second = await recorder.stop()
        XCTAssertFalse(first)
        XCTAssertFalse(second)
        XCTAssertFalse(recorder.holdsIdleSleepAssertion)
        XCTAssertFalse(recorder.isRecording)
    }

    // MARK: - Recovery failure accounting (REC15)

    /// One `.failed` per failure run, however many terminal returns land in it, so a flapping
    /// device does not spam notifications.
    func test_aRecoveryFailureRunReportsFailedOnce() {
        let recorder = MeetingRecorder()
        var outcomes: [MeetingRecorder.CaptureRecoveryOutcome] = []
        recorder.onConfigurationChange = { outcomes.append($0) }

        recorder.deviceRecovery.reportRecoveryFailure()
        recorder.deviceRecovery.reportRecoveryFailure()
        recorder.deviceRecovery.reportRecoveryFailure()

        XCTAssertEqual(outcomes, [.failed])
        XCTAssertEqual(recorder.deviceRecovery.consecutiveRecoveryFailures, 3, "every failure still counts toward the budget")
    }

    /// The tap watchdog stands down exactly when the budget is spent, not on the first failure
    /// (a latch would give up recoveries that were going to work) and not never (REC15's spin).
    func test_theMicIsAbandonedExactlyAtTheRecoveryBudget() {
        let recorder = MeetingRecorder()
        for _ in 1..<InputDeviceRecovery.recoveryFailureBudget {
            recorder.deviceRecovery.reportRecoveryFailure()
        }
        XCTAssertFalse(recorder.deviceRecovery.micCaptureAbandoned, "one short of the budget is still worth asking again")

        recorder.deviceRecovery.reportRecoveryFailure()

        XCTAssertTrue(recorder.deviceRecovery.micCaptureAbandoned)
        XCTAssertEqual(InputDeviceRecovery.recoveryFailureBudget, 5)
    }

    // MARK: - The retry schedule

    /// A second retry inside the window replaces the first rather than queueing beside it, so one
    /// device change never has two evaluations in flight.
    func test_aSecondRetryScheduleSupersedesTheFirst() throws {
        let recorder = MeetingRecorder()
        recorder.deviceRecovery.scheduleRecoveryRetry(after: 60, gapStart: Date())
        let first = try XCTUnwrap(recorder.deviceRecovery.pendingRecoveryRetry)

        recorder.deviceRecovery.scheduleRecoveryRetry(after: 60, gapStart: Date())
        let second = try XCTUnwrap(recorder.deviceRecovery.pendingRecoveryRetry)

        XCTAssertTrue(first.isCancelled, "the superseded retry must not fire")
        XCTAssertFalse(second.isCancelled)
        XCTAssertFalse(first === second)
        second.cancel()
    }

    /// A fresh change carries new information about the route, so it cancels a retry still
    /// queued for the previous one.
    func test_aFreshConfigurationChangeCancelsAPendingRetry() throws {
        let recorder = MeetingRecorder()
        recorder.deviceRecovery.scheduleRecoveryRetry(after: 60, gapStart: Date())
        let pending = try XCTUnwrap(recorder.deviceRecovery.pendingRecoveryRetry)

        recorder.deviceRecovery.handleConfigurationChange()

        XCTAssertTrue(pending.isCancelled)
        XCTAssertNil(recorder.deviceRecovery.pendingRecoveryRetry)
        XCTAssertEqual(recorder.deviceRecovery.configurationRecoveryAttempts, 0, "a fresh change restarts the retry budget")
    }

    // MARK: - Idle recorders start nothing

    func test_aConfigurationChangeWhileIdleStartsNoRecovery() {
        let recorder = MeetingRecorder()
        recorder.deviceRecovery.handleConfigurationChange()
        XCTAssertNil(recorder.deviceRecovery.recoveryTask)
        XCTAssertNil(recorder.deviceRecovery.pendingRecoveryRetry)
    }

    func test_aTapWatchdogTickWhileIdleStartsNoRecovery() {
        let recorder = MeetingRecorder()
        recorder.deviceRecovery.checkTapLiveness()
        XCTAssertNil(recorder.deviceRecovery.recoveryTask)
    }

    func test_aWakeWhileIdleStartsNoRecoveryAndNoRetry() {
        let recorder = MeetingRecorder()
        recorder.handleDidWake()
        XCTAssertNil(recorder.deviceRecovery.recoveryTask)
        XCTAssertNil(recorder.systemChannel.systemAudioAutoRetryTimer)
    }

    /// A loss reported after the recording ended (a late `didStopWithError` hop) must not raise
    /// the banner or arm REC8's automatic retry against a recorder that is not recording.
    func test_aSystemAudioLossWhileIdleIsANoOp() {
        let recorder = MeetingRecorder()
        var degraded: [String] = []
        recorder.onSystemAudioDegraded = { degraded.append($0) }

        recorder.systemChannel.handleSystemAudioLost(reason: "test")

        XCTAssertEqual(degraded, [])
        XCTAssertFalse(recorder.systemChannel.systemDegraded)
        XCTAssertNil(recorder.systemChannel.systemAudioAutoRetryTimer)
    }

    // MARK: - stop() reads as its sequence (ARCH8 step 4)

    /// The steps have ordering constraints that used to live only in comments inside one 265-line
    /// body. This pins the order they run in, which is the behaviour the split must not change:
    /// the stream halts before recovery drains, recovery drains before the engine goes down, the
    /// coverage read waits for the tap removal, and the files close after the drains and before
    /// the merge reads them.
    func test_stopRunsItsStepsInTheOrderTheyAlwaysRan() throws {
        let root = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        let text = try String(
            contentsOf: root.appendingPathComponent("Sources/MeetingPipe/MeetingRecorder.swift"),
            encoding: .utf8
        )
        let body = try XCTUnwrap(
            text.components(separatedBy: "func stop(limitSeconds: Double? = nil) async -> Bool {").last?
                .components(separatedBy: "\n    }\n").first
        )
        let steps = [
            "let session = endSession()",
            "standDownTimersAndHooks()",
            "await systemChannel.haltCapture()",
            "await deviceRecovery.standDown()",
            "await teardownEngine()",
            "snapshotMicCoverage()",
            "let writerWedged = await drainWriters()",
            "finalizeFiles()",
            "await mergeIntermediates(",
            "persistAfterMerge(",
        ]
        var cursor = body.startIndex
        for step in steps {
            let found = try XCTUnwrap(body.range(of: step, range: cursor..<body.endIndex), "\(step) missing or out of order")
            cursor = found.upperBound
        }
        XCTAssertLessThan(body.components(separatedBy: "\n").count, 60, "stop() is the sequence; the work lives in the steps")
    }
}
