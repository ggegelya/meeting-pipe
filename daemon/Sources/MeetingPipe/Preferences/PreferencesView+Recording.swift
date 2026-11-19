import AppKit
import SwiftUI

struct RecordingSectionView: View {
    @ObservedObject var store: ConfigStore
    /// UX88: allowlist bundle id to installed app name, for the tags.
    @State private var consentAppNames: [String: String] = [:]
    /// UX89: the library root changes only through this store's confirmed move or switch.
    @StateObject private var stats: StorageStatsStore

    init(store: ConfigStore, workflowStore: WorkflowStore, moveGuard: LibraryMoveGuard = LibraryMoveGuard()) {
        self.store = store
        _stats = StateObject(wrappedValue: StorageStatsStore(
            configStore: store, workflowStore: workflowStore, moveGuard: moveGuard
        ))
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            SettingsSectionHeader("Recording",
                caption: "How audio is captured to disk, and which apps record automatically.")

            SettingsGroup("Audio") {
                // UX89: a read-only path. A free-text field here saved a half-typed path 0.5 s after a
                // keystroke and re-pointed recordings, backups, Ask and digests at it.
                SettingsStackRow("Output directory", showsDivider: false) {
                    Text(store.outputDirPath)
                        .font(.system(.body, design: .monospaced))
                        .lineLimit(1)
                        .truncationMode(.middle)
                        .textSelection(.enabled)
                        .frame(maxWidth: .infinity, alignment: .leading)
                    LibraryRootButtons(stats: stats)
                }
            } footer: {
                // The sample-rate picker lived here until HYG2. Capture is a
                // deliberate 16 kHz constant (what Parakeet TDT consumes), so the
                // control offered a choice nothing honored.
                if let error = stats.moveError {
                    FailureNotice(failure: FailurePresentation(diagnostics: error, operation: .storage, title: "Couldn't change the recordings folder")).foregroundStyle(.mpDanger)
                } else {
                    Text("Recordings are stereo 16 kHz WAV: your mic on the left channel, system audio on the right. Move library takes your recordings with it; Use another folder leaves them where they are.")
                }
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

            SettingsGroup("Auto-record allowlist") {
                SettingsFullRow(showsDivider: false) {
                    if store.everyMeetingPrompts {
                        Text("No apps yet - every meeting will prompt.")
                            .font(.mpTextSM)
                            .foregroundStyle(Color(MPColors.fgSubtle))
                            .frame(maxWidth: .infinity, alignment: .leading)
                    } else {
                        // UX88: tags by app name; the stored value is still the bundle id.
                        WrappingHStack(items: store.autoConsentApps) { bundleID in
                            SettingsTag(consentAppNames[bundleID] ?? bundleID) {
                                store.removeAutoConsentApp(bundleID)
                            }
                            .help(bundleID)
                        }
                    }
                }
                SettingsFullRow {
                    // UX88: the shared app picker in place of a raw bundle-id field. Preferences
                    // holds no meeting list, so it offers the registry's apps, the ones already
                    // here, and Other app…; the workflow editor adds the library's sources.
                    MeetingAppPicker(
                        selection: nil,
                        placeholder: "Add app\u{2026}",
                        librarySources: [:],
                        current: store.autoConsentApps,
                        excluding: MeetingAppChoices.allowlistExclusions(
                            current: store.autoConsentApps, browsers: MeetingAppRegistry.shared.browserBundles
                        ),
                        onPick: { picked in
                            guard !picked.isEmpty else { return }
                            store.addAutoConsentApp(picked)
                        }
                    )
                    .frame(maxWidth: .infinity, alignment: .leading)
                }
            } footer: {
                Text("When the daemon detects audio from these apps, recording starts without showing the prompt. Picking Always for an app on the prompt adds it here; remove it to be asked again from the next meeting on.")
            }
        }
        .libraryRootDialogs(stats)
        .onAppear { refreshConsentAppNames() }
        .onChange(of: store.autoConsentApps) { _, _ in refreshConsentAppNames() }
    }

    /// Resolved once per change of the list, never per render (`InstalledApps` caches).
    private func refreshConsentAppNames() {
        var names: [String: String] = [:]
        for id in store.autoConsentApps {
            if let name = InstalledApps.name(for: id) { names[id] = name }
        }
        consentAppNames = names
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
