import AppKit
import SwiftUI

/// SwiftUI Preferences window opened from the menu bar.
///
/// One window at a time — re-opening the menu item brings the existing
/// window to the front rather than stacking duplicates.
final class PreferencesWindow {
    private var window: NSWindow?
    private let store: ConfigStore
    private let secrets: SecretsStore

    init(store: ConfigStore, secrets: SecretsStore) {
        self.store = store
        self.secrets = secrets
    }

    func show() {
        if let w = window {
            w.makeKeyAndOrderFront(nil)
            NSApp.activate(ignoringOtherApps: true)
            return
        }

        let view = PreferencesView(store: store, secrets: secrets)
        let host = NSHostingController(rootView: view)
        let w = NSWindow(contentViewController: host)
        w.title = "MeetingPipe Preferences"
        w.styleMask = [.titled, .closable, .miniaturizable]
        w.setContentSize(NSSize(width: 540, height: 620))
        w.isReleasedWhenClosed = false
        w.center()
        // Capture close so we don't keep a dead window pointer around;
        // delegate target is held weakly.
        let delegate = PreferencesWindowDelegate { [weak self] in
            self?.window = nil
        }
        objc_setAssociatedObject(w, &Self.delegateKey, delegate, .OBJC_ASSOCIATION_RETAIN)
        w.delegate = delegate

        self.window = w
        w.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }

    private static var delegateKey: UInt8 = 0
}

private final class PreferencesWindowDelegate: NSObject, NSWindowDelegate {
    private let onClose: () -> Void
    init(onClose: @escaping () -> Void) { self.onClose = onClose }
    func windowWillClose(_ notification: Notification) { onClose() }
}

private struct PreferencesView: View {
    @ObservedObject var store: ConfigStore
    @ObservedObject var secrets: SecretsStore
    @StateObject private var doctor = DoctorRunner()

    @State private var newConsentBundleID: String = ""
    @State private var doctorSheetOpen: Bool = false

    var body: some View {
        TabView {
            recordingTab
                .tabItem { Label("Recording", systemImage: "mic") }

            detectionTab
                .tabItem { Label("Detection", systemImage: "waveform") }

            integrationsTab
                .tabItem { Label("Integrations", systemImage: "key") }

            pipelineTab
                .tabItem { Label("Pipeline", systemImage: "gearshape.2") }

            modesTab
                .tabItem { Label("Modes", systemImage: "lock.shield") }
        }
        .padding(20)
        .frame(minWidth: 520, minHeight: 580)
        .sheet(isPresented: $doctorSheetOpen) {
            doctorSheet
        }
    }

    // MARK: Recording

    private var recordingTab: some View {
        Form {
            Section {
                LabeledContent("Output directory") {
                    HStack {
                        TextField("", text: $store.outputDirPath)
                            .textFieldStyle(.roundedBorder)
                        Button("Choose…") { chooseOutputDir() }
                    }
                }
                LabeledContent("Sample rate") {
                    Picker("", selection: $store.sampleRate) {
                        Text("16 kHz (recommended)").tag(16000)
                        Text("24 kHz").tag(24000)
                        Text("48 kHz").tag(48000)
                    }
                    .labelsHidden()
                    .pickerStyle(.menu)
                }
            }

            Section("Auto-record without prompt") {
                if store.autoConsentApps.isEmpty {
                    Text("No bundle IDs added.")
                        .foregroundStyle(.secondary)
                        .font(.callout)
                } else {
                    ForEach(store.autoConsentApps, id: \.self) { bid in
                        HStack {
                            Text(bid).font(.system(.body, design: .monospaced))
                            Spacer()
                            Button(role: .destructive) {
                                store.autoConsentApps.removeAll { $0 == bid }
                            } label: {
                                Image(systemName: "minus.circle")
                            }
                            .buttonStyle(.borderless)
                        }
                    }
                }
                HStack {
                    TextField("us.zoom.xos", text: $newConsentBundleID)
                        .textFieldStyle(.roundedBorder)
                    Button("Add") {
                        let trimmed = newConsentBundleID.trimmingCharacters(in: .whitespaces)
                        guard !trimmed.isEmpty,
                              !store.autoConsentApps.contains(trimmed) else { return }
                        store.autoConsentApps.append(trimmed)
                        newConsentBundleID = ""
                    }
                    .disabled(newConsentBundleID.trimmingCharacters(in: .whitespaces).isEmpty)
                }
            }
        }
        .formStyle(.grouped)
    }

    // MARK: Detection

    private var detectionTab: some View {
        Form {
            Section("Debounce") {
                LabeledContent("Start (sec)") {
                    Slider(
                        value: $store.debounceStartSec,
                        in: 1...30,
                        step: 1
                    ) {
                        Text("Start debounce")
                    } minimumValueLabel: {
                        Text("1")
                    } maximumValueLabel: {
                        Text("30")
                    }
                    .frame(maxWidth: .infinity)
                    Text("\(Int(store.debounceStartSec))s").monospacedDigit().frame(width: 36, alignment: .trailing)
                }
                LabeledContent("End (sec)") {
                    Slider(value: $store.debounceEndSec, in: 1...30, step: 1)
                    Text("\(Int(store.debounceEndSec))s").monospacedDigit().frame(width: 36, alignment: .trailing)
                }
            }
            Section("Hotkey") {
                LabeledContent("Manual record") {
                    TextField("ctrl+option+m", text: $store.manualHotkey)
                        .textFieldStyle(.roundedBorder)
                }
                Text("Format: 'ctrl+option+m', 'cmd+shift+r'. Restart MeetingPipe after changing.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Section("Prompt") {
                LabeledContent("Timeout (sec)") {
                    Slider(value: $store.promptTimeoutSec, in: 1...120, step: 1)
                    Text("\(Int(store.promptTimeoutSec))s").monospacedDigit().frame(width: 36, alignment: .trailing)
                }
            }
        }
        .formStyle(.grouped)
    }

    // MARK: Integrations

    private var integrationsTab: some View {
        Form {
            Section("Anthropic") {
                LabeledContent("API key") {
                    SecureField("sk-ant-…", text: $secrets.anthropicAPIKey)
                        .textFieldStyle(.roundedBorder)
                }
                Text("Required for the summary step. Stored in ~/.config/meeting-pipe/secrets.env (mode 0600).")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Section("Notion") {
                LabeledContent("Integration token") {
                    SecureField("ntn_…", text: $secrets.notionToken)
                        .textFieldStyle(.roundedBorder)
                }
                LabeledContent("Database ID") {
                    TextField("32-char hex from your database URL", text: $store.notionDatabaseId)
                        .textFieldStyle(.roundedBorder)
                        .font(.system(.body, design: .monospaced))
                }
                Text("Create the integration at notion.so/profile/integrations, share your Meetings database with it, and paste the database ID here.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Section("Verify") {
                Button {
                    doctorSheetOpen = true
                    doctor.run()
                } label: {
                    Label("Run mp doctor", systemImage: "stethoscope")
                }
                Text("Pings Anthropic + Notion, validates the ML runtimes, surfaces any missing setup. Output appears in a popup.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
    }

    // MARK: Pipeline

    private var pipelineTab: some View {
        Form {
            Section("Summarization backend") {
                LabeledContent("Backend") {
                    Picker("", selection: $store.summarizationBackend) {
                        Text("Anthropic API (cloud)").tag("anthropic")
                        Text("Local MLX (on-device)").tag("local")
                        Text("Auto (cloud, fall back to local)").tag("auto")
                    }
                    .labelsHidden()
                    .pickerStyle(.menu)
                }
                Text(backendHelpText)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                if store.summarizationBackend != "anthropic" {
                    LabeledContent("Model size") {
                        Picker("", selection: localModelPresetBinding) {
                            ForEach(LocalModelPreset.all, id: \.id) { preset in
                                Text(preset.label).tag(preset.id)
                            }
                            Text("Custom").tag(LocalModelPreset.customId)
                        }
                        .labelsHidden()
                        .pickerStyle(.menu)
                    }
                    Text(localModelPresetHelp)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    LabeledContent("Model id") {
                        TextField("", text: $store.summarizationLocalModel)
                            .textFieldStyle(.roundedBorder)
                            .frame(minWidth: 280)
                            .disabled(currentLocalModelPresetId != LocalModelPreset.customId)
                    }
                    LabeledContent("Local endpoint") {
                        TextField("", text: $store.summarizationLocalEndpoint)
                            .textFieldStyle(.roundedBorder)
                            .frame(minWidth: 280)
                    }
                    Text("Local mode lazy-spawns mlx_lm.server on first use; the server shuts down after 5 min of idle. Models live in ~/.cache/huggingface/hub. The daemon pre-fetches the configured model when you switch backend so the first meeting does not wait for HF.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }

            Section("Transcription language") {
                LabeledContent("") {
                    Picker("", selection: $store.transcriptionLanguage) {
                        Text("English (en)").tag("en")
                        Text("Auto-detect").tag("auto")
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
                }
                Text("English is the default. Whisper's auto-detect runs on the first 30 s of audio and misfires on accented speech and silence-heavy openings (a Standup with Indian-English accents has been classified as Spanish in the wild). Force a language when most of your meetings are in one; the multilingual ASR still handles non-native accents fine once language is locked.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Section("Summary language") {
                LabeledContent("") {
                    Picker("", selection: $store.summaryLanguage) {
                        Text("Match transcript (auto)").tag("auto")
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
                }
                Text("Auto mirrors the transcript's detected language. Force a code to always summarize in that language regardless of input.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Section("Long-meeting guard") {
                LabeledContent("Skip auto-summary above") {
                    Slider(
                        value: Binding(
                            get: { Double(store.summarizationSkipAboveChars) },
                            set: { store.summarizationSkipAboveChars = Int($0) }
                        ),
                        in: 0...300_000,
                        step: 5_000
                    )
                    Text(skipThresholdLabel)
                        .monospacedDigit()
                        .frame(width: 110, alignment: .trailing)
                }
                Text("When the transcript exceeds this size, the pipeline writes a paste-into-Claude bundle instead of calling the Anthropic API. 0 disables the guard. ~80,000 chars ≈ 1 hour of speech.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
    }

    private var backendHelpText: String {
        switch store.summarizationBackend {
        case "local":
            return "Audio, transcript, and summary stay on this Mac. No outbound API calls."
        case "auto":
            return "Tries Anthropic first; falls back to local if the API fails or the key is missing."
        default:
            return "Calls api.anthropic.com. Requires ANTHROPIC_API_KEY in secrets.env."
        }
    }

    /// Looks up the current `summarizationLocalModel` against the preset
    /// table; returns the matching preset's id, or `customId` if the user
    /// has typed a model id that is not in the preset list.
    private var currentLocalModelPresetId: String {
        LocalModelPreset.all.first(where: { $0.modelId == store.summarizationLocalModel })?.id
            ?? LocalModelPreset.customId
    }

    /// Two-way binding the Picker drives. Setting it to a known preset id
    /// rewrites `summarizationLocalModel` to that preset's model id;
    /// selecting "Custom" leaves the existing model id alone so the user
    /// can edit it freely in the text field below.
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

    private var localModelPresetHelp: String {
        let id = currentLocalModelPresetId
        if let p = LocalModelPreset.all.first(where: { $0.id == id }) {
            return "\(p.diskHint) on disk, \(p.speedHint). \(p.qualityHint)"
        }
        return "Any HuggingFace MLX-quantised model id."
    }

    private var skipThresholdLabel: String {
        let n = store.summarizationSkipAboveChars
        if n == 0 { return "Disabled" }
        // Rough conversion: ~80,000 chars = 1 hour of speech.
        let hours = Double(n) / 80_000.0
        if hours >= 1 {
            return String(format: "%.1f h", hours)
        }
        return "\(n / 1000)k chars"
    }

    // MARK: Doctor sheet

    private var doctorSheet: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Image(systemName: "stethoscope")
                Text("mp doctor").font(.headline)
                Spacer()
                statusLabel
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
                Button("Re-run") {
                    doctor.run()
                }
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

    private var statusLabel: some View {
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

    // MARK: Modes

    private var modesTab: some View {
        Form {
            Section("Regulated mode") {
                Toggle("Skip Notion publish (local Markdown only)", isOn: $store.regulatedMode)
                Text("When enabled, the pipeline writes summaries to disk only — no transcript or summary is uploaded to Notion. Use for client / regulated meetings.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Section("Tools") {
                Button("Open config in editor") {
                    NSWorkspace.shared.open(Config.defaultPath)
                }
                Button("Reveal config in Finder") {
                    NSWorkspace.shared.activateFileViewerSelecting([Config.defaultPath])
                }
            }
        }
        .formStyle(.grouped)
    }

    // MARK: Helpers

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
}

/// Curated model presets for the Pipeline tab's Picker.
///
/// Three sizes that span the practical sweet-spot for meeting summarization
/// on M-series hardware. Larger models exist; users who want them pick
/// "Custom" and paste a HuggingFace MLX repo id directly.
struct LocalModelPreset {
    let id: String          // Stable picker tag.
    let label: String       // Human-readable menu entry.
    let modelId: String     // HuggingFace repo id `mlx-community/...`.
    let diskHint: String    // Approx download / cache footprint.
    let speedHint: String   // Rough per-meeting latency on M-series.
    let qualityHint: String // One-line vibes-summary of expected output quality.

    static let customId = "__custom"

    static let all: [LocalModelPreset] = [
        LocalModelPreset(
            id: "small",
            label: "Small (Qwen 3B-4bit)",
            modelId: "mlx-community/Qwen2.5-3B-Instruct-4bit",
            diskHint: "~2 GB",
            speedHint: "~10s per meeting",
            qualityHint: "Fast first run, lower quality. Good default to try local mode."
        ),
        LocalModelPreset(
            id: "recommended",
            label: "Recommended (Qwen 14B-4bit)",
            modelId: "mlx-community/Qwen2.5-14B-Instruct-4bit",
            diskHint: "~8 GB",
            speedHint: "~45-130s per meeting",
            qualityHint: "Better decisions and action item discipline."
        ),
        LocalModelPreset(
            id: "large",
            label: "Large (Qwen 32B-4bit)",
            modelId: "mlx-community/Qwen2.5-32B-Instruct-4bit",
            diskHint: "~18 GB",
            speedHint: "~2-4 min per meeting",
            qualityHint: "Highest quality of the curated presets. Wants 32 GB+ RAM."
        ),
    ]
}
