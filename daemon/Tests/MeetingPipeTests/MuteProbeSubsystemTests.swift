import ApplicationServices
import XCTest
@testable import MeetingPipe

/// Locks in the post-extraction contract for `MuteProbeSubsystem`:
/// arm/disarm respects config gating and source kind, the tick callback
/// only emits transitions when the AX state actually flips, and
/// `.unknown` evaluations don't whipsaw the recorder.
///
/// The probe owns no AVFoundation or AX dependency directly when driven
/// through its injected `evaluator` and `windowCapture` closures, so
/// these tests run on a Command Line Tools install too.
final class MuteProbeSubsystemTests: XCTestCase {

    private static let teams = AppSource(
        bundleID: "com.microsoft.teams2",
        displayName: "Teams",
        kind: .native
    )
    private static let browser = AppSource(
        bundleID: "com.google.chrome",
        displayName: "Chrome",
        kind: .browser
    )

    /// Construct a stub handle. The AXUIElement isn't dereferenced when
    /// the evaluator is injected, so a placeholder element of the system
    /// process is fine and avoids needing accessibility-trust to run.
    private func stubHandle(bundleID: String) -> MeetingWindowHandle {
        MeetingWindowHandle(
            element: AXUIElementCreateSystemWide(),
            pid: 0,
            bundleID: bundleID
        )
    }

    // MARK: - Arming

    func test_arm_no_op_when_disabled() {
        var captureCalls = 0
        let probe = MuteProbeSubsystem(
            evaluator: { _ in .unknown },
            windowCapture: { _ in captureCalls += 1; return nil },
            pollInterval: 10
        )
        let armed = probe.arm(source: Self.teams, enabled: false)
        XCTAssertFalse(armed)
        XCTAssertEqual(captureCalls, 0, "Arming when disabled must not touch AX")
    }

    func test_arm_no_op_for_browser_source() {
        var captureCalls = 0
        let probe = MuteProbeSubsystem(
            evaluator: { _ in .unknown },
            windowCapture: { _ in captureCalls += 1; return nil },
            pollInterval: 10
        )
        XCTAssertFalse(probe.arm(source: Self.browser, enabled: true))
        XCTAssertEqual(captureCalls, 0, "Browser sources skip the AX walk entirely")
    }

    func test_arm_no_op_when_window_capture_returns_nil() {
        let probe = MuteProbeSubsystem(
            evaluator: { _ in .unknown },
            windowCapture: { _ in nil },
            pollInterval: 10
        )
        XCTAssertFalse(probe.arm(source: Self.teams, enabled: true))
    }

    func test_arm_succeeds_when_handle_captured() {
        let probe = MuteProbeSubsystem(
            evaluator: { _ in .unknown },
            windowCapture: { src in self.stubHandle(bundleID: src.bundleID) },
            pollInterval: 10
        )
        XCTAssertTrue(probe.arm(source: Self.teams, enabled: true))
        probe.disarm()
    }

    // MARK: - Tick transitions

    func test_tick_emits_pause_on_muted() {
        var verdict: MeetingMuteProbe.State = .muted
        let probe = MuteProbeSubsystem(
            evaluator: { _ in verdict },
            windowCapture: { src in self.stubHandle(bundleID: src.bundleID) },
            pollInterval: 10
        )
        var events: [MuteProbeSubsystem.Transition] = []
        probe.onTransition = { events.append($0) }
        XCTAssertTrue(probe.arm(source: Self.teams, enabled: true))
        probe.tick()
        XCTAssertEqual(events, [.paused(bundleID: Self.teams.bundleID)])
        // Same state → no duplicate event.
        probe.tick()
        XCTAssertEqual(events, [.paused(bundleID: Self.teams.bundleID)])
        // Flip to unmuted → resume event.
        verdict = .unmuted
        probe.tick()
        XCTAssertEqual(events, [
            .paused(bundleID: Self.teams.bundleID),
            .resumed(bundleID: Self.teams.bundleID),
        ])
        probe.disarm()
    }

    func test_tick_ignores_unknown_verdict() {
        var verdict: MeetingMuteProbe.State = .unknown
        let probe = MuteProbeSubsystem(
            evaluator: { _ in verdict },
            windowCapture: { src in self.stubHandle(bundleID: src.bundleID) },
            pollInterval: 10
        )
        var events: [MuteProbeSubsystem.Transition] = []
        probe.onTransition = { events.append($0) }
        XCTAssertTrue(probe.arm(source: Self.teams, enabled: true))
        probe.tick()
        XCTAssertTrue(events.isEmpty)
        XCTAssertEqual(probe.lastState, .unknown)
        // A clear AX result after an unknown still emits.
        verdict = .muted
        probe.tick()
        XCTAssertEqual(events, [.paused(bundleID: Self.teams.bundleID)])
        probe.disarm()
    }

    // MARK: - Disarming

    func test_disarm_resets_state_so_a_fresh_arm_re_emits() {
        var verdict: MeetingMuteProbe.State = .muted
        let probe = MuteProbeSubsystem(
            evaluator: { _ in verdict },
            windowCapture: { src in self.stubHandle(bundleID: src.bundleID) },
            pollInterval: 10
        )
        var events: [MuteProbeSubsystem.Transition] = []
        probe.onTransition = { events.append($0) }
        XCTAssertTrue(probe.arm(source: Self.teams, enabled: true))
        probe.tick()
        XCTAssertEqual(events.count, 1)
        probe.disarm()
        XCTAssertEqual(probe.lastState, .unknown)
        // Re-arm and re-tick — verdict still .muted, must emit again since
        // disarm cleared the cached state.
        XCTAssertTrue(probe.arm(source: Self.teams, enabled: true))
        probe.tick()
        XCTAssertEqual(events.count, 2)
        probe.disarm()
    }

    func test_tick_before_arm_is_a_no_op() {
        let probe = MuteProbeSubsystem(
            evaluator: { _ in .muted },
            windowCapture: { _ in nil },
            pollInterval: 10
        )
        var events: [MuteProbeSubsystem.Transition] = []
        probe.onTransition = { events.append($0) }
        probe.tick()
        XCTAssertTrue(events.isEmpty)
    }
}
