import XCTest
@testable import MeetingPipe

/// Locks in the post-extraction contract for `DetectionStateMachine`:
/// the typed transitions, the embedded cooldown facade, the prompt
/// timeout timer, and the idle-transition callback that the Coordinator
/// hooks for deferred config refreshes.
final class DetectionStateMachineTests: XCTestCase {

    private static let teams = AppSource(bundleID: "com.microsoft.teams2", displayName: "Teams")

    // MARK: - Transitions

    func test_starts_idle_and_accepts_prompts() {
        let m = DetectionStateMachine()
        XCTAssertEqual(m.current, .idle)
        XCTAssertTrue(m.isAcceptingPrompts)
    }

    func test_setPrompting_blocks_further_prompts() {
        let m = DetectionStateMachine()
        m.setPrompting(source: Self.teams)
        if case .prompting(let s) = m.current {
            XCTAssertEqual(s, Self.teams)
        } else {
            XCTFail("expected .prompting, got \(m.current)")
        }
        XCTAssertFalse(m.isAcceptingPrompts)
    }

    func test_setRecording_and_setStopping_carry_payload() {
        let m = DetectionStateMachine()
        let url = URL(fileURLWithPath: "/tmp/x.wav")
        m.setRecording(file: url, source: Self.teams, summaryMode: .auto)
        if case .recording(let f, let s, let mode) = m.current {
            XCTAssertEqual(f, url)
            XCTAssertEqual(s, Self.teams)
            XCTAssertEqual(mode, .auto)
        } else {
            XCTFail("expected .recording, got \(m.current)")
        }
        m.setStopping(file: url, source: Self.teams, summaryMode: .auto)
        if case .stopping = m.current {} else {
            XCTFail("expected .stopping")
        }
    }

    // MARK: - Idle callback

    func test_setIdle_fires_onIdleTransition_each_time() {
        let m = DetectionStateMachine()
        var fired = 0
        m.onIdleTransition = { fired += 1 }
        m.setPrompting(source: Self.teams)
        XCTAssertEqual(fired, 0)
        m.setIdle()
        XCTAssertEqual(fired, 1)
        m.setPrompting(source: Self.teams)
        m.setIdle()
        XCTAssertEqual(fired, 2)
    }

    // MARK: - Abandon prompt (skip / prompt-timeout / force-stop-while-prompting)

    func test_abandonPrompt_returns_to_idle_and_cools_down_only_that_bundle() {
        let m = DetectionStateMachine()
        var idleFired = 0
        m.onIdleTransition = { idleFired += 1 }
        m.setPrompting(source: Self.teams)
        XCTAssertFalse(m.isAcceptingPrompts)

        m.abandonPrompt(source: Self.teams)

        // Back to idle so a meeting in *another* app is still detected. The old
        // `.suppressed` blocked all detection until a corroborated lifecycle end
        // that the Teams compact-window artifact never produced, wedging detection
        // for the rest of the meeting (the bug this regression guards).
        XCTAssertTrue(m.isAcceptingPrompts, "abandonPrompt returns to idle")
        // The idle hook fires so the Coordinator disengages the lifecycle adapter
        // (and its 1 Hz Leave-button poll), instead of leaking it.
        XCTAssertEqual(idleFired, 1)
        // Only the skipped bundle is cooled down; a different app is not.
        XCTAssertTrue(m.isCoolingDown(bundleID: Self.teams.bundleID, cooldownSec: 60))
        XCTAssertFalse(m.isCoolingDown(bundleID: "us.zoom.xos", cooldownSec: 60))
    }

    func test_abandonPrompt_cancels_the_pending_prompt_timeout() {
        let m = DetectionStateMachine()
        m.setPrompting(source: Self.teams)
        var fired = false
        m.startPromptTimeout(for: Self.teams, timeoutSec: 0.05) { fired = true }
        m.abandonPrompt(source: Self.teams)
        let exp = expectation(description: "wait past the scheduled fire")
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.15) { exp.fulfill() }
        wait(for: [exp], timeout: 1.0)
        XCTAssertFalse(fired, "abandonPrompt cancels the timeout; the timer must not fire after it")
    }

    // MARK: - Cooldown facade

    func test_cooldown_facade_round_trips() {
        let m = DetectionStateMachine()
        XCTAssertFalse(m.isCoolingDown(bundleID: "us.zoom.xos", cooldownSec: 60))
        m.recordCooldownEnd(bundleID: "us.zoom.xos")
        XCTAssertTrue(m.isCoolingDown(bundleID: "us.zoom.xos", cooldownSec: 60))
        m.clearCooldown(bundleID: "us.zoom.xos")
        XCTAssertFalse(m.isCoolingDown(bundleID: "us.zoom.xos", cooldownSec: 60))
    }

    // MARK: - Pending config refresh

    func test_pending_refresh_is_idempotent_and_idle_gated() {
        let m = DetectionStateMachine()
        XCTAssertFalse(m.consumePendingConfigRefreshIfIdle())
        m.markConfigRefreshPending()
        // Not idle yet — mid-recording — refresh stays pending.
        m.setRecording(
            file: URL(fileURLWithPath: "/tmp/x.wav"),
            source: Self.teams,
            summaryMode: .auto
        )
        XCTAssertFalse(m.consumePendingConfigRefreshIfIdle())
        // Back to idle — consumes once.
        m.setIdle()
        XCTAssertTrue(m.consumePendingConfigRefreshIfIdle())
        // Already consumed — repeat call returns false.
        XCTAssertFalse(m.consumePendingConfigRefreshIfIdle())
    }

    // MARK: - Prompt timeout

    func test_prompt_timeout_fires_only_when_still_prompting_same_source() {
        let m = DetectionStateMachine()
        m.setPrompting(source: Self.teams)
        let exp = expectation(description: "timeout fires")
        var fired = false
        m.startPromptTimeout(for: Self.teams, timeoutSec: 0.05) {
            fired = true
            exp.fulfill()
        }
        wait(for: [exp], timeout: 1.0)
        XCTAssertTrue(fired)
    }

    func test_prompt_timeout_cancelled_does_not_fire() {
        let m = DetectionStateMachine()
        m.setPrompting(source: Self.teams)
        var fired = false
        m.startPromptTimeout(for: Self.teams, timeoutSec: 0.05) { fired = true }
        m.cancelPromptTimeout()
        // Wait a hair past the scheduled fire to confirm it's been cancelled.
        let exp = expectation(description: "wait")
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.15) { exp.fulfill() }
        wait(for: [exp], timeout: 1.0)
        XCTAssertFalse(fired)
    }

    func test_prompt_timeout_skipped_when_state_changed() {
        let m = DetectionStateMachine()
        m.setPrompting(source: Self.teams)
        var fired = false
        m.startPromptTimeout(for: Self.teams, timeoutSec: 0.05) { fired = true }
        m.setIdle()
        let exp = expectation(description: "wait")
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.15) { exp.fulfill() }
        wait(for: [exp], timeout: 1.0)
        XCTAssertFalse(fired, "Timer fired but state had left .prompting")
    }

    // MARK: - Label helper

    func test_label_is_stable_for_jsonl_events() {
        XCTAssertEqual(DetectionStateMachine.label(.idle), "idle")
        XCTAssertEqual(DetectionStateMachine.label(.prompting(source: Self.teams)), "prompting")
        XCTAssertEqual(DetectionStateMachine.label(.suppressed(source: Self.teams)), "suppressed")
        XCTAssertEqual(
            DetectionStateMachine.label(.recording(
                file: URL(fileURLWithPath: "/tmp/x.wav"),
                source: Self.teams,
                summaryMode: .auto
            )),
            "recording"
        )
        XCTAssertEqual(
            DetectionStateMachine.label(.stopping(
                file: URL(fileURLWithPath: "/tmp/x.wav"),
                source: Self.teams,
                summaryMode: .auto
            )),
            "stopping"
        )
    }
}
