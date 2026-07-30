import AppKit
import SwiftUI

/// The read-only Diagnostics window (UX20). One window at a time; re-opening
/// brings it to front. Owns the `NSWindow` lifecycle and the
/// `WindowActivationManager` handshake so Cmd+Tab works while it is up. Modeled
/// on `PreferencesWindow`.
final class DiagnosticsWindow {
    private var window: NSWindow?

    func show() {
        if let w = window {
            // The manager owns the policy flip, the deferred front + activate, and the deminiaturize, and counts by window identity (UX39).
            WindowActivationManager.shared.showWindow(w)
            return
        }

        let host = NSHostingController(rootView: MPControlAccent(DiagnosticsView()))
        let w = NSWindow(contentViewController: host)
        w.title = "MeetingPipe Diagnostics"
        w.styleMask = [.titled, .closable, .miniaturizable, .resizable]
        w.setContentSize(NSSize(width: 820, height: 560))
        w.minSize = NSSize(width: 640, height: 400)
        w.setFrameAutosaveName("MeetingPipeDiagnosticsWindow")
        if w.frame.origin == .zero { w.center() }
        w.isReleasedWhenClosed = false

        let delegate = DiagnosticsWindowDelegate { [weak self] closing in
            self?.window = nil
            WindowActivationManager.shared.didCloseWindow(closing)
        }
        objc_setAssociatedObject(w, &Self.delegateKey, delegate, .OBJC_ASSOCIATION_RETAIN)
        w.delegate = delegate

        self.window = w
        WindowActivationManager.shared.showWindow(w)
    }

    private static var delegateKey: UInt8 = 0
}

private final class DiagnosticsWindowDelegate: NSObject, NSWindowDelegate {
    private let onClose: (NSWindow) -> Void
    init(onClose: @escaping (NSWindow) -> Void) { self.onClose = onClose }
    // The window is read off the notification because it retains this delegate; capturing it would be a cycle.
    func windowWillClose(_ notification: Notification) {
        guard let closing = notification.object as? NSWindow else { return }
        onClose(closing)
    }
}
