import ApplicationServices
import CoreAudio
import XCTest
@testable import MeetingPipeCore

/// END17 (2026-11-13 amendment, G025, F033): the native adapter's two new readings, end to end. An
/// app quit was definitive in ADR 0017's tier table but no native adapter ever started a
/// `WorkspaceSignal`, and a live process-audio reading held its veto for ever once the app's
/// objects vanished.
final class NativeAppQuitTests: XCTestCase {

    private let teams = MeetingLifecycleContext(bundleID: "com.microsoft.teams2", kind: .native, pid: 4242)
    private let webex = MeetingLifecycleContext(bundleID: "com.cisco.webexmeetingsapp", kind: .native, pid: 4343)

    final class Crank { var tick: (() -> Void)? }

    private func quietWorkspace() -> WorkspaceSignal {
        WorkspaceSignal(probe: { _ in nil }, notificationCenter: NotificationCenter())
    }

    /// The public initializer, the one `Coordinator` uses, starts the app-quit signal and maps it
    /// to a definitive end under the started context; `stop` stops it.
    func test_the_public_initializer_wires_the_app_quit_END17() throws {
        let workspace = quietWorkspace()
        let adapter = NativeLifecycleAdapter(config: .webex, axBus: AXObserverBus(), workspace: workspace)
        var events: [PrimarySignalEvent] = []
        try adapter.start(context: webex, handle: LifecycleAdapterHandle()) { events.append($0) }

        workspace.handleTerminated(reason: "test")
        let quit = events.filter { $0.kind == .workspaceAppTerminated }
        XCTAssertEqual(quit.count, 1)
        XCTAssertEqual(quit.first?.state, .ended)
        XCTAssertEqual(quit.first?.context, webex)

        adapter.stop()
        workspace.handleTerminated(reason: "after_stop")
        XCTAssertEqual(events.filter { $0.kind == .workspaceAppTerminated }.count, 1, "stopped with the adapter")
    }

    /// The END14 case, rewritten so the quit arrives through the native adapter rather than as a
    /// hand-made event: Teams holding the mic does not veto its own quit.
    func test_a_native_quit_ends_at_once_under_a_live_mic_END14_END17() throws {
        let workspace = quietWorkspace()
        let windowCrank = Crank()
        let window = ShareableContentSignal(
            probe: { [ShareableContentSignal.ShareableWindowSummary(bundleIdentifier: "com.microsoft.teams2", title: "Standup")] },
            scheduler: { _, action in windowCrank.tick = action; return { windowCrank.tick = nil } }
        )
        let leave = AXLeaveButtonSignal(
            axBus: AXObserverBus(), probe: { _ in .healthy },
            scheduler: { _, action in { } }
        )
        let mic = ProcessAudioSignal(
            halBus: CoreAudioHALBus(),
            probe: { _, _ in true },
            scheduler: { _, _ in { } },
            resolver: { _ in .resolved([9999]) }
        )
        let adapter = NativeLifecycleAdapter(
            config: .teams, processAudio: mic, shareableContent: window, axLeaveButton: leave, workspace: workspace
        )
        let coordinator = MeetingLifecycleCoordinator(
            adapters: [adapter], scheduler: { _, _ in { } }
        )
        try coordinator.engage(context: teams, handle: LifecycleAdapterHandle())
        drain(coordinator)
        coordinator.confirmRecording()
        drain(coordinator)
        XCTAssertEqual(coordinator.current, .inMeeting(context: teams))
        XCTAssertEqual(coordinator.liveCallSignal, .callIsUp)

        workspace.handleTerminated(reason: "test")
        drain(coordinator)
        XCTAssertEqual(
            coordinator.current,
            .ended(context: teams, reason: EndingReason(leadingSignal: "workspace_app_terminated", confirmedBy: []))
        )
    }

    /// A running mic whose objects vanish reaches the engine as unknown through the adapter, and
    /// the coordinator's live-call reading stops saying the call is up.
    func test_a_vanished_mic_reaches_the_engine_as_unknown_END17() throws {
        let micReading = LockedBox<Bool?>(true)
        let micCrank = Crank()
        let mic = ProcessAudioSignal(
            halBus: CoreAudioHALBus(),
            probe: { _, _ in micReading.get() },
            scheduler: { _, action in micCrank.tick = action; return { micCrank.tick = nil } },
            resolver: { _ in .resolved([9999]) }
        )
        let adapter = NativeLifecycleAdapter(
            config: .teams,
            processAudio: mic,
            shareableContent: ShareableContentSignal(probe: { [] }, scheduler: { _, _ in { } }),
            axLeaveButton: AXLeaveButtonSignal(axBus: AXObserverBus(), probe: { _ in .healthy }, scheduler: { _, _ in { } }),
            workspace: quietWorkspace()
        )
        var events: [PrimarySignalEvent] = []
        try adapter.start(context: teams, handle: LifecycleAdapterHandle()) { events.append($0) }
        micReading.set(nil)
        micCrank.tick?()
        let micStates = events.filter { $0.kind == .processAudioIsRunningInput }.map(\.state)
        XCTAssertEqual(micStates, [.live, .unknown])
        adapter.stop()
    }

    private func drain(_ coordinator: MeetingLifecycleCoordinator) {
        let done = expectation(description: "drain")
        coordinator.tick()
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.05) { done.fulfill() }
        wait(for: [done], timeout: 2)
    }
}
