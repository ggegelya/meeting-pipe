import AVFoundation
import XCTest
@testable import MeetingPipe
@testable import MeetingPipeCore

/// END11: a recording started by hand had no end detection, so it ran until the owner stopped it.
///
/// The element was resolved correctly and handed to nobody. `armLeaveButton` is
/// `activeAdapter?.armLeaveButton(element)`, `activeAdapter` is set only by `engage`, and the only
/// caller of `engage` is `handleDiscovery`, whose skip-latch and cooldown branches both `return`
/// before reaching it. DET13 made the *element* reachable by retaining the cooldown-suppressed
/// sighting; this is the neighbouring half that was assumed to follow and did not. Field cost:
/// `20260817-164312.wav` ran 72 minutes, through a `system_capture_lost` and a full system sleep,
/// because nothing could end it.
@MainActor
final class ExplicitStartLifecycleTests: XCTestCase {

    private var tempDir: URL!

    override func setUpWithError() throws {
        try super.setUpWithError()
        tempDir = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("end11-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: tempDir)
        try super.tearDownWithError()
    }

    private func makeController() -> (MeetingSessionController, FakeSessionHost) {
        let host = FakeSessionHost(tempDir: tempDir, workflows: [])
        return (MeetingSessionController(coordinator: host), host)
    }

    private func source(_ bundleID: String) -> AppSource {
        AppSource(bundleID: bundleID, displayName: bundleID)
    }

    private func settle() async {
        for _ in 0..<50 { await Task.yield() }
    }

    // MARK: - Item 4: an end belongs to the recording it names

    /// Red against `main`: `handleMeetingEnded`'s `.recording` branch called `stopRecording`
    /// without ever comparing the ended bundle to the recording's own source, so a stale adapter
    /// for another app stopped the wrong recording.
    func test_endForAnotherApp_doesNotStopThisRecording() async {
        let (controller, host) = makeController()
        host.stateMachine.setRecording(
            file: tempDir.appendingPathComponent("rec.wav"),
            source: source("com.microsoft.teams2"),
            summaryMode: .auto
        )

        controller.handleMeetingEnded(
            bundleID: "us.zoom.xos",
            reason: EndingReason(leadingSignal: "ax_leave_button_invalid")
        )
        await settle()

        XCTAssertEqual(
            host.recorderSpy.stopCallCount, 0,
            "a Zoom end must not stop a Teams recording"
        )
    }

    func test_endForTheRecordingsOwnApp_stopsIt() async {
        let (controller, host) = makeController()
        host.stateMachine.setRecording(
            file: tempDir.appendingPathComponent("rec.wav"),
            source: source("com.microsoft.teams2"),
            summaryMode: .auto
        )

        controller.handleMeetingEnded(
            bundleID: "com.microsoft.teams2",
            reason: EndingReason(leadingSignal: "ax_leave_button_invalid")
        )
        await settle()

        XCTAssertEqual(
            host.recorderSpy.stopCallCount, 1,
            "the identity guard must narrow which end applies, never whether an end is honoured"
        )
    }

    /// A source-less recording has no identity to compare and no AX end anchor either, so dropping
    /// the end there would take away the only automatic stop it can reach short of the idle
    /// backstop. Today's behaviour is deliberately preserved.
    func test_endStillStopsASourcelessRecording() async {
        let (controller, host) = makeController()
        host.stateMachine.setRecording(
            file: tempDir.appendingPathComponent("rec.wav"), source: nil, summaryMode: .auto
        )

        controller.handleMeetingEnded(
            bundleID: "com.microsoft.teams2",
            reason: EndingReason(leadingSignal: "ax_leave_button_invalid")
        )
        await settle()

        XCTAssertEqual(host.recorderSpy.stopCallCount, 1)
    }

    // MARK: - Items 1 and 2: what each explicit start gets

    /// Item 2's decision, pinned: a source-less recording engages no adapter, so it has no AX end
    /// anchor by construction and its only automatic bound is the idle auto-stop.
    func test_sourcelessStart_engagesNoAdapter() {
        let (controller, host) = makeController()
        controller.engageLifecycleIfNeeded(source: nil)
        XCTAssertFalse(
            host.lifecycleCoord.isEngaged,
            "there is no pid and no Leave button to anchor on, so there is nothing to engage"
        )
    }

    /// The bound a source-less recording does get. `armSystemLevelMirror` is what feeds
    /// `IdleStopBackstop`, and it is wired for every recording, source or not.
    func test_sourcelessRecording_armsTheIdleBound() {
        let (controller, host) = makeController()
        controller.armSystemLevelMirror()
        XCTAssertNotNil(
            host.recorderSpy.onMicLevel,
            "the idle auto-stop is the source-less path's only bound; it has to be fed"
        )
        controller.disarmSystemLevelMirror()
        XCTAssertNil(host.recorderSpy.onMicLevel)
    }

    /// Engaging is idempotent, and that is not an optimisation: `engage()` opens with
    /// `disengage()`, so an unguarded call on an explicit start would stop a healthy
    /// discovery-engaged adapter and reset the engine to `.idle` mid-meeting.
    func test_engageIsSkippedWhenAnAdapterIsAlreadyLive() throws {
        let (controller, host) = makeController()
        XCTAssertFalse(host.lifecycleCoord.isEngaged)
        controller.engageLifecycleIfNeeded(source: source("com.microsoft.teams2"))
        // No pid in a unit test, so nothing engages; the guard's real proof is the Core-level
        // `MeetingLifecycleCoordinatorTests` engage/disengage pair plus the ordering fence below.
        XCTAssertFalse(host.lifecycleCoord.isEngaged)
    }
}

/// END11's wiring fence, in END10's shape and for the same reason: the defect is a call that was
/// never made, `engageLifecycle` needs a real pid so no unit test can reach it, and the claim is
/// perfectly readable on the checkout.
final class ExplicitStartWiringFenceTests: XCTestCase {

    private func repoRoot() -> URL {
        URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent()
            .deletingLastPathComponent().deletingLastPathComponent()
    }

    private func controllerSource() throws -> String {
        try String(
            contentsOf: repoRoot()
                .appendingPathComponent("daemon/Sources/MeetingPipe/MeetingSessionController.swift"),
            encoding: .utf8
        )
    }

    /// Red against `main`: the engage call did not exist anywhere on the start path.
    func testBeginRecordingEngagesTheLifecycleBeforeArmingTheLeaveButton() throws {
        let text = try controllerSource()
        guard let engage = text.range(of: "self.engageLifecycleIfNeeded(source: source)") else {
            return XCTFail(
                "the recording-start path does not engage the lifecycle. An explicit start then "
                    + "resolves a Leave button and hands it to a nil adapter, which is END11: "
                    + "20260817-164312.wav ran 72 minutes because nothing could end it."
            )
        }
        let arm = try XCTUnwrap(
            text.range(of: "self.armLifecycleLeaveButton(source: source)"),
            "the leave-button arm went missing from the start path"
        )
        XCTAssertTrue(
            engage.lowerBound < arm.lowerBound,
            "engage has to precede the arm, or there is still no adapter to arm onto when it lands"
        )
    }

    /// The guard that keeps the engage from resetting a live session.
    func testEngageHelperGuardsOnAlreadyEngaged() throws {
        let text = try controllerSource()
        XCTAssertTrue(
            text.contains("guard !coordinator.lifecycleCoord.isEngaged else {"),
            "engageLifecycleIfNeeded lost its idempotency guard; engage() opens with disengage(), "
                + "so this would tear down a healthy discovery-engaged adapter"
        )
    }
}
