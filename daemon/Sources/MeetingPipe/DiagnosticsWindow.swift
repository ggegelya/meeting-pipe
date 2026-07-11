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
            let wasHidden = !w.isVisible
            w.makeKeyAndOrderFront(nil)
            NSApp.activate(ignoringOtherApps: true)
            if wasHidden { WindowActivationManager.shared.didShowWindow() }
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

        let delegate = DiagnosticsWindowDelegate { [weak self] in
            self?.window = nil
            WindowActivationManager.shared.didCloseWindow()
        }
        objc_setAssociatedObject(w, &Self.delegateKey, delegate, .OBJC_ASSOCIATION_RETAIN)
        w.delegate = delegate

        self.window = w
        w.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
        WindowActivationManager.shared.didShowWindow()
    }

    private static var delegateKey: UInt8 = 0
}

private final class DiagnosticsWindowDelegate: NSObject, NSWindowDelegate {
    private let onClose: () -> Void
    init(onClose: @escaping () -> Void) { self.onClose = onClose }
    func windowWillClose(_ notification: Notification) { onClose() }
}
