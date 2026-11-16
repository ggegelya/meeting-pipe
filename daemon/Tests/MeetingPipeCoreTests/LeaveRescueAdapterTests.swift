import ApplicationServices
import XCTest
@testable import MeetingPipeCore

/// END18 (F002, G006, D027): the rescue, end to end through the real signals. The real
/// `AXLeaveButtonSignal` and `ShareableContentSignal` run under `NativeLifecycleAdapter` (fake
/// probes, hand-cranked schedulers), into `MeetingLifecycleCoordinator` and the engine. Nothing
/// injects a `.live` by hand, which is how END8's engine test passed for months over a rescue that
/// never reached the engine. Webex's config has no process audio, the case where END14's veto
/// cannot absorb the window-gone and this path is all there is.
final class LeaveRescueAdapterTests: XCTestCase {

    private let context = MeetingLifecycleContext(bundleID: "com.cisco.webexmeetingsapp", kind: .native, pid: 4242)

    final class Crank {
        var tick: (() -> Void)?
    }

    private struct Rig {
        let coordinator: MeetingLifecycleCoordinator
        let window: ShareableContentSignal
        let leave: AXLeaveButtonSignal
        let windowPresent: Box
        let engineTick: Crank
        let clockOffset: Box2
    }

    final class Box { var value = true }
    final class Box2 { var value: TimeInterval = 0 }

    private func makeRig() throws -> Rig {
        let windowPresent = Box()
        let windowCrank = Crank()
        let leaveCrank = Crank()
        let window = ShareableContentSignal(
            probe: {
                windowPresent.value
                    ? [ShareableContentSignal.ShareableWindowSummary(bundleIdentifier: "com.cisco.webexmeetingsapp", title: "Webex Meeting")]
                    : []
            },
            scheduler: { _, action in windowCrank.tick = action; return { windowCrank.tick = nil } }
        )
        let leave = AXLeaveButtonSignal(
            axBus: AXObserverBus(),
            probe: { _ in .healthy },
            scheduler: { _, action in leaveCrank.tick = action; return { leaveCrank.tick = nil } }
        )
        let adapter = NativeLifecycleAdapter(
            config: .webex, processAudio: nil, shareableContent: window, axLeaveButton: leave
        )
        let engineTick = Crank()
        let offset = Box2()
        let coordinator = MeetingLifecycleCoordinator(
            adapters: [adapter],
            scheduler: { _, action in engineTick.tick = action; return { engineTick.tick = nil } },
            clock: { Date().addingTimeInterval(offset.value) }
        )
        try coordinator.engage(context: context, handle: LifecycleAdapterHandle(leaveButton: AXUIElementCreateSystemWide()))
        drain(coordinator)
        coordinator.confirmRecording()
        drain(coordinator)
        XCTAssertEqual(coordinator.current, .inMeeting(context: context), "Leave and window read live at engage")
        return Rig(coordinator: coordinator, window: window, leave: leave, windowPresent: windowPresent, engineTick: engineTick, clockOffset: offset)
    }

    private func drain(_ coordinator: MeetingLifecycleCoordinator) {
        let done = expectation(description: "drain")
        coordinator.tick()
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.05) { done.fulfill() }
        wait(for: [done], timeout: 2)
    }

    private func windowGoes(_ rig: Rig) {
        rig.windowPresent.value = false
        rig.window.evaluate(reason: "poll")
        drain(rig.coordinator)
        XCTAssertEqual(
            rig.coordinator.current,
            .endingProvisional(context: context, reason: EndingReason(leadingSignal: "shareable_content_window_gone"))
        )
    }

    /// (a) The window goes with the Leave button armed and healthy; the rescue reverts the hold.
    func test_theRescue_revertsAWindowGoneHold_throughTheRealSignal() throws {
        let rig = try makeRig()
        windowGoes(rig)
        rig.coordinator.rescueLeaveButton(AXUIElementCreateSystemWide())
        drain(rig.coordinator)
        XCTAssertEqual(rig.coordinator.current, .inMeeting(context: context))
    }

    /// (b) The same hold with no rescue and no process audio does not confirm at the lone dwell:
    /// the Leave button reading live in the engine's states contradicts it.
    func test_withoutTheRescue_theHoldDoesNotConfirmAtTheLoneDwell() throws {
        let rig = try makeRig()
        windowGoes(rig)
        rig.clockOffset.value = PromotionEngine.defaultLoneDwell + 5
        drain(rig.coordinator)
        XCTAssertEqual(
            rig.coordinator.current,
            .endingProvisional(context: context, reason: EndingReason(leadingSignal: "shareable_content_window_gone")),
            "still held, never ended"
        )
    }

    /// (c) The late-arm on an armed healthy button still emits nothing (END8's own race), so only
    /// the rescue entry reverts.
    func test_theLateArm_stillDoesNotRevert() throws {
        let rig = try makeRig()
        windowGoes(rig)
        rig.coordinator.armLeaveButton(AXUIElementCreateSystemWide())
        drain(rig.coordinator)
        XCTAssertEqual(
            rig.coordinator.current,
            .endingProvisional(context: context, reason: EndingReason(leadingSignal: "shareable_content_window_gone"))
        )
    }
}

/// END18's wiring fence, in END10's shape: the adapter test starts at the coordinator, and the
/// seam F002 hid behind is the host's choice of entry. `rescueProvisionalEnd` must hand the walked
/// button to the rescue, not the late-arm.
final class LeaveRescueWiringFenceTests: XCTestCase {
    func test_theHostsRescue_callsTheRescueEntry() throws {
        let root = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent()
            .deletingLastPathComponent().deletingLastPathComponent()
        let text = try String(
            contentsOf: root.appendingPathComponent("daemon/Sources/MeetingPipe/MeetingSessionController.swift"),
            encoding: .utf8
        )
        guard let start = text.range(of: "func rescueProvisionalEnd(context: MeetingLifecycleContext) {"),
              let end = text.range(of: "// MARK: - END9 / END17: the hold", range: start.upperBound..<text.endIndex) else {
            return XCTFail("rescueProvisionalEnd moved or was renamed; this fence needs updating with it")
        }
        let body = String(text[start.lowerBound..<end.lowerBound])
        XCTAssertTrue(body.contains("lifecycleCoord.rescueLeaveButton("), "the rescue no longer reaches the rescue entry")
        XCTAssertFalse(body.contains("lifecycleCoord.armLeaveButton("), "the late-arm emits nothing on a healthy button (F002)")
    }
}

