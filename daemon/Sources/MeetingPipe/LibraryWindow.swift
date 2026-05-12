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
            // Re-show counts as a fresh open from the activation
            // manager's perspective only if the window was hidden
            // (not visible). Without this guard a second click on
            // "Open Library..." while the window is already up would
            // bump the counter past the real open-window count.
            let wasHidden = !w.isVisible
            w.makeKeyAndOrderFront(nil)
            NSApp.activate(ignoringOtherApps: true)
            if wasHidden { WindowActivationManager.shared.didShowWindow() }
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

private final class LibraryWindowDelegate: NSObject, NSWindowDelegate {
    private let onClose: () -> Void
    init(onClose: @escaping () -> Void) { self.onClose = onClose }
    func windowWillClose(_ notification: Notification) { onClose() }
}

// MARK: - Observable bridge

/// High-frequency processing-queue counter, split off from
/// `LibraryWindowModel` so a 10-job burst doesn't cascade re-renders
/// into the rail, list, and detail. Only the toolbar observes this.
///
/// `ObservableObject` rather than a property on the parent because
/// SwiftUI tracks subscriptions per-`ObservableObject`: any `@Published`
/// on the parent triggers re-renders in every parent subscriber, which
/// is the pathology we're avoiding.
final class ProcessingTracker: ObservableObject {
    @Published var count: Int = 0
}

/// Mirrors the recording state machine into a SwiftUI-observable shape
/// so the toolbar can render the state pill without subscribing
/// directly to AppKit setters.
///
/// Threading: all mutations run on the main queue (matches Coordinator
/// threading — every public method on the Coordinator must already run
/// on main). Properties stay narrow on purpose; rapidly-changing values
/// like the processing-queue size live on the sibling
/// `ProcessingTracker` so they don't pull the whole window through a
/// re-render every tick.
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
    /// Stem of the meeting currently being recorded (live wav write in
    /// flight). The list view uses this to render the matching row with
    /// a recording-tinted pulse — the on-disk status alone can't tell
    /// the difference between "wav still being written" and "wav done,
    /// pipeline running".
    @Published var liveRecordingStem: String? = nil

    /// Held as a non-`@Published` constant so reads from the toolbar
    /// don't trigger a republish of the parent model. The toolbar
    /// observes `processing` directly via its own `@ObservedObject`.
    let processing = ProcessingTracker()

    /// Coordinator is held weakly so the model can drive menu actions
    /// (Start/Stop, Preferences) without creating a retain cycle.
    weak var coordinator: Coordinator?

    /// Backing store for the meetings list. Built once with the daemon's
    /// recordings directory; the list view subscribes to it.
    let meetingStore: MeetingStore

    /// Per-context routing rules (TECH-B). Assigned by the Coordinator
    /// after it builds the store so the Workflows tab can ForEach over
    /// `workflows` without holding a separate Combine subscription.
    /// Nil-able so headless tests + the initial-state path don't need to
    /// thread the store through.
    weak var workflowStore: WorkflowStore?

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

    /// Re-enqueue the full `mp run-all` pipeline for a stalled meeting.
    /// Used by the context menu's "Retry pipeline" action when a row
    /// has aged into `.failed` status without ever producing a summary.
    @discardableResult
    func retryMeeting(stem: String) -> Result<Void, Error> {
        coordinator?.retryMeeting(stem: stem) ?? .failure(NSError(
            domain: "LibraryWindowModel", code: 1,
            userInfo: [NSLocalizedDescriptionKey: "Coordinator unavailable"]
        ))
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

/// Library window root. Smart-folder rail + scoped list + context-aware
/// detail pane, with a custom toolbar across the top hosting state
/// pill, record button, and preferences gear.
///
/// IA derived from the design bundle's "Pattern B + a borrowed piece of
/// C" winner: Workflows are filter scopes (not destinations), the
/// previously-hidden recording state lives in the persistent toolbar,
/// and a workflow-scope selection promotes a third inspector column.
struct LibraryRootView: View {
    @ObservedObject var model: LibraryWindowModel
    @ObservedObject var meetingStore: MeetingStore
    @State private var scope: LibraryScope = .allMeetings
    @State private var meetingSelection: Set<Meeting.ID> = []
    /// Drives the workflow editor sheet. Set non-nil to edit; cleared
    /// when the sheet dismisses.
    @State private var editingWorkflow: Workflow? = nil
    /// Drives the "+ New workflow" sheet. We branch on a separate flag
    /// rather than overloading `editingWorkflow` so the sheet can
    /// initialise a stub Workflow lazily inside the sheet builder —
    /// keeping the rail's button stateless.
    @State private var isCreatingWorkflow: Bool = false
    /// Memoized rail counts. Recomputed only when `meetingStore.revision`
    /// or the workflow list actually changes. Without this the rail's
    /// O(meetings × scopes) bucketing ran on every body re-execution,
    /// which fired for unrelated reasons (status / processing ticks
    /// before the model split, animation timeline ticks, etc.).
    @State private var cachedCounts: ScopeCounts = .zero
    /// Fingerprint paired with `cachedCounts`. (`revision`, workflow ids).
    @State private var lastCountsKey: CountsKey = .empty

    /// Initialiser captures the store explicitly so SwiftUI tracks it as
    /// an `@ObservedObject` dependency — passing it in from the parent
    /// rather than reaching through `model.meetingStore` lets us
    /// re-render the root precisely on `revision` bumps instead of on
    /// every property of the parent model.
    init(model: LibraryWindowModel) {
        self.model = model
        self.meetingStore = model.meetingStore
    }

    var body: some View {
        VStack(spacing: 0) {
            if let store = model.workflowStore {
                LibraryToolbar(
                    model: model,
                    processing: model.processing,
                    workflowStore: store,
                    selection: $scope,
                    onEditWorkflow: { wf in editingWorkflow = wf }
                )
            }
            split
        }
        .frame(minWidth: 760)
        .onAppear {
            meetingStore.start()
            recomputeCounts()
        }
        .onDisappear {
            // Suspend the directory watcher while the window is hidden.
            // The window outlives the view via isReleasedWhenClosed=false,
            // and without this a closed Library would keep rescanning
            // every time the pipeline wrote a new sidecar — re-firing
            // the @Published on `meetings` into a tree nobody could see.
            meetingStore.stop()
        }
        .onChange(of: meetingStore.revision) { _, _ in recomputeCounts() }
        .onChange(of: model.workflowStore?.workflows.count ?? 0) { _, _ in recomputeCounts() }
        .sheet(item: $editingWorkflow, onDismiss: { editingWorkflow = nil }) { wf in
            if let store = model.workflowStore {
                WorkflowEditorSheet(workflow: wf, store: store) {
                    editingWorkflow = nil
                }
            }
        }
        .sheet(isPresented: $isCreatingWorkflow) {
            if let store = model.workflowStore {
                NewWorkflowSheet(store: store) { newID in
                    isCreatingWorkflow = false
                    // After creating, jump straight to the new workflow's
                    // scope so the rail confirms the action visually and
                    // the inspector lights up on the right.
                    if let id = newID { scope = .workflow(id) }
                }
            }
        }
    }

    @ViewBuilder
    private var split: some View {
        if let store = model.workflowStore {
            NavigationSplitView {
                LibrarySidebar(
                    selection: $scope,
                    workflowStore: store,
                    counts: cachedCounts,
                    onCreateWorkflow: { isCreatingWorkflow = true }
                )
            } content: {
                LibraryListView(
                    store: meetingStore,
                    libraryModel: model,
                    scope: scope,
                    workflows: store.workflows,
                    selection: $meetingSelection
                )
            } detail: {
                detailPane(workflowStore: store)
            }
        } else {
            // Headless / first-run path before the WorkflowStore has
            // been wired in by the Coordinator. The rail can't render
            // without a store; fall back to a sidebar-less list.
            LibraryListView(
                store: meetingStore,
                libraryModel: model,
                scope: .allMeetings,
                workflows: [],
                selection: $meetingSelection
            )
        }
    }

    /// Rebuild the rail's counts. Cheap-fingerprint guard so we don't
    /// rebuild when nothing the rail cares about changed — for example,
    /// adding a workflow updates `workflows.count`, but tweaking a
    /// workflow's name does not (and shouldn't trigger a rail recount).
    private func recomputeCounts() {
        let workflows = model.workflowStore?.workflows ?? []
        let key = CountsKey(
            storeRevision: meetingStore.revision,
            workflowIDs: workflows.map(\.id)
        )
        if key == lastCountsKey { return }
        cachedCounts = ScopeCounts.build(
            meetings: meetingStore.meetings,
            workflows: workflows
        )
        lastCountsKey = key
    }

    private struct CountsKey: Equatable {
        let storeRevision: Int
        let workflowIDs: [Workflow.ID]
        static let empty = CountsKey(storeRevision: -1, workflowIDs: [])
    }

    /// Detail column is context-aware:
    ///   • Multiple meetings selected → batch-actions pane.
    ///   • Single meeting selected    → MeetingDetailView (today's behaviour).
    ///   • No meeting, workflow scope → WorkflowInspector.
    ///   • Otherwise                  → empty-state ("Select a meeting").
    @ViewBuilder
    private func detailPane(workflowStore store: WorkflowStore) -> some View {
        let selected = model.meetingStore.meetings.filter { meetingSelection.contains($0.id) }
        if selected.count > 1 {
            BatchActionsPane(meetings: selected, libraryModel: model)
        } else if let only = selected.first {
            MeetingDetailView(meeting: only)
        } else if case .workflow(let id) = scope, let wf = store.workflow(id: id) {
            WorkflowInspector(
                workflow: wf,
                recentMeetings: recentMeetings(for: wf, workflows: store.workflows),
                onEdit: { editingWorkflow = wf }
            )
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

    /// Newest five meetings carrying this workflow's name. Shared
    /// helper so the inspector doesn't duplicate the filter logic
    /// already in `MeetingStore`.
    private func recentMeetings(for workflow: Workflow, workflows: [Workflow]) -> [Meeting] {
        model.meetingStore.meetings
            .filter { ($0.workflowName == workflow.name) }
            .prefix(5)
            .map { $0 }
    }

}

// MARK: - Workflow editor sheets

/// Wraps `WorkflowEditor` in a sheet shell so the existing list-column
/// editor can be re-used as a modal. The new IA invokes it from the
/// toolbar's "Edit workflow" button and from the inspector pane.
private struct WorkflowEditorSheet: View {
    let workflow: Workflow
    @ObservedObject var store: WorkflowStore
    let onClose: () -> Void

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Text(workflow.name)
                    .font(.headline)
                Spacer()
                Button("Done", action: onClose)
                    .keyboardShortcut(.defaultAction)
            }
            .padding(.horizontal, 18)
            .padding(.vertical, 12)
            Divider()
            WorkflowEditor(workflow: workflow, store: store)
                .padding(20)
        }
        .frame(minWidth: 560, idealWidth: 640, minHeight: 520, idealHeight: 640)
    }
}

/// "+ New workflow" sheet — inserts a stub, hands the resulting id to
/// the caller so the rail can route to the newly-created scope.
private struct NewWorkflowSheet: View {
    @ObservedObject var store: WorkflowStore
    let onClose: (Workflow.ID?) -> Void
    @State private var stub: Workflow? = nil

    var body: some View {
        Group {
            if let s = stub {
                VStack(spacing: 0) {
                    HStack {
                        Text("New workflow")
                            .font(.headline)
                        Spacer()
                        Button("Done") { onClose(s.id) }
                            .keyboardShortcut(.defaultAction)
                    }
                    .padding(.horizontal, 18)
                    .padding(.vertical, 12)
                    Divider()
                    WorkflowEditor(workflow: s, store: store)
                        .padding(20)
                }
            } else {
                ProgressView()
                    .frame(width: 640, height: 520)
            }
        }
        .frame(minWidth: 560, idealWidth: 640, minHeight: 520, idealHeight: 640)
        .onAppear {
            let next = Workflow(
                name: "Untitled workflow",
                color: "#3478F6",
                sinks: [.notion(databaseId: "")],
                backend: .anthropic,
                isDefault: store.workflows.isEmpty,
                order: store.workflows.count
            )
            try? store.upsert(next)
            stub = next
        }
    }
}
