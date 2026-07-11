import AppKit
import SwiftUI

struct PipelineSectionView: View {
    @ObservedObject var store: ConfigStore
    @ObservedObject private var ui = UISettings.shared
    @State private var promptText: String?
    @State private var promptLoading = false
    @State private var promptError: String?
    @State private var showLocalModelConfig = false
    @State private var voiceprintMeetings = 0

    // FEAT3-MANAGE: the named-speaker roster. Read directly for display (the
    // `VoiceprintProfile` exception); mutations go through `mp roster` via `launcher`.
    @State private var rosterPeople: [RosterProfile.Person] = []
    @State private var rosterError: String?
    @State private var launcher = PipelineLauncher()

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            SettingsSectionHeader("Pipeline",
                caption: "What runs after the recording stops: summarization and languages. Transcription is in-process (FluidAudio).")

            SettingsGroup("Summarization") {
                SettingsRow("Backend", showsDivider: false) {
                    // Dropdown (not segmented): four backends in a segmented
                    // control stretched the window off-screen; a menu stays a
                    // fixed width regardless of how many backends exist.
                    SettingsMenuPicker(
                        selection: $store.summarizationBackend,
                        options: [
                            ("anthropic",          "Anthropic"),
                            ("local",              "Local MLX"),
                            ("auto",               "Auto"),
                            ("apple_intelligence", "Apple (experimental)"),
                        ]
                    )
                }
                if store.summarizationBackend == "local" || store.summarizationBackend == "auto" {
                    // The local-MLX cluster (preset, model id, endpoint, active
                    // model, preload) is collapsed behind a disclosure so the
                    // common case (just pick a backend) stays uncluttered. (DSN1)
                    SettingsDisclosure("Configure local model",
                        sublabel: "Model preset, endpoint, active model, and preload.",
                        isExpanded: $showLocalModelConfig) {
                        SettingsRow("Local model",
                            sublabel: localModelHint) {
                            Picker("", selection: localModelPresetBinding) {
                                ForEach(LocalModelPreset.all, id: \.id) { preset in
                                    Text(preset.label).tag(preset.id)
                                }
                                Text("Custom").tag(LocalModelPreset.customId)
                            }
                            .labelsHidden()
                            .pickerStyle(.menu)
                            .fixedSize()
                        }
                        if currentLocalModelPresetId == LocalModelPreset.customId {
                            SettingsStackRow("Model id",
                                sublabel: "HuggingFace MLX repo id.") {
                                TextField("mlx-community/...", text: $store.summarizationLocalModel)
                                    .textFieldStyle(.roundedBorder)
                                    .font(.system(.body, design: .monospaced))
                            }
                        }
                        SettingsStackRow("Endpoint URL",
                            sublabel: "Local mlx_lm.server target.") {
                            TextField("http://127.0.0.1:8765", text: $store.summarizationLocalEndpoint)
                                .textFieldStyle(.roundedBorder)
                                .font(.system(.body, design: .monospaced))
                        }
                        SettingsStackRow("Active model",
                            sublabel: activeModelSizeHint) {
                            Text(activeModelName)
                                .font(.system(.body, design: .monospaced))
                                .foregroundStyle(Color(MPColors.fgMuted))
                                .textSelection(.enabled)
                                .lineLimit(1)
                                .truncationMode(.middle)
                        }
                        SettingsToggleRow("Preload at launch",
                            sublabel: "Warm the model when the app starts so the first summary skips the cold-start. Holds the model in RAM while idle.",
                            isOn: $ui.preloadLocalModelAtLaunch)
                    }
                }
            } footer: {
                pipelineBackendFooter
            }

            SettingsGroup("Your name") {
                SettingsStackRow("Display name",
                    sublabel: "Stamped on your own voice in the transcript so speaker labels read as your name, not \"Speaker 1\". Leave blank to keep generic labels.") {
                    TextField("e.g. Alex", text: $store.summarizationUserLabel)
                        .textFieldStyle(.roundedBorder)
                }
                SettingsRow("Voice profile",
                    sublabel: voiceProfileSublabel,
                    showsDivider: false) {
                    Button("Reset") {
                        VoiceprintProfile.reset()
                        voiceprintMeetings = 0
                    }
                    .buttonStyle(.mpGhost)
                    .disabled(voiceprintMeetings == 0)
                }
            }

            SettingsGroup("People") {
                if rosterPeople.isEmpty {
                    SettingsRow("No named voices yet",
                        sublabel: "Name a speaker from a meeting's transcript (right-click a speaker) and they show up here to rename or remove.",
                        alignTop: true,
                        showsDivider: false) {
                        EmptyView()
                    }
                } else {
                    ForEach(rosterPeople) { person in
                        SettingsRow(person.name,
                            sublabel: "\(person.sampleCount) voice sample\(person.sampleCount == 1 ? "" : "s")",
                            showsDivider: person != rosterPeople.last) {
                            HStack(spacing: MPSpace.s2) {
                                Button("Rename…") { beginRename(person) }
                                    .buttonStyle(.mpGhost)
                                Button("Remove") { beginRemove(person) }
                                    .buttonStyle(.mpGhost)
                            }
                        }
                    }
                }
            } footer: {
                if let error = rosterError {
                    Text(error).foregroundStyle(.mpDanger)
                } else {
                    Text("Named voices are matched across meetings so a recurring person surfaces by name. Removing one stops it being auto-named; it does not change past transcripts.")
                }
            }

            SettingsGroup("Summarization prompt") {
                SettingsRow("System prompt", alignTop: true, showsDivider: false) {
                    promptPreview
                }
            } footer: {
                Text("Read-only preview of the system prompt sent to the summarizer, with your configured team context and summary language applied.")
            }

            SettingsGroup("Languages") {
                SettingsRow("Transcription",
                    sublabel: "Whisper. Auto-detect chooses per-meeting.",
                    showsDivider: false) {
                    languagePicker(selection: $store.transcriptionLanguage, includeMatch: false)
                }
                SettingsRow("Summary",
                    sublabel: "Output language for the Notion summary.") {
                    languagePicker(selection: $store.summaryLanguage, includeMatch: true)
                }
            }

            SettingsGroup("Long meetings") {
                SettingsStackRow("Chunking threshold", showsDivider: false) {
                    SettingsSlider(
                        value: Binding(
                            get: { Double(store.summarizationSkipAboveChars) },
                            set: { store.summarizationSkipAboveChars = Int($0) }
                        ),
                        range: 0...300_000,
                        step: 5_000,
                        format: skipThresholdLabel,
                        valueWidth: 100
                    )
                }
            } footer: {
                Text("When the transcript exceeds this size, a cloud backend writes a paste-into-Claude bundle instead of calling the Anthropic API; a local backend summarizes it on-device with a map-reduce, no bundle. 0 disables the guard. ~80,000 chars ≈ 1 hour of speech.")
            }

            SettingsGroup("Weekly digest") {
                SettingsToggleRow("Scheduled weekly digest",
                    sublabel: "Installs a per-user launch agent that runs `mp digest` on the day and time below; read the results in the Library's Digests view.",
                    isOn: digestEnabledBinding)
                SettingsRow("Day", sublabel: "Which day the digest runs.") {
                    SettingsMenuPicker(selection: digestWeekdayBinding, options: Self.weekdayOptions, width: 140)
                        .disabled(!ui.digestScheduleEnabled)
                }
                SettingsRow("Time", sublabel: "When it runs that day.", showsDivider: false) {
                    DatePicker("", selection: digestTimeBinding, displayedComponents: .hourAndMinute)
                        .labelsHidden()
                        .disabled(!ui.digestScheduleEnabled)
                }
            } footer: {
                Text("The digest summarizes your open actions and recent decisions across the whole library, on-device (no new egress). Generate one on demand from the Library's Digests view.")
            }
        }
        .onAppear {
            voiceprintMeetings = VoiceprintProfile.meetingsLearned()
            refreshRoster()
        }
    }

    // MARK: - Roster (FEAT3-MANAGE)

    private func refreshRoster() {
        rosterPeople = RosterProfile.people()
    }

    private func beginRename(_ person: RosterProfile.Person) {
        guard let entered = Self.promptForName(
            title: "Rename “\(person.name)”",
            message: "The voiceprint is kept; only the name changes.",
            initial: person.name
        ) else { return }
        let trimmed = entered.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, trimmed != person.name else { return }
        rosterError = nil
        Log.event(category: "coordinator", action: "roster_rename_requested",
                  attributes: ["old": person.name, "new": trimmed])
        launcher.rosterRename(old: person.name, new: trimmed) { result in
            Task { @MainActor in
                switch result {
                case .success:
                    Log.event(category: "coordinator", action: "roster_rename_done",
                              attributes: ["old": person.name, "new": trimmed])
                    refreshRoster()
                case .failure(let error):
                    Log.event(category: "coordinator", action: "roster_rename_failed",
                              attributes: ["old": person.name, "error": error.localizedDescription])
                    rosterError = "Rename failed: \(error.localizedDescription)"
                }
            }
        }
    }

    private func beginRemove(_ person: RosterProfile.Person) {
        let alert = NSAlert()
        alert.alertStyle = .warning
        alert.messageText = "Remove “\(person.name)” from the roster?"
        alert.informativeText = "Their voice will no longer be auto-named in future meetings. Past transcripts are unchanged."
        alert.addButton(withTitle: "Remove")
        alert.addButton(withTitle: "Cancel")
        guard alert.runModal() == .alertFirstButtonReturn else { return }
        rosterError = nil
        Log.event(category: "coordinator", action: "roster_remove_requested",
                  attributes: ["name": person.name])
        launcher.rosterForget(name: person.name) { result in
            Task { @MainActor in
                switch result {
                case .success:
                    Log.event(category: "coordinator", action: "roster_remove_done",
                              attributes: ["name": person.name])
                    refreshRoster()
                case .failure(let error):
                    Log.event(category: "coordinator", action: "roster_remove_failed",
                              attributes: ["name": person.name, "error": error.localizedDescription])
                    rosterError = "Remove failed: \(error.localizedDescription)"
                }
            }
        }
    }

    /// A modal name prompt (NSAlert + text field), the AppKit idiom for the few text
    /// inputs outside SwiftUI. Returns nil on cancel.
    private static func promptForName(title: String, message: String, initial: String) -> String? {
        let alert = NSAlert()
        alert.messageText = title
        alert.informativeText = message
        alert.addButton(withTitle: "Rename")
        alert.addButton(withTitle: "Cancel")
        let field = NSTextField(frame: NSRect(x: 0, y: 0, width: 240, height: 24))
        field.stringValue = initial
        alert.accessoryView = field
        alert.window.initialFirstResponder = field
        return alert.runModal() == .alertFirstButtonReturn ? field.stringValue : nil
    }

    // MARK: - Digest schedule (AI4)

    private static let weekdayOptions: [(value: Int, label: String)] = [
        (1, "Monday"), (2, "Tuesday"), (3, "Wednesday"), (4, "Thursday"),
        (5, "Friday"), (6, "Saturday"), (7, "Sunday"),
    ]

    /// Re-render from UISettings, then (re)install or remove the launch agent so a
    /// schedule change takes effect immediately, mirroring the launch-at-login toggle.
    private func applyDigestSchedule() {
        DigestSchedulerService.apply(
            enabled: ui.digestScheduleEnabled,
            weekday: ui.digestWeekday, hour: ui.digestHour, minute: ui.digestMinute
        )
    }

    private var digestEnabledBinding: Binding<Bool> {
        Binding(get: { ui.digestScheduleEnabled }, set: { on in
            ui.digestScheduleEnabled = on
            applyDigestSchedule()
        })
    }

    private var digestWeekdayBinding: Binding<Int> {
        Binding(get: { ui.digestWeekday }, set: { day in
            ui.digestWeekday = day
            applyDigestSchedule()
        })
    }

    private var digestTimeBinding: Binding<Date> {
        Binding(
            get: {
                Calendar.current.date(from: DateComponents(hour: ui.digestHour, minute: ui.digestMinute))
                    ?? Date(timeIntervalSince1970: 0)
            },
            set: { newDate in
                let c = Calendar.current.dateComponents([.hour, .minute], from: newDate)
                ui.digestHour = c.hour ?? 9
                ui.digestMinute = c.minute ?? 0
                applyDigestSchedule()
            }
        )
    }

    private var voiceProfileSublabel: String {
        voiceprintMeetings == 0
            ? "Learned automatically from the mic channel of your stereo recordings, then used to label you on mono or merged calls. Not learned yet."
            : "Learned from \(voiceprintMeetings) meeting\(voiceprintMeetings == 1 ? "" : "s"). Used to label you on mono or merged calls."
    }

    private var localModelHint: String {
        let id = currentLocalModelPresetId
        if let p = LocalModelPreset.all.first(where: { $0.id == id }) {
            return "\(p.diskHint) on disk, \(p.speedHint). \(p.qualityHint)"
        }
        return "Any HuggingFace MLX-quantised model id."
    }

    @ViewBuilder
    private var pipelineBackendFooter: some View {
        switch store.summarizationBackend {
        case "local":
            Text("Audio, transcript, and summary stay on this Mac. No outbound API calls.")
        case "auto":
            Text("Tries Anthropic first; falls back to local if the API fails or the key is missing.")
        case "apple_intelligence":
            if let reason = AppleIntelligenceSummarizer.availabilityReason {
                Text("Experimental, not recommended for daily use. On-device Apple Intelligence (macOS 26+), currently unavailable: \(reason).")
            } else {
                Text("Experimental, not recommended for daily use. On-device Apple Intelligence (macOS 26+) is native and zero-egress, but its small context forces heavy chunking on long meetings, it can mislabel Ukrainian, and it may echo dialogue on short meetings. Prefer Local MLX for a zero-egress backend.")
            }
        default:
            Text("Calls api.anthropic.com. Requires an Anthropic API key (set it under Integrations).")
        }
    }

    private var currentLocalModelPresetId: String {
        LocalModelPreset.all.first(where: { $0.modelId == store.summarizationLocalModel })?.id
            ?? LocalModelPreset.customId
    }

    private var localModelPresetBinding: Binding<String> {
        Binding<String>(
            get: { self.currentLocalModelPresetId },
            set: { newID in
                if newID != LocalModelPreset.customId,
                   let p = LocalModelPreset.all.first(where: { $0.id == newID }) {
                    store.summarizationLocalModel = p.modelId
                }
            }
        )
    }

    @ViewBuilder
    private func languagePicker(selection: Binding<String>, includeMatch: Bool) -> some View {
        Picker("", selection: selection) {
            if includeMatch {
                Text("Match transcript").tag("auto")
            } else {
                Text("Auto-detect").tag("auto")
            }
            Text("English (en)").tag("en")
            Text("Українська (uk)").tag("uk")
            Text("Русский (ru)").tag("ru")
            Text("Deutsch (de)").tag("de")
            Text("Español (es)").tag("es")
            Text("Français (fr)").tag("fr")
            Text("Italiano (it)").tag("it")
            Text("Português (pt)").tag("pt")
            Text("Polski (pl)").tag("pl")
        }
        .labelsHidden()
        .pickerStyle(.menu)
        .fixedSize()
    }

    private func skipThresholdLabel(_ value: Double) -> String {
        let n = Int(value)
        if n == 0 { return "Disabled" }
        let hours = Double(n) / 80_000.0
        if hours >= 1 { return String(format: "%.1f h", hours) }
        return "\(n / 1000)k chars"
    }

    private var activeModelName: String {
        let id = store.summarizationLocalModel
        return id.isEmpty ? "(none configured)" : id
    }

    private var activeModelSizeHint: String {
        if let p = LocalModelPreset.all.first(where: { $0.modelId == store.summarizationLocalModel }) {
            return "\(p.diskHint) on disk"
        }
        return "Custom model; size unknown"
    }

    @ViewBuilder
    private var promptPreview: some View {
        VStack(alignment: .leading, spacing: 6) {
            if let text = promptText {
                ScrollView {
                    Text(text)
                        .font(.system(.caption, design: .monospaced))
                        .textSelection(.enabled)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
                .frame(maxHeight: 220)
            } else if let err = promptError {
                Text("Couldn't load the prompt: \(err)")
                    .font(.caption)
                    .foregroundStyle(Color(MPColors.fgMuted))
                    .frame(maxWidth: .infinity, alignment: .leading)
            } else {
                Button(promptLoading ? "Loading…" : "View prompt") {
                    Task { await loadPrompt() }
                }
                .buttonStyle(.mpGhost)
                .disabled(promptLoading)
            }
            Spacer(minLength: 0)
        }
    }

    @MainActor
    private func loadPrompt() async {
        promptLoading = true
        promptError = nil
        switch await SummarizationPromptPreview.load() {
        case .ok(let text): promptText = text
        case .failed(let err): promptError = err
        }
        promptLoading = false
    }
}

/// Runs `mp summarize --print-prompt` off-main to fetch the rendered system prompt for the read-only Preferences preview (TECH-A15). Best-effort: carries a message on failure rather than throwing into the view.
enum SummarizationPromptPreview {
    enum Outcome {
        case ok(String)
        case failed(String)
    }

    static func load() async -> Outcome {
        guard let mp = PipelineLauncher.findMP() else {
            return .failed("`mp` not found. Run scripts/install.sh.")
        }
        return await Task.detached(priority: .userInitiated) {
            let p = Process()
            p.executableURL = URL(fileURLWithPath: mp.shell)
            p.arguments = mp.args + ["summarize", "--print-prompt"]
            p.environment = PipelineLauncher.freshEnvironment()
            let out = Pipe()
            let err = Pipe()
            p.standardOutput = out
            p.standardError = err
            do {
                try p.run()
            } catch {
                return .failed(error.localizedDescription)
            }
            let outData = out.fileHandleForReading.readDataToEndOfFile()
            p.waitUntilExit()
            if p.terminationStatus != 0 {
                let errText = String(data: err.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""
                return .failed(
                    errText.isEmpty
                        ? "mp exited \(p.terminationStatus)"
                        : errText.trimmingCharacters(in: .whitespacesAndNewlines)
                )
            }
            let text = String(data: outData, encoding: .utf8) ?? ""
            return .ok(text.trimmingCharacters(in: .whitespacesAndNewlines))
        }.value
    }
}

// MARK: - Integrations
