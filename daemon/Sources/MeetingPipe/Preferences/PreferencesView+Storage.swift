import AppKit
import SwiftUI

/// Preferences ▸ Storage (STOR1). Where the library's disk footprint becomes
/// visible: total size, what each retention policy governs, and the two caches
/// that are safe to throw away.
///
/// Retention itself is edited per workflow (Workflows tab), because that is where
/// the policy belongs. This section reports the consequences.
struct StorageSectionView: View {
    @ObservedObject var store: ConfigStore
    @StateObject private var stats: StorageStatsStore

    @State private var confirmingEviction = false

    init(store: ConfigStore, workflowStore: WorkflowStore) {
        self.store = store
        _stats = StateObject(wrappedValue: StorageStatsStore(
            configStore: store, workflowStore: workflowStore
        ))
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            SettingsSectionHeader(
                "Storage",
                caption: "An hour of recorded meeting is about 0.7 GB. Retention policies live on each workflow."
            ) {
                Button(stats.isScanning ? "Scanning…" : "Rescan") {
                    Task { await stats.rescan() }
                }
                .buttonStyle(.mpGhost)
                .disabled(stats.isScanning)
            }

            libraryGroup
            policyGroup
            cachesGroup
        }
        .task { await stats.rescan() }
        .confirmationDialog(
            "Delete unused models?",
            isPresented: $confirmingEviction,
            titleVisibility: .visible
        ) {
            Button("Delete \(byteText(stats.stats?.evictableModelBytes))", role: .destructive) {
                Task { await stats.evictUnusedModels() }
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("Every downloaded model except the one Pipeline is configured to use. They re-download on demand.")
        }
    }

    // MARK: Groups

    private var libraryGroup: some View {
        SettingsGroup("Library") {
            SettingsRow("Recordings folder", sublabel: store.outputDirPath) {
                Button("Reveal in Finder") {
                    NSWorkspace.shared.activateFileViewerSelecting([libraryURL])
                }
                .buttonStyle(.mpGhost)
            }
            SettingsRow("Total size",
                sublabel: "Recordings, transcripts, summaries, and every sidecar.") {
                valueText(stats.stats?.libraryBytes)
            }
            SettingsRow("Audio",
                sublabel: audioSublabel) {
                valueText((stats.stats?.wavBytes ?? 0) + (stats.stats?.flacBytes ?? 0))
            }
            SettingsRow("Kept originals",
                sublabel: "Pre-redaction copies, app-private and excluded from backups. Reaped after 30 days.") {
                valueText(stats.stats?.originalsBytes)
            }
            SettingsRow("Free on this volume", showsDivider: false) {
                valueText(stats.stats?.freeBytes)
            }
        }
    }

    private var policyGroup: some View {
        SettingsGroup("Retention") {
            ForEach(RetentionPolicy.allCases, id: \.self) { policy in
                SettingsRow(policyTitle(policy), sublabel: policyCaption(policy)) {
                    valueText(stats.stats?.byPolicy[policy] ?? 0)
                }
            }
            SettingsRow("No workflow",
                sublabel: "Manual recordings, and meetings whose workflow was deleted. Always kept.",
                showsDivider: false) {
                valueText(stats.stats?.unassignedBytes)
            }
        } footer: {
            Text("A policy only ever touches a finished, published meeting. Anything under Needs you is left alone, however old it is.")
        }
    }

    private var cachesGroup: some View {
        SettingsGroup("Caches") {
            SettingsRow("Waveform peaks",
                sublabel: "Recomputed the next time you open a meeting's Audio tab.") {
                HStack(spacing: MPSpace.s2) {
                    valueText(stats.stats?.waveformCacheBytes)
                    Button("Clear") {
                        Task { await stats.clearWaveformCache() }
                    }
                    .buttonStyle(.mpGhost)
                    .disabled((stats.stats?.waveformCacheBytes ?? 0) == 0)
                }
            }
            SettingsRow("Downloaded models",
                sublabel: modelsSublabel,
                showsDivider: false) {
                HStack(spacing: MPSpace.s2) {
                    valueText(stats.stats?.modelCacheBytes)
                    Button("Evict unused") { confirmingEviction = true }
                        .buttonStyle(.mpGhost)
                        .disabled((stats.stats?.evictableModelBytes ?? 0) == 0)
                }
            }
        }
    }

    // MARK: Copy

    private var libraryURL: URL {
        URL(fileURLWithPath: (store.outputDirPath as NSString).expandingTildeInPath)
    }

    private var audioSublabel: String {
        guard let stats = stats.stats, stats.flacBytes > 0 else {
            return "Uncompressed WAV, as recorded."
        }
        return "\(byteText(stats.wavBytes)) WAV, \(byteText(stats.flacBytes)) compressed to FLAC."
    }

    private var modelsSublabel: String {
        guard let stats = stats.stats, !stats.models.isEmpty else {
            return "No local models downloaded yet."
        }
        let inUse = stats.models.filter(\.inUse).count
        return "\(stats.models.count) downloaded, \(inUse) in use by the configured backend."
    }

    private func policyTitle(_ policy: RetentionPolicy) -> String {
        switch policy {
        case .keep:     return "Keep audio forever"
        case .compress: return "Compress to FLAC"
        case .drop:     return "Drop audio"
        }
    }

    private func policyCaption(_ policy: RetentionPolicy) -> String {
        switch policy {
        case .keep:
            return "The default. Nothing is ever reclaimed."
        case .compress:
            return "Lossless. Playback and waveform are unaffected; quiet speech roughly halves."
        case .drop:
            return "Transcript and summary are kept; the recording is deleted."
        }
    }

    // MARK: Value rendering

    /// A right-aligned byte count, or an ellipsis while the first scan runs. The
    /// placeholder is deliberate: showing "0 bytes" for a library nobody has
    /// measured yet would be a lie.
    @ViewBuilder
    private func valueText(_ bytes: Int?) -> some View {
        Text(byteText(bytes))
            .font(.mpTextBase.monospacedDigit())
            .foregroundStyle(Color(MPColors.fgMuted))
    }

    private func byteText(_ bytes: Int?) -> String {
        bytes.map(StorageStatsStore.format) ?? "…"
    }
}
