import ApplicationServices
import Foundation

/// Zoom (us.zoom.xos) adapter. PRIMARY set matches Teams:
/// ShareableContent + ProcessAudio + AXLeaveButton.
public final class ZoomLifecycleAdapter: LifecycleAdapter {

    public let bundleIDs: Set<String> = ["us.zoom.xos"]
    public let kind: MeetingLifecycleContext.Kind = .native

    private let processAudio: ProcessAudioSignal
    private let shareableContent: ShareableContentSignal
    private let axLeaveButton: AXLeaveButtonSignal

    public init(
        halBus: CoreAudioHALBus,
        axBus: AXObserverBus,
        eventLog: EventLog = NoopEventLog()
    ) {
        self.processAudio = ProcessAudioSignal(halBus: halBus, eventLog: eventLog)
        self.shareableContent = ShareableContentSignal(eventLog: eventLog)
        self.axLeaveButton = AXLeaveButtonSignal(axBus: axBus, eventLog: eventLog)
    }

    public func start(
        context: MeetingLifecycleContext,
        handle: LifecycleAdapterHandle,
        sink: @escaping (PrimarySignalEvent) -> Void
    ) throws {
        processAudio.onChange = { value in
            sink(PrimarySignalEvent(
                kind: .processAudioIsRunningInput,
                state: value ? .live : .ended,
                timestamp: Date(),
                context: context
            ))
        }
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
        try processAudio.start(context: context)
        shareableContent.start(context: context, titleMatch: MeetingTitlePatterns.zoom)
        if let leaveButton = handle.leaveButton {
            try axLeaveButton.start(context: context, leaveButton: leaveButton)
        }
    }

    public func stop() {
        processAudio.stop()
        shareableContent.stop()
        axLeaveButton.stop()
    }
}
