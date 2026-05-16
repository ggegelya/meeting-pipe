import ApplicationServices
import Foundation

/// Native Slack adapter for huddle lifecycle (TECH-C12).
///
/// Slack huddles do not expose a stable AX Leave button that fires
/// `kAXUIElementDestroyedNotification` reliably. The adapter falls
/// back to ShareableContent on the Slack window title plus an
/// optional `kAXUIElementDestroyedNotification` subscription on the
/// huddle title-bar widget when the AX walk surfaces one.
///
/// The browser PWA case is handled by `BrowserMeetingLifecycleAdapter`
/// through the `slackHuddle` title matcher; this adapter covers the
/// native `com.tinyspeck.slackmacgap` install.
public final class SlackLifecycleAdapter: LifecycleAdapter {

    public let bundleIDs: Set<String> = ["com.tinyspeck.slackmacgap"]
    public let kind: MeetingLifecycleContext.Kind = .native

    private let shareableContent: ShareableContentSignal
    private let axLeaveButton: AXLeaveButtonSignal

    public init(
        axBus: AXObserverBus,
        eventLog: EventLog = NoopEventLog()
    ) {
        self.shareableContent = ShareableContentSignal(eventLog: eventLog)
        self.axLeaveButton = AXLeaveButtonSignal(axBus: axBus, eventLog: eventLog)
    }

    public func start(
        context: MeetingLifecycleContext,
        handle: LifecycleAdapterHandle,
        sink: @escaping (PrimarySignalEvent) -> Void
    ) throws {
        shareableContent.onChange = { present in
            sink(PrimarySignalEvent(
                kind: .shareableContentWindow,
                state: present ? .live : .ended,
                timestamp: Date(),
                context: context
            ))
        }
        axLeaveButton.onChange = { state in
            sink(PrimarySignalEvent(
                kind: .axLeaveButton,
                state: state == .invalid ? .ended : .live,
                timestamp: Date(),
                context: context
            ))
        }
        shareableContent.start(
            context: context,
            titleMatch: MeetingTitlePatterns.slackHuddle
        )
        if let leaveButton = handle.leaveButton {
            try axLeaveButton.start(context: context, leaveButton: leaveButton)
        }
    }

    public func stop() {
        shareableContent.stop()
        axLeaveButton.stop()
    }
}
