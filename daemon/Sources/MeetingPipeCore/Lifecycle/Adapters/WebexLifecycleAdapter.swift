import ApplicationServices
import Foundation

/// Webex adapter. PRIMARY set is ShareableContent + AXLeaveButton
/// only; `ProcessAudio` is deliberately excluded because Cisco
/// documents that Webex holds the microphone open after meetings
/// end for ultrasound-based device discovery (Cisco Devices feature),
/// which would otherwise produce a false `process_audio = live`
/// reading well past the meeting end.
///
/// Bundle IDs cover both the legacy `com.cisco.webexmeetingsapp`
/// and the unified Webex App (`com.cisco.spark` per Cisco's
/// documentation; the unified app's identifier should be verified
/// against the user's actual install at runtime per the TECH-C13
/// stop-and-ask trigger).
public final class WebexLifecycleAdapter: LifecycleAdapter {

    public let bundleIDs: Set<String> = ["com.cisco.webexmeetingsapp", "com.cisco.spark"]
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
        shareableContent.start(context: context, titleMatch: MeetingTitlePatterns.webex)
        if let leaveButton = handle.leaveButton {
            try axLeaveButton.start(context: context, leaveButton: leaveButton)
        }
    }

    public func stop() {
        shareableContent.stop()
        axLeaveButton.stop()
    }
}
