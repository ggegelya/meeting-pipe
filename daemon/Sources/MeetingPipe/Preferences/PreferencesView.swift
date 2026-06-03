import AppKit
import SwiftUI

/// Shared selection state for the Preferences window. `PreferencesWindow.show(initial:)` mutates `current` to deeplink an external caller (e.g. permission-warning row) to a specific section; SwiftUI re-renders the sidebar whether the window is fresh or already on screen.
final class PreferencesSelectionState: ObservableObject {
    @Published var current: PreferencesItem = .general
}

/// Sidebar items for the Preferences window (TECH-E4). IA per the Claude-Design handoff, refined in DSN1: General (hotkeys, appearance), Recording (output, debounce, allowlist), Prompt (timeout, stop conditions), Pipeline (summarization), Integrations (Anthropic, Notion), Permissions (TCC, regulated mode), Advanced (config/logs).
enum PreferencesItem: String, CaseIterable, Identifiable, Hashable {
    case general
    case recording
    case prompt
    case pipeline
    case integrations
    case permissions
    case advanced

    var id: String { rawValue }

    var title: String {
        switch self {
        case .general:      return "General"
        case .recording:    return "Recording"
        case .prompt:       return "Prompt"
        case .pipeline:     return "Pipeline"
        case .integrations: return "Integrations"
        case .permissions:  return "Permissions"
        case .advanced:     return "Advanced"
        }
    }

    /// SF Symbols mapped from the Lucide names in the prototype.
    var systemImage: String {
        switch self {
        case .general:      return "slider.horizontal.3"
        case .recording:    return "mic"
        case .prompt:       return "waveform"
        case .pipeline:     return "cpu"
        case .integrations: return "powerplug"
        case .permissions:  return "lock.shield"
        case .advanced:     return "command"
        }
    }
}

/// Top-level Preferences view. NavigationSplitView with a 200pt sidebar rail and a raised-paper detail pane.
struct PreferencesView: View {
    @ObservedObject var store: ConfigStore
    @ObservedObject var secrets: SecretsStore
    @ObservedObject var selectionState: PreferencesSelectionState
    @StateObject private var doctor = DoctorRunner()

    @State private var doctorSheetOpen: Bool = false

    var body: some View {
        NavigationSplitView {
            PreferencesSidebar(selection: $selectionState.current)
        } detail: {
            ScrollView {
                detailContent
                    .padding(.horizontal, 32)
                    .padding(.vertical, 28)
                    .frame(maxWidth: 620, alignment: .topLeading)
                    .frame(maxWidth: .infinity, alignment: .top)
            }
            .background(Color(MPColors.bg))
        }
        .frame(minWidth: 780, minHeight: 660)
        .sheet(isPresented: $doctorSheetOpen) { doctorSheet }
    }

    @ViewBuilder
    private var detailContent: some View {
        switch selectionState.current {
        case .general:
            GeneralSectionView(store: store)
        case .recording:
            RecordingSectionView(store: store)
        case .prompt:
            PromptSectionView(store: store)
        case .pipeline:
            PipelineSectionView(store: store)
        case .integrations:
            IntegrationsSectionView(
                store: store,
                secrets: secrets,
                onRunDoctor: {
                    doctorSheetOpen = true
                    doctor.run()
                }
            )
        case .permissions:
            PermissionsSectionView(store: store)
        case .advanced:
            AdvancedSectionView()
        }
    }

    // MARK: Doctor sheet

    private var doctorSheet: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Image(systemName: "stethoscope")
                Text("mp doctor").font(.headline)
                Spacer()
                doctorStatusLabel
            }

            ScrollView {
                Text(doctor.output.isEmpty ? "Running…" : doctor.output)
                    .font(.system(.body, design: .monospaced))
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .textSelection(.enabled)
            }
            .background(Color(NSColor.textBackgroundColor))
            .border(Color.secondary.opacity(0.3))

            HStack {
                Button("Re-run") { doctor.run() }
                    .disabled(doctor.state == .running)
                Spacer()
                Button("Close") {
                    if doctor.state == .running { doctor.cancel() }
                    doctorSheetOpen = false
                }
                .keyboardShortcut(.defaultAction)
            }
        }
        .padding(20)
        .frame(minWidth: 560, minHeight: 420)
    }

    private var doctorStatusLabel: some View {
        switch doctor.state {
        case .idle:
            return AnyView(Text("Idle").foregroundStyle(.secondary).font(.caption))
        case .running:
            return AnyView(
                HStack(spacing: 6) {
                    ProgressView().controlSize(.small)
                    Text("Running…").font(.caption)
                }
            )
        case .finished(let exit):
            let ok = exit == 0
            return AnyView(
                HStack(spacing: 4) {
                    Image(systemName: ok ? "checkmark.circle.fill" : "xmark.circle.fill")
                        .foregroundStyle(ok ? Color.green : Color.red)
                    Text(ok ? "Done (exit 0)" : "Failed (exit \(exit))").font(.caption)
                }
            )
        }
    }
}

// MARK: - Sidebar

/// Sidebar rail: SwiftUI List with `.sidebar` style, signal-blue active row.
private struct PreferencesSidebar: View {
    @Binding var selection: PreferencesItem

    var body: some View {
        List(selection: $selection) {
            ForEach(PreferencesItem.allCases) { item in
                Label(item.title, systemImage: item.systemImage)
                    .tag(item)
            }
        }
        .listStyle(.sidebar)
        .navigationSplitViewColumnWidth(min: 180, ideal: 200, max: 240)
    }
}

// MARK: - General

private struct GeneralSectionView: View {
    @ObservedObject var store: ConfigStore
    @ObservedObject private var ui = UISettings.shared
    @State private var launchAtLogin: Bool = LaunchAtLoginService.isEnabled

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            SettingsSectionHeader("General",
                caption: "Global hotkeys, appearance, and startup behaviour.")

            SettingsGroup("Appearance") {
                SettingsRow("Theme",
                    sublabel: "Override the system appearance. SwiftUI windows and the recording HUD follow this choice.",
                    showsDivider: false) {
                    SettingsSegmented(
                        selection: $ui.theme,
                        options: [
                            (.light,  "Light"),
                            (.system, "System"),
                            (.dark,   "Dark"),
                        ]
                    )
                    Spacer(minLength: 0)
                }
                // Menu-bar icon style (outline vs filled) was a cosmetic-only
                // toggle; cut in the DSN1 IA pass. The glyph stays at its
                // default; UISettings.menuBarIconStyle remains for the status bar.
            }

            SettingsGroup("Startup") {
                SettingsToggleRow("Launch at login",
                    sublabel: launchAtLoginSublabel,
                    isOn: launchAtLoginBinding)
                SettingsToggleRow("Relaunch after quitting",
                    sublabel: "On: Quit restarts MeetingPipe in the menu bar. Off: Quit fully closes it. Either way a crash still auto-recovers.",
                    isOn: Binding(
                        get: { !ui.disableAutoRestart },
                        set: { ui.disableAutoRestart = !$0 }
                    ),
                    showsDivider: false)
            } footer: {
                if LaunchAtLoginService.requiresApproval {
                    Text("macOS has marked this login item as needing approval. Open System Settings → General → Login Items and re-enable MeetingPipe.")
                } else {
                    Text("Registers MeetingPipe with macOS via SMAppService. The relaunch-after-quit behaviour takes effect after the launch agent is reinstalled (re-run scripts/install.sh).")
                }
            }

            SettingsGroup("Sound") {
                // TECH-DSN5: one opt-in, default-off post-call completion tone.
                SettingsToggleRow("Play a tone when a meeting finishes",
                    sublabel: "A short system tone when the summary is ready. Off by default, and never during a call.",
                    isOn: $ui.playCompletionTone,
                    showsDivider: false)
            }

            SettingsGroup("Hotkeys") {
                SettingsRow("Manual toggle",
                    sublabel: "Start or stop a recording from anywhere.",
                    showsDivider: false) {
                    SettingsHotkeyField(text: $store.manualHotkey)
                    Spacer(minLength: 0)
                }
                SettingsRow("Force stop",
                    sublabel: "Stop immediately, even if detection still thinks a meeting is live.") {
                    SettingsHotkeyField(text: $store.forceStopHotkey)
                    Spacer(minLength: 0)
                }
            } footer: {
                Text("Click a field, then press the chord you want to bind (one or more of ⌃⌥⇧⌘ plus a letter). The toggle hotkey starts/stops; the force-stop hotkey only stops, so panic-pressing can never accidentally start a recording. Restart MeetingPipe after changing.")
            }
        }
    }

    private var launchAtLoginSublabel: String {
        if LaunchAtLoginService.requiresApproval {
            return "Needs approval in System Settings → Login Items."
        }
        return launchAtLogin
            ? "MeetingPipe will start automatically when you log in."
            : "MeetingPipe only starts when you launch it manually."
    }

    /// Re-reads SMAppService status after each set so a `requiresApproval` state doesn't leave the toggle wedged "on" visually.
    private var launchAtLoginBinding: Binding<Bool> {
        Binding(
            get: { launchAtLogin },
            set: { newValue in
                LaunchAtLoginService.set(enabled: newValue)
                launchAtLogin = LaunchAtLoginService.isEnabled
            }
        )
    }
}

// MARK: - Recording

private struct RecordingSectionView: View {
    @ObservedObject var store: ConfigStore
    @State private var newConsentBundleID: String = ""

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            SettingsSectionHeader("Recording",
                caption: "How audio is captured to disk, and which apps record automatically.")

            SettingsGroup("Audio") {
                SettingsRow("Output directory", alignTop: true, showsDivider: false) {
                    TextField("", text: $store.outputDirPath)
                        .textFieldStyle(.roundedBorder)
                        .font(.system(.body, design: .monospaced))
                    Button("Choose…") { chooseOutputDir() }
                    Button {
                        revealOutputDir()
                    } label: {
                        Image(systemName: "arrow.up.right.square")
                            .frame(width: 20)
                    }
                    .buttonStyle(.borderless)
                    .help("Reveal in Finder")
                }
                SettingsRow("Sample rate",
                    sublabel: "16 kHz matches Whisper. Higher rates are downsampled.") {
                    Picker("", selection: $store.sampleRate) {
                        Text("16 kHz · recommended").tag(16000)
                        Text("24 kHz").tag(24000)
                        Text("48 kHz").tag(48000)
                    }
                    .labelsHidden()
                    .pickerStyle(.menu)
                    .fixedSize()
                    Spacer(minLength: 0)
                }
            }

            SettingsGroup("Microphone") {
                SettingsToggleRow("Pause mic when muted",
                    sublabel: "Pauses mic capture while you're muted in Teams / Zoom / Slack / Webex. Uses the locale catalogue (en, uk, de, es, fr, ja, pt, ru).",
                    isOn: $store.honorAppMute,
                    showsDivider: false)
                SettingsToggleRow("Voice processing",
                    sublabel: "Apple's noise-suppression + AGC. Drops your mic gain system-wide while recording, so other apps hear you quietly. Off by default; flip on only for solo voice memos.",
                    isOn: $store.voiceProcessing)
            } footer: {
                Text("Voice processing takes effect on the next recording. Mute pausing applies to every meeting.")
            }

            SettingsGroup("Detection") {
                SettingsRow("Start debounce", showsDivider: false) {
                    SettingsSlider(
                        value: $store.debounceStartSec,
                        range: 1...30,
                        step: 1,
                        format: { "\(Int($0)) s" }
                    )
                }
                SettingsRow("End debounce") {
                    SettingsSlider(
                        value: $store.debounceEndSec,
                        range: 1...30,
                        step: 1,
                        format: { "\(Int($0)) s" }
                    )
                }
            } footer: {
                Text("Debounce smooths out brief mic gaps. A higher start debounce avoids recording phantom audio; a higher end debounce avoids cutting off pauses.")
            }

            SettingsGroup("Auto-record allowlist") {
                SettingsFullRow(showsDivider: false) {
                    if store.autoConsentApps.isEmpty {
                        Text("No apps yet - every meeting will prompt.")
                            .font(.system(size: 12))
                            .foregroundStyle(.tertiary)
                            .frame(maxWidth: .infinity, alignment: .leading)
                    } else {
                        WrappingHStack(items: store.autoConsentApps) { bundleID in
                            SettingsTag(bundleID) {
                                store.autoConsentApps.removeAll { $0 == bundleID }
                            }
                        }
                    }
                }
                SettingsFullRow {
                    HStack(spacing: 8) {
                        TextField("us.zoom.xos", text: $newConsentBundleID)
                            .textFieldStyle(.roundedBorder)
                            .font(.system(.body, design: .monospaced))
                            .onSubmit(addBundle)
                        Button("Add", action: addBundle)
                            .disabled(newConsentBundleID.trimmingCharacters(in: .whitespaces).isEmpty)
                    }
                }
            } footer: {
                Text("When the daemon detects audio from these apps, recording starts without showing the prompt.")
            }
        }
    }

    private func addBundle() {
        let trimmed = newConsentBundleID.trimmingCharacters(in: .whitespaces)
        guard !trimmed.isEmpty, !store.autoConsentApps.contains(trimmed) else { return }
        store.autoConsentApps.append(trimmed)
        newConsentBundleID = ""
    }

    private func chooseOutputDir() {
        let panel = NSOpenPanel()
        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        panel.allowsMultipleSelection = false
        panel.canCreateDirectories = true
        panel.prompt = "Choose"
        if panel.runModal() == .OK, let url = panel.url {
            store.outputDirPath = url.path
        }
    }

    private func revealOutputDir() {
        let expanded = (store.outputDirPath as NSString).expandingTildeInPath
        let url = URL(fileURLWithPath: expanded)
        NSWorkspace.shared.activateFileViewerSelecting([url])
    }
}

// MARK: - Prompt

private struct PromptSectionView: View {
    @ObservedObject var store: ConfigStore

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            SettingsSectionHeader("Prompt",
                caption: "What happens the moment a meeting is detected.")

            SettingsGroup("When a meeting is detected") {
                SettingsRow("Prompt timeout", showsDivider: false) {
                    SettingsSlider(
                        value: $store.promptTimeoutSec,
                        range: 1...120,
                        step: 1,
                        format: { "\(Int($0)) s" }
                    )
                }
                SettingsRow("Default action",
                    sublabel: defaultActionSublabel) {
                    // Dropdown (not segmented): "Record (BYO)" widened the
                    // segmented control enough to shove the Prompt tab off-screen
                    // (same fix as the Pipeline backend picker). A menu stays a
                    // fixed width regardless of label length.
                    SettingsMenuPicker(
                        selection: $store.defaultPromptAction,
                        options: [
                            ("skip",   "Skip"),
                            ("record", "Record"),
                            ("byo",    "Record (BYO)"),
                        ]
                    )
                    Spacer(minLength: 0)
                }
                SettingsRow("Re-prompt cooldown",
                    sublabel: "After a recording or skip, suppress new prompts for the same app for this many seconds. Catches post-call mic flickers from Teams/Zoom.") {
                    SettingsSlider(
                        value: $store.repromptCooldownSec,
                        range: 0...300,
                        step: 5,
                        format: { "\(Int($0)) s" }
                    )
                }
            } footer: {
                Text("The floating prompt panel asks whether to record. If you don't respond, the default action above fires when the timeout elapses.")
            }

            SettingsGroup("Stop conditions") {
                SettingsRow("Mic-only silence backstop",
                    sublabel: "Auto-stop if your mic is silent AND no system audio plays for this many seconds. Catches the 'everyone else left and I forgot to stop' case.",
                    showsDivider: false) {
                    SettingsSlider(
                        value: $store.micOnlySilenceSec,
                        range: 60...1800,
                        step: 30,
                        format: { Self.formatMinutesOrSeconds(Int($0)) }
                    )
                }
            } footer: {
                Text("Independent of the existing 5-minute silence auto-stop, which triggers when BOTH mic and system audio go silent.")
            }
            // Regulated mode moved to the Permissions pane in the DSN1 IA pass:
            // it is a privacy / egress control, not a prompt concern. The
            // cosmetic "Show menu-bar lock" toggle was cut at the same time.
        }
    }

    private var defaultActionSublabel: String {
        switch store.defaultPromptAction {
        case "record":
            return "Auto-start an auto-summary recording when the prompt times out."
        case "byo":
            return "Auto-start a BYO recording (no Anthropic call; paste bundle on stop)."
        default:
            return "Suppress the call (no recording) when the prompt times out."
        }
    }

    /// Show exact-minute values as "N min", otherwise raw seconds. Keeps the silence-backstop slider readable across its 1-to-30-minute range.
    private static func formatMinutesOrSeconds(_ seconds: Int) -> String {
        if seconds % 60 == 0 { return "\(seconds / 60) min" }
        return "\(seconds) s"
    }
}

// MARK: - Pipeline

private struct PipelineSectionView: View {
    @ObservedObject var store: ConfigStore
    @ObservedObject private var ui = UISettings.shared
    @State private var promptText: String?
    @State private var promptLoading = false
    @State private var promptError: String?
    @State private var showLocalModelConfig = false

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
                            ("apple_intelligence", "Apple"),
                        ]
                    )
                    Spacer(minLength: 0)
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
                            Spacer(minLength: 0)
                        }
                        if currentLocalModelPresetId == LocalModelPreset.customId {
                            SettingsRow("Model id",
                                sublabel: "HuggingFace MLX repo id.") {
                                TextField("mlx-community/...", text: $store.summarizationLocalModel)
                                    .textFieldStyle(.roundedBorder)
                                    .font(.system(.body, design: .monospaced))
                            }
                        }
                        SettingsRow("Endpoint URL",
                            sublabel: "Local mlx_lm.server target.") {
                            TextField("http://127.0.0.1:8765", text: $store.summarizationLocalEndpoint)
                                .textFieldStyle(.roundedBorder)
                                .font(.system(.body, design: .monospaced))
                        }
                        SettingsRow("Active model",
                            sublabel: activeModelSizeHint) {
                            Text(activeModelName)
                                .font(.system(.body, design: .monospaced))
                                .foregroundStyle(.secondary)
                                .textSelection(.enabled)
                                .lineLimit(1)
                                .truncationMode(.middle)
                            Spacer(minLength: 0)
                        }
                        SettingsToggleRow("Preload at launch",
                            sublabel: "Warm the model when the app starts so the first summary skips the cold-start. Holds the model in RAM while idle.",
                            isOn: $ui.preloadLocalModelAtLaunch)
                    }
                }
            } footer: {
                pipelineBackendFooter
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
                    Spacer(minLength: 0)
                }
                SettingsRow("Summary",
                    sublabel: "Output language for the Notion summary.") {
                    languagePicker(selection: $store.summaryLanguage, includeMatch: true)
                    Spacer(minLength: 0)
                }
            }

            SettingsGroup("Long meetings") {
                SettingsRow("Chunking threshold", showsDivider: false) {
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
                Text("When the transcript exceeds this size, the pipeline writes a paste-into-Claude bundle instead of calling the Anthropic API. 0 disables the guard. ~80,000 chars ≈ 1 hour of speech.")
            }
        }
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
                Text("On-device Apple Intelligence (macOS 26+). Currently unavailable: \(reason).")
            } else {
                Text("On-device Apple Intelligence (macOS 26+). No outbound API calls; the system model produces the summary.")
            }
        default:
            Text("Calls api.anthropic.com. Requires ANTHROPIC_API_KEY in secrets.env.")
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
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, alignment: .leading)
            } else {
                Button(promptLoading ? "Loading…" : "View prompt") {
                    Task { await loadPrompt() }
                }
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

private struct IntegrationsSectionView: View {
    @ObservedObject var store: ConfigStore
    @ObservedObject var secrets: SecretsStore
    var onRunDoctor: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            SettingsSectionHeader("Integrations",
                caption: "Credentials for outbound services. Stored in ~/.config/meeting-pipe/secrets.env (mode 0600).") {
                Button {
                    onRunDoctor()
                } label: {
                    Label("Run doctor…", systemImage: "stethoscope")
                }
            }

            SettingsGroup("Anthropic") {
                SettingsRow("API key", alignTop: true, showsDivider: false) {
                    SettingsSecretField(text: $secrets.anthropicAPIKey, placeholder: "sk-ant-…")
                }
                SettingsRow("Status") {
                    if !secrets.anthropicAPIKey.isEmpty {
                        SettingsStatusPill(tone: .granted, icon: "checkmark.circle.fill", text: "Configured")
                    } else {
                        SettingsStatusPill(tone: .needed, icon: "exclamationmark.triangle.fill", text: "Not configured")
                    }
                    Spacer(minLength: 0)
                }
            } footer: {
                Text("Used to summarize transcripts. Get a key at console.anthropic.com. Local MLX backend doesn't need this.")
            }

            SettingsGroup("Notion") {
                SettingsRow("Integration token", alignTop: true, showsDivider: false) {
                    SettingsSecretField(text: $secrets.notionToken, placeholder: "ntn_…")
                }
                SettingsRow("Database ID") {
                    TextField("32-char hex from your database URL", text: $store.notionDatabaseId)
                        .textFieldStyle(.roundedBorder)
                        .font(.system(.body, design: .monospaced))
                }
                SettingsRow("Status") {
                    if !secrets.notionToken.isEmpty && !store.notionDatabaseId.isEmpty {
                        SettingsStatusPill(tone: .granted, icon: "checkmark.circle.fill", text: "Configured")
                    } else {
                        SettingsStatusPill(tone: .needed, icon: "exclamationmark.triangle.fill", text: "Not configured")
                    }
                    Spacer(minLength: 0)
                }
            } footer: {
                Text("Create the integration at notion.so/profile/integrations, share your Meetings database with it, and paste the database ID here.")
            }
        }
    }
}

// MARK: - Permissions

/// Permissions section: one card per TCC permission, icon badge + status pill + Request/Open Settings button, plus a privacy callout at the bottom.
struct PermissionsSectionView: View {
    @ObservedObject var store: ConfigStore
    @ObservedObject private var center = PermissionsCenter.shared
    @State private var workingKind: PermissionsCenter.Kind? = nil

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            SettingsSectionHeader("Permissions",
                caption: "The four TCC permissions the daemon needs. None of these send anything off your machine.") {
                Button {
                    // Also clears deferred hints so the user returning from Settings sees a clean state.
                    for kind in PermissionsCenter.Kind.allCases {
                        center.clearDeferredHint(kind)
                    }
                    Task { await center.refreshAll() }
                } label: {
                    Label("Re-check", systemImage: "arrow.clockwise")
                }
            }

            SettingsGroup {
                ForEach(Array(PermissionsCenter.Kind.allCases.enumerated()), id: \.element.id) { index, kind in
                    PermissionsCardRow(
                        kind: kind,
                        status: center.status(kind),
                        isWorking: workingKind == kind,
                        isFirst: index == 0,
                        showsDeferredHint: center.deferredToSettings.contains(kind),
                        onRequest: { perform(action: .request, on: kind) },
                        onOpenSettings: { perform(action: .openSettings, on: kind) }
                    )
                }
            }

            // Regulated mode lives here (moved out of Prompt in the DSN1 IA
            // pass): it is a privacy / egress control, alongside the TCC
            // permissions and the on-device privacy note.
            SettingsGroup("Regulated mode") {
                SettingsToggleRow("Skip Notion publish",
                    sublabel: store.regulatedMode
                        ? "On - Notion publish is disabled for every meeting."
                        : "Off - meetings publish to each workflow's own sinks (Notion only if that workflow enables it).",
                    isOn: $store.regulatedMode,
                    showsDivider: false)
            } footer: {
                Text("Use for client / regulated meetings. The pipeline writes summaries to disk only - no transcript or summary is uploaded to Notion.")
            }

            privacyCallout
                .padding(.top, 4)
                .padding(.bottom, 22)

            Text("Granting Accessibility from System Settings requires a daemon restart for the change to take effect - macOS caches the trust verdict per-process at launch.")
                .font(.system(size: 12))
                .foregroundStyle(.secondary)
                .padding(.leading, 2)
                .fixedSize(horizontal: false, vertical: true)
        }
        .onAppear { center.startPolling() }
        .onDisappear { center.stopPolling() }
    }

    private var privacyCallout: some View {
        HStack(alignment: .top, spacing: 10) {
            Image(systemName: "lock.shield")
                .font(.system(size: 16))
                .foregroundStyle(Color(MPColors.signal600))
                .padding(.top, 1)
            Text("Audio capture is fully on-device. The pipeline only reaches the network when sending the transcript to Anthropic for summarization, and when publishing to Notion.")
                .font(.system(size: 12))
                .lineSpacing(2)
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 12)
        .background(
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .fill(Color(MPColors.signal600).opacity(0.10))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .strokeBorder(Color(MPColors.signal600).opacity(0.18), lineWidth: 1)
        )
    }

    private enum Action { case request, openSettings }

    private func perform(action: Action, on kind: PermissionsCenter.Kind) {
        switch action {
        case .request:
            Task {
                workingKind = kind
                defer { workingKind = nil }
                switch kind {
                case .microphone:      await center.requestMic()
                case .screenRecording: await center.requestScreenRecording()
                case .accessibility:   _ = center.requestAccessibility()
                case .notifications:   await center.requestNotifications()
                }
            }
        case .openSettings:
            center.openSystemSettings(for: kind)
        }
    }
}

private struct PermissionsCardRow: View {
    let kind: PermissionsCenter.Kind
    let status: PermissionsCenter.Status
    let isWorking: Bool
    let isFirst: Bool
    let showsDeferredHint: Bool
    let onRequest: () -> Void
    let onOpenSettings: () -> Void

    var body: some View {
        VStack(spacing: 0) {
            if !isFirst {
                Rectangle()
                    .fill(Color(MPColors.borderFaint))
                    .frame(height: 1)
            }
            HStack(alignment: .center, spacing: 14) {
                ZStack {
                    RoundedRectangle(cornerRadius: 8, style: .continuous)
                        .fill(Color(MPColors.bgSunk))
                        .frame(width: 32, height: 32)
                    Image(systemName: iconName)
                        .font(.system(size: 16))
                        .foregroundStyle(.secondary)
                }
                VStack(alignment: .leading, spacing: 2) {
                    HStack(spacing: 8) {
                        Text(kind.displayName)
                            .font(.system(size: 13, weight: .medium))
                        SettingsStatusPill(
                            tone: pillTone,
                            icon: pillIcon,
                            text: pillText
                        )
                    }
                    Text(rationale)
                        .font(.system(size: 12))
                        .foregroundStyle(.secondary)
                        .lineSpacing(1)
                        .fixedSize(horizontal: false, vertical: true)
                    if showsDeferredHint {
                        Text("Toggle MeetingPipe on in System Settings, then click Re-check.")
                            .font(.system(size: 11))
                            .foregroundStyle(Color(MPColors.signal600))
                            .padding(.top, 2)
                    }
                }
                Spacer(minLength: 8)
                actionButton
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 12)
        }
    }

    @ViewBuilder
    private var actionButton: some View {
        if isWorking {
            ProgressView().controlSize(.small).frame(width: 100, alignment: .trailing)
        } else {
            switch status {
            case .granted:
                Button("Open Settings", action: onOpenSettings)
                    .controlSize(.small)
            case .denied:
                Button("Open Settings", action: onOpenSettings)
                    .controlSize(.small)
                    .buttonStyle(.borderedProminent)
            case .notDetermined, .unknown:
                Button("Request", action: onRequest)
                    .controlSize(.small)
                    .buttonStyle(.borderedProminent)
            }
        }
    }

    private var iconName: String {
        switch kind {
        case .microphone:      return "mic"
        case .screenRecording: return "rectangle.dashed"
        case .accessibility:   return "figure.stand"
        case .notifications:   return "bell"
        }
    }

    private var rationale: String {
        switch kind {
        case .microphone:
            return "Captures your voice via AVAudioEngine. Audio stays on this Mac."
        case .screenRecording:
            return "Captures system audio via ScreenCaptureKit. No video is recorded."
        case .accessibility:
            return "Reads browser tab titles to detect Meet and Teams Web sessions."
        case .notifications:
            return "Record / skip prompts and 'meeting published' alerts."
        }
    }

    private var pillTone: SettingsStatusPill.Tone {
        switch status {
        case .granted: return .granted
        case .denied:  return .denied
        case .notDetermined, .unknown: return .needed
        }
    }
    private var pillIcon: String {
        switch status {
        case .granted: return "checkmark.circle.fill"
        case .denied:  return "xmark.octagon.fill"
        case .notDetermined: return "exclamationmark.triangle.fill"
        case .unknown: return "ellipsis.circle"
        }
    }
    private var pillText: String {
        switch status {
        case .granted: return "Granted"
        case .denied:  return "Denied"
        case .notDetermined: return "Needed"
        case .unknown: return "Checking…"
        }
    }
}

// MARK: - Advanced

private struct AdvancedSectionView: View {
    @ObservedObject private var ui = UISettings.shared

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            SettingsSectionHeader("Advanced",
                caption: "Plumbing for power users. Most people never come here.")

            SettingsGroup("Configuration") {
                SettingsRow("Config file",
                    sublabel: Config.defaultPath.path,
                    showsDivider: false) {
                    Button("Open in editor") {
                        NSWorkspace.shared.open(Config.defaultPath)
                    }
                    Button("Reveal in Finder") {
                        NSWorkspace.shared.activateFileViewerSelecting([Config.defaultPath])
                    }
                    Spacer(minLength: 0)
                }
                SettingsRow("Logs folder",
                    sublabel: "Rotated daily. Used by mp doctor and bug reports.") {
                    Button("Open logs") {
                        NSWorkspace.shared.open(Log.logsDir)
                    }
                    Spacer(minLength: 0)
                }
            }

            SettingsGroup("Diagnostics") {
                SettingsToggleRow("Verbose logging",
                    sublabel: "Emit extra detail to the unified log and pass MP_VERBOSE=1 to pipeline subprocesses.",
                    isOn: $ui.verboseLogging,
                    showsDivider: false)
            } footer: {
                Text("Takes effect after restarting MeetingPipe - the env var is set at daemon launch and inherited by every subprocess spawned afterwards.")
            }

            Text("MeetingPipe - config lives in `~/.config/meeting-pipe/`. Workflows live in `~/.config/meeting-pipe/workflows/`. Both are plain TOML - safe to edit by hand if you know what you're doing.")
                .font(.system(size: 11))
                .foregroundStyle(.tertiary)
                .padding(.top, 4)
                .padding(.horizontal, 2)
                .frame(maxWidth: .infinity, alignment: .center)
                .fixedSize(horizontal: false, vertical: true)
        }
    }
}

// MARK: - Wrapping HStack

/// Wrapping row layout for the bundle-id tag stack, using SwiftUI's `Layout` API.
private struct WrappingHStack<Data: RandomAccessCollection, Content: View>: View where Data.Element: Hashable {
    let items: Data
    let spacing: CGFloat
    @ViewBuilder var content: (Data.Element) -> Content

    init(items: Data, spacing: CGFloat = 6, @ViewBuilder content: @escaping (Data.Element) -> Content) {
        self.items = items
        self.spacing = spacing
        self.content = content
    }

    var body: some View {
        FlowLayout(spacing: spacing) {
            ForEach(Array(items), id: \.self) { item in
                content(item)
            }
        }
    }
}

private struct FlowLayout: Layout {
    var spacing: CGFloat

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let width = proposal.width ?? .infinity
        let rows = computeRows(subviews: subviews, width: width)
        let height = rows.reduce(CGFloat(0)) { acc, row in
            acc + row.height + (acc == 0 ? 0 : spacing)
        }
        return CGSize(width: proposal.width ?? rows.first?.width ?? 0, height: height)
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        let width = bounds.width
        var y = bounds.minY
        let rows = computeRows(subviews: subviews, width: width)
        for row in rows {
            var x = bounds.minX
            for index in row.indices {
                let size = subviews[index].sizeThatFits(.unspecified)
                subviews[index].place(at: CGPoint(x: x, y: y), proposal: ProposedViewSize(size))
                x += size.width + spacing
            }
            y += row.height + spacing
        }
    }

    private func computeRows(subviews: Subviews, width: CGFloat) -> [(indices: [Int], width: CGFloat, height: CGFloat)] {
        var rows: [(indices: [Int], width: CGFloat, height: CGFloat)] = []
        var current: (indices: [Int], width: CGFloat, height: CGFloat) = ([], 0, 0)
        for (i, sub) in subviews.enumerated() {
            let size = sub.sizeThatFits(.unspecified)
            let needsBreak = !current.indices.isEmpty && current.width + size.width + spacing > width
            if needsBreak {
                rows.append(current)
                current = ([], 0, 0)
            }
            current.indices.append(i)
            current.width += size.width + (current.indices.count == 1 ? 0 : spacing)
            current.height = max(current.height, size.height)
        }
        if !current.indices.isEmpty { rows.append(current) }
        return rows
    }
}
