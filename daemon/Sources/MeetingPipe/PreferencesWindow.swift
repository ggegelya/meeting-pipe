import AppKit
import SwiftUI

/// Preferences window (TECH-E4: 780x660 NavigationSplitView, replaced the old 540x620 TabView). One window at a time; re-opening brings it to front. Owns the `NSWindow` lifecycle and the `WindowActivationManager` handshake so Cmd+Tab works while Preferences is up. `LocalModelPreset` lives here so callers don't need to import the Preferences/ folder.
final class PreferencesWindow {
    private var window: NSWindow?
    private let store: ConfigStore
    private let secrets: SecretsStore
    /// Shared selection state for `show(initial:)` deeplinks.
    private let selectionState = PreferencesSelectionState()

    init(store: ConfigStore, secrets: SecretsStore) {
        self.store = store
        self.secrets = secrets
    }

    /// Open the window, optionally deeplinking to `initial`. Idempotent: re-call brings the existing window to front.
    func show(initial: PreferencesItem? = nil) {
        if let item = initial {
            selectionState.current = item
        }

        if let w = window {
            let wasHidden = !w.isVisible
            w.makeKeyAndOrderFront(nil)
            NSApp.activate(ignoringOtherApps: true)
            if wasHidden { WindowActivationManager.shared.didShowWindow() }
            return
        }

        let view = PreferencesView(
            store: store,
            secrets: secrets,
            selectionState: selectionState
        )
        let host = NSHostingController(rootView: view)
        let w = NSWindow(contentViewController: host)
        w.title = "MeetingPipe Preferences"
        // Resizable: benefits from extra width for long Notion DB IDs.
        w.styleMask = [.titled, .closable, .miniaturizable, .resizable]
        w.setContentSize(NSSize(width: 780, height: 660))
        w.minSize = NSSize(width: 720, height: 560)
        // Bound the window to the screen so a wide control can never push it
        // off-screen (regression seen when the 4-option backend picker stretched
        // the Pipeline tab). Still resizable within the screen for long IDs.
        if let visible = NSScreen.main?.visibleFrame.size {
            w.maxSize = NSSize(width: visible.width, height: visible.height)
        }
        w.isReleasedWhenClosed = false
        w.center()

        let delegate = PreferencesWindowDelegate { [weak self] in
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

private final class PreferencesWindowDelegate: NSObject, NSWindowDelegate {
    private let onClose: () -> Void
    init(onClose: @escaping () -> Void) { self.onClose = onClose }
    func windowWillClose(_ notification: Notification) { onClose() }
}

/// Curated MLX model presets for the Pipeline picker. Three sizes covering the practical range on M-series; "Custom" accepts any HuggingFace MLX repo id.
struct LocalModelPreset {
    let id: String
    let label: String
    let modelId: String     // HuggingFace repo id `mlx-community/...`
    let diskHint: String    // Approx download / cache footprint
    let speedHint: String   // Rough per-meeting latency on M-series
    let qualityHint: String

    static let customId = "__custom"

    static let all: [LocalModelPreset] = [
        LocalModelPreset(
            id: "small",
            label: "Small (Qwen 3B-4bit)",
            modelId: "mlx-community/Qwen2.5-3B-Instruct-4bit",
            diskHint: "~2 GB",
            speedHint: "~10s per meeting",
            qualityHint: "Fast first run, lower quality. Good default to try local mode."
        ),
        LocalModelPreset(
            id: "recommended",
            label: "Recommended (Qwen 14B-4bit)",
            modelId: "mlx-community/Qwen2.5-14B-Instruct-4bit",
            diskHint: "~8 GB",
            speedHint: "~45-130s per meeting",
            qualityHint: "Better decisions and action item discipline."
        ),
        LocalModelPreset(
            id: "large",
            label: "Large (Qwen 32B-4bit)",
            modelId: "mlx-community/Qwen2.5-32B-Instruct-4bit",
            diskHint: "~18 GB",
            speedHint: "~2-4 min per meeting",
            qualityHint: "Highest quality of the curated presets. Wants 32 GB+ RAM."
        ),
    ]
}
