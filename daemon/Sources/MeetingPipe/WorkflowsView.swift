import AppKit
import SwiftUI

/// Workflow editor / wizard, presented as a sheet from the rail, toolbar, or inspector. Drives both create and edit; the old "Workflows" sidebar tab was dropped when workflows became rail scopes.

// MARK: - Editor (TECH-B7 wizard surface)

/// Flat representation of the sinks checkboxes; per-sink config (Notion DB id) lives inline to avoid a sub-sheet.
private struct SinkSelection: Equatable {
    var notionEnabled: Bool = false
    var notionDatabaseID: String = ""
    var obsidianEnabled: Bool = false
    var filesystemEnabled: Bool = false

    /// Rebuild `Workflow.sinks` from checkbox state; order matches the form rows (Notion, Obsidian, Filesystem).
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

/// Full workflow editor, shared between create and edit paths.
struct WorkflowEditor: View {
    let workflow: Workflow
    @ObservedObject var store: WorkflowStore
    /// New workflows start with a blank name field (so the placeholder shows and the sheet header reads "New workflow") even though the persisted stub has a default name (TECH-UI-7).
    var startsBlank: Bool = false
    /// Reports the live name field value so the enclosing sheet header can reflect it as the user types (TECH-UI-7).
    var onNameChange: ((String) -> Void)? = nil
    /// Notion DB list for the picker (TECH-B8). Held at editor level so the picker is populated on open, not only when Notion is toggled on.
    @StateObject private var notionDBs = NotionDatabaseList()

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
        .onChange(of: name) { _, newName in onNameChange?(newName) }
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
                TextField("Untitled workflow", text: $name)
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
                notionDBPicker
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

    /// Notion DB picker (TECH-B8). Three states: populated cache shows a Picker + Refresh; empty cache shows a "Fetch databases" button + raw TextField fallback; loading/failed shows a status row alongside the fallback.
    @ViewBuilder
    private var notionDBPicker: some View {
        VStack(alignment: .leading, spacing: 6) {
            if !notionDBs.entries.isEmpty {
                Picker("Database", selection: $sinks.notionDatabaseID) {
                    Text("(none)").tag("")
                    ForEach(notionDBs.entries) { db in
                        Text(db.title).tag(db.id)
                    }
                    // Preserve a manually-pasted id not yet in the cache; without this clause SwiftUI's Picker silently snaps the selection to (none) and the user's input vanishes on the next render.
                    if !sinks.notionDatabaseID.isEmpty,
                       !notionDBs.entries.contains(where: { $0.id == sinks.notionDatabaseID }) {
                        Text("Custom · \(sinks.notionDatabaseID.prefix(8))…")
                            .tag(sinks.notionDatabaseID)
                    }
                }
                .pickerStyle(.menu)
            }
            HStack {
                if notionDBs.entries.isEmpty || sinks.notionDatabaseID.isEmpty {
                    TextField("paste DB id", text: $sinks.notionDatabaseID)
                        .textFieldStyle(.roundedBorder)
                        .font(.system(.body, design: .monospaced))
                        .frame(minWidth: 220)
                }
                Spacer(minLength: 0)
                refreshButton
            }
            statusLabel
        }
    }

    @ViewBuilder
    private var refreshButton: some View {
        Button {
            notionDBs.refresh()
        } label: {
            Label(
                notionDBs.entries.isEmpty ? "Fetch databases" : "Refresh",
                systemImage: "arrow.clockwise"
            )
        }
        .buttonStyle(.borderless)
        .disabled(notionDBs.state == .loading)
    }

    @ViewBuilder
    private var statusLabel: some View {
        switch notionDBs.state {
        case .idle:
            EmptyView()
        case .loading:
            HStack(spacing: 4) {
                ProgressView().controlSize(.small)
                Text("Fetching databases…")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        case .loaded(let list):
            Text("\(list.count) database\(list.count == 1 ? "" : "s") cached")
                .font(.caption2)
                .foregroundStyle(.tertiary)
        case .failed(let err):
            Text(err)
                .font(.caption)
                .foregroundStyle(.red)
                .lineLimit(2)
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
        name = startsBlank ? "" : workflow.name
        onNameChange?(name)
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
