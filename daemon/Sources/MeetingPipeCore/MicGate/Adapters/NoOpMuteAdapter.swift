import Foundation

/// Configuration record for a browser-hosted meeting surface with no AX mute signal.
public struct NoOpMuteConfig {
    public let bundleIDs: Set<String>
    /// MuteLabels TOML app key, also the events.jsonl surface tag.
    public let app: String
    /// `micgate` event action emitted at `start` so dogfood analysis
    /// can tell the no-AX surfaces apart.
    public let logAction: String

    public init(bundleIDs: Set<String>, app: String, logAction: String) {
        self.bundleIDs = bundleIDs
        self.app = app
        self.logAction = logAction
    }
}

public extension NoOpMuteConfig {
    /// Browser bundle IDs are deliberately broad: a meeting runs in any
    /// Chromium / WebKit / Gecko browser the user prefers.
    static let browserBundleIDs: Set<String> = [
        "com.google.Chrome",
        "com.microsoft.edgemac",
        "company.thebrowser.Browser",
        "com.apple.Safari",
        "org.mozilla.firefox"
    ]

    /// Google Meet: browser-hosted, no per-tab mic API on macOS 14-15.
    static let meet = NoOpMuteConfig(
        bundleIDs: browserBundleIDs, app: "meet",
        logAction: "meet_adapter_no_ax_signal"
    )

    /// Any other in-browser meeting surface (Teams web, Webex web,
    /// Slack PWA huddles) the lifecycle coordinator routes here.
    static let browser = NoOpMuteConfig(
        bundleIDs: browserBundleIDs, app: "browser",
        logAction: "browser_adapter_no_ax_signal"
    )
}

/// MicGate adapter for browser-hosted meetings. Browsers expose no per-tab mic state, so `start` logs the context and MicGate falls through to HAL VAD + RMS. Replaces the byte-identical MeetMuteAdapter / BrowserMuteAdapter pair.
public final class NoOpMuteAdapter: MicGateAdapter {
    public var bundleIDs: Set<String> { config.bundleIDs }
    public var app: String { config.app }

    private let config: NoOpMuteConfig
    private let eventLog: EventLog

    public init(config: NoOpMuteConfig, eventLog: EventLog = NoopEventLog()) {
        self.config = config
        self.eventLog = eventLog
    }

    public func start(
        context: MeetingLifecycleContext,
        handle: MicGateAdapterHandle,
        sink: @escaping (AXMuteButtonProbe.Event) -> Void
    ) throws {
        eventLog.emit(category: "micgate", action: config.logAction, attributes: [
            "bundle_id": context.bundleID
        ])
    }

    public func stop() {}
}
