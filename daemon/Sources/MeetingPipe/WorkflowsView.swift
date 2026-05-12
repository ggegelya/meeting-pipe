import AppKit
import SwiftUI

/// Library window's "Workflows" tab.
///
/// Two-pane: list of workflows on the left with drag-reorder, full
/// editor on the right. The editor doubles as the "New workflow
/// wizard" (TECH-B7) — both creation and edit share the same form;
/// when the user clicks `+ New Workflow` we insert a stub and route
/// straight to the editor.
///
/// Drives `WorkflowStore` directly. Every mutation persists through
/// the store's upsert/delete/reorder APIs so reordering or renaming
/// hits disk before the next list-render runs.
struct WorkflowsView: View {
    @ObservedObject var store: WorkflowStore
    @State private var selection: Workflow.ID?
    @State private var showAdvanced: Bool = false

    /// "Show advanced" gate (per TECH-B6 spec). With only the seeded
    /// default present, the list collapses to a one-row explainer to
    /// avoid overwhelming users who never wanted per-context routing in
    /// the first place. The toggle is sticky — once flipped it stays on
    /// for the session so reorderings during an editing pass don't
    /// thrash the UI.
    private var showsList: Bool {
        showAdvanced || store.workflows.count > 1
    }

    var body: some View {
        Group {
            if showsList {
                splitView
            } else {
                singleWorkflowOnboarding
            }
        }
        .navigationTitle("Workflows")
    }

    // MARK: - Split list + editor

    private var splitView: some View {
        HStack(spacing: 0) {
            list
                .frame(minWidth: 240, idealWidth: 280, maxWidth: 320)
            Divider()
            editor
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }

    private var list: some View {
        VStack(spacing: 0) {
            List(selection: $selection) {
                ForEach(store.workflows) { wf in
                    WorkflowRow(workflow: wf)
                        .tag(wf.id as Workflow.ID?)
                }
                .onMove(perform: handleReorder)
            }
            Divider()
            HStack {
                Button {
                    addWorkflow()
                } label: {
                    Label("New Workflow", systemImage: "plus")
                }
                .buttonStyle(.borderless)
                Spacer()
                if showAdvanced && store.workflows.count <= 1 {
                    Button("Hide advanced") { showAdvanced = false }
                        .buttonStyle(.borderless)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
            .padding(8)
        }
        .background(Color(NSColor.controlBackgroundColor))
    }

    @ViewBuilder
    private var editor: some View {
        if let id = selection, let wf = store.workflow(id: id) {
            WorkflowEditor(workflow: wf, store: store)
                .padding(20)
        } else {
            VStack(spacing: 8) {
                Image(systemName: "square.stack.3d.up")
                    .font(.system(size: 36))
                    .foregroundStyle(.tertiary)
                Text("Select a workflow")
                    .foregroundStyle(.secondary)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }

    private func handleReorder(from source: IndexSet, to destination: Int) {
        var rebuilt = store.workflows
        rebuilt.move(fromOffsets: source, toOffset: destination)
        try? store.reorder(rebuilt)
    }

    private func addWorkflow() {
        let next = Workflow(
            name: "Untitled workflow",
            color: "#3478F6",
            sinks: [.notion(databaseId: "")],
            backend: .anthropic,
            isDefault: store.workflows.isEmpty,
            order: store.workflows.count
        )
        try? store.upsert(next)
        selection = next.id
    }

    // MARK: - Onboarding

    /// Surface when only the seeded "General" workflow exists. Tells the
    /// user the feature is there without forcing them through a list /
    /// editor surface they don't need yet.
    private var singleWorkflowOnboarding: some View {
        VStack(spacing: 14) {
            Image(systemName: "square.stack.3d.up")
                .font(.system(size: 44))
                .foregroundStyle(.tertiary)
            Text("One workflow active")
                .font(.title3)
            Text("All meetings route through the default workflow. Add more to send different meetings to different Notion DBs, contexts, or backends.")
                .font(.callout)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .frame(maxWidth: 360)
            HStack(spacing: 10) {
                Button("Edit default") {
                    showAdvanced = true
                    selection = store.workflows.first?.id
                }
                Button("Add workflow") {
                    showAdvanced = true
                    addWorkflow()
                }
                .buttonStyle(.borderedProminent)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .padding(40)
    }
}

// MARK: - Row

/// Compact list row showing the workflow's color + name + default badge.
struct WorkflowRow: View {
    let workflow: Workflow

    var body: some View {
        HStack(spacing: 8) {
            glyph
            Text(workflow.name)
                .lineLimit(1)
                .truncationMode(.tail)
            Spacer(minLength: 4)
            if workflow.isDefault {
                Text("default")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }
        }
        .padding(.vertical, 2)
    }

    @ViewBuilder
    private var glyph: some View {
        if let emoji = workflow.emoji, !emoji.isEmpty {
            Text(emoji)
        } else if let color = HexColor.parse(workflow.color) {
            Circle()
                .fill(Color(color))
                .frame(width: 10, height: 10)
        } else {
            Circle()
                .fill(Color.accentColor)
                .frame(width: 10, height: 10)
        }
    }
}

// MARK: - Editor (TECH-B7 wizard surface)

/// One row in the sinks checklist. Per-sink config (Notion DB id) lives
/// inline so the user doesn't need to descend into a sub-sheet to wire
/// up a workflow's destination.
private struct SinkSelection: Equatable {
    var notionEnabled: Bool = false
    var notionDatabaseID: String = ""
    var obsidianEnabled: Bool = false
    var filesystemEnabled: Bool = false

    /// Reconstruct the typed array `Workflow.sinks` consumes from the
    /// checkbox state. Order follows the form's row order so the
    /// pipeline's fanout runs Notion → Obsidian → Filesystem.
    func toWorkflowSinks() -> [WorkflowSink] {
        var out: [WorkflowSink] = []
        if notionEnabled { out.append(.notion(databaseId: notionDatabaseID)) }
        if obsidianEnabled { out.append(.obsidian) }
        if filesystemEnabled { out.append(.filesystem) }
        return out
    }

    static func from(_ sinks: [WorkflowSink]) -> SinkSelection {
        var s = SinkSelection()
        for sink in sinks {
            switch sink {
            case .notion(let dbId):
                s.notionEnabled = true
                s.notionDatabaseID = dbId
            case .obsidian:
                s.obsidianEnabled = true
            case .filesystem:
                s.filesystemEnabled = true
            }
        }
        return s
    }
}

/// Full workflow editor / wizard. Same surface drives "New workflow"
/// (after the list inserts a stub and routes here) and "edit existing
/// workflow" — there's no separate modal because the inline form is
/// already the form the wizard would render.
struct WorkflowEditor: View {
    let workflow: Workflow
    @ObservedObject var store: WorkflowStore

    @State private var name: String = ""
    @State private var color: String = ""
    @State private var emoji: String = ""
    @State private var contextPrompt: String = ""
    @State private var isDefault: Bool = false
    @State private var matchingRules: [WorkflowMatchingRule] = []
    @State private var sinks = SinkSelection()
    @State private var backend: WorkflowBackend = .anthropic
    @State private var ndaMode: Bool = false
    @State private var pendingDeleteAlert: Bool = false
    @State private var saveError: String?

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                header
                Form {
                    identitySection
                    matchingRulesSection
                    contextSection
                    sinksSection
                    backendSection
                    flagsSection
                    defaultSection
                }
                .formStyle(.grouped)
                if let err = saveError {
                    Text(err)
                        .font(.caption)
                        .foregroundStyle(.red)
                }
                actionsRow
            }
            .padding(.vertical, 4)
        }
        .onAppear(perform: hydrate)
        .onChange(of: workflow.id) { _, _ in hydrate() }
        .alert("Delete this workflow?", isPresented: $pendingDeleteAlert) {
            Button("Cancel", role: .cancel) {}
            Button("Delete", role: .destructive, action: deleteSelf)
        } message: {
            Text("Meetings already recorded keep their workflow metadata; only future meetings stop matching this workflow.")
        }
    }

    private var header: some View {
        HStack(spacing: 10) {
            if !emoji.isEmpty {
                Text(emoji).font(.title2)
            } else if let parsed = HexColor.parse(color) {
                Circle().fill(Color(parsed)).frame(width: 16, height: 16)
            }
            Text(name.isEmpty ? "(unnamed)" : name).font(.title3)
            if workflow.isDefault {
                Text("default")
                    .font(.caption)
                    .padding(.horizontal, 6).padding(.vertical, 2)
                    .background(Capsule().fill(Color.secondary.opacity(0.15)))
            }
            Spacer()
        }
    }

    // MARK: Sections

    private var identitySection: some View {
        Section("Identity") {
            LabeledContent("Name") {
                TextField("", text: $name)
                    .textFieldStyle(.roundedBorder)
                    .onSubmit(save)
            }
            LabeledContent("Color") {
                HStack {
                    TextField("#RRGGBB", text: $color)
                        .textFieldStyle(.roundedBorder)
                        .frame(width: 110)
                        .font(.system(.body, design: .monospaced))
                    if let parsed = HexColor.parse(color) {
                        Circle().fill(Color(parsed)).frame(width: 16, height: 16)
                    }
                    Spacer()
                }
            }
            LabeledContent("Emoji") {
                TextField("optional", text: $emoji)
                    .textFieldStyle(.roundedBorder)
                    .frame(width: 80)
            }
        }
    }

    private var matchingRulesSection: some View {
        Section("Matching rules") {
            if matchingRules.isEmpty {
                Text("No rules — this workflow matches only when used as the default.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            } else {
                ForEach($matchingRules) { $rule in
                    matchingRuleRow($rule: $rule)
                }
                .onDelete { offsets in
                    matchingRules.remove(atOffsets: offsets)
                }
            }
            Button {
                matchingRules.append(WorkflowMatchingRule())
            } label: {
                Label("Add rule", systemImage: "plus")
            }
            .buttonStyle(.borderless)
            Text("Bundle id matches the meeting app (e.g. `us.zoom.xos`, `com.microsoft.teams2`). Title regex is case-insensitive and tests the window title; useful to split a single browser into per-tab workflows.")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
    }

    private func matchingRuleRow(@Binding rule: WorkflowMatchingRule) -> some View {
        HStack(alignment: .top, spacing: 8) {
            VStack(spacing: 4) {
                TextField("bundle id", text: $rule.bundleID)
                    .textFieldStyle(.roundedBorder)
                    .font(.system(.body, design: .monospaced))
                TextField("title regex (optional)", text: $rule.titleRegex)
                    .textFieldStyle(.roundedBorder)
                    .font(.system(.body, design: .monospaced))
            }
            Button(role: .destructive) {
                matchingRules.removeAll { $0.id == rule.id }
            } label: {
                Image(systemName: "minus.circle")
            }
            .buttonStyle(.borderless)
        }
    }

    private var contextSection: some View {
        Section("Context prompt") {
            TextEditor(text: $contextPrompt)
                .font(.system(.body, design: .monospaced))
                .frame(minHeight: 120, maxHeight: 240)
                .border(Color.secondary.opacity(0.2))
            Text("Seasoning the LLM sees for every meeting matched by this workflow. Example: \"Confidential client meeting; redact names; FDA 21 CFR Part 11 context.\"")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
    }

    private var sinksSection: some View {
        Section("Sinks") {
            Toggle(isOn: $sinks.notionEnabled) { Text("Notion") }
            if sinks.notionEnabled {
                LabeledContent("Database id") {
                    TextField("32-char hex from your DB URL", text: $sinks.notionDatabaseID)
                        .textFieldStyle(.roundedBorder)
                        .font(.system(.body, design: .monospaced))
                }
            }
            Toggle(isOn: $sinks.obsidianEnabled) { Text("Obsidian") }
            Toggle(isOn: $sinks.filesystemEnabled) { Text("Filesystem (local Markdown only)") }
            if ndaMode {
                Text("NDA mode forces filesystem-only; toggles above are ignored at run time.")
                    .font(.caption)
                    .foregroundStyle(.orange)
            }
        }
    }

    private var backendSection: some View {
        Section("Backend") {
            Picker("", selection: $backend) {
                Text("Anthropic (cloud)").tag(WorkflowBackend.anthropic)
                Text("Local MLX").tag(WorkflowBackend.local)
                Text("Auto (cloud, fall back to local)").tag(WorkflowBackend.auto)
            }
            .labelsHidden()
            .pickerStyle(.segmented)
            .disabled(ndaMode)
            if ndaMode {
                Text("NDA mode forces the local backend; the picker is disabled.")
                    .font(.caption)
                    .foregroundStyle(.orange)
            }
        }
    }

    private var flagsSection: some View {
        Section("Flags") {
            Toggle("NDA mode (force local backend, filesystem only)", isOn: $ndaMode)
            Text("Surfaces in the HUD and the menu-bar title so a misroute is visible before the meeting starts.")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
    }

    private var defaultSection: some View {
        Section("Default") {
            Toggle("Use as default", isOn: $isDefault)
                .disabled(workflow.isDefault)
            Text("The default workflow matches any meeting that no other workflow's rules pick up. Toggle on a different workflow here to switch the default.")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
    }

    private var actionsRow: some View {
        HStack {
            Button("Save", action: save)
                .keyboardShortcut(.defaultAction)
            Spacer()
            Button(role: .destructive) {
                pendingDeleteAlert = true
            } label: {
                Label("Delete", systemImage: "trash")
            }
            .disabled(workflow.isDefault)
        }
    }

    // MARK: Form state

    private func hydrate() {
        name = workflow.name
        color = workflow.color
        emoji = workflow.emoji ?? ""
        contextPrompt = workflow.contextPrompt
        isDefault = workflow.isDefault
        matchingRules = workflow.matchingRules
        sinks = SinkSelection.from(workflow.sinks)
        backend = workflow.backend
        ndaMode = workflow.flags.ndaMode
        saveError = nil
    }

    private func save() {
        var clone = workflow
        let trimmedName = name.trimmingCharacters(in: .whitespaces)
        guard !trimmedName.isEmpty else {
            saveError = "Name is required"
            return
        }
        clone.name = trimmedName
        clone.color = color.isEmpty ? "#3478F6" : color
        clone.emoji = emoji.isEmpty ? nil : emoji
        clone.contextPrompt = contextPrompt
        clone.isDefault = isDefault
        clone.matchingRules = matchingRules
        clone.sinks = sinks.toWorkflowSinks()
        clone.backend = backend
        clone.flags.ndaMode = ndaMode
        do {
            try store.upsert(clone)
            saveError = nil
        } catch {
            saveError = error.localizedDescription
        }
    }

    private func deleteSelf() {
        do {
            _ = try store.delete(id: workflow.id)
        } catch {
            saveError = error.localizedDescription
        }
    }
}
