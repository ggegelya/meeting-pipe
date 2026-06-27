import XCTest
@testable import MeetingPipeCore

final class PromotionEngineTests: XCTestCase {

    private let teamsContext = MeetingLifecycleContext(
        bundleID: "com.microsoft.teams2",
        kind: .native,
        pid: 1234
    )

    private let browserContext = MeetingLifecycleContext(
        bundleID: "com.google.Chrome.app.fmgjjmmmlfnkbppncabfkddbjimcfncm",
        kind: .browser,
        pid: 7890
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

    private func browserEvent(
        _ kind: PrimarySignalKind,
        _ state: PrimarySignalState,
        at: TimeInterval
    ) -> PrimarySignalEvent {
        PrimarySignalEvent(
            kind: kind,
            state: state,
            timestamp: Date(timeIntervalSince1970: at),
            context: browserContext
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

    func test_lone_ax_leave_during_starting_holds_engine_live() {
        // START1/AUD-1: while the prompt is up (engine in `.starting`), a bare Leave-button
        // invalidation is the Teams compact-window re-render artifact, not a real end. It must
        // NOT drive the engine to a terminal `.ended` (which then absorbs every later signal and
        // wedges detection). The engine holds in `.starting`, so a Record press still arms it.
        let engine = PromotionEngine()
        _ = engine.ingest(event(.shareableContentWindow, .live, at: 0))
        let held = engine.ingest(event(.axLeaveButton, .ended, at: 1))
        XCTAssertNil(held, "A lone ax-leave end during `.starting` is held, not promoted to `.ended`")
        // Engine is still live: confirming the recorder promotes to `.inMeeting`.
        let confirmed = engine.confirmRecording()
        XCTAssertEqual(confirmed?.verdict, .inMeeting(context: teamsContext))
    }

    func test_ax_leave_held_in_starting_does_not_block_a_reliable_end() {
        // A genuine pre-record end still terminates: the held ax-leave does not stop a reliable
        // signal (window-gone) from ending directly, so a slow prompt over a meeting that really
        // ended is still torn down.
        let engine = PromotionEngine()
        _ = engine.ingest(event(.shareableContentWindow, .live, at: 0))
        XCTAssertNil(engine.ingest(event(.axLeaveButton, .ended, at: 1)))
        let decision = engine.ingest(event(.shareableContentWindow, .ended, at: 2))
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

    // MARK: - TECH-END2 corroboration guard (screen-share false-stop)

    func test_lone_ax_leave_invalid_does_not_promote_to_ended_after_debounce() {
        // The confirmed 2026-06-09 repro: ax-leave goes transiently invalid on a
        // screen-share re-render. With no corroborating signal it must NOT auto-stop;
        // it stays provisional so the silence backstop, not a false end, decides.
        let engine = PromotionEngine(debounce: 2.0)
        _ = engine.ingest(event(.axLeaveButton, .live, at: 0))
        _ = engine.confirmRecording()
        let provisional = engine.ingest(event(.axLeaveButton, .ended, at: 1))
        XCTAssertEqual(
            provisional?.verdict,
            .endingProvisional(
                context: teamsContext,
                reason: EndingReason(leadingSignal: "ax_leave_button_invalid")
            )
        )
        let post = engine.tick(at: Date(timeIntervalSince1970: 4))
        XCTAssertNil(post, "A lone ax-leave invalid must not confirm an end on the debounce alone")
    }

    func test_rewalk_confirm_promotes_a_lone_ax_leave_provisional() {
        // The end-stop fix: when the daemon's Leave-button re-walk verifies the control is really
        // gone, confirmProvisionalEnd promotes the held provisional to .ended immediately (the
        // re-walk is the corroboration), recorded in confirmedBy. This stops a genuine native leave
        // that the tick() guard alone would otherwise hold until window-gone or a manual stop.
        let engine = PromotionEngine(debounce: 2.0)
        _ = engine.ingest(event(.axLeaveButton, .live, at: 0))
        _ = engine.confirmRecording()
        _ = engine.ingest(event(.axLeaveButton, .ended, at: 1))
        let decision = engine.confirmProvisionalEnd()
        XCTAssertEqual(
            decision?.verdict,
            .ended(
                context: teamsContext,
                reason: EndingReason(
                    leadingSignal: "ax_leave_button_invalid",
                    confirmedBy: ["ax_leave_rewalk"]
                )
            )
        )
        XCTAssertNil(
            engine.tick(at: Date(timeIntervalSince1970: 5)),
            "Once confirmed-ended, a later tick must not re-emit"
        )
    }

    func test_rewalk_confirm_is_noop_when_not_provisional() {
        // No provisional end in flight: confirming is a no-op (a concurrent revert or end already
        // moved the phase), so it can never fabricate an end out of .idle or .inMeeting.
        let engine = PromotionEngine(debounce: 2.0)
        XCTAssertNil(engine.confirmProvisionalEnd(), "idle: nothing to confirm")
        _ = engine.ingest(event(.axLeaveButton, .live, at: 0))
        _ = engine.confirmRecording()
        XCTAssertNil(engine.confirmProvisionalEnd(), "in_meeting: nothing to confirm")
    }

    func test_window_gone_still_promotes_alone_after_debounce() {
        // The guard is scoped: a reliable signal (window-gone) keeps promoting on the
        // debounce by itself, so the ends that already work are preserved.
        let engine = PromotionEngine(debounce: 2.0)
        _ = engine.ingest(event(.shareableContentWindow, .live, at: 0))
        _ = engine.confirmRecording()
        _ = engine.ingest(event(.shareableContentWindow, .ended, at: 1))
        let post = engine.tick(at: Date(timeIntervalSince1970: 4))
        XCTAssertEqual(
            post?.verdict,
            .ended(
                context: teamsContext,
                reason: EndingReason(leadingSignal: "shareable_content_window_gone", confirmedBy: [])
            )
        )
    }

    func test_ax_leave_invalid_promotes_when_corroborated_by_window_gone() {
        // A real leave: window-gone corroborates ax-leave, so .ended fires (fast path).
        let engine = PromotionEngine(debounce: 2.0)
        _ = engine.ingest(event(.axLeaveButton, .live, at: 0))
        _ = engine.ingest(event(.shareableContentWindow, .live, at: 0))
        _ = engine.confirmRecording()
        _ = engine.ingest(event(.axLeaveButton, .ended, at: 1))
        let decision = engine.ingest(event(.shareableContentWindow, .ended, at: 1.3))
        XCTAssertEqual(
            decision?.verdict,
            .ended(
                context: teamsContext,
                reason: EndingReason(
                    leadingSignal: "ax_leave_button_invalid",
                    confirmedBy: ["shareable_content_window_gone"]
                )
            )
        )
    }

    func test_held_ax_leave_provisional_ends_when_window_gone_arrives_after_debounce() {
        // Guard holds provisional past the debounce; a later window-gone corroborates
        // and the meeting ends, so the backstop is not the only escape.
        let engine = PromotionEngine(debounce: 2.0)
        _ = engine.ingest(event(.axLeaveButton, .live, at: 0))
        _ = engine.confirmRecording()
        _ = engine.ingest(event(.axLeaveButton, .ended, at: 1))
        XCTAssertNil(engine.tick(at: Date(timeIntervalSince1970: 5)), "Held while uncorroborated")
        let decision = engine.ingest(event(.shareableContentWindow, .ended, at: 6))
        XCTAssertEqual(
            decision?.verdict,
            .ended(
                context: teamsContext,
                reason: EndingReason(
                    leadingSignal: "ax_leave_button_invalid",
                    confirmedBy: ["shareable_content_window_gone"]
                )
            )
        )
    }

    func test_ax_leave_provisional_reverts_to_in_meeting_when_control_returns() {
        // The signal's re-walk finds the live control and emits .live; provisional reverts.
        let engine = PromotionEngine(debounce: 2.0)
        _ = engine.ingest(event(.axLeaveButton, .live, at: 0))
        _ = engine.confirmRecording()
        _ = engine.ingest(event(.axLeaveButton, .ended, at: 1))
        let revert = engine.ingest(event(.axLeaveButton, .live, at: 1.5))
        XCTAssertEqual(revert?.verdict, .inMeeting(context: teamsContext))
        XCTAssertNil(engine.tick(at: Date(timeIntervalSince1970: 4)), "No end after the control returns")
    }

    func test_requiresCorroboration_is_scoped_to_ax_leave() {
        XCTAssertTrue(PrimarySignalKind.axLeaveButton.requiresCorroboration)
        XCTAssertFalse(PrimarySignalKind.shareableContentWindow.requiresCorroboration)
        XCTAssertFalse(PrimarySignalKind.workspaceAppTerminated.requiresCorroboration)
        XCTAssertFalse(PrimarySignalKind.windowTitleLeftPattern.requiresCorroboration)
        XCTAssertFalse(PrimarySignalKind.browserTabTitle.requiresCorroboration)
    }

    // MARK: - Browser path corroboration (GAP 2)

    func test_workspace_termination_confirms_browser_ended_without_debounce() {
        // The browser path now fuses more than one PRIMARY signal:
        // ShareableContent leads .ended, WorkspaceSignal (a distinct
        // kind) confirms, so .ended fires immediately instead of
        // waiting out the 2 s debounce a lone signal would need.
        let engine = PromotionEngine(debounce: 2.0)
        _ = engine.ingest(browserEvent(.browserTabTitle, .live, at: 0))
        _ = engine.confirmRecording()
        _ = engine.ingest(browserEvent(.browserTabTitle, .ended, at: 25))
        let decision = engine.ingest(browserEvent(.workspaceAppTerminated, .ended, at: 25.3))

        XCTAssertEqual(
            decision?.verdict,
            .ended(
                context: browserContext,
                reason: EndingReason(
                    leadingSignal: "browser_tab_title_left_meet_pattern",
                    confirmedBy: ["workspace_app_terminated"]
                )
            )
        )
    }

    func test_window_title_can_lead_browser_ended_confirmed_by_shareable_content() {
        // PWA path: the AX window-title signal leads, the
        // shareable-content snapshot confirms.
        let engine = PromotionEngine(debounce: 2.0)
        _ = engine.ingest(browserEvent(.windowTitleLeftPattern, .live, at: 0))
        _ = engine.confirmRecording()
        _ = engine.ingest(browserEvent(.windowTitleLeftPattern, .ended, at: 10))
        let decision = engine.ingest(browserEvent(.shareableContentWindow, .ended, at: 10.4))

        XCTAssertEqual(
            decision?.verdict,
            .ended(
                context: browserContext,
                reason: EndingReason(
                    leadingSignal: "window_title_left_pattern",
                    confirmedBy: ["shareable_content_window_gone"]
                )
            )
        )
    }

    func test_new_browser_signal_kinds_have_stable_raw_values() {
        // The raw values surface verbatim in events.jsonl and the
        // dogfood report, so they are part of the contract.
        XCTAssertEqual(PrimarySignalKind.workspaceAppTerminated.rawValue, "workspace_app_terminated")
        XCTAssertEqual(PrimarySignalKind.windowTitleLeftPattern.rawValue, "window_title_left_pattern")
    }
}
