import AVFoundation
import XCTest
@testable import MeetingPipe

/// REC16: three defects on `MeetingRecorder`'s mid-recording capture-health paths, filed together
/// because they share one seam. Found by reading the recorder against the field log during the
/// END10/END11 investigation rather than from a symptom.
/// T7 source fence (pins implementation): three tests grep MeetingRecorder, SystemAudioChannel and Coordinator for the one engine-replacement helper, the setMicCaptureLost calls and wall-clock outage marks. Missing seam: an injectable engine in MeetingRecorder (recovery itself has one since ARCH8: `InputDeviceRecoveryHost`), an injectable clock in SystemAudioChannel, a headless Coordinator.
final class CaptureHealthREC16Tests: XCTestCase {

    // MARK: - Item 2: the outage span has to survive a system sleep

    /// The 2026-08-17 case, reproduced in arithmetic. `system_capture_lost` fired at 17:45:14 and
    /// `system_capture_resumed` at 17:54:31, a 557.0 s wallclock gap, and the pad written was
    /// `gap_sec: 106.8` with `pad_clamped: false`. The shortfall is 450.2 s, which is the sleep:
    /// `systemUptime` does not advance while the Mac is asleep, so the monotonic span measured
    /// only the waking part of the outage.
    ///
    /// Red against `main`, where the recorder stamped both marks from `systemUptime`.
    func test_anOutageSpanningASleepPadsTheWallGap() {
        let sampleRate = 48_000.0
        // A wall clock that ran for the full outage against a monotonic one that stopped for the
        // 450.2 s the machine was asleep. Only the wall pair is passed now.
        let lostAtWall = 1_000_000.0
        let retryAtWall = lostAtWall + 557.0

        let plan = SystemCaptureRetryPlanner.plan(
            hasOpenFile: true, capturedFirstFrame: true,
            lostAt: lostAtWall, retryAt: retryAtWall, sampleRate: sampleRate
        )
        guard case .resumeOpenFile(let padFrames, let gapSeconds, let clamped) = plan else {
            return XCTFail("an open file with captured audio has to resume, got \(plan)")
        }
        XCTAssertEqual(gapSeconds, 557.0, accuracy: 0.01)
        XCTAssertFalse(clamped, "557 s has to pad in full or the recovered channel is late by the excess")
        XCTAssertEqual(Double(padFrames), 557.0 * sampleRate, accuracy: sampleRate)
        XCTAssertNotEqual(
            gapSeconds, 106.81894104165258,
            "this is the monotonic answer the field case actually wrote"
        )
    }

    /// The control case from the same log: an outage with no sleep in it, which was already
    /// correct and must stay correct.
    func test_anOutageWithNoSleepIsUnchanged() {
        let plan = SystemCaptureRetryPlanner.plan(
            hasOpenFile: true, capturedFirstFrame: true,
            lostAt: 1_000_000.0, retryAt: 1_000_007.679, sampleRate: 48_000
        )
        guard case .resumeOpenFile(_, let gapSeconds, let clamped) = plan else {
            return XCTFail("expected a resume, got \(plan)")
        }
        XCTAssertEqual(gapSeconds, 7.679, accuracy: 0.001)
        XCTAssertFalse(clamped)
    }

    /// The cap had to move with the clock, and the spec said to re-derive it rather than assume it:
    /// measuring on the wall clock is what lets a sleep-length gap reach the cap at all. At the old
    /// 300 s the 2026-08-17 case would have clamped and stayed misaligned by 257 s, which is the
    /// same failure wearing a fix.
    func test_theCapClearsTheLargestObservedOutage() {
        XCTAssertGreaterThan(
            SystemCaptureRetryPlanner.maxPadSeconds, 557.0,
            "the largest outage in the field corpus has to pad in full"
        )
    }

    /// The cap still has to bind, or an overnight sleep writes silence until the disk fills.
    func test_thePadIsStillCappedForAPathologicalGap() {
        let plan = SystemCaptureRetryPlanner.plan(
            hasOpenFile: true, capturedFirstFrame: true,
            lostAt: 1_000_000.0, retryAt: 1_000_000.0 + SystemCaptureRetryPlanner.maxPadSeconds + 600,
            sampleRate: 48_000
        )
        guard case .resumeOpenFile(let padFrames, let gapSeconds, let clamped) = plan else {
            return XCTFail("expected a resume, got \(plan)")
        }
        XCTAssertTrue(clamped)
        XCTAssertEqual(Double(padFrames), SystemCaptureRetryPlanner.maxPadSeconds * 48_000, accuracy: 1)
        XCTAssertGreaterThan(gapSeconds, SystemCaptureRetryPlanner.maxPadSeconds,
                             "the real gap is still reported even when the pad is cut")
    }

    // MARK: - Item 1: a replaced engine must not go deaf

    /// `armConfigurationChangeObserver()` registers with `object: engine`, so the observer is bound
    /// to one instance. REC15 taught `recoverCapture` to replace a condemned engine mid-recording
    /// and did not re-arm it, so the observer then watched an object nothing posts to.
    ///
    /// The recorder's own replacement path needs a live engine and a real input device, so what is
    /// pinned here is the notification-binding property that made it a bug: an observer registered
    /// against one object does not hear another. If this ever stops being true, `replaceEngine`
    /// stops being necessary and the fence should be revisited rather than deleted.
    func test_anObserverBoundToOneObjectDoesNotHearAnother() {
        let first = NSObject()
        let second = NSObject()
        var heard = 0
        let token = NotificationCenter.default.addObserver(
            forName: .AVAudioEngineConfigurationChange, object: first, queue: nil
        ) { _ in heard += 1 }
        defer { NotificationCenter.default.removeObserver(token) }

        NotificationCenter.default.post(name: .AVAudioEngineConfigurationChange, object: second)
        XCTAssertEqual(heard, 0, "this is why replacing the engine silently disabled recovery")
        NotificationCenter.default.post(name: .AVAudioEngineConfigurationChange, object: first)
        XCTAssertEqual(heard, 1, "and this is that the binding otherwise works")
    }

    /// The wiring fence, in END10's shape: every engine replacement goes through the one helper
    /// that re-arms. Red against `main`, where `recoverCapture` assigned the engine directly.
    func test_everyEngineReplacementGoesThroughTheReArmingHelper() throws {
        let text = try String(
            contentsOf: URL(fileURLWithPath: #filePath)
                .deletingLastPathComponent().deletingLastPathComponent()
                .deletingLastPathComponent().deletingLastPathComponent()
                .appendingPathComponent("daemon/Sources/MeetingPipe/MeetingRecorder.swift"),
            encoding: .utf8
        )
        let assignments = text.components(separatedBy: "engine = AVAudioEngine()").count - 1
        XCTAssertEqual(
            assignments, 2,
            "expected exactly two: the stored-property initializer and the one inside "
                + "replaceEngine(reason:). A third is a site that skipped the re-arm, which is "
                + "the REC15 regression this task fixed."
        )
        XCTAssertTrue(text.contains("private func replaceEngine(reason: String) {"))
        XCTAssertTrue(
            text.contains("if wasArmed { deviceRecovery.armConfigurationChangeObserver() }"),
            "the helper has to actually re-arm, or it is a rename"
        )
    }

    // MARK: - Item 3: an unrecoverable mic failure has to stay visible

    /// Every `configuration_change_unrecoverable` path ends in `reportRecoveryFailure`, which
    /// fires `.failed` once and does not stop the recording, so the recording ran to its normal
    /// end writing a dead mic channel behind a single dismissible toast. In the field the event
    /// fired 13 times against 5 recoveries.
    ///
    /// The Coordinator owns that wiring and is not constructible headless, so the persistence is
    /// pinned where it lives: on the HUD state itself and on the source of the handler.
    @MainActor
    func test_theMicLostStateOutranksTheOtherTwoLabelOwners() {
        let hud = RecordingHUDWindow()
        hud.setMicCaptureLost(true)
        XCTAssertTrue(hud.micCaptureLost)

        // Both other label owners must defer while it is on, or the state the reader needs is
        // overwritten by one that is merely also true.
        hud.setOffTheRecord(true)
        XCTAssertTrue(hud.micCaptureLost, "off-the-record must not clear a lost mic")
        hud.setConfirmingEnd(true)
        XCTAssertTrue(hud.micCaptureLost, "confirming-end must not clear a lost mic either")

        hud.setMicCaptureLost(false)
        XCTAssertFalse(hud.micCaptureLost)
    }

    /// The window outlives the recording (the Coordinator holds one), so this is per-recording
    /// state that has to be dropped at teardown. Without it a meeting that lost its mic opens the
    /// next one reading "Mic lost" and the other two labels defer to a failure that already ended.
    @MainActor
    func test_theMicLostStateDoesNotLeakIntoTheNextRecording() {
        let hud = RecordingHUDWindow()
        hud.setMicCaptureLost(true)
        XCTAssertTrue(hud.micCaptureLost)
        hud.dismiss(animated: false)
        XCTAssertFalse(hud.micCaptureLost, "a new meeting must not inherit the last one's failure")
    }

    /// The handler is a persistent state paired with the toast, not the toast alone. Red against
    /// `main`, where `.failed` reached `notifyCaptureLost()` and nothing else.
    func test_theFailedOutcomeDrivesAPersistentStateNotJustAToast() throws {
        let text = try String(
            contentsOf: URL(fileURLWithPath: #filePath)
                .deletingLastPathComponent().deletingLastPathComponent()
                .deletingLastPathComponent().deletingLastPathComponent()
                .appendingPathComponent("daemon/Sources/MeetingPipe/Coordinator.swift"),
            encoding: .utf8
        )
        XCTAssertTrue(
            text.contains("self.recordingHUD.setMicCaptureLost(true)"),
            "a lost mic has to leave a state behind, not only a dismissible notification"
        )
        XCTAssertTrue(
            text.contains("self.recordingHUD.setMicCaptureLost(false)"),
            "and a recovery has to clear it, or the state is a latch"
        )
    }

    /// The clock choice itself, which no runtime test in this repo can reach: stamping
    /// `systemLostAt` needs a live SCStream outage on a real machine. The planner tests above pin
    /// the arithmetic and the cap; this pins the input those numbers come from, which is the half
    /// that was actually wrong. Red against `main`, where both marks came from `systemUptime`.
    func test_theSystemOutageMarksAreStampedOnTheWallClock() throws {
        let text = try String(
            contentsOf: URL(fileURLWithPath: #filePath)
                .deletingLastPathComponent().deletingLastPathComponent()
                .deletingLastPathComponent().deletingLastPathComponent()
                .appendingPathComponent("daemon/Sources/MeetingPipe/SystemAudioChannel.swift"),
            encoding: .utf8
        )
        let marks = text.components(separatedBy: "systemLostAt = ").dropFirst()
        XCTAssertGreaterThanOrEqual(marks.count, 2, "expected the loss mark and the stall mark")
        for mark in marks {
            let line = mark.prefix(while: { $0 != "\n" })
            guard line.contains("ProcessInfo") || line.contains("Date()") else { continue }
            XCTAssertFalse(
                line.contains("systemUptime"),
                "systemUptime stops while the Mac sleeps, which is the REC16 defect: \(line)"
            )
            XCTAssertTrue(line.contains("Date()"), "the outage span is wall clock: \(line)")
        }
    }
}
