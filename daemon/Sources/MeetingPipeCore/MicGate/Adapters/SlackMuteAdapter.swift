import Foundation

public final class SlackMuteAdapter: MicGateAdapter {
    public let bundleIDs: Set<String> = ["com.tinyspeck.slackmacgap"]
    public let app: String = "slack"

    private let probe: AXMuteButtonProbe

    public init(
        axBus: AXObserverBus,
        catalogue: MuteLabels,
        eventLog: EventLog = NoopEventLog()
    ) {
        self.probe = AXMuteButtonProbe(
            app: app, axBus: axBus, catalogue: catalogue, eventLog: eventLog
        )
    }

    public func start(
        context: MeetingLifecycleContext,
        handle: MicGateAdapterHandle,
        sink: @escaping (AXMuteButtonProbe.Event) -> Void
    ) throws {
        probe.onChange = sink
        if let button = handle.muteButton {
            try probe.start(pid: context.pid, bundleID: context.bundleID, button: button)
        }
    }

    public func stop() {
        probe.stop()
    }
}
