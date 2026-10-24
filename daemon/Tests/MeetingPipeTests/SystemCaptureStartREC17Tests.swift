import MeetingPipeCore
import XCTest
@testable import MeetingPipe

/// REC17: a system-audio start that never returns. On 2026-09-17 `SCStream.startCapture()`
/// took 64 minutes, the far side of the call was silence for all of it, and no fence saw
/// it: nothing bounded the start, the liveness watchdog engages only after a first buffer,
/// `retrySystemAudio` no-ops on the non-nil hung capture, and the idle backstop read the
/// channel that never came up as a silent one and nudged the owner twice.
///
/// The recorder's own timeout path needs a live engine and Screen Recording TCC, so what is
/// pinned here is the pure ledger the late completion consults, the bounded runner's
/// branching, and source-text fences on the wiring, in `CaptureHealthREC16Tests`' shape.
/// T7 source fence (pins implementation): five tests grep MeetingRecorder and SystemAudioCapture for the bounded start, timeout routing, auto-retry flag, ledger gates and liveness guard. Missing seam: an injectable system capture (SCStream) in MeetingRecorder.
final class SystemCaptureStartREC17Tests: XCTestCase {

    private func repoFile(_ relative: String) throws -> String {
        try String(
            contentsOf: URL(fileURLWithPath: #filePath)
                .deletingLastPathComponent().deletingLastPathComponent()
                .deletingLastPathComponent().deletingLastPathComponent()
                .appendingPathComponent(relative),
            encoding: .utf8
        )
    }

    // MARK: - Item 2: the late-completion ledger

    func test_aCompletionNobodyAbandonedIsAdopted() {
        var attempt = SystemCaptureStartAttempt()
        XCTAssertFalse(attempt.isAbandoned)
        XCTAssertEqual(attempt.completed(), .adopt)
        XCTAssertTrue(attempt.isCompleted)
        XCTAssertFalse(attempt.isAbandoned, "adopting is not abandoning")
    }

    /// The 2026-09-17 shape: the budget elapsed, then 64 minutes later the start returned.
    func test_aTimedOutAttemptDiscardsItsLateCompletion() {
        var attempt = SystemCaptureStartAttempt()
        attempt.timedOut()
        XCTAssertTrue(attempt.isAbandoned)
        XCTAssertEqual(attempt.completed(), .discard(.timedOut))
    }

    /// `stop()` used to be `guard let stream = stream else { return }`, and `stream` is assigned
    /// only after `startCapture()` returns, so a stop that beat the start left the stream it
    /// eventually produced running until process exit.
    func test_aStopThatBeatsTheStartDiscardsItsCompletion() {
        var attempt = SystemCaptureStartAttempt()
        attempt.stopped()
        XCTAssertEqual(attempt.completed(), .discard(.stopped))
    }

    /// The first abandonment is the reason that gets logged; a stop landing on an already
    /// timed-out attempt must not relabel it, and vice versa.
    func test_theFirstAbandonmentWins() {
        var a = SystemCaptureStartAttempt()
        a.timedOut()
        a.stopped()
        XCTAssertEqual(a.completed(), .discard(.timedOut))

        var b = SystemCaptureStartAttempt()
        b.stopped()
        b.timedOut()
        XCTAssertEqual(b.completed(), .discard(.stopped))
    }

    /// An abandonment that lands after the completion finds an adopted stream, which `stop()`
    /// then stops the ordinary way. The ledger says abandoned (so the delegate stops
    /// delivering) without rewriting history.
    func test_anAbandonmentAfterCompletionDoesNotUnadopt() {
        var attempt = SystemCaptureStartAttempt()
        XCTAssertEqual(attempt.completed(), .adopt)
        attempt.timedOut()
        XCTAssertTrue(attempt.isAbandoned)
        XCTAssertTrue(attempt.isCompleted)
    }

    // MARK: - Item 1: the bounded runner

    func test_aStartThatNeverReturnsTimesOutWithinTheBudget() async {
        let began = Date()
        let outcome = await boundedSystemCaptureStart(seconds: 0.2) {
            try? await Task.sleep(nanoseconds: 60 * NSEC_PER_SEC)
            return .adopt
        }
        XCTAssertEqual(outcome, .timedOut)
        XCTAssertLessThan(Date().timeIntervalSince(began), 5.0, "the caller must stop waiting at the budget")
    }

    func test_aStartThatReturnsInTimeIsStarted() async {
        let outcome = await boundedSystemCaptureStart(seconds: 5) { .adopt }
        XCTAssertEqual(outcome, .started)
    }

    func test_aStartThatThrowsIsFailedWithItsReason() async {
        struct Boom: LocalizedError { var errorDescription: String? { "no display" } }
        let outcome = await boundedSystemCaptureStart(seconds: 5) { throw Boom() }
        XCTAssertEqual(outcome, .failed("no display"))
    }

    /// The stop-beat-the-start case surfaces as its own outcome rather than as `.failed`:
    /// the recorder's failure branch deletes a system WAV that holds nothing, and a discarded
    /// completion after a stop must not reach it.
    func test_aDiscardedCompletionIsNotAFailure() async {
        let outcome = await boundedSystemCaptureStart(seconds: 5) { .discard(.stopped) }
        XCTAssertEqual(outcome, .discarded(.stopped))
    }

    // MARK: - Wiring fences

    /// The recorder reaches `capture.start()` only through the bounded runner. Red against
    /// `main`, where `startSystemCapture` ran `try await capture.start()` bare inside its Task.
    func test_theRecorderAwaitsTheSystemStartOnlyThroughTheBound() throws {
        let text = try repoFile("daemon/Sources/MeetingPipe/MeetingRecorder.swift")
        let bare = text.components(separatedBy: "try await capture.start()").count - 1
        XCTAssertEqual(bare, 1, "exactly one call, and it has to be the one inside the bounded runner's closure")
        XCTAssertTrue(
            text.contains("await boundedSystemCaptureStart(seconds: MeetingRecorder.systemStartBudgetSeconds, { try await capture.start() })"),
            "the one call is the bounded runner's operation, with the named budget"
        )
        let runner = try repoFile("daemon/Sources/MeetingPipe/SystemCaptureStartAttempt.swift")
        XCTAssertTrue(
            runner.contains("await runWithTimeout(seconds: seconds)"),
            "boundedSystemCaptureStart is a wrapper over runWithTimeout, not a second timeout primitive"
        )
    }

    /// A timed-out start is a loss like any other: it has to reach `handleSystemAudioLost`, which
    /// is what clears `systemCapture` (so Retry is reachable), sets `systemDegraded`, shows the
    /// banner and schedules REC8's automatic retry. And it has to mark the capture abandoned
    /// first, or the late completion adopts its stream.
    func test_aTimedOutStartRoutesThroughTheLossPathAfterAbandoningTheCapture() throws {
        let text = try repoFile("daemon/Sources/MeetingPipe/MeetingRecorder.swift")
        guard let branch = text.range(of: "case .timedOut:\n                capture.abandonStart()") else {
            return XCTFail("the timeout branch has to abandon the capture before anything else")
        }
        let rest = text[branch.upperBound...]
        XCTAssertTrue(
            rest.contains("action: \"system_capture_start_timed_out\""),
            "the timeout is an event of its own, so the next incident is one grep"
        )
        XCTAssertTrue(
            text.contains("handleSystemAudioLost(\n            reason: \"system_capture_start_timed_out\""),
            "the loss path is the one that makes Retry reachable and shows the banner"
        )
    }

    /// REC8's contract is one hands-off retry per outage. A first start that times out gets it
    /// (the acceptance's `system_capture_auto_retry` row 7 s after the timeout); a retry that
    /// itself never comes up is the same outage continuing, and it gets the banner and no
    /// further automatic attempt, or the recorder re-enters ScreenCaptureKit every 17 s for as
    /// long as it stays wedged.
    func test_aTimedOutRetryFallsBackToTheBannerWithoutAnotherAutomaticAttempt() throws {
        let text = try repoFile("daemon/Sources/MeetingPipe/MeetingRecorder.swift")
        XCTAssertTrue(text.contains("autoRetry: !isRetry"), "a timed-out first start still gets REC8's retry; a timed-out retry does not")
        XCTAssertTrue(text.contains("if autoRetry { scheduleSystemAudioAutoRetry() }"))
        XCTAssertTrue(
            text.contains("stalledForSeconds: TimeInterval = 0, autoRetry: Bool = true"),
            "every other loss path keeps its automatic retry by default"
        )
    }

    /// The budget itself: wide enough that no healthy start on record trips it (the worst of the
    /// last eight days was 2.82 s) and narrow enough to land the banner well before the nudge the
    /// owner actually saw (240 s at their setting; 30 s at the slider's 60 s floor).
    func test_theBudgetSitsBetweenTheSlowestHealthyStartAndTheEarliestNudge() {
        XCTAssertEqual(MeetingRecorder.systemStartBudgetSeconds, 10)
        XCTAssertGreaterThan(MeetingRecorder.systemStartBudgetSeconds, 2.82 * 3)
        XCTAssertLessThan(
            MeetingRecorder.systemStartBudgetSeconds,
            IdleStopBackstop.safeNotifySeconds(forAutoStop: 60),
            "the banner has to be up before the earliest nudge the Preferences slider allows"
        )
    }

    /// Both delegate callbacks consult the ledger. A discarded stream still delivers for the
    /// beat between `startCapture()` returning and `stopCapture()` taking effect, and those
    /// buffers would otherwise reach a writer a retry may by then own; a late `didStopWithError`
    /// would tear down the retry's live capture, since `handleSystemAudioLost` checks no identity.
    func test_anAbandonedCaptureDeliversNoBuffersAndReportsNoDeath() throws {
        let text = try repoFile("daemon/Sources/MeetingPipe/SystemAudioCapture.swift")
        XCTAssertEqual(
            text.components(separatedBy: "guard !isStartAbandoned else { return }").count - 1, 1,
            "the buffer gate in didOutputSampleBuffer"
        )
        XCTAssertEqual(
            text.components(separatedBy: "guard holdsAdoptedStream else { return }").count - 1, 1,
            "the death gate in didStopWithError: adopted, not abandoned, not yet stopped"
        )
        XCTAssertTrue(
            text.contains("case .discard(let why):"),
            "the post-startCapture path has to branch on the ledger, not assign the stream unconditionally"
        )
        XCTAssertFalse(
            text.contains("guard let stream = stream else { return }"),
            "stop() can no longer no-op on a start that has not returned; it has to abandon it"
        )
    }

    // MARK: - Item 3: the host tells the backstop when the channel is down

    /// The controller's mapping from recorder health plus the level mirror to the backstop's
    /// input. The mirror is fed by the system tap alone, so it stops moving when the channel
    /// does; whatever it last read, a down channel is `.down`.
    func test_aDownChannelIsDownWhateverTheMirrorLastRead() {
        XCTAssertEqual(MeetingSessionController.backstopSystemChannel(health: .down, levelDb: -120), .down)
        XCTAssertEqual(
            MeetingSessionController.backstopSystemChannel(health: .down, levelDb: -20), .down,
            "a loud last reading before the loss must not read as a far side still talking"
        )
    }

    func test_aLiveChannelReadsTheMirrorAgainstTheSilenceFloor() {
        XCTAssertEqual(
            MeetingSessionController.backstopSystemChannel(health: .live, levelDb: -120), .live(hasAudio: false)
        )
        XCTAssertEqual(
            MeetingSessionController.backstopSystemChannel(health: .live, levelDb: -30), .live(hasAudio: true)
        )
    }

    /// Screen Recording denied is the chosen mic-only state the backstop was built for; it is
    /// not held.
    func test_aPermissionDeniedChannelIsMicOnlyNotDown() {
        XCTAssertEqual(MeetingSessionController.backstopSystemChannel(health: .micOnly, levelDb: -120), .micOnly)
    }

    /// The recorder's own read is the part no headless test can drive to `.live` (that needs
    /// an SCStream buffer), so its idle answer is pinned: no capture and no denial is `.down`,
    /// which is also what a start that has not returned yet looks like.
    func test_anIdleRecorderReportsTheChannelDown() {
        let recorder = MeetingRecorder()
        XCTAssertFalse(recorder.isRecording)
        if SystemAudioCapture.permissionState == .denied {
            XCTAssertEqual(recorder.systemChannelHealth, .micOnly)
        } else {
            XCTAssertEqual(recorder.systemChannelHealth, .down)
        }
    }

    // MARK: - The liveness gate is per attempt

    /// `systemFires` is never reset between recordings (only at `start()` now), and a retry keeps
    /// counting from where the dead stream left off, so `systemFires > 0` was true on every
    /// retry and on any recording that followed a stop whose teardown let one trailing buffer
    /// through. The watchdog then judged a spin-up it was written to ignore: 3 s unchanged
    /// counter, stall, teardown of a stream that was 2.7 s from its first buffer.
    func test_theLivenessGateCountsFromTheAttemptNotFromZero() throws {
        let text = try repoFile("daemon/Sources/MeetingPipe/MeetingRecorder.swift")
        XCTAssertTrue(
            text.contains("guard isRecording, systemCapture != nil, systemFires > systemFiresAtArm else { return }"),
            "the watchdog engages on the current attempt's first buffer, not on a count inherited from a previous one"
        )
        XCTAssertFalse(
            text.contains("guard isRecording, systemCapture != nil, systemFires > 0 else { return }"),
            "the old gate is the one that could not see a hung first start and false-positived on a slow retry"
        )
    }
}
