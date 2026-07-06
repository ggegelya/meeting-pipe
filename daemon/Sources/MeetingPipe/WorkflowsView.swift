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
        // WF6: rebuilt on the Preferences design system (SettingsGroup / SettingsRow
        // / SettingsToggleRow / SettingsMenuPicker) so a workflow reads as one
        // product with Preferences, replacing the stock grouped `Form` that made
        // editing "feel off". Each group self-spaces (SettingsGroup pads its own
        // bottom), so the outer stack is spacing 0.
        ScrollView {
            VStack(alignment: .leading, spacing: 0) {
                header
                identitySection
                matchingRulesSection
                contextSection
                sinksSection
                backendSection
                flagsSection
                defaultSection
                if let err = saveError {
                    Text(err)
                        .font(.mpTextSM)
                        .foregroundStyle(.mpDanger)
                        .padding(.bottom, 12)
                }
                actionsRow
            }
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
                Text(emoji).font(.mpTextXL)
            } else if let parsed = HexColor.parse(color) {
                Circle().fill(Color(parsed)).frame(width: 16, height: 16)
            }
            Text(name.isEmpty ? "Untitled workflow" : name)
                .font(.mpTextLG.weight(.semibold))
            if workflow.isDefault {
                Text("default")
                    .font(.mpTextXS)
                    .foregroundStyle(Color(MPColors.fgMuted))
                    .padding(.horizontal, 6).padding(.vertical, 2)
                    .background(Capsule().fill(Color(MPColors.bgSunk)))
            }
            Spacer()
        }
        .padding(.bottom, 16)
    }

    // MARK: Sections

    /// Shared trailing-control width so the Color and Emoji rows line up under
    /// the Name field instead of each picking its own size (TECH-WF4).
    private static let identityFieldWidth: CGFloat = 150

    private var identitySection: some View {
        SettingsGroup("Identity") {
            // Name is the primary field, so it stacks full-width under its label
            // (SettingsStackRow); Color and Emoji are compact trailing controls.
            SettingsStackRow("Name", showsDivider: false) {
                TextField("", text: $name, prompt: Text("Untitled workflow"))
                    .textFieldStyle(.roundedBorder)
                    .frame(maxWidth: .infinity)
                    .onSubmit(save)
            }
            SettingsRow("Color") {
                // Curated swatches only (TECH-DSN11): the popover is the sole
                // colour control so workflows stay a tonal family. No free-hex
                // field - it was the path off-palette colours leaked in.
                colorSwatchButton
            }
            SettingsRow("Emoji") {
                Button {
                    NSApp.orderFrontCharacterPalette(nil)
                } label: {
                    Image(systemName: "face.smiling")
                }
                .buttonStyle(.mpIcon)
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
        SettingsGroup("Matching rules") {
            if matchingRules.isEmpty {
                SettingsFullRow(showsDivider: false) {
                    Text("No rules - this workflow matches only when used as the default.")
                        .font(.mpTextSM)
                        .foregroundStyle(Color(MPColors.fgMuted))
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
            } else {
                // Iterate by id (WorkflowMatchingRule is Identifiable); the row's
                // own "minus" button removes by id, so no positional
                // `$matchingRules` binding goes stale on delete. `.onDelete` is
                // dropped with the Form (it only works inside a List/Form); the
                // per-row minus button is the delete path.
                ForEach(Array(matchingRules.enumerated()), id: \.element.id) { idx, rule in
                    SettingsFullRow(showsDivider: idx > 0) {
                        matchingRuleRow(id: rule.id)
                    }
                }
            }
            SettingsFullRow {
                Button {
                    matchingRules.append(WorkflowMatchingRule())
                } label: {
                    Label("Add rule", systemImage: "plus")
                }
                .buttonStyle(.mpGhost)
                .frame(maxWidth: .infinity, alignment: .leading)
            }
        } footer: {
            Text("Bundle id matches the meeting app (e.g. `us.zoom.xos`, `com.microsoft.teams2`). Title regex is case-insensitive and tests the window title; useful to split a single browser into per-tab workflows.")
        }
    }

    private func matchingRuleRow(id: UUID) -> some View {
        HStack(alignment: .top, spacing: 8) {
            VStack(spacing: 4) {
                TextField("bundle id", text: ruleBinding(id, \.bundleID))
                    .textFieldStyle(.roundedBorder)
                    .font(.mpTextBase.monospaced())
                TextField("title regex (optional)", text: ruleBinding(id, \.titleRegex))
                    .textFieldStyle(.roundedBorder)
                    .font(.mpTextBase.monospaced())
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
        SettingsGroup("Context prompt") {
            SettingsFullRow(showsDivider: false) {
                TextEditor(text: $contextPrompt)
                    .font(.mpTextBase.monospaced())
                    .frame(minHeight: 120, maxHeight: 240)
                    .scrollContentBackground(.hidden)
                    .padding(6)
                    .background(
                        RoundedRectangle(cornerRadius: MPRadius.sm, style: .continuous)
                            .fill(Color(NSColor.textBackgroundColor))
                    )
                    .overlay(
                        RoundedRectangle(cornerRadius: MPRadius.sm, style: .continuous)
                            .strokeBorder(Color(MPColors.border), lineWidth: 1)
                    )
            }
        } footer: {
            Text("Seasoning the LLM sees for every meeting matched by this workflow. Example: \"Confidential client meeting; redact names; FDA 21 CFR Part 11 context.\"")
        }
    }

    private var sinksSection: some View {
        SettingsGroup("Sinks") {
            SettingsToggleRow("Notion", isOn: $sinks.notionEnabled, showsDivider: false)
            if sinks.notionEnabled {
                SettingsFullRow(showsDivider: false) {
                    notionDBPicker
                }
            }
            SettingsToggleRow("Obsidian", isOn: $sinks.obsidianEnabled)
            SettingsToggleRow("Filesystem (local Markdown only)", isOn: $sinks.filesystemEnabled)
            if ndaMode {
                note("NDA mode forces filesystem-only; toggles above are ignored at run time.", color: .mpWarning)
            }
        }
    }

    /// A full-width caption row inside a card, the design-system replacement for
    /// the stock `Text().font(.caption)` help/warning lines the grouped Form used
    /// (WF6). Warning lines pass `.mpWarning`, neutral help `Color(MPColors.fgMuted)`.
    private func note(_ text: String, color: Color) -> some View {
        SettingsFullRow {
            Text(text)
                .font(.mpTextSM)
                .foregroundStyle(color)
                .fixedSize(horizontal: false, vertical: true)
                .frame(maxWidth: .infinity, alignment: .leading)
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
                        .font(.mpTextBase.monospaced())
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
                    .font(.mpTextSM)
                    .foregroundStyle(Color(MPColors.fgMuted))
            }
        case .loaded(let list):
            Text("\(list.count) database\(list.count == 1 ? "" : "s") cached")
                .font(.mpTextXS)
                .foregroundStyle(Color(MPColors.fgSubtle))
        case .failed(let err):
            Text(err)
                .font(.mpTextSM)
                .foregroundStyle(.mpDanger)
                .lineLimit(2)
        }
    }

    private var backendSection: some View {
        SettingsGroup("Backend") {
            // Menu (not segmented): five options overflow a segmented control,
            // the same reason Preferences uses a menu picker here (TECH-WF1). 260pt
            // so the longest label ("Auto (cloud, fall back to local)") fits.
            SettingsRow("Backend", showsDivider: false) {
                SettingsMenuPicker(
                    selection: $backend,
                    options: [
                        (WorkflowBackend?.none,      "Use global default"),
                        (.some(.anthropic),          "Anthropic (cloud)"),
                        (.some(.local),              "Local MLX"),
                        (.some(.auto),               "Auto (cloud, fall back to local)"),
                        (.some(.appleIntelligence),  "Apple Intelligence (on-device)"),
                    ],
                    width: 260
                )
                .disabled(ndaMode)
            }
            if ndaMode {
                note("NDA mode forces the local backend; the picker is disabled.", color: .mpWarning)
            } else if backend == nil {
                note("Inherits the backend from Preferences > Pipeline.", color: Color(MPColors.fgMuted))
            } else if backend == .appleIntelligence, let reason = AppleIntelligenceSummarizer.availabilityReason {
                note("Apple Intelligence is unavailable here: \(reason)", color: .mpWarning)
            }
        }
    }

    private var flagsSection: some View {
        SettingsGroup("Flags") {
            SettingsToggleRow(
                "NDA mode (force local backend, filesystem only)",
                sublabel: "Surfaces in the HUD and the menu-bar title so a misroute is visible before the meeting starts.",
                isOn: $ndaMode,
                showsDivider: false
            )
            SettingsToggleRow(
                "Redact muted spans from the notes",
                sublabel: "Off by default: the full mic is kept and transcribed (a fragile mute oracle can never silently drop your speech). On, muted moments are removed from the consumed notes offline; the full recording is still kept aside for recovery.",
                isOn: $redactMutedSpans
            )
        }
    }

    private var defaultSection: some View {
        SettingsGroup("Default") {
            SettingsToggleRow(
                "Use as default",
                sublabel: "The default workflow matches any meeting that no other workflow's rules pick up. Toggle on a different workflow here to switch the default.",
                isOn: $isDefault,
                showsDivider: false
            )
            .disabled(workflow.isDefault)
        }
    }

    private var actionsRow: some View {
        HStack {
            Button("Save", action: save)
                .buttonStyle(.mpGhost)
                .keyboardShortcut(.defaultAction)
            Spacer()
            // Neutral ghost capsule + trash glyph; the destructive emphasis lives
            // in the confirmation alert's `.destructive` Delete, matching DSN28's
            // move off colored inline buttons (there is no `.mpDanger` capsule).
            Button(role: .destructive) {
                pendingDeleteAlert = true
            } label: {
                Label("Delete", systemImage: "trash")
            }
            .buttonStyle(.mpGhost)
            .disabled(workflow.isDefault)
        }
        .padding(.top, 4)
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
