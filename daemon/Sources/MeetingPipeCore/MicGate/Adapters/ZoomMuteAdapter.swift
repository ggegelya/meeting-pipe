import Foundation

public final class ZoomMuteAdapter: MicGateAdapter {
    public let bundleIDs: Set<String> = ["us.zoom.xos"]
    public let app: String = "zoom"

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
