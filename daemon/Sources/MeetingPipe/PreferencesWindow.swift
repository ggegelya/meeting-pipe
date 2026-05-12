import AppKit
import SwiftUI

/// SwiftUI Preferences window opened from the menu bar.
///
/// One window at a time — re-opening the menu item brings the existing
/// window to the front rather than stacking duplicates. The window's
/// actual content lives in `PreferencesView`
/// (`Preferences/PreferencesView.swift`); this class only owns the
/// `NSWindow` lifecycle and the WindowActivationManager handshake so
/// Cmd+Tab keeps working when Preferences is up.
///
/// TECH-E4 swapped the old 540×620 six-tab `TabView` for a 780×660
/// NavigationSplitView with a sidebar. The model presets table used by
/// the Pipeline section still lives here so callers can reach it
/// without crossing into the Preferences/ folder for one struct.
final class PreferencesWindow {
    private var window: NSWindow?
    private let store: ConfigStore
    private let secrets: SecretsStore

    init(store: ConfigStore, secrets: SecretsStore) {
        self.store = store
        self.secrets = secrets
    }

    func show() {
        if let w = window {
            let wasHidden = !w.isVisible
            w.makeKeyAndOrderFront(nil)
            NSApp.activate(ignoringOtherApps: true)
            if wasHidden { WindowActivationManager.shared.didShowWindow() }
            return
        }

        let view = PreferencesView(store: store, secrets: secrets)
        let host = NSHostingController(rootView: view)
        let w = NSWindow(contentViewController: host)
        w.title = "MeetingPipe Preferences"
        // Resizable now — the sidebar layout works at 780×660 default but
        // benefits from a little extra width on long Notion DB ids.
        w.styleMask = [.titled, .closable, .miniaturizable, .resizable]
        w.setContentSize(NSSize(width: 780, height: 660))
        w.minSize = NSSize(width: 720, height: 560)
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

/// Curated MLX model presets for the Pipeline section's Picker.
///
/// Three sizes that span the practical sweet-spot for meeting
/// summarization on M-series hardware. Larger models exist; users who
/// want them pick "Custom" and paste a HuggingFace MLX repo id directly.
struct LocalModelPreset {
    let id: String          // Stable picker tag.
    let label: String       // Human-readable menu entry.
    let modelId: String     // HuggingFace repo id `mlx-community/...`.
    let diskHint: String    // Approx download / cache footprint.
    let speedHint: String   // Rough per-meeting latency on M-series.
    let qualityHint: String // One-line vibes-summary of expected output quality.

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
