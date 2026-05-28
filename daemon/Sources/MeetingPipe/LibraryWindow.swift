import AppKit
import Combine
import SwiftUI

/// Three-pane Library window. Lifecycle mirrors `PreferencesWindow`: one instance held by the Coordinator, `show()` brings it forward (creating once), Cmd+W hides rather than releasing so the daemon keeps the configured frame.
final class LibraryWindow {
    private var window: NSWindow?
    private let model: LibraryWindowModel

    init(model: LibraryWindowModel) {
        self.model = model
    }

    func show() {
        if let w = window {
            // Guard: only count as a fresh open if the window was hidden. A second click while already visible would bump the counter past the real open count.
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
        // Cmd+W orders the window out without deallocating; next show() restores state.
        w.isReleasedWhenClosed = false
        w.setFrameAutosaveName("MeetingPipeLibraryWindow")
        // setFrameAutosaveName loads on first attach; center only when no saved frame exists so first launch isn't pinned to the bottom-left corner.
        if !w.setFrameUsingName("MeetingPipeLibraryWindow") {
            w.center()
        }

        let delegate = LibraryWindowDelegate { [weak self] in
            // Keep the reference so re-open restores the same frame and scroll/selection state.
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

/// High-frequency processing-queue counter, split off from `LibraryWindowModel` so bursts don't cascade re-renders into the rail, list, and detail. Only the toolbar observes this. Kept as a separate `ObservableObject` because SwiftUI tracks subscriptions per-object: a `@Published` on the parent would re-render every parent subscriber on every tick.
final class ProcessingTracker: ObservableObject {
    @Published var count: Int = 0
}

/// SwiftUI-observable mirror of the recording state machine. Threading: all mutations run on main (the Coordinator already enforces this). Rapidly-changing values like processing-queue depth live on `ProcessingTracker` so they don't pull the whole window through a re-render every tick.
final class LibraryWindowModel: ObservableObject {

    /// Display-only summary of `AppState`; the UI never branches on the underlying URL / SummaryMode.
    enum Status: Equatable {
        case idle
        case prompting(appName: String)
        case recording(appName: String?)
        case stopping
    }

    @Published var status: Status = .idle
    /// Stem of the in-flight recording. The list view uses this to pulse the matching row; on-disk status alone can't distinguish "wav being written" from "wav done, pipeline running".
    @Published var liveRecordingStem: String? = nil

    /// Set by the menu-bar Quick Find panel. The root view switches scope to All Meetings, selects the row, then clears this back to nil so the next pick is a fresh edge.
    @Published var pendingSelection: String? = nil

    /// Non-`@Published` so toolbar reads don't republish the parent model; the toolbar observes it directly via `@ObservedObject`.
    let processing = ProcessingTracker()

    /// Weak to avoid a retain cycle; drives menu actions (Start/Stop, Preferences).
    weak var coordinator: Coordinator?

    /// Backing store for the meetings list; the list view subscribes to it.
    let meetingStore: MeetingStore

    /// Assigned by the Coordinator after it builds the store (TECH-B). Nil-able so headless tests and the initial-state path don't need it.
    weak var workflowStore: WorkflowStore?

    init(coordinator: Coordinator? = nil, recordingsDir: URL) {
        self.coordinator = coordinator
        self.meetingStore = MeetingStore(recordingsDir: recordingsDir)
    }

    var isRecording: Bool {
        if case .recording = status { return true }
        return false
    }

    /// Disabled only in `.stopping`: the recorder is mid-flush and a button press would race the async finalize.
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

    /// Republish via `mp publish-notion`. Async-wraps the Coordinator callback so SwiftUI callers can `await` the result.
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

    /// Regenerate summary via `mp summarize` then republish. Same async-wrap pattern as `republishMeeting`.
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

    /// Re-enqueue the full `mp run-all` pipeline for a stalled/failed meeting.
    @discardableResult
    func retryMeeting(stem: String) -> Result<Void, Error> {
        coordinator?.retryMeeting(stem: stem) ?? .failure(NSError(
            domain: "LibraryWindowModel", code: 1,
            userInfo: [NSLocalizedDescriptionKey: "Coordinator unavailable"]
        ))
    }

    /// Move every sidecar for a stem to the Trash.
    @discardableResult
    func softDeleteMeeting(stem: String) -> Result<Void, Error> {
        coordinator?.softDeleteMeeting(stem: stem) ?? .failure(NSError(
            domain: "LibraryWindowModel", code: 1,
            userInfo: [NSLocalizedDescriptionKey: "Coordinator unavailable"]
        ))
    }

    /// Copy the standard human-facing artefacts for a stem to the chosen folder.
    func exportMeeting(stem: String, to destination: URL) -> Result<Int, Error> {
        coordinator?.exportMeeting(stem: stem, to: destination) ?? .failure(NSError(
            domain: "LibraryWindowModel", code: 1,
            userInfo: [NSLocalizedDescriptionKey: "Coordinator unavailable"]
        ))
    }
}

// MARK: - Root view

/// Library window root: smart-folder rail, scoped list, and context-aware detail pane. Workflows are filter scopes (not destinations); the toolbar hosts the state pill, record button, and preferences gear; a workflow-scope selection promotes a third inspector column.
struct LibraryRootView: View {
    @ObservedObject var model: LibraryWindowModel
    @ObservedObject var meetingStore: MeetingStore
    @State private var scope: LibraryScope = .allMeetings
    @State private var meetingSelection: Set<Meeting.ID> = []
    /// Drives the workflow editor sheet. Set non-nil to edit.
    @State private var editingWorkflow: Workflow? = nil
    /// Drives the "+ New workflow" sheet. Separate from `editingWorkflow` so the sheet can initialise a stub lazily, keeping the rail's button stateless.
    @State private var isCreatingWorkflow: Bool = false
    /// Memoized rail counts, recomputed only on `meetingStore.revision` or workflow-list changes. Without this the O(meetings × scopes) bucketing ran on every body re-execution (status ticks, animation timeline, etc.).
    @State private var cachedCounts: ScopeCounts = .zero
    /// Fingerprint paired with `cachedCounts`: (revision, workflow ids).
    @State private var lastCountsKey: CountsKey = .empty

    /// Captures the store explicitly so SwiftUI tracks it as `@ObservedObject`. Reaching through `model.meetingStore` would re-render on every parent property, not just `revision` bumps.
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
            // Suspend the watcher while hidden. The window outlives the view (isReleasedWhenClosed=false), so without this a closed Library would keep rescanning on every pipeline write.
            meetingStore.stop()
        }
        .onChange(of: meetingStore.revision) { _, _ in recomputeCounts() }
        .onChange(of: model.workflowStore?.workflows.count ?? 0) { _, _ in recomputeCounts() }
        .onChange(of: model.pendingSelection) { _, stem in
            guard let stem else { return }
            // Quick Find can fire while a workflow scope is active; switch to All Meetings so the row is always visible.
            scope = .allMeetings
            meetingSelection = [stem]
            model.pendingSelection = nil
        }
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
                    // Jump to the new workflow's scope so the rail + inspector confirm the action.
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
            // WorkflowStore not yet wired; fall back to a sidebar-less list.
            LibraryListView(
                store: meetingStore,
                libraryModel: model,
                scope: .allMeetings,
                workflows: [],
                selection: $meetingSelection
            )
        }
    }

    /// Rebuild rail counts, guarded by a cheap fingerprint. Adding a workflow changes `workflows.count`; renaming one does not, and shouldn't trigger a recount.
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

    /// Context-aware detail column: multi-selection shows batch-actions, single shows MeetingDetailView, empty workflow scope shows WorkflowInspector, otherwise empty state.
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

    /// Newest five meetings for this workflow, so the inspector doesn't duplicate MeetingStore's filter logic.
    private func recentMeetings(for workflow: Workflow, workflows: [Workflow]) -> [Meeting] {
        model.meetingStore.meetings
            .filter { ($0.workflowName == workflow.name) }
            .prefix(5)
            .map { $0 }
    }

}

// MARK: - Workflow editor sheets

/// Wraps `WorkflowEditor` in a sheet shell, invoked from the toolbar's "Edit workflow" button and the inspector pane.
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

/// "+ New workflow" sheet. Inserts a stub and returns its id so the rail can route to the new scope.
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
