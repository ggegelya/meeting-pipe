import AppKit
import SwiftUI

/// Sidebar navigation items for the redesigned Preferences window (TECH-E4).
/// IA reshuffle per the Claude-Design handoff:
///   - General      — global hotkeys (lifted from Detection — they're
///                    system-wide, not detection-specific).
///   - Recording    — output dir, sample rate, debounce sliders, allowlist
///                    (merged with the former Detection tab; one mental
///                    model: "how a meeting becomes a recording").
///   - Prompt       — prompt timeout + regulated mode (pulled from the
///                    old Modes tab into the moment-of-detection context).
///   - Pipeline     — backend, model, languages, long-meeting threshold.
///   - Integrations — Anthropic, Notion, mp doctor button.
///   - Permissions  — the four TCC rows from TECH-E3, restyled to the
///                    new card chrome.
///   - Advanced     — open config / reveal / open logs (rescued from
///                    the old Modes tab where they were marooned).
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

    /// SF Symbol mapping (the Lucide names from the prototype mapped to
    /// their SF Symbol equivalents per the design-system guide).
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

/// Top-level Preferences SwiftUI view. NavigationSplitView holds the
/// sidebar (200pt sunk-paper rail) and the detail pane (raised paper
/// canvas with section content). One section visible at a time; the
/// sidebar uses signal-blue for the active row, matching the prompt
/// panel's accent treatment.
struct PreferencesView: View {
    @ObservedObject var store: ConfigStore
    @ObservedObject var secrets: SecretsStore
    @StateObject private var doctor = DoctorRunner()

    @State private var selection: PreferencesItem = .general
    @State private var doctorSheetOpen: Bool = false

    var body: some View {
        NavigationSplitView {
            PreferencesSidebar(selection: $selection)
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
        switch selection {
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
            PermissionsSectionView()
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

/// Left rail. 200pt wide, sunk-paper background, signal-blue active
/// row. Uses SwiftUI List with sidebar style — close enough to the
/// prototype's button stack that we don't need a custom control.
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
                SettingsRow("Menu-bar icon",
                    sublabel: "Outline keeps the ring around the waveform; filled drops the ring for a chunkier glyph.") {
                    SettingsSegmented(
                        selection: $ui.menuBarIconStyle,
                        options: [
                            (.outline, "Outline"),
                            (.filled,  "Filled"),
                        ]
                    )
                    Spacer(minLength: 0)
                }
            }

            SettingsGroup("Startup") {
                SettingsRow("Launch at login",
                    sublabel: launchAtLoginSublabel,
                    showsDivider: false) {
                    Toggle("", isOn: launchAtLoginBinding)
                        .labelsHidden()
                        .toggleStyle(.switch)
                    Spacer(minLength: 0)
                }
            } footer: {
                if LaunchAtLoginService.requiresApproval {
                    Text("macOS has marked this login item as needing approval. Open System Settings → General → Login Items and re-enable MeetingPipe.")
                } else {
                    Text("Registers MeetingPipe with macOS via SMAppService. Listed under System Settings → General → Login Items.")
                }
            }

            SettingsGroup("Hotkeys") {
                SettingsRow("Manual toggle",
                    sublabel: "Start or stop a recording from anywhere.",
                    showsDivider: false) {
                    TextField("ctrl+option+m", text: $store.manualHotkey)
                        .textFieldStyle(.roundedBorder)
                        .font(.system(.body, design: .monospaced))
                        .frame(maxWidth: 200)
                    Spacer(minLength: 0)
                }
                SettingsRow("Force stop",
                    sublabel: "Stop immediately, even if detection still thinks a meeting is live.") {
                    TextField("ctrl+option+shift+m", text: $store.forceStopHotkey)
                        .textFieldStyle(.roundedBorder)
                        .font(.system(.body, design: .monospaced))
                        .frame(maxWidth: 200)
                    Spacer(minLength: 0)
                }
            } footer: {
                Text("Format: \"ctrl+option+m\", \"cmd+shift+r\". The toggle hotkey starts/stops. The force-stop hotkey only stops — pressing it when idle is a no-op, so panic-pressing can never accidentally start a recording. Restart MeetingPipe after changing.")
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

    /// Two-way binding that calls into SMAppService on change and
    /// re-reads the real status afterwards. Without the re-read, a
    /// `requiresApproval` state would leave the toggle wedged "on"
    /// visually while SMAppService refuses the registration.
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
                        Text("No apps yet — every meeting will prompt.")
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
    @ObservedObject private var ui = UISettings.shared

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
                    SettingsSegmented(
                        selection: $store.defaultPromptAction,
                        options: [
                            ("skip",   "Skip"),
                            ("record", "Record"),
                            ("byo",    "Record (BYO)"),
                        ]
                    )
                    Spacer(minLength: 0)
                }
            } footer: {
                Text("The floating prompt panel asks whether to record. If you don't respond, the default action above fires when the timeout elapses.")
            }

            SettingsGroup("Regulated mode") {
                SettingsRow("Skip Notion publish",
                    sublabel: store.regulatedMode
                        ? "On — Notion publish is disabled for every meeting."
                        : "Off — meetings publish to Notion normally.",
                    showsDivider: false) {
                    Toggle("", isOn: $store.regulatedMode)
                        .labelsHidden()
                        .toggleStyle(.switch)
                    Spacer(minLength: 0)
                }
                SettingsRow("Show menu-bar lock",
                    sublabel: "Append a lock glyph to the status-bar title whenever regulated mode is on.") {
                    Toggle("", isOn: $ui.showRegulatedBadge)
                        .labelsHidden()
                        .toggleStyle(.switch)
                        .disabled(!store.regulatedMode)
                    Spacer(minLength: 0)
                }
            } footer: {
                Text("Use for client / regulated meetings. The pipeline writes summaries to disk only — no transcript or summary is uploaded to Notion.")
            }
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
}

// MARK: - Pipeline

private struct PipelineSectionView: View {
    @ObservedObject var store: ConfigStore

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            SettingsSectionHeader("Pipeline",
                caption: "What runs after the recording stops — transcription, summarization, languages.")

            SettingsGroup("Summarization") {
                SettingsRow("Backend", showsDivider: false) {
                    SettingsSegmented(
                        selection: $store.summarizationBackend,
                        options: [
                            ("anthropic", "Anthropic"),
                            ("local",     "Local MLX"),
                            ("auto",      "Auto"),
                        ]
                    )
                    Spacer(minLength: 0)
                }
                if store.summarizationBackend != "anthropic" {
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
                }
            } footer: {
                pipelineBackendFooter
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

/// Reskinned Permissions section (replaces the old PermissionsTab). Same
/// `PermissionsCenter` source of truth, new chrome: card-per-permission
/// with icon badge + status pill + Request/Open Settings button, plus
/// the privacy callout banner at the bottom matching the prototype's
/// signal-tinted callout block.
struct PermissionsSectionView: View {
    @ObservedObject private var center = PermissionsCenter.shared
    @State private var workingKind: PermissionsCenter.Kind? = nil

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            SettingsSectionHeader("Permissions",
                caption: "The four TCC permissions the daemon needs. None of these send anything off your machine.") {
                Button {
                    // Re-check both refreshes status AND clears any
                    // lingering "toggle on, then re-check" hints, since
                    // the user is signalling they have come back from
                    // Settings.
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

            privacyCallout
                .padding(.top, 4)
                .padding(.bottom, 22)

            Text("Granting Accessibility from System Settings requires a daemon restart for the change to take effect — macOS caches the trust verdict per-process at launch.")
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
                SettingsRow("Verbose logging",
                    sublabel: "Emit extra detail to the unified log and pass MP_VERBOSE=1 to pipeline subprocesses.",
                    showsDivider: false) {
                    Toggle("", isOn: $ui.verboseLogging)
                        .labelsHidden()
                        .toggleStyle(.switch)
                    Spacer(minLength: 0)
                }
            } footer: {
                Text("Takes effect after restarting MeetingPipe — the env var is set at daemon launch and inherited by every subprocess spawned afterwards.")
            }

            Text("MeetingPipe — config lives in `~/.config/meeting-pipe/`. Workflows live in `~/.config/meeting-pipe/workflows/`. Both are plain TOML — safe to edit by hand if you know what you're doing.")
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

/// Simple wrapping-row layout for the bundle-id tag stack. SwiftUI's
/// builtin `Layout` API gives us this without an HStack-per-row hack;
/// caps the row to the container width and overflows onto the next.
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
