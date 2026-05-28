import AppKit
import Foundation

/// App-termination PRIMARY signal. Wires `NSWorkspaceDidTerminateApplicationNotification` (filtered by
/// bundle ID) plus `NSRunningApplication.isTerminated` KVO to cover the race where the app quits before
/// the notification observer is registered. Threading: `start`/`stop` and all callbacks on main.
public final class WorkspaceSignal {

    public typealias Probe = (String) -> NSRunningApplication?

    public var onTerminated: ((MeetingLifecycleContext) -> Void)?
    public private(set) var terminated: Bool = false

    private let eventLog: EventLog
    private let probe: Probe
    private let notificationCenter: NotificationCenter

    private var observer: NSObjectProtocol?
    private var runningApp: NSRunningApplication?
    private var kvoObservation: NSKeyValueObservation?
    private var context: MeetingLifecycleContext?

    public init(
        eventLog: EventLog = NoopEventLog(),
        probe: @escaping Probe = WorkspaceSignal.defaultProbe,
        notificationCenter: NotificationCenter = NSWorkspace.shared.notificationCenter
    ) {
        self.eventLog = eventLog
        self.probe = probe
        self.notificationCenter = notificationCenter
    }

    public func start(context: MeetingLifecycleContext) {
        stop()
        self.context = context
        self.terminated = false

        observer = notificationCenter.addObserver(
            forName: NSWorkspace.didTerminateApplicationNotification,
            object: nil,
            queue: .main
        ) { [weak self] note in
            guard let self = self else { return }
            guard let app = note.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication else { return }
            if app.bundleIdentifier == context.bundleID {
                self.handleTerminated(reason: "workspace_notification")
            }
        }

        if let app = probe(context.bundleID) {
            self.runningApp = app
            kvoObservation = app.observe(\.isTerminated, options: [.initial, .new]) { [weak self] app, _ in
                guard let self = self else { return }
                if app.isTerminated { self.handleTerminated(reason: "running_application_kvo") }
            }
        }
    }

    public func stop() {
        if let observer = observer { notificationCenter.removeObserver(observer); self.observer = nil }
        kvoObservation?.invalidate(); kvoObservation = nil
        runningApp = nil
        context = nil
        terminated = false
    }

    func handleTerminated(reason: String) {
        guard let context = context, !terminated else { return }
        terminated = true
        eventLog.emit(category: "signal", action: "workspace_app_terminated", attributes: [
            "bundle_id": context.bundleID,
            "reason": reason
        ])
        onTerminated?(context)
    }

    public static let defaultProbe: Probe = { bundleID in
        NSRunningApplication.runningApplications(withBundleIdentifier: bundleID).first
    }
}
