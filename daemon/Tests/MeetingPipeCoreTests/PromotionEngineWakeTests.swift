import XCTest
@testable import MeetingPipeCore

/// END22: a sleep inside a hold. Before, every dwell ran on the wall clock, so a lid closed for
/// longer than a dwell confirmed the end on the first tick after waking, before any signal re-read.
final class PromotionEngineWakeTests: XCTestCase {

    private let context = MeetingLifecycleContext(bundleID: "com.microsoft.teams2", kind: .native, pid: 1234)
    private let lone = PromotionEngine.defaultLoneDwell
    private let pair = PromotionEngine.defaultConfirmDwell

    private func event(_ kind: PrimarySignalKind, _ state: PrimarySignalState, at: TimeInterval) -> PrimarySignalEvent {
        PrimarySignalEvent(kind: kind, state: state, timestamp: Date(timeIntervalSince1970: at), context: context)
    }

    private func at(_ seconds: TimeInterval) -> Date { Date(timeIntervalSince1970: seconds) }

    /// A window-led hold opened at 100 with nothing else to read: only the lone dwell can end it.
    private func windowHold(awaitingVetoer: Bool = false) -> PromotionEngine {
        let engine = PromotionEngine()
        engine.reset(awaitingVetoer: awaitingVetoer)
        _ = engine.ingest(event(.shareableContentWindow, .live, at: 0))
        _ = engine.confirmRecording()
        _ = engine.ingest(event(.shareableContentWindow, .ended, at: 100))
        return engine
    }

    func test_a_sleep_longer_than_the_lone_dwell_does_not_confirm_on_waking() {
        let engine = windowHold()
        engine.noteWake(sleptFrom: at(200), until: at(3800))
        XCTAssertNil(engine.tick(at: at(3801)), "no reading since the wake")
        XCTAssertNil(engine.ingest(event(.shareableContentWindow, .ended, at: 3802)), "the fresh reading")
        XCTAssertNil(engine.awaitingFreshReadingSince)
        XCTAssertNil(engine.tick(at: at(3803)), "103 s awake is not the lone dwell")
        XCTAssertNil(engine.tick(at: at(100 + lone + 3600 - 1)))
        let end = engine.tick(at: at(100 + lone + 3600 + 1))
        XCTAssertEqual(end?.verdict, .ended(
            context: context,
            reason: EndingReason(leadingSignal: "shareable_content_window_gone", confirmedBy: ["lone_dwell"])
        ))
    }

    /// The gate itself: a lone dwell already due when the lid closed does not confirm on waking
    /// until something has re-read.
    func test_a_dwell_due_at_the_wake_waits_for_a_fresh_reading() {
        let engine = windowHold()
        engine.noteWake(sleptFrom: at(100 + lone + 1), until: at(100 + lone + 3601))
        XCTAssertNil(engine.tick(at: at(100 + lone + 3603)), "due, but nothing has re-read")
        _ = engine.ingest(event(.shareableContentWindow, .ended, at: 100 + lone + 3604))
        XCTAssertNotNil(engine.tick(at: at(100 + lone + 3605)))
    }

    func test_a_sleep_inside_the_pair_dwell_is_not_counted() {
        let engine = PromotionEngine()
        _ = engine.ingest(event(.shareableContentWindow, .live, at: 0))
        _ = engine.ingest(event(.processAudioIsRunningInput, .live, at: 0))
        _ = engine.confirmRecording()
        _ = engine.ingest(event(.processAudioIsRunningInput, .ended, at: 100))
        _ = engine.ingest(event(.shareableContentWindow, .ended, at: 101))
        engine.noteWake(sleptFrom: at(120), until: at(3720))
        XCTAssertNil(engine.tick(at: at(3721)), "no reading since the wake")
        _ = engine.ingest(event(.shareableContentWindow, .ended, at: 3722))
        XCTAssertNil(engine.tick(at: at(3723)), "22 s awake since the later edge")
        XCTAssertNil(engine.tick(at: at(101 + pair + 3600 - 1)))
        XCTAssertNotNil(engine.tick(at: at(101 + pair + 3600 + 1)))
    }

    func test_process_audio_returning_live_after_a_wake_reverts_the_hold() {
        let engine = PromotionEngine()
        _ = engine.ingest(event(.shareableContentWindow, .live, at: 0))
        _ = engine.ingest(event(.processAudioIsRunningInput, .live, at: 0))
        _ = engine.confirmRecording()
        _ = engine.ingest(event(.processAudioIsRunningInput, .ended, at: 100))
        engine.noteWake(sleptFrom: at(200), until: at(3800))
        XCTAssertEqual(engine.ingest(event(.processAudioIsRunningInput, .live, at: 3801))?.verdict, .inMeeting(context: context))
    }

    func test_a_stale_or_unknown_reading_does_not_clear_the_gate_and_the_bound_does() {
        let engine = PromotionEngine()
        engine.reset(awaitingVetoer: true)
        _ = engine.ingest(event(.shareableContentWindow, .live, at: 0))
        _ = engine.ingest(event(.processAudioIsRunningInput, .live, at: 0))
        _ = engine.confirmRecording()
        _ = engine.ingest(event(.processAudioIsRunningInput, .ended, at: 100))
        engine.noteWake(sleptFrom: at(200), until: at(3800))
        _ = engine.ingest(event(.shareableContentWindow, .ended, at: 150))
        XCTAssertNotNil(engine.awaitingFreshReadingSince, "stamped before the sleep, drained after it")
        _ = engine.ingest(event(.processAudioIsRunningInput, .unknown, at: 3801))
        XCTAssertNotNil(engine.awaitingFreshReadingSince, "objects re-registering on wake are not a reading")
        _ = engine.ingest(event(.shareableContentWindow, .ended, at: 3802))
        XCTAssertNotNil(engine.awaitingFreshReadingSince, "with a vetoer engaged, only its own reading counts")
        XCTAssertNil(engine.tick(at: at(3800 + PromotionEngine.wakeFreshReadingBound - 1)))
        XCTAssertNotNil(engine.awaitingFreshReadingSince)
        _ = engine.tick(at: at(3800 + PromotionEngine.wakeFreshReadingBound + 1))
        XCTAssertNil(engine.awaitingFreshReadingSince, "the bound lapses the gate for a vetoer that never reports")
    }

    func test_the_vetoers_own_fresh_reading_clears_the_gate() {
        let engine = windowHold(awaitingVetoer: true)
        engine.noteWake(sleptFrom: at(200), until: at(3800))
        _ = engine.ingest(event(.processAudioIsRunningInput, .ended, at: 3801))
        XCTAssertNil(engine.awaitingFreshReadingSince)
    }

    func test_a_starting_held_for_the_vetoer_does_not_end_across_a_sleep() {
        let engine = PromotionEngine()
        engine.reset(awaitingVetoer: true)
        _ = engine.ingest(event(.axLeaveButton, .live, at: 0))
        XCTAssertNil(engine.ingest(event(.shareableContentWindow, .ended, at: 0.5)), "held for process audio")
        engine.noteWake(sleptFrom: at(1), until: at(1001))
        XCTAssertNil(engine.tick(at: at(1001.2)), "0.7 s awake of a 2 s grace")
        XCTAssertNil(engine.tick(at: at(1002.6)), "the grace ran, the wake gate holds")
        XCTAssertNotNil(engine.tick(at: at(1001 + PromotionEngine.wakeFreshReadingBound + 0.1)))
    }

    func test_sleeps_accumulate_and_reset_clears_them() {
        let engine = PromotionEngine()
        engine.noteWake(sleptFrom: at(10), until: at(20))
        engine.noteWake(sleptFrom: at(30), until: at(50))
        XCTAssertEqual(engine.awake(from: at(0), to: at(100)), 70)
        XCTAssertEqual(engine.awake(from: at(15), to: at(35)), 10, "partial overlaps are clamped")
        engine.reset()
        XCTAssertEqual(engine.awake(from: at(0), to: at(100)), 100)
        XCTAssertNil(engine.awaitingFreshReadingSince)
    }

    func test_a_wake_leaves_the_release_stamp_where_it_was() {
        let engine = PromotionEngine()
        _ = engine.ingest(event(.shareableContentWindow, .live, at: 0))
        _ = engine.ingest(event(.processAudioIsRunningInput, .live, at: 0))
        _ = engine.confirmRecording()
        _ = engine.ingest(event(.processAudioIsRunningInput, .ended, at: 100))
        let before = engine.holdEvidence
        engine.noteWake(sleptFrom: at(200), until: at(3800))
        XCTAssertEqual(engine.holdEvidence, before)
        XCTAssertEqual(engine.holdEvidence?.releasedAt, at(100))
    }

    func test_a_screen_wake_or_unlock_with_no_sleep_leaves_the_dwell_alone() {
        let engine = windowHold()
        engine.noteWake(sleptFrom: nil, until: at(500))
        _ = engine.ingest(event(.shareableContentWindow, .ended, at: 501))
        XCTAssertNotNil(engine.tick(at: at(100 + lone + 1)), "an unlock is not a sleep: the lone dwell ran")
    }
}
