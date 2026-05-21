import XCTest
@testable import MeetingPipeCore

final class PromotionEngineTests: XCTestCase {

    private let teamsContext = MeetingLifecycleContext(
        bundleID: "com.microsoft.teams2",
        kind: .native,
        pid: 1234
    )

    private func event(
        _ kind: PrimarySignalKind,
        _ state: PrimarySignalState,
        at: TimeInterval
    ) -> PrimarySignalEvent {
        PrimarySignalEvent(
            kind: kind,
            state: state,
            timestamp: Date(timeIntervalSince1970: at),
            context: teamsContext
        )
    }

    func test_first_live_signal_promotes_to_starting() {
        let engine = PromotionEngine()
        let decision = engine.ingest(event(.shareableContentWindow, .live, at: 0))
        XCTAssertEqual(decision?.verdict, .starting(context: teamsContext))
    }

    func test_confirm_recording_promotes_starting_to_in_meeting() {
        let engine = PromotionEngine()
        _ = engine.ingest(event(.shareableContentWindow, .live, at: 0))
        let decision = engine.confirmRecording()
        XCTAssertEqual(decision?.verdict, .inMeeting(context: teamsContext))
    }

    func test_ended_signal_during_starting_promotes_straight_to_ended() {
        let engine = PromotionEngine()
        _ = engine.ingest(event(.shareableContentWindow, .live, at: 0))
        let decision = engine.ingest(event(.shareableContentWindow, .ended, at: 1))
        XCTAssertEqual(
            decision?.verdict,
            .ended(
                context: teamsContext,
                reason: EndingReason(leadingSignal: "shareable_content_window_gone")
            )
        )
    }

    func test_first_ended_signal_promotes_to_ending_provisional() {
        let engine = PromotionEngine()
        _ = engine.ingest(event(.shareableContentWindow, .live, at: 0))
        _ = engine.confirmRecording()
        let decision = engine.ingest(event(.shareableContentWindow, .ended, at: 1))
        XCTAssertEqual(
            decision?.verdict,
            .endingProvisional(
                context: teamsContext,
                reason: EndingReason(leadingSignal: "shareable_content_window_gone")
            )
        )
    }

    func test_second_distinct_ended_signal_promotes_to_ended_with_confirmation() {
        let engine = PromotionEngine()
        _ = engine.ingest(event(.shareableContentWindow, .live, at: 0))
        _ = engine.ingest(event(.processAudioIsRunningInput, .live, at: 0))
        _ = engine.confirmRecording()
        _ = engine.ingest(event(.shareableContentWindow, .ended, at: 1))
        let decision = engine.ingest(event(.processAudioIsRunningInput, .ended, at: 1.5))

        XCTAssertEqual(
            decision?.verdict,
            .ended(
                context: teamsContext,
                reason: EndingReason(
                    leadingSignal: "shareable_content_window_gone",
                    confirmedBy: ["process_audio_is_running_input_false"]
                )
            )
        )
    }

    func test_tick_after_debounce_promotes_to_ended_without_confirmation() {
        let engine = PromotionEngine(debounce: 2.0)
        _ = engine.ingest(event(.shareableContentWindow, .live, at: 0))
        _ = engine.confirmRecording()
        _ = engine.ingest(event(.shareableContentWindow, .ended, at: 1))

        let pre = engine.tick(at: Date(timeIntervalSince1970: 2.5))
        XCTAssertNil(pre, "Debounce has not elapsed yet")

        let post = engine.tick(at: Date(timeIntervalSince1970: 3.0))
        XCTAssertEqual(
            post?.verdict,
            .ended(
                context: teamsContext,
                reason: EndingReason(leadingSignal: "shareable_content_window_gone", confirmedBy: [])
            )
        )
    }

    func test_leading_signal_flipping_back_to_live_reverts_to_in_meeting() {
        let engine = PromotionEngine(debounce: 2.0)
        _ = engine.ingest(event(.shareableContentWindow, .live, at: 0))
        _ = engine.confirmRecording()
        _ = engine.ingest(event(.shareableContentWindow, .ended, at: 1))
        let revert = engine.ingest(event(.shareableContentWindow, .live, at: 1.2))

        XCTAssertEqual(revert?.verdict, .inMeeting(context: teamsContext))
        let post = engine.tick(at: Date(timeIntervalSince1970: 3.5))
        XCTAssertNil(post, "Debounce must not fire after a revert")
    }

    func test_event_for_different_context_is_ignored() {
        let engine = PromotionEngine()
        let other = MeetingLifecycleContext(bundleID: "us.zoom.xos", kind: .native, pid: 9999)
        _ = engine.ingest(event(.shareableContentWindow, .live, at: 0))
        let decision = engine.ingest(PrimarySignalEvent(
            kind: .processAudioIsRunningInput,
            state: .ended,
            timestamp: Date(timeIntervalSince1970: 1),
            context: other
        ))
        XCTAssertNil(decision)
    }

    func test_ended_phase_swallows_further_signals() {
        let engine = PromotionEngine()
        _ = engine.ingest(event(.shareableContentWindow, .live, at: 0))
        _ = engine.ingest(event(.shareableContentWindow, .ended, at: 1))
        _ = engine.tick(at: Date(timeIntervalSince1970: 5))

        let post = engine.ingest(event(.processAudioIsRunningInput, .live, at: 6))
        XCTAssertNil(post, "Once ended, the engine ignores further events until reset")
    }

    func test_reset_returns_engine_to_idle() {
        let engine = PromotionEngine()
        _ = engine.ingest(event(.shareableContentWindow, .live, at: 0))
        engine.reset()
        let decision = engine.ingest(event(.processAudioIsRunningInput, .live, at: 1))
        XCTAssertEqual(decision?.verdict, .starting(context: teamsContext))
    }
}
