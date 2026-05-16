import Foundation

/// Google Meet adapter. Meet is browser-hosted only and exposes no
/// public per-tab mic-mute API as of macOS 14-15, so the adapter
/// provides no AX evidence. MicGate falls through to HAL VAD + RMS
/// for these contexts, producing `.silentByRMS` when the user isn't
/// speaking and `.hot` otherwise. The adapter still registers so the
/// coordinator can record the context in events.jsonl and so the
/// shape stays consistent with the other clients.
///
/// Browser bundle IDs are deliberately broad: Meet runs in any
/// Chromium / WebKit / Gecko browser the user prefers.
public final class MeetMuteAdapter: MicGateAdapter {
    public let bundleIDs: Set<String> = [
        "com.google.Chrome",
        "com.microsoft.edgemac",
        "company.thebrowser.Browser",
        "com.apple.Safari",
        "org.mozilla.firefox"
    ]
    public let app: String = "meet"

    private let eventLog: EventLog

    public init(eventLog: EventLog = NoopEventLog()) {
        self.eventLog = eventLog
    }

    public func start(
        context: MeetingLifecycleContext,
        handle: MicGateAdapterHandle,
        sink: @escaping (AXMuteButtonProbe.Event) -> Void
    ) throws {
        eventLog.emit(category: "micgate", action: "meet_adapter_no_ax_signal", attributes: [
            "bundle_id": context.bundleID
        ])
    }

    public func stop() {}
}
