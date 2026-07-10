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
    @ObservedObject private var ui = UISettings.shared
    @StateObject private var stats: StorageStatsStore

    @State private var confirmingEviction = false
    @State private var pendingMove: LibraryMover.Plan?

    // STOR3: backup-now state. The launcher persists across renders so an in-flight
    // backup reports back; it also self-retains its subprocess, so this is belt-and-braces.
    @State private var launcher = PipelineLauncher()
    @State private var backupInFlight = false
    @State private var backupError: String?
    @State private var lastBackupAge: String?

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

            syncGroup
            libraryGroup
            backupGroup
            policyGroup
            cachesGroup
        }
        .task { await stats.rescan() }
        .onAppear { refreshLastBackup() }
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
        .confirmationDialog(
            "Move the library?",
            isPresented: Binding(get: { pendingMove != nil }, set: { if !$0 { pendingMove = nil } }),
            titleVisibility: .visible
        ) {
            if let plan = pendingMove {
                Button("Move \(plan.fileCount) files (\(byteText(plan.bytes)))") {
                    pendingMove = nil
                    Task { await stats.executeMove(plan) }
                }
            }
            Button("Cancel", role: .cancel) { pendingMove = nil }
        } message: {
            if let plan = pendingMove {
                Text("\(plan.source.path)\nmoves to\n\(plan.destination.path)")
            }
        }
    }

    // MARK: Cloud sync (SEC12)

    /// Only rendered when a provider is detected. A library that stays on this Mac
    /// needs no reassurance pill; a library that does not is the most important
    /// thing on this screen, so it goes first.
    @ViewBuilder
    private var syncGroup: some View {
        if let provider = stats.syncProvider {
            SettingsGroup("Cloud sync") {
                SettingsRow(
                    stats.promisesZeroEgress
                        ? "This Mac promises zero egress, and the library is syncing anyway"
                        : "Your recordings leave this Mac",
                    sublabel: provider.evidence,
                    alignTop: true,
                    showsDivider: false
                ) {
                    HStack(spacing: MPSpace.s2) {
                        SettingsStatusPill(
                            tone: stats.promisesZeroEgress ? .denied : .needed,
                            icon: "icloud.and.arrow.up",
                            text: provider.name
                        )
                        Button("Move library…") { chooseNewLibraryRoot() }
                            .buttonStyle(.mpGhost)
                    }
                }
            } footer: {
                if let error = stats.moveError {
                    Text(error).foregroundStyle(.mpDanger)
                } else if stats.promisesZeroEgress {
                    Text("Regulated mode and NDA workflows force summarization on-device, but they cannot stop \(provider.name) from uploading the recording after it is written. Move the library outside the synced folder, or turn the sync off.")
                } else {
                    Text("Everything meeting-pipe writes here, recordings included, is uploaded by \(provider.name).")
                }
            }
        } else if stats.moveError != nil {
            SettingsGroup("Cloud sync") {
                SettingsRow("Move failed", sublabel: stats.moveError, alignTop: true, showsDivider: false) {
                    EmptyView()
                }
            }
        }
    }

    /// Ask for a destination, plan the move, and hand the plan to the confirmation
    /// dialog. Nothing on disk changes until the user confirms.
    private func chooseNewLibraryRoot() {
        let panel = NSOpenPanel()
        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        panel.canCreateDirectories = true
        panel.allowsMultipleSelection = false
        panel.prompt = "Choose"
        panel.message = "Pick a folder outside every cloud-sync folder. Your recordings folder keeps its name inside it."
        guard panel.runModal() == .OK, let destination = panel.url else { return }
        pendingMove = stats.planMove(to: destination)
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

    // MARK: Backup (STOR3)

    /// Spawns `mp backup <dir>` to a remembered destination. Restore stays a terminal
    /// step (a new-Mac restore runs before the app is configured), so it is not
    /// surfaced here - the footer points at the README runbook.
    private var backupGroup: some View {
        SettingsGroup("Backup") {
            SettingsRow(
                "Back up now",
                sublabel: backupDestinationSublabel,
                alignTop: true,
                showsDivider: false
            ) {
                HStack(spacing: MPSpace.s2) {
                    if backupInFlight {
                        ProgressView().controlSize(.small)
                    }
                    Button(ui.backupDestinationPath == nil ? "Choose destination…" : "Change…") {
                        chooseBackupDestination()
                    }
                    .buttonStyle(.mpGhost)
                    .disabled(backupInFlight)
                    Button("Back up now") { runBackup() }
                        .buttonStyle(.mpGhost)
                        .disabled(backupInFlight || ui.backupDestinationPath == nil)
                }
            }
        } footer: {
            if let error = backupError {
                Text(error).foregroundStyle(.mpDanger)
            } else {
                Text(lastBackupAge ?? "No backup has run on this Mac yet. Restore is a terminal step; see the README backup runbook.")
            }
        }
    }

    private var backupDestinationSublabel: String {
        ui.backupDestinationPath.map { "A dated archive of your library, config, and corrections lands in \($0)." }
            ?? "A dated archive of your library, config, and corrections. Pick where it goes."
    }

    /// Pick (or change) the remembered backup destination. Defaults the panel to the
    /// current destination so "Change…" opens where the last archive went.
    private func chooseBackupDestination() {
        let panel = NSOpenPanel()
        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        panel.canCreateDirectories = true
        panel.allowsMultipleSelection = false
        panel.prompt = "Choose"
        panel.message = "Pick a folder for meeting-pipe backups. Prefer one outside a cloud-synced folder if the library is sensitive."
        if let current = ui.backupDestinationPath {
            panel.directoryURL = URL(fileURLWithPath: current)
        }
        guard panel.runModal() == .OK, let url = panel.url else { return }
        ui.backupDestinationPath = url.path
        backupError = nil
    }

    private func runBackup() {
        guard let dest = ui.backupDestinationPath, !backupInFlight else { return }
        backupError = nil
        backupInFlight = true
        launcher.backup(dir: URL(fileURLWithPath: dest)) { result in
            Task { @MainActor in
                backupInFlight = false
                switch result {
                case .success:
                    refreshLastBackup()
                case .failure(let error):
                    backupError = error.localizedDescription
                }
            }
        }
    }

    private func refreshLastBackup() {
        lastBackupAge = LastBackup.ageDescription()
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
