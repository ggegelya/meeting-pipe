import Foundation

/// Configuration record for a native meeting client with an AX mute button. Collapses the byte-identical Teams/Zoom/Webex/Slack adapters into a data row.
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

/// MicGate adapter for native clients with an AX mute button. Per-app differences live in `NativeAppMuteConfig`.
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

    /// Test seam (MIC20): an injected probe, so a test can drive the held flag through the adapter
    /// and watch it land on the probe. Without it the protocol's no-op default could stand in for
    /// `setEndHeld` below and every test would stay green.
    init(config: NativeAppMuteConfig, probe: AXMuteButtonProbe) {
        self.config = config
        self.probe = probe
    }

    public func start(
        context: MeetingLifecycleContext,
        handle: MicGateAdapterHandle,
        sink: @escaping (AXMuteButtonProbe.Event) -> Void
    ) throws {
        probe.onChange = sink
        // Returns at once: the probe subscribes and reads on its own queue (PERF10).
        if let button = handle.muteButton {
            probe.start(
                pid: context.pid,
                bundleID: context.bundleID,
                button: button,
                resolveElement: handle.resolveMuteButton
            )
        }
    }

    public func stop() {
        probe.stop()
    }

    public func setEndHeld(_ held: Bool) {
        probe.setEndHeld(held)
    }
}
