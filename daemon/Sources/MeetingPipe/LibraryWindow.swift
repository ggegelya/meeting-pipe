import AppKit
import Combine
import SwiftUI

/// Three-pane Library window — the daemon's primary UI surface beyond
/// the menu bar. Shell only at TECH-A1: the sidebar is live and wired,
/// the content + detail panes show placeholders until A2 / A4 land.
///
/// Lifecycle mirrors `PreferencesWindow`: one instance held by the
/// Coordinator, `show()` brings it forward (creating once), Cmd+W hides
/// rather than releasing so the daemon keeps the configured frame.
final class LibraryWindow {
    private var window: NSWindow?
    private let model: LibraryWindowModel

    init(model: LibraryWindowModel) {
        self.model = model
    }

    func show() {
        if let w = window {
            w.makeKeyAndOrderFront(nil)
            NSApp.activate(ignoringOtherApps: true)
            return
        }

        let view = LibraryRootView(model: model)
            .environmentObject(model)
        let host = NSHostingController(rootView: view)
        let w = NSWindow(contentViewController: host)
        w.title = "MeetingPipe Library"
        w.styleMask = [.titled, .closable, .miniaturizable, .resizable]
        w.setContentSize(NSSize(width: 900, height: 600))
        w.minSize = NSSize(width: 720, height: 480)
        // Cmd+W (performClose:) on a window with isReleasedWhenClosed=false
        // orders it out without deallocating. The daemon keeps running and
        // the next `show()` brings the same window back with restored state.
        w.isReleasedWhenClosed = false
        // Persist size/origin across launches.
        w.setFrameAutosaveName("MeetingPipeLibraryWindow")
        // setFrameAutosaveName loads on first attach; if there's no saved
        // frame yet, center the window so first launch is not pinned to the
        // bottom-left corner.
        if !w.setFrameUsingName("MeetingPipeLibraryWindow") {
            w.center()
        }

        let delegate = LibraryWindowDelegate { [weak self] in
            // Don't null the reference — keeping it lets re-open restore
            // the same configured frame, and a freshly-built NSWindow would
            // lose any selection or scroll state once A2 / A4 land.
            _ = self
        }
        objc_setAssociatedObject(w, &Self.delegateKey, delegate, .OBJC_ASSOCIATION_RETAIN)
        w.delegate = delegate

        self.window = w
        w.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }

    private static var delegateKey: UInt8 = 0
}

private final class LibraryWindowDelegate: NSObject, NSWindowDelegate {
    private let onClose: () -> Void
    init(onClose: @escaping () -> Void) { self.onClose = onClose }
    func windowWillClose(_ notification: Notification) { onClose() }
}

// MARK: - Observable bridge

/// Mirrors the recording state machine into a SwiftUI-observable shape
/// so the Library's sidebar footer can show "Idle / Recording" + the
/// processing-queue badge + model-download progress without subscribing
/// directly to AppKit setters.
///
/// All mutations run on the main queue (matches Coordinator threading
/// — every public method on the Coordinator must already run on main).
final class LibraryWindowModel: ObservableObject {

    /// Display-only summary of `AppState`. We don't expose the full state
    /// because the UI never branches on the underlying URL / SummaryMode.
    enum Status: Equatable {
        case idle
        case prompting(appName: String)
        case recording(appName: String?)
        case stopping
    }

    @Published var status: Status = .idle
    @Published var processingCount: Int = 0
    @Published var modelDownload: ModelDownloadSupervisor.State = .idle
    /// Stem of the meeting currently being recorded (live wav write in
    /// flight). The list view uses this to render the matching row with
    /// a recording-tinted pulse — the on-disk status alone can't tell
    /// the difference between "wav still being written" and "wav done,
    /// pipeline running".
    @Published var liveRecordingStem: String? = nil

    /// Coordinator is held weakly so the model can drive menu actions
    /// (Start/Stop, Preferences) without creating a retain cycle.
    weak var coordinator: Coordinator?

    /// Backing store for the meetings list. Built once with the daemon's
    /// recordings directory; the list view subscribes to it.
    let meetingStore: MeetingStore

    init(coordinator: Coordinator? = nil, recordingsDir: URL) {
        self.coordinator = coordinator
        self.meetingStore = MeetingStore(recordingsDir: recordingsDir)
    }

    var isRecording: Bool {
        if case .recording = status { return true }
        return false
    }

    /// The recording toggle is enabled in every state except `.stopping`.
    /// During `.stopping` the recorder is mid-flush and a button press
    /// would race the async finalize.
    var canToggleRecording: Bool {
        if case .stopping = status { return false }
        return true
    }

    func toggleRecording() {
        coordinator?.menuStart()
    }

    func openPreferences() {
        coordinator?.menuPreferences()
    }

    /// Republish a meeting via the standard `mp publish-notion` subprocess.
    /// Wraps the Coordinator's callback in a Swift `async` shape so the
    /// SwiftUI editor can `await` the result and update its UI state.
    func republishMeeting(stem: String) async -> Result<URL?, Error> {
        guard let coordinator = coordinator else {
            return .failure(NSError(
                domain: "LibraryWindowModel", code: 1,
                userInfo: [NSLocalizedDescriptionKey: "Coordinator unavailable"]
            ))
        }
        return await withCheckedContinuation { (cont: CheckedContinuation<Result<URL?, Error>, Never>) in
            coordinator.republishMeeting(stem: stem) { result in
                cont.resume(returning: result)
            }
        }
    }

    /// Regenerate the summary for a meeting via `mp summarize` + republish.
    /// Same async wrapping pattern as `republishMeeting`.
    func regenerateMeeting(stem: String) async -> Result<URL?, Error> {
        guard let coordinator = coordinator else {
            return .failure(NSError(
                domain: "LibraryWindowModel", code: 1,
                userInfo: [NSLocalizedDescriptionKey: "Coordinator unavailable"]
            ))
        }
        return await withCheckedContinuation { (cont: CheckedContinuation<Result<URL?, Error>, Never>) in
            coordinator.regenerateMeeting(stem: stem) { result in
                cont.resume(returning: result)
            }
        }
    }

    /// Move every sidecar associated with a stem to the user's Trash.
    @discardableResult
    func softDeleteMeeting(stem: String) -> Result<Void, Error> {
        coordinator?.softDeleteMeeting(stem: stem) ?? .failure(NSError(
            domain: "LibraryWindowModel", code: 1,
            userInfo: [NSLocalizedDescriptionKey: "Coordinator unavailable"]
        ))
    }

    /// Copy the standard human-facing artefacts for a stem into the
    /// chosen destination folder.
    func exportMeeting(stem: String, to destination: URL) -> Result<Int, Error> {
        coordinator?.exportMeeting(stem: stem, to: destination) ?? .failure(NSError(
            domain: "LibraryWindowModel", code: 1,
            userInfo: [NSLocalizedDescriptionKey: "Coordinator unavailable"]
        ))
    }
}

// MARK: - Root view

/// Three-pane `NavigationSplitView`. Sidebar drives the top-level
/// section; the content column is the meetings list, and the detail
/// column is a placeholder until TECH-A4 lands.
struct LibraryRootView: View {
    @ObservedObject var model: LibraryWindowModel
    @State private var selection: LibrarySidebarItem = .library
    @State private var meetingSelection: Meeting.ID?

    var body: some View {
        NavigationSplitView {
            LibrarySidebar(selection: $selection, model: model)
        } content: {
            contentPane
        } detail: {
            detailPane
        }
        .navigationTitle("Library")
        .onAppear { model.meetingStore.start() }
        .onChange(of: selection) { _, new in
            // Preferences lives in its own top-level window. Routing back
            // to .library keeps the rail's visible selection coherent with
            // the actual focused surface.
            if new == .preferences {
                model.openPreferences()
                DispatchQueue.main.async { selection = .library }
            }
        }
    }

    @ViewBuilder
    private var contentPane: some View {
        switch selection {
        case .library:
            LibraryListView(store: model.meetingStore, selection: $meetingSelection)
        case .workflows:
            WorkflowsPlaceholder()
        case .preferences:
            // Selection bounces back to .library via `onChange`; this view
            // flashes for one runloop tick and is never seen in practice.
            Color.clear
        }
    }

    @ViewBuilder
    private var detailPane: some View {
        if let selectedID = meetingSelection,
           let meeting = model.meetingStore.meetings.first(where: { $0.id == selectedID }) {
            MeetingDetailView(meeting: meeting)
        } else {
            VStack(spacing: 8) {
                Image(systemName: "doc.text")
                    .font(.system(size: 36))
                    .foregroundStyle(.tertiary)
                Text("Select a meeting")
                    .foregroundStyle(.secondary)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }
}

private struct WorkflowsPlaceholder: View {
    var body: some View {
        VStack(spacing: 12) {
            Image(systemName: "square.stack.3d.up")
                .font(.system(size: 48))
                .foregroundStyle(.tertiary)
            Text("Workflows")
                .font(.title3)
                .foregroundStyle(.secondary)
            Text("Per-context routing rules. Wiring lands with TECH-B.")
                .font(.callout)
                .foregroundStyle(.tertiary)
                .multilineTextAlignment(.center)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .padding(40)
    }
}
