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
    /// UX45: the fourth case. The pipeline has published to a mounted share since
    /// FEAT1; this checkbox is what made it reachable per workflow.
    var lanEnabled: Bool = false

    /// Rebuild `Workflow.sinks` from checkbox state; order matches the form rows (Notion, Obsidian, Filesystem, LAN).
    func toWorkflowSinks() -> [WorkflowSink] {
        var out: [WorkflowSink] = []
        if notionEnabled { out.append(.notion(databaseId: notionDatabaseID)) }
        if obsidianEnabled { out.append(.obsidian) }
        if filesystemEnabled { out.append(.filesystem) }
        if lanEnabled { out.append(.lan) }
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
            case .lan:
                s.lanEnabled = true
            }
        }
        return s
    }

    func isEnabled(_ target: PublishTarget) -> Bool {
        switch target {
        case .obsidian:   return obsidianEnabled
        case .filesystem: return filesystemEnabled
        case .lan:        return lanEnabled
        }
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
    /// Called after a *successful* delete, for the same reason (UX30): a confirmed delete
    /// used to leave the sheet open over a workflow that no longer existed. Defaults to
    /// `onCommit`, which is the right close path for the edit sheet. The new-workflow
    /// sheet overrides it because its commit hook routes the rail to the id it just
    /// created, and after a delete that id names nothing.
    var onDelete: (() -> Void)? = nil
    /// UX21: lets the editor offer an inline model download when this workflow
    /// resolves to the on-device backend but the MLX model is not yet cached. Nil
    /// in headless tests and any host that has no daemon behind it.
    var localModelPreflight: LocalModelPreflight? = nil
    /// UX44: opens Preferences ▸ Pipeline ▸ Vocabulary with this workflow's scope
    /// preselected. Nil in headless tests and any host with no Preferences window
    /// behind it, in which case the link row is not drawn at all rather than drawn dead.
    var onOpenVocabulary: ((String) -> Void)? = nil
    /// UX45: where the non-Notion sinks write, so a checkbox that turns on a sink
    /// with no destination says so instead of failing silently at publish time. A
    /// snapshot, injected the same way `localModelPreflight` is; nil in headless
    /// tests and any host with no `ConfigStore` behind it, which then show no
    /// captions rather than guessing.
    var publishTargets: PublishTargets? = nil
    /// Notion DB list for the picker (TECH-B8). Held at editor level so the picker is populated on open, not only when Notion is toggled on.
    @StateObject private var notionDBs = NotionDatabaseList()

    @State private var name: String = ""
    @State private var color: String = ""
    @State private var emoji: String = ""
    @State private var contextPrompt: String = ""
    @State private var isDefault: Bool = false
    @State private var matchingRules: [WorkflowMatchingRule] = []
    @State private var extraSections: [WorkflowExtraSection] = []
    @State private var sinks = SinkSelection()
    @State private var backend: WorkflowBackend? = nil
    @State private var ndaMode: Bool = false
    @State private var redactMutedSpans: Bool = false
    @State private var retentionPolicy: RetentionPolicy = .keep
    @State private var retentionAfterDays: Int = 30
    @State private var pendingDeleteAlert: Bool = false
    @State private var saveError: String?
    @State private var colorPopoverOpen: Bool = false
    /// UX21: whether the configured local model is uncached while this workflow
    /// resolves to the local backend. Cached in state (refreshed on appear and on
    /// a backend / NDA change) so the filesystem cache probe never runs per-render.
    @State private var localModelMissing: Bool = false
    /// UX21: latched once the user taps "Download now", so the affordance switches
    /// from the button to a quiet "downloading, see the menu bar" acknowledgement.
    @State private var localModelDownloadStarted: Bool = false

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
                vocabularySection
                extraSectionsSection
                sinksSection
                backendSection
                flagsSection
                retentionSection
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
        .onChange(of: ndaMode) { _, _ in refreshLocalModelMissing() }
        .onChange(of: backend) { _, _ in refreshLocalModelMissing() }
        .alert(WorkflowDeletion.confirmTitle, isPresented: $pendingDeleteAlert) {
            Button("Cancel", role: .cancel) {}
            Button(WorkflowDeletion.confirmButton, role: .destructive, action: deleteSelf)
        } message: {
            Text(WorkflowDeletion.confirmMessage)
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
            // WF9: a quiet hint row under the field it is about, never a block.
            // Renaming a workflow is common and refusing the save would be hostile, but
            // the Library resolves a meeting's workflow by name, so a collision costs
            // the owner a scope whose counts nothing in the UI can explain. Say so while
            // it is still free to change.
            if let hint = nameCollisionHint {
                note(hint, color: .mpWarning)
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

    /// WF9: the live name field against every other workflow in the store. Reads the
    /// typed value, not the saved one, so the hint appears as the collision is typed and
    /// clears the moment it is edited away.
    private var nameCollisionHint: String? {
        let trimmed = name.trimmingCharacters(in: .whitespaces)
        return WorkflowNameCollision.explanation(
            name: trimmed,
            others: WorkflowNameCollision.others(
                named: trimmed, excluding: workflow.id, in: store.workflows
            )
        )
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

    // MARK: Extra sections (WF7)

    private var extraSectionsSection: some View {
        SettingsGroup("Extra summary sections") {
            if extraSections.isEmpty {
                SettingsFullRow(showsDivider: false) {
                    Text("None - this workflow uses the standard summary shape.")
                        .font(.mpTextSM)
                        .foregroundStyle(Color(MPColors.fgMuted))
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
            } else {
                ForEach(Array(extraSections.enumerated()), id: \.element.id) { idx, sec in
                    SettingsFullRow(showsDivider: idx > 0) {
                        extraSectionRow(id: sec.id)
                    }
                }
            }
            SettingsFullRow {
                Button {
                    extraSections.append(WorkflowExtraSection())
                } label: {
                    Label("Add section", systemImage: "plus")
                }
                .buttonStyle(.mpGhost)
                .frame(maxWidth: .infinity, alignment: .leading)
            }
        } footer: {
            Text("Extra sections the summarizer fills for every meeting in this workflow, on top of the standard ones. Name the section (e.g. \"Billable follow-ups\") and tell the model what to put there. Rendered read-only in the Library and in every publisher. A row with a blank name or instruction is ignored.")
        }
    }

    private func extraSectionRow(id: UUID) -> some View {
        HStack(alignment: .top, spacing: 8) {
            VStack(spacing: 4) {
                TextField("section name", text: sectionBinding(id, \.name))
                    .textFieldStyle(.roundedBorder)
                TextField("instruction for the model", text: sectionBinding(id, \.instruction))
                    .textFieldStyle(.roundedBorder)
            }
            Button(role: .destructive) {
                extraSections.removeAll { $0.id == id }
            } label: {
                Image(systemName: "minus.circle")
            }
            .buttonStyle(.borderless)
        }
    }

    /// Id-keyed binding into `extraSections` (the `ruleBinding` idiom), so a row's
    /// binding never goes stale when a different row is removed.
    private func sectionBinding(_ id: UUID, _ keyPath: WritableKeyPath<WorkflowExtraSection, String>) -> Binding<String> {
        Binding(
            get: { extraSections.first(where: { $0.id == id })?[keyPath: keyPath] ?? "" },
            set: { newValue in
                if let i = extraSections.firstIndex(where: { $0.id == id }) {
                    extraSections[i][keyPath: keyPath] = newValue
                }
            }
        )
    }

    /// UX44: the cross-link out to this workflow's own vocabulary. Renders under the
    /// context prompt (see `body`), because the two are the same idea from either end:
    /// the context prompt is what the model is told about this workflow, the vocabulary
    /// is what the transcriber is. FEAT11 shipped per-workflow terms with no mention of
    /// them anywhere near a workflow, so reaching them meant leaving the sheet, opening
    /// Preferences, and re-selecting the workflow you had just been editing.
    ///
    /// It links rather than embeds deliberately: the terms live in a file this sheet does
    /// not own, edited by a store this sheet does not hold, and a second editor over the
    /// same table is how two writers end up racing the same debounce.
    ///
    /// Sends the **saved** name, not the live field: `glossary.toml` keys a workflow's
    /// table by name, and an unsaved rename names a table that does not exist yet.
    @ViewBuilder
    private var vocabularySection: some View {
        if let open = onOpenVocabulary {
            SettingsGroup("Vocabulary") {
                SettingsFullRow(showsDivider: false) {
                    HStack(spacing: 10) {
                        Text(WorkflowVocabularyLink.caption)
                            .font(.mpTextSM)
                            .foregroundStyle(Color(MPColors.fgMuted))
                            .fixedSize(horizontal: false, vertical: true)
                        Spacer(minLength: 0)
                        Button(WorkflowVocabularyLink.buttonLabel) { open(workflow.name) }
                            .buttonStyle(.mpGhost)
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                }
            }
        }
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
                    // FEAT11: TextEditor has no prompt, so an empty one used to be a
                    // blank box next to a one-line footer, and both of the owner's NDA
                    // workflows stayed empty. Overlay the guidance instead, hit-testing
                    // off so a click still lands in the editor beneath it.
                    .overlay(alignment: .topLeading) {
                        if WorkflowContextHint.needsContext(prompt: contextPrompt) {
                            Text(WorkflowContextHint.placeholder)
                                .font(.mpTextXS.monospaced())
                                .foregroundStyle(Color(MPColors.fgSubtle))
                                .padding(.horizontal, 11)
                                .padding(.vertical, 12)
                                .allowsHitTesting(false)
                                .accessibilityHidden(true)
                        }
                    }
            }
        } footer: {
            Text("Seasoning the LLM sees for every meeting matched by this workflow. It costs the model nothing to be told what it would otherwise have to guess, and the smaller the backend, the more this is worth.")
        }
    }

    private var sinksSection: some View {
        SettingsGroup("Sinks") {
            SettingsToggleRow("Notion", isOn: $sinks.notionEnabled, showsDivider: false)
            if sinks.notionEnabled {
                SettingsFullRow(showsDivider: false) {
                    NotionDatabasePicker(
                        databaseID: $sinks.notionDatabaseID,
                        list: notionDBs,
                        disableFetch: ndaMode
                    )
                }
            }
            SettingsToggleRow("Obsidian", isOn: $sinks.obsidianEnabled)
            unconfiguredNote(.obsidian)
            SettingsToggleRow("Filesystem (local Markdown only)", isOn: $sinks.filesystemEnabled)
            unconfiguredNote(.filesystem)
            SettingsToggleRow(
                "LAN share",
                sublabel: "A mounted SMB/NFS share. The same files as the filesystem sink, written only after a reachability check, so a share that is down fails loudly instead of quietly landing on local disk.",
                isOn: $sinks.lanEnabled
            )
            unconfiguredNote(.lan)
            if ndaMode {
                note("NDA mode forces filesystem-only; toggles above are ignored at run time.", color: .mpWarning)
            }
        }
    }

    /// UX45: the quiet cue under a sink whose destination was never set, the WF9
    /// name-collision shape. Enable-but-broken used to be entirely silent: three
    /// of these four sinks are configured in global config, and until UX45 that
    /// config had no UI at all, so a checkbox could turn on a publish that could
    /// never happen. Absent (not empty) when the caption has nothing to say, and
    /// absent everywhere when the host handed in no targets, which is the headless
    /// and test case.
    @ViewBuilder
    private func unconfiguredNote(_ target: PublishTarget) -> some View {
        if let caption = publishTargets?.caption(for: target, enabled: sinks.isEnabled(target)) {
            note(caption, color: .mpWarning)
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

    private var backendSection: some View {
        SettingsGroup("Backend") {
            // Menu (not segmented): the options overflow a segmented control,
            // the same reason Preferences uses a menu picker here (TECH-WF1). 260pt
            // so the longest label ("Auto (cloud, fall back to local)") fits.
            SettingsRow("Backend", showsDivider: false) {
                SettingsMenuPicker(
                    selection: $backend,
                    options: Self.backendOptions,
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
            if localModelMissing {
                localModelDownloadRow
            }
        }
    }

    /// The workflow backend picker's rows (UX31). Every pinnable backend, named
    /// out of the one vocabulary, plus the inherit row. `claude_cli` and `openai`
    /// were missing here while the global setting offered them, so a workflow
    /// could not pin an engine the product already shipped; the pipeline accepted
    /// both all along (see `WorkflowBackend`).
    static let backendOptions: [(value: WorkflowBackend?, label: String)] =
        [(value: WorkflowBackend?.none, label: "Use global default")]
            + WorkflowBackend.allCases.map { (value: .some($0), label: $0.engine.pickerLabel) }

    /// UX21: the inline "model not downloaded" affordance. Shown when this
    /// workflow resolves to the on-device backend but the MLX model is not cached,
    /// so the first meeting summarizes fine only if the model is fetched first.
    /// "Download now" routes through the daemon's shared supervisor (progress in
    /// the menu bar); the download persists after this sheet closes.
    @ViewBuilder
    private var localModelDownloadRow: some View {
        SettingsFullRow {
            HStack(spacing: 10) {
                Image(systemName: "arrow.down.circle")
                    .foregroundStyle(.mpWarning)
                if localModelDownloadStarted {
                    Text("Downloading the local model. Progress shows in the menu bar.")
                        .font(.mpTextSM)
                        .foregroundStyle(Color(MPColors.fgMuted))
                        .fixedSize(horizontal: false, vertical: true)
                    Spacer(minLength: 0)
                } else {
                    Text("The local model is not downloaded (\(localModelPreflight?.downloadSizeLabel() ?? "several GB")). It is needed before this workflow's first meeting.")
                        .font(.mpTextSM)
                        .foregroundStyle(Color(MPColors.fgMuted))
                        .fixedSize(horizontal: false, vertical: true)
                    Spacer(minLength: 0)
                    Button("Download now") {
                        localModelPreflight?.startDownload()
                        localModelDownloadStarted = true
                    }
                    .buttonStyle(.mpGhost)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
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

    /// STOR1. Deliberately the last thing in the editor before Default: it is the
    /// only setting here that deletes data, and it should read as a decision, not
    /// a toggle you flip on the way past.
    private var retentionSection: some View {
        SettingsGroup("Audio retention") {
            SettingsRow("When a meeting is done", showsDivider: retentionPolicy != .keep) {
                SettingsMenuPicker(
                    selection: $retentionPolicy,
                    options: [
                        (RetentionPolicy.keep,     "Keep the audio forever"),
                        (.compress,                "Compress it to FLAC"),
                        (.drop,                    "Delete the audio"),
                    ],
                    width: 260
                )
            }
            if retentionPolicy != .keep {
                SettingsRow("After", sublabel: "Days from the meeting's start.", showsDivider: false) {
                    SettingsMenuPicker(
                        selection: $retentionAfterDays,
                        options: [(7, "7 days"), (30, "30 days"), (90, "90 days"), (365, "1 year")],
                        width: 140
                    )
                }
            }
        } footer: {
            switch retentionPolicy {
            case .keep:
                Text("Nothing is ever reclaimed. An hour of meeting is about 0.7 GB.")
            case .compress:
                Text("Lossless: the recording still plays, still shows a waveform, and can still be reprocessed. Quiet speech roughly halves; a noisy room saves less.")
            case .drop:
                Text("The transcript and summary are kept, the recording is not. This cannot be undone, and a deleted recording cannot be re-transcribed.")
            }
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
            // UX30: the shared destructive style, not a neutral ghost capsule. The comment
            // that used to sit here justified the ghost with "there is no `.mpDanger`
            // capsule", which was never true: the style shipped for the Library's own
            // "Move to Trash", just declared private inside `BatchActionsPane`. It is now
            // `.mpDanger` in `Preferences/PreferencesControls.swift` and both use it, so
            // this control carries the same weight as every other delete in the app
            // instead of reading like a peer of Save.
            if workflow.isDefault {
                Text(WorkflowDeletion.defaultDisabledReason)
                    .font(.mpTextXS)
                    .foregroundStyle(Color(MPColors.fgMuted))
                    .fixedSize(horizontal: false, vertical: true)
                    .padding(.trailing, 8)
            }
            Button(role: .destructive) {
                pendingDeleteAlert = true
            } label: {
                Label("Delete", systemImage: "trash")
            }
            .buttonStyle(.mpDanger)
            .disabled(workflow.isDefault)
            // The disabled control used to give no reason for being disabled. The caption
            // above is the visible half; these carry it to the tooltip and to VoiceOver,
            // which the caption alone would not reach in reading order.
            .help(workflow.isDefault ? WorkflowDeletion.defaultDisabledReason : "")
            .accessibilityHint(workflow.isDefault ? WorkflowDeletion.defaultDisabledReason : "")
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
        extraSections = workflow.extraSections
        sinks = SinkSelection.from(workflow.sinks)
        backend = workflow.backend
        ndaMode = workflow.flags.ndaMode
        redactMutedSpans = workflow.flags.redactMutedSpans
        retentionPolicy = workflow.retention.policy
        retentionAfterDays = workflow.retention.afterDays
        saveError = nil
        localModelDownloadStarted = false
        refreshLocalModelMissing()
    }

    /// UX21: recompute whether the on-device model download should be offered.
    /// Only when the workflow resolves to the local backend (an NDA flag, or a
    /// `.local` pin) AND the model is uncached. The preflight's probe is a
    /// filesystem scan, so this runs on appear and on a backend / NDA change, not
    /// per-render.
    private func refreshLocalModelMissing() {
        let resolvesLocal = ndaMode || backend == .local
        localModelMissing = resolvesLocal && (localModelPreflight?.isModelMissing() ?? false)
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
        clone.extraSections = extraSections.filter {
            !$0.name.trimmingCharacters(in: .whitespaces).isEmpty
                || !$0.instruction.trimmingCharacters(in: .whitespaces).isEmpty
        }
        clone.sinks = sinks.toWorkflowSinks()
        clone.backend = backend
        clone.flags.ndaMode = ndaMode
        clone.flags.redactMutedSpans = redactMutedSpans
        clone.retention = WorkflowRetention(policy: retentionPolicy, afterDays: retentionAfterDays)
        do {
            // `update`, not `upsert` (UX30): the editor always edits something the store
            // already holds, even in the New workflow sheet, whose stub is persisted on
            // open. Routing Save through the update-only door is the belt against the
            // silent undo, so a Return aimed at a workflow that was deleted out from under
            // this sheet says so instead of appending it back.
            guard try store.update(clone) else {
                saveError = WorkflowDeletion.saveAfterDeleteReason
                return
            }
            saveError = nil
            onCommit?()
        } catch {
            saveError = error.localizedDescription
        }
    }

    /// UX30: the whole delete path is `WorkflowDeletion.run`, so the rail row's own Delete
    /// (UX32) shares this flow rather than re-deriving it. On success the host sheet
    /// dismisses, exactly once; a refusal or a failure lands its reason in the same
    /// `saveError` slot a failed Save uses, instead of closing as if it had worked.
    private func deleteSelf() {
        WorkflowDeletion.run(
            id: workflow.id,
            store: store,
            dismiss: { (onDelete ?? onCommit)?() },
            report: { saveError = $0 }
        )
    }
}
