import Foundation

/// Generic browser-hosted MicGate adapter. Same shape as
/// `MeetMuteAdapter`: no AX mute signal because browsers don't
/// expose per-tab mic state. Picks up Teams web, Webex web, Slack
/// PWA huddles, and any other in-browser meeting surface that the
/// lifecycle coordinator routes here.
///
/// Distinguished from `MeetMuteAdapter` only by the `app` key so
/// events.jsonl can tell the surfaces apart for dogfood analysis.
public final class BrowserMuteAdapter: MicGateAdapter {
    public let bundleIDs: Set<String> = [
        "com.google.Chrome",
        "com.microsoft.edgemac",
        "company.thebrowser.Browser",
        "com.apple.Safari",
        "org.mozilla.firefox"
    ]
    public let app: String = "browser"

    private let eventLog: EventLog

    public init(eventLog: EventLog = NoopEventLog()) {
        self.eventLog = eventLog
    }

    public func start(
        context: MeetingLifecycleContext,
        handle: MicGateAdapterHandle,
        sink: @escaping (AXMuteButtonProbe.Event) -> Void
    ) throws {
        eventLog.emit(category: "micgate", action: "browser_adapter_no_ax_signal", attributes: [
            "bundle_id": context.bundleID
        ])
    }

    public func stop() {}
}
