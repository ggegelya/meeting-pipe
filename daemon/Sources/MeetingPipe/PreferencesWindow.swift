import AppKit
import SwiftUI

/// Preferences window (TECH-E4: a NavigationSplitView, replaced the old 540x620 TabView; opens at 820x660 with a 780x660 floor since UX43). One window at a time; re-opening brings it to front. Owns the `NSWindow` lifecycle and the `WindowActivationManager` handshake so Cmd+Tab works while Preferences is up. `LocalModelPreset` lives here so callers don't need to import the Preferences/ folder.
final class PreferencesWindow {
    private var window: NSWindow?
    private let store: ConfigStore
    private let secrets: SecretsStore
    /// Read by the Storage section to attribute library bytes to retention policies (STOR1).
    private let workflows: WorkflowStore
    /// Shared selection state for `show(initial:)` deeplinks.
    private let selectionState = PreferencesSelectionState()
    /// UX60: how the Permissions pane reaches the daemon's shared model-download
    /// supervisor, for the regulated-mode group's inline "Download now".
    ///
    /// A provider rather than a value because `Coordinator` builds this window
    /// inside its own `init`, where `configRefresh` (a `lazy var`) cannot be
    /// touched yet; the coordinator sets it once it is up. Resolved when the
    /// window is built, which is enough: `LocalModelPreflight` is a struct of
    /// closures that read live state on each call.
    var localModelPreflightProvider: (() -> LocalModelPreflight?)?

    init(store: ConfigStore, secrets: SecretsStore, workflows: WorkflowStore) {
        self.store = store
        self.secrets = secrets
        self.workflows = workflows
    }

    /// Open the window, optionally deeplinking to `initial`. Idempotent: re-call brings the existing window to front.
    ///
    /// `vocabularyScope` (UX44) additionally asks the Pipeline pane's Vocabulary editor to
    /// preselect that workflow, which is what the workflow sheet's "Vocabulary…" link
    /// needs: without it the link lands the user in the same picker they just left a
    /// workflow to reach. Set before the window is built and before it is brought
    /// forward, for the same reason `initial` is: the pane may already be on screen, in
    /// which case the published change is the only thing that moves it.
    func show(initial: PreferencesItem? = nil, vocabularyScope: String? = nil) {
        if let scope = vocabularyScope {
            selectionState.pendingVocabularyScope = scope
        }
        if let item = initial {
            selectionState.current = item
        }

        if let w = window {
            // Policy flip, deferred front + activate, and deminiaturize all live in the manager, which counts by window identity so a re-open of a minimized window cannot drift the count (UX39).
            WindowActivationManager.shared.showWindow(w)
            return
        }

        let view = PreferencesView(
            store: store,
            secrets: secrets,
            workflows: workflows,
            selectionState: selectionState,
            localModelPreflight: localModelPreflightProvider?()
        )
        let host = NSHostingController(rootView: MPControlAccent(view))
        let w = NSWindow(contentViewController: host)
        w.title = "MeetingPipe Preferences"
        // Resizable: benefits from extra width for long Notion DB IDs.
        w.styleMask = [.titled, .closable, .miniaturizable, .resizable]
        // 820 wide, not the 780 floor below (UX43, owner call 2026-08-03): the sidebar
        // and the detail pane's 32pt gutters take ~200 of the width, so at 780 the pane
        // could offer ~515pt to content designed to read at 620. Opening at 820 is what
        // makes that measure reachable without the user resizing first.
        w.setContentSize(NSSize(width: 820, height: 660))
        // UX43: the floor is the SwiftUI root's own `.frame(minWidth:minHeight:)`
        // (`PreferencesView`). It used to be 720x560, so the window could be resized
        // below the size the hierarchy inside it declares as its minimum, and the
        // squeeze landed on the control columns ("Choose destination…" truncated).
        // `contentMinSize`, not `minSize`: the latter is frame-space, so 660 there
        // would still allow a content box a title bar shorter than the root demands.
        w.contentMinSize = NSSize(width: 780, height: 660)
        // Bound the window to the screen so a wide control can never push it
        // off-screen (regression seen when the 4-option backend picker stretched
        // the Pipeline tab). Still resizable within the screen for long IDs.
        if let visible = NSScreen.main?.visibleFrame.size {
            w.maxSize = NSSize(width: visible.width, height: visible.height)
        }
        w.isReleasedWhenClosed = false
        w.center()

        let delegate = PreferencesWindowDelegate { [weak self] closing in
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

private final class PreferencesWindowDelegate: NSObject, NSWindowDelegate {
    private let onClose: (NSWindow) -> Void
    init(onClose: @escaping (NSWindow) -> Void) { self.onClose = onClose }
    // Read the closing window off the notification: this delegate is retained by that window, so capturing it in the closure would be a cycle.
    func windowWillClose(_ notification: Notification) {
        guard let closing = notification.object as? NSWindow else { return }
        onClose(closing)
    }
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

    // Small / Recommended / Large map to 3B / 7B / 14B (LOCAL6). The picker
    // matches the stored model id against `modelId`, so a config still holding
    // the dropped 32B id falls through to "Custom" with the id intact rather
    // than being silently rewritten.
    static let all: [LocalModelPreset] = [
        LocalModelPreset(
            id: "small",
            label: "Small (Qwen 3B-4bit)",
            modelId: "mlx-community/Qwen2.5-3B-Instruct-4bit",
            diskHint: "~2 GB",
            speedHint: "~10s per meeting",
            qualityHint: "Fastest, smallest download; lower quality (1 failure over the test corpus)."
        ),
        LocalModelPreset(
            id: "recommended",
            label: "Recommended (Qwen 7B-4bit)",
            modelId: "mlx-community/Qwen2.5-7B-Instruct-4bit",
            diskHint: "~4.3 GB",
            speedHint: "~30-90s per meeting",
            qualityHint: "The engine-comparison sweet spot: on par with the 14B on capture, names owners, memory-safe, zero failures."
        ),
        LocalModelPreset(
            id: "large",
            label: "Large (Qwen 14B-4bit)",
            modelId: "mlx-community/Qwen2.5-14B-Instruct-4bit",
            diskHint: "~8 GB",
            speedHint: "~45-130s per meeting",
            // The RAM claim that used to live in this string ("wants 24 GB+ RAM (can OOM on 16 GB)") is now derived per machine by `LocalModelTier` and rendered beside the row (LOCAL16), so the picker states the limit for the Mac in front of the user rather than for a generic one.
            qualityHint: "Highest quality of the curated presets, but the heaviest to run."
        ),
    ]

    // MARK: - Picker seam (UX43)
    //
    // The four rules the Local model picker runs on, pure so they are testable
    // without a view or a config. They exist because Custom used to be a dead
    // option: the binding derived its selection from the stored id alone and its
    // setter dropped the Custom tag, so picking Custom wrote nothing, the getter
    // re-derived the previous preset, and the Model id field that Custom is
    // supposed to reveal could never appear.

    /// The selection a stored model id implies: the preset that pins it, else Custom.
    /// The fall-through is deliberate (a config holding the dropped 32B id keeps it,
    /// intact, rather than being silently rewritten), and it is the only reason the
    /// Custom row existed at all before it could be selected.
    static func id(forModelId modelId: String) -> String {
        all.first { $0.modelId == modelId }?.id ?? customId
    }

    /// What selecting `id` writes to `summarization.local_model`, or nil for Custom,
    /// which writes nothing on its own: the Model id field beside it is the writer.
    static func modelId(forID id: String) -> String? {
        all.first { $0.id == id }?.modelId
    }

    /// Whether the Model id field is shown for a selection. Derived from
    /// `modelId(forID:)` rather than compared against `customId` a second time, so
    /// the field is revealed for exactly the selections that write nothing on their
    /// own. The two cannot drift apart into a selection that neither writes nor
    /// offers a field, which is what the dead branch was.
    static func showsModelIdField(forID id: String) -> Bool {
        modelId(forID: id) == nil
    }

    /// The id a typed Custom field should persist, or nil while it is not usable yet.
    /// `ModelIdField.persistable`, which every typed model-id field shares.
    static func persistableModelId(_ typed: String) -> String? {
        ModelIdField.persistable(typed)
    }
}

/// The rule every typed model-id field in Preferences persists through: the local
/// model's Custom field (UX43) and the Anthropic model row. Pure so it is testable
/// without a view or a config.
enum ModelIdField {
    /// The id a typed field should persist, or nil while it is not usable yet.
    /// Trimmed, because a pasted id carries whitespace. Blank is nil rather than an
    /// empty write: `ConfigStore`'s save is debounced 500 ms, so a field cleared on
    /// the way to a new value would otherwise be persisted as no model at all.
    static func persistable(_ typed: String) -> String? {
        let trimmed = typed.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }
}
