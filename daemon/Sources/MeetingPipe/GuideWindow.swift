import AppKit
import SwiftUI

/// The read-only user-guide window (DOC11), opened from the menu bar's
/// **Guide…**. One window at a time; re-opening brings it to front. Modeled on
/// `DiagnosticsWindow`, including the `WindowActivationManager` handshake that
/// keeps Cmd+Tab working while it is up.
final class GuideWindow {
    private var window: NSWindow?

    func show() {
        if let w = window {
            // The manager owns the policy flip, the deferred front + activate, and the deminiaturize, and counts by window identity (UX39).
            WindowActivationManager.shared.showWindow(w)
            return
        }

        let host = NSHostingController(rootView: MPControlAccent(GuideView()))
        let w = NSWindow(contentViewController: host)
        w.title = "MeetingPipe Guide"
        w.styleMask = [.titled, .closable, .miniaturizable, .resizable]
        // Wide enough that the document column actually reaches
        // `SummaryLayout.readingMeasure`: rail + divider + measure + both
        // gutters is 220 + 1 + 720 + 40 = 981. At the 940 DOC11 shipped, the
        // column resolved ~40pt short and every paragraph wrapped early, which
        // is a strange way to read a document on a 1440pt screen.
        w.setContentSize(NSSize(width: 1000, height: 700))
        // Below the reading measure plus the section rail the columns start
        // fighting, so the floor is the width the content actually asks for.
        w.contentMinSize = NSSize(width: 720, height: 420)
        w.setFrameAutosaveName("MeetingPipeGuideWindow")
        if w.frame.origin == .zero { w.center() }
        w.isReleasedWhenClosed = false

        let delegate = GuideWindowDelegate { [weak self] closing in
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

private final class GuideWindowDelegate: NSObject, NSWindowDelegate {
    private let onClose: (NSWindow) -> Void
    init(onClose: @escaping (NSWindow) -> Void) { self.onClose = onClose }
    // The window is read off the notification because it retains this delegate; capturing it would be a cycle.
    func windowWillClose(_ notification: Notification) {
        guard let closing = notification.object as? NSWindow else { return }
        onClose(closing)
    }
}
