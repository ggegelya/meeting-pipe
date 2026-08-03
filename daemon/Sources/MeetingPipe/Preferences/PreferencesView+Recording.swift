import AppKit
import SwiftUI

struct RecordingSectionView: View {
    @ObservedObject var store: ConfigStore
    @State private var newConsentBundleID: String = ""

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            SettingsSectionHeader("Recording",
                caption: "How audio is captured to disk, and which apps record automatically.")

            SettingsGroup("Audio") {
                SettingsStackRow("Output directory", showsDivider: false) {
                    TextField("", text: $store.outputDirPath)
                        .textFieldStyle(.roundedBorder)
                        .font(.system(.body, design: .monospaced))
                    Button("Choose…") { chooseOutputDir() }
                        .buttonStyle(.mpGhost)
                    Button {
                        revealOutputDir()
                    } label: {
                        Image(systemName: "arrow.up.right.square")
                    }
                    .buttonStyle(.mpIcon)
                    .help("Reveal in Finder")
                }
            } footer: {
                // The sample-rate picker lived here until HYG2. Capture is a
                // deliberate 16 kHz constant (what Parakeet TDT consumes), so the
                // control offered a choice nothing honored.
                Text("Recordings are stereo 16 kHz WAV: your mic on the left channel, system audio on the right.")
            }

            SettingsGroup("Microphone") {
                SettingsToggleRow("Track in-app mute",
                    sublabel: "Watches your mute button in Teams / Zoom / Slack / Webex (locale catalogue: en, uk, de, es, fr, ja, pt, ru). The mic is always recorded in full; tracking lets a workflow's \"Redact muted spans\" remove those moments from the notes offline, and helps auto-stop a dead meeting. Only a regulated / NDA workflow silences the mic live.",
                    isOn: $store.honorAppMute,
                    showsDivider: false)
                SettingsToggleRow("Voice processing",
                    sublabel: "Apple's noise-suppression + AGC. Drops your mic gain system-wide while recording, so other apps hear you quietly. Off by default; flip on only for solo voice memos.",
                    isOn: $store.voiceProcessing)
            } footer: {
                Text("Voice processing takes effect on the next recording. Mute tracking applies to every meeting.")
            }

            SettingsGroup("Detection") {
                SettingsStackRow("End debounce", showsDivider: false) {
                    SettingsSlider(
                        value: $store.debounceEndSec,
                        range: 1...30,
                        step: 1,
                        format: { "\(Int($0)) s" }
                    )
                }
            } footer: {
                // The start-debounce slider lived here until HYG2. Nothing consumed
                // it: detection promotes on the first live signal so the prompt
                // appears promptly, and the real start gate is the recorder arming.
                Text("How long the detector waits after a meeting's signals go away before ending the recording, so a brief gap does not cut off a pause. Takes effect on the next daemon launch.")
            }

            SettingsGroup("Auto-record allowlist") {
                SettingsFullRow(showsDivider: false) {
                    if store.autoConsentApps.isEmpty {
                        Text("No apps yet - every meeting will prompt.")
                            .font(.mpTextSM)
                            .foregroundStyle(Color(MPColors.fgSubtle))
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
                            .buttonStyle(.mpGhost)
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

/// The bundle-id tag stack's convenience over the shared `FlowLayout`: a collection in,
/// a wrapped row of tags out. The layout itself moved to `PreferencesControls.swift` when
/// the cast strip became its second caller (UX51); this wrapper stayed, because taking a
/// collection and a per-element builder is this pane's shape, not a shared one.
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
