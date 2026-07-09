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
        let host = NSHostingController(rootView: MPControlAccent(view))
        let w = NSWindow(contentViewController: host)
        w.title = "MeetingPipe Library"
        w.styleMask = [.titled, .closable, .miniaturizable, .resizable]
        w.setContentSize(NSSize(width: 1120, height: 680))
        w.minSize = NSSize(width: LibraryLayout.windowMinWidth, height: LibraryLayout.windowMinHeight)
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
/// Live pipeline-progress snapshot for the active job's row (TECH-UX5).
struct ActiveProcessing: Equatable {
    let stem: String
    let stage: String
    let elapsedSec: Int
    let stalled: Bool
}

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

    /// Live pipeline progress for the row being processed (TECH-UX5). Nil when no active pipeline job; the list hands the matching row its snapshot.
    @Published var activeProcessing: ActiveProcessing? = nil

    /// Set by the menu-bar Quick Find panel. The root view switches scope to All Meetings, selects the row, then clears this back to nil so the next pick is a fresh edge.
    @Published var pendingSelection: String? = nil

    /// When a Facts or Ask row opens a meeting, the scope snaps to All meetings, so
    /// the detail header shows a dismissible "Opened from <source>" banner (DSN22
    /// #9). Keyed by stem so navigating to any other meeting hides it on its own.
    struct InsightOrigin: Equatable {
        let stem: String
        let source: String   // "Facts" / "Ask"
    }
    @Published var openedFromInsight: InsightOrigin? = nil

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

    /// Republish via `mp publish` (the sink fanout). Async-wraps the Coordinator callback so SwiftUI callers can `await` the result.
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

    /// Cancel the active pipeline job (TECH-UX5), e.g. from a stalled row.
    func cancelProcessing() {
        coordinator?.cancelActiveJob()
    }

    /// True when the configured backend is on-device (MLX-local or Apple
    /// Intelligence), so the free local re-run preview is offered (TECH-A16).
    var canPreviewLocally: Bool {
        let backend = coordinator?.summarizationBackend ?? "anthropic"
        return backend == "local" || backend == "apple_intelligence"
    }

    /// Re-run summarization into a candidate preview (TECH-A16); never publishes.
    /// `contextOverride` (TECH-FEAT7) feeds an ad-hoc reprocess prompt for that
    /// run only; nil is the plain local re-run.
    func previewSummary(stem: String, contextOverride: String? = nil) async -> Result<Void, Error> {
        guard let coordinator = coordinator else {
            return .failure(NSError(
                domain: "LibraryWindowModel", code: 1,
                userInfo: [NSLocalizedDescriptionKey: "Coordinator unavailable"]
            ))
        }
        return await withCheckedContinuation { (cont: CheckedContinuation<Result<Void, Error>, Never>) in
            coordinator.previewSummary(stem: stem, contextOverride: contextOverride) { cont.resume(returning: $0) }
        }
    }

    /// TECH-FEAT7: the effective context prompt for prefilling the reprocess editor.
    func effectiveContextPrompt(stem: String) -> String {
        coordinator?.effectiveContextPrompt(stem: stem) ?? ""
    }

    @discardableResult
    func keepCandidateSummary(stem: String) -> Result<Void, Error> {
        coordinator?.keepCandidateSummary(stem: stem) ?? .failure(NSError(
            domain: "LibraryWindowModel", code: 1,
            userInfo: [NSLocalizedDescriptionKey: "Coordinator unavailable"]
        ))
    }

    func discardCandidateSummary(stem: String) {
        coordinator?.discardCandidateSummary(stem: stem)
    }

    /// Publish a hand-pasted summary (TECH-UX3): writes `<stem>.summary.md` and
    /// runs `mp publish-from-paste`. Async-wrapped like `republishMeeting`.
    func publishFromPaste(stem: String, summaryText: String) async -> Result<Void, Error> {
        guard let coordinator = coordinator else {
            return .failure(NSError(
                domain: "LibraryWindowModel", code: 1,
                userInfo: [NSLocalizedDescriptionKey: "Coordinator unavailable"]
            ))
        }
        return await withCheckedContinuation { (cont: CheckedContinuation<Result<Void, Error>, Never>) in
            coordinator.publishFromPaste(stem: stem, summaryText: summaryText) { result in
                cont.resume(returning: result)
            }
        }
    }

    /// Ask a natural-language question across the library (AI3). Async-wrapped like
    /// `republishMeeting`; the AskView shows a spinner while this runs.
    func askMeetings(question: String) async -> Result<AskAnswer, Error> {
        guard let coordinator = coordinator else {
            return .failure(NSError(
                domain: "LibraryWindowModel", code: 1,
                userInfo: [NSLocalizedDescriptionKey: "Coordinator unavailable"]
            ))
        }
        return await withCheckedContinuation { (cont: CheckedContinuation<Result<AskAnswer, Error>, Never>) in
            coordinator.askMeetings(question: question) { result in
                cont.resume(returning: result)
            }
        }
    }

    /// Enroll a meeting speaker into the named-speaker roster (FEAT3-ROSTER).
    /// Async-wrapped like `askMeetings`; the transcript naming sheet awaits it.
    func rosterEnroll(stem: String, label: String, name: String) async -> Result<Void, Error> {
        guard let coordinator = coordinator else {
            return .failure(NSError(
                domain: "LibraryWindowModel", code: 1,
                userInfo: [NSLocalizedDescriptionKey: "Coordinator unavailable"]
            ))
        }
        return await withCheckedContinuation { (cont: CheckedContinuation<Result<Void, Error>, Never>) in
            coordinator.rosterEnroll(stem: stem, label: label, name: name) { result in
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
        .frame(minWidth: LibraryLayout.windowMinWidth)
        // Cmd+, opens Preferences from the Library window. The status-bar menu's
        // key equivalent (StatusBarController) is not validated against a key
        // window in this LSUIElement app (no NSApp.mainMenu), so the Preferences
        // shortcut is wired into the view hierarchy here.
        .background(
            Button("") { model.openPreferences() }
                .keyboardShortcut(",", modifiers: .command)
                .opacity(0)
                .accessibilityHidden(true)
        )
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
                Group {
                    if case .facts = scope {
                        // The facts projection takes the center column (DV1):
                        // its rows are facts, not meetings, and "open" navigates
                        // back to All Meetings with the source row selected.
                        FactsView(store: meetingStore) { stem in
                            model.openedFromInsight = .init(stem: stem, source: "Facts")
                            scope = .allMeetings
                            meetingSelection = [stem]
                        }
                    } else if case .ask = scope {
                        // Ask-AI (AI3) also takes the center column: a question box
                        // over a cited answer, each citation navigating back to its
                        // source meeting like a Facts row does.
                        AskView(model: model) { stem in
                            model.openedFromInsight = .init(stem: stem, source: "Ask")
                            scope = .allMeetings
                            meetingSelection = [stem]
                        }
                    } else {
                        LibraryListView(
                            store: meetingStore,
                            libraryModel: model,
                            scope: scope,
                            workflows: store.workflows,
                            selection: $meetingSelection
                        )
                    }
                }
                // Floor the center column so the status pill + date can't be
                // squeezed off the row edge when the window or columns narrow.
                .navigationSplitViewColumnWidth(min: LibraryLayout.listMinWidth, ideal: LibraryLayout.listIdealWidth)
            } detail: {
                detailPane(workflowStore: store)
                    // Floor the detail column so it clears the Audio tab footer
                    // instead of sliding its leading content under the divider
                    // at the window minimum (TECH-UX11).
                    .navigationSplitViewColumnWidth(min: LibraryLayout.detailMinWidth, ideal: LibraryLayout.detailIdealWidth)
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
        if case .facts = scope {
            // Facts owns the center column; the detail stays a quiet hint (a row's
            // "open" jumps to All Meetings, which re-renders this pane normally).
            VStack(spacing: 8) {
                Image(systemName: "list.bullet.rectangle")
                    .font(.system(size: 36))
                    .foregroundStyle(Color(MPColors.fgSubtle))
                Text("Open actions and recent decisions across your meetings.")
                    .foregroundStyle(Color(MPColors.fgMuted))
                    .multilineTextAlignment(.center)
                    .frame(maxWidth: 260)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else if case .ask = scope {
            // Ask owns the center column (like Facts); a citation's "open" jumps to
            // All Meetings, which re-renders this pane normally.
            VStack(spacing: 8) {
                Image(systemName: "bubble.left.and.text.bubble.right")
                    .font(.system(size: 36))
                    .foregroundStyle(Color(MPColors.fgSubtle))
                Text("Answers are drawn from your meetings, on-device, with citations.")
                    .foregroundStyle(Color(MPColors.fgMuted))
                    .multilineTextAlignment(.center)
                    .frame(maxWidth: 260)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else if selected.count > 1 {
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
                    .foregroundStyle(Color(MPColors.fgSubtle))
                Text("Select a meeting")
                    .foregroundStyle(Color(MPColors.fgMuted))
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

    /// Live mirror of the editor's name field (TECH-UI-7). Nil until the editor
    /// reports a value, so the header shows the saved name with no first-frame flash.
    @State private var liveName: String? = nil

    private var headerTitle: String {
        let n = liveName ?? workflow.name
        return n.trimmingCharacters(in: .whitespaces).isEmpty ? "New workflow" : n
    }

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Text(headerTitle)
                    .font(.headline)
                Spacer()
                Button("Cancel", action: onClose)
                    .keyboardShortcut(.cancelAction)
            }
            .padding(.horizontal, 18)
            .padding(.vertical, 12)
            Divider()
            // Save commits and closes; Cancel above discards unsaved edits.
            WorkflowEditor(workflow: workflow, store: store, onNameChange: { liveName = $0 }, onCommit: onClose)
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
    /// Live name from the (blank-started) editor field (TECH-UI-7); header reads
    /// "New workflow" until the user types, then mirrors the field.
    @State private var liveName: String? = nil

    private var headerTitle: String {
        let n = (liveName ?? "").trimmingCharacters(in: .whitespaces)
        return n.isEmpty ? "New workflow" : n
    }

    var body: some View {
        Group {
            if let s = stub {
                VStack(spacing: 0) {
                    HStack {
                        Text(headerTitle)
                            .font(.headline)
                        Spacer()
                        Button("Cancel") {
                            // The stub was persisted on open; discard it so a
                            // cancelled "New workflow" doesn't orphan an
                            // "Untitled workflow" in the rail.
                            _ = try? store.delete(id: s.id)
                            onClose(nil)
                        }
                        .keyboardShortcut(.cancelAction)
                    }
                    .padding(.horizontal, 18)
                    .padding(.vertical, 12)
                    Divider()
                    // Save commits (keeping the stub, renamed) and closes.
                    WorkflowEditor(workflow: s, store: store, startsBlank: true, onNameChange: { liveName = $0 }, onCommit: { onClose(s.id) })
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
                color: MPColors.defaultWorkflowHex,
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
