import Foundation

public final class WebexMuteAdapter: MicGateAdapter {
    public let bundleIDs: Set<String> = ["com.cisco.webexmeetingsapp", "com.cisco.spark"]
    public let app: String = "webex"

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
