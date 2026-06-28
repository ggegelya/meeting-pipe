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
    /// Called after a successful Save so the host sheet can dismiss; Save now
    /// commits *and* closes instead of silently persisting with no visible change.
    var onCommit: (() -> Void)? = nil
    /// Notion DB list for the picker (TECH-B8). Held at editor level so the picker is populated on open, not only when Notion is toggled on.
    @StateObject private var notionDBs = NotionDatabaseList()

    @State private var name: String = ""
    @State private var color: String = ""
    @State private var emoji: String = ""
    @State private var contextPrompt: String = ""
    @State private var isDefault: Bool = false
    @State private var matchingRules: [WorkflowMatchingRule] = []
    @State private var sinks = SinkSelection()
    @State private var backend: WorkflowBackend? = nil
    @State private var ndaMode: Bool = false
    @State private var redactMutedSpans: Bool = false
    @State private var pendingDeleteAlert: Bool = false
    @State private var saveError: String?
    @State private var colorPopoverOpen: Bool = false

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
                        .foregroundStyle(.mpDanger)
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

    /// Shared trailing-control width so the Color and Emoji rows line up under
    /// the Name field instead of each picking its own size (TECH-WF4).
    private static let identityFieldWidth: CGFloat = 150

    private var identitySection: some View {
        Section("Identity") {
            LabeledContent("Name") {
                // `prompt:` (not the title arg) so the placeholder doesn't render
                // as leaked label text beside the field in this LabeledContent/Form.
                TextField("", text: $name, prompt: Text("Untitled workflow"))
                    .textFieldStyle(.roundedBorder)
                    .onSubmit(save)
            }
            LabeledContent("Color") {
                // Curated swatches only (TECH-DSN11): the popover is the sole
                // colour control so workflows stay a tonal family. No free-hex
                // field - it was the path off-palette colours leaked in.
                colorSwatchButton
            }
            LabeledContent("Emoji") {
                HStack(spacing: 8) {
                    Button {
                        NSApp.orderFrontCharacterPalette(nil)
                    } label: {
                        Image(systemName: "face.smiling")
                    }
                    .buttonStyle(.bordered)
                    .help("Open the emoji & symbols palette")
                    TextField("", text: $emoji, prompt: Text("optional"))
                        .textFieldStyle(.roundedBorder)
                        .frame(width: Self.identityFieldWidth)
                        .onChange(of: emoji) { _, newValue in
                            let constrained = Self.constrainToOneEmoji(newValue)
                            if constrained != newValue { emoji = constrained }
                        }
                }
            }
        }
    }

    /// Keep the Emoji field to a single grapheme (TECH-WF2): the system palette
    /// or a paste can drop in several, so keep the last one so a fresh pick
    /// replaces the old. A grapheme cluster (flag, ZWJ family) counts as one.
    static func constrainToOneEmoji(_ raw: String) -> String {
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let last = trimmed.last else { return "" }
        return String(last)
    }

    /// A swatch button that opens a small palette popover anchored to the field
    /// (TECH-WF3), replacing the native `ColorPicker` whose shared system panel
    /// floated detached at a screen corner. The popover is the only colour
    /// control (TECH-DSN11): it offers the curated `MPColors.workflowSwatches`.
    private var colorSwatchButton: some View {
        Button {
            colorPopoverOpen = true
        } label: {
            RoundedRectangle(cornerRadius: 5)
                .fill(HexColor.parse(color).map { Color(nsColor: $0) } ?? Color(nsColor: MPColors.signal600))
                .frame(width: 38, height: 22)
                .overlay(
                    RoundedRectangle(cornerRadius: 5)
                        .strokeBorder(Color.secondary.opacity(0.3), lineWidth: 1)
                )
        }
        .buttonStyle(.plain)
        .popover(isPresented: $colorPopoverOpen, arrowEdge: .bottom) {
            colorPalettePopover
        }
    }

    private var colorPalettePopover: some View {
        let columns = Array(repeating: GridItem(.fixed(26), spacing: 8), count: 6)
        return LazyVGrid(columns: columns, spacing: 8) {
            ForEach(MPColors.workflowSwatches, id: \.self) { hex in
                Button {
                    color = hex
                    colorPopoverOpen = false
                } label: {
                    Circle()
                        .fill(Color(nsColor: HexColor.parse(hex) ?? .gray))
                        .frame(width: 24, height: 24)
                        .overlay(
                            Circle().strokeBorder(
                                isSelectedColor(hex) ? Color.primary : Color.secondary.opacity(0.25),
                                lineWidth: isSelectedColor(hex) ? 2 : 1
                            )
                        )
                }
                .buttonStyle(.plain)
                .help(hex)
            }
        }
        .padding(12)
        .frame(width: 220)
    }

    private func isSelectedColor(_ hex: String) -> Bool {
        color.trimmingCharacters(in: .whitespaces).uppercased() == hex.uppercased()
    }

    private var matchingRulesSection: some View {
        Section("Matching rules") {
            if matchingRules.isEmpty {
                Text("No rules - this workflow matches only when used as the default.")
                    .font(.caption)
                    .foregroundStyle(Color(MPColors.fgMuted))
            } else {
                // Iterate by value/id, not a positional `$matchingRules`
                // binding: removing a row inside a binding-based ForEach makes
                // SwiftUI read a now-missing index on the next render and crash
                // (the per-row "minus" delete button hit this).
                ForEach(matchingRules) { rule in
                    matchingRuleRow(id: rule.id)
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
                .foregroundStyle(Color(MPColors.fgMuted))
        }
    }

    private func matchingRuleRow(id: UUID) -> some View {
        HStack(alignment: .top, spacing: 8) {
            VStack(spacing: 4) {
                TextField("bundle id", text: ruleBinding(id, \.bundleID))
                    .textFieldStyle(.roundedBorder)
                    .font(.system(.body, design: .monospaced))
                TextField("title regex (optional)", text: ruleBinding(id, \.titleRegex))
                    .textFieldStyle(.roundedBorder)
                    .font(.system(.body, design: .monospaced))
            }
            Button(role: .destructive) {
                matchingRules.removeAll { $0.id == id }
            } label: {
                Image(systemName: "minus.circle")
            }
            .buttonStyle(.borderless)
        }
    }

    /// Id-keyed binding into `matchingRules`, so a row never holds a positional
    /// binding that goes stale when a different row is removed (TECH-WF crash fix).
    private func ruleBinding(_ id: UUID, _ keyPath: WritableKeyPath<WorkflowMatchingRule, String>) -> Binding<String> {
        Binding(
            get: { matchingRules.first(where: { $0.id == id })?[keyPath: keyPath] ?? "" },
            set: { newValue in
                if let i = matchingRules.firstIndex(where: { $0.id == id }) {
                    matchingRules[i][keyPath: keyPath] = newValue
                }
            }
        )
    }

    private var contextSection: some View {
        Section("Context prompt") {
            TextEditor(text: $contextPrompt)
                .font(.system(.body, design: .monospaced))
                .frame(minHeight: 120, maxHeight: 240)
                .border(Color.secondary.opacity(0.2))
            Text("Seasoning the LLM sees for every meeting matched by this workflow. Example: \"Confidential client meeting; redact names; FDA 21 CFR Part 11 context.\"")
                .font(.caption)
                .foregroundStyle(Color(MPColors.fgMuted))
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
                    .foregroundStyle(.mpWarning)
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
        // NDA workflows are local-only; don't offer a network DB fetch for them
        // (the regulated global flag is gated inside refresh()). (TECH-SEC4)
        .disabled(notionDBs.state == .loading || ndaMode)
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
                    .foregroundStyle(Color(MPColors.fgMuted))
            }
        case .loaded(let list):
            Text("\(list.count) database\(list.count == 1 ? "" : "s") cached")
                .font(.caption2)
                .foregroundStyle(Color(MPColors.fgSubtle))
        case .failed(let err):
            Text(err)
                .font(.caption)
                .foregroundStyle(.mpDanger)
                .lineLimit(2)
        }
    }

    private var backendSection: some View {
        Section("Backend") {
            // Menu (not segmented): five options overflow the segmented control,
            // the same reason Preferences uses a menu picker here. (TECH-WF1)
            Picker("", selection: $backend) {
                Text("Use global default").tag(WorkflowBackend?.none)
                Text("Anthropic (cloud)").tag(WorkflowBackend?.some(.anthropic))
                Text("Local MLX").tag(WorkflowBackend?.some(.local))
                Text("Auto (cloud, fall back to local)").tag(WorkflowBackend?.some(.auto))
                Text("Apple Intelligence (on-device)").tag(WorkflowBackend?.some(.appleIntelligence))
            }
            .labelsHidden()
            .pickerStyle(.menu)
            .disabled(ndaMode)
            if ndaMode {
                Text("NDA mode forces the local backend; the picker is disabled.")
                    .font(.caption)
                    .foregroundStyle(.mpWarning)
            } else if backend == nil {
                Text("Inherits the backend from Preferences > Pipeline.")
                    .font(.caption)
                    .foregroundStyle(Color(MPColors.fgMuted))
            } else if backend == .appleIntelligence, let reason = AppleIntelligenceSummarizer.availabilityReason {
                Text("Apple Intelligence is unavailable here: \(reason)")
                    .font(.caption)
                    .foregroundStyle(.mpWarning)
            }
        }
    }

    private var flagsSection: some View {
        Section("Flags") {
            Toggle("NDA mode (force local backend, filesystem only)", isOn: $ndaMode)
            Text("Surfaces in the HUD and the menu-bar title so a misroute is visible before the meeting starts.")
                .font(.caption)
                .foregroundStyle(Color(MPColors.fgMuted))
            Toggle("Redact muted spans from the notes", isOn: $redactMutedSpans)
            Text("Off by default: the full mic is kept and transcribed (a fragile mute oracle can never silently drop your speech). On, muted moments are removed from the consumed notes offline; the full recording is still kept aside for recovery.")
                .font(.caption)
                .foregroundStyle(Color(MPColors.fgMuted))
        }
    }

    private var defaultSection: some View {
        Section("Default") {
            Toggle("Use as default", isOn: $isDefault)
                .disabled(workflow.isDefault)
            Text("The default workflow matches any meeting that no other workflow's rules pick up. Toggle on a different workflow here to switch the default.")
                .font(.caption)
                .foregroundStyle(Color(MPColors.fgMuted))
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
        redactMutedSpans = workflow.flags.redactMutedSpans
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
        clone.color = color.isEmpty ? MPColors.defaultWorkflowHex : color
        clone.emoji = emoji.isEmpty ? nil : emoji
        clone.contextPrompt = contextPrompt
        clone.isDefault = isDefault
        clone.matchingRules = matchingRules
        clone.sinks = sinks.toWorkflowSinks()
        clone.backend = backend
        clone.flags.ndaMode = ndaMode
        clone.flags.redactMutedSpans = redactMutedSpans
        do {
            try store.upsert(clone)
            saveError = nil
            onCommit?()
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
