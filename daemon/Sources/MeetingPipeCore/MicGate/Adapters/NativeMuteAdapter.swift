import Foundation

/// One native meeting client that exposes an AX mute button, described
/// as data for `NativeMuteAdapter`. Collapses the byte-identical Teams /
/// Zoom / Webex / Slack mute adapters into a row.
public struct NativeAppMuteConfig {
    public let bundleIDs: Set<String>
    /// MuteLabels TOML app key (`"teams"`, `"zoom"`, `"webex"`, `"slack"`).
    public let app: String

    public init(bundleIDs: Set<String>, app: String) {
        self.bundleIDs = bundleIDs
        self.app = app
    }
}

public extension NativeAppMuteConfig {
    static let teams = NativeAppMuteConfig(
        bundleIDs: ["com.microsoft.teams2", "com.microsoft.teams"], app: "teams"
    )
    static let zoom = NativeAppMuteConfig(bundleIDs: ["us.zoom.xos"], app: "zoom")
    static let webex = NativeAppMuteConfig(
        bundleIDs: ["com.cisco.webexmeetingsapp", "com.cisco.spark"], app: "webex"
    )
    static let slack = NativeAppMuteConfig(
        bundleIDs: ["com.tinyspeck.slackmacgap"], app: "slack"
    )
}

/// MicGate adapter for native meeting clients that expose an AX mute
/// button. One parameterized class in place of the byte-identical
/// Teams / Zoom / Webex / Slack mute adapters; the per-app differences
/// live in `NativeAppMuteConfig`.
public final class NativeMuteAdapter: MicGateAdapter {
    public var bundleIDs: Set<String> { config.bundleIDs }
    public var app: String { config.app }

    private let config: NativeAppMuteConfig
    private let probe: AXMuteButtonProbe

    public init(
        config: NativeAppMuteConfig,
        axBus: AXObserverBus,
        catalogue: MuteLabels,
        eventLog: EventLog = NoopEventLog()
    ) {
        self.config = config
        self.probe = AXMuteButtonProbe(
            app: config.app, axBus: axBus, catalogue: catalogue, eventLog: eventLog
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
