import Foundation

/// What restoring one archive into this Mac's roots would do (STOR5).
///
/// Written by `mp.restore.plan_restore` and read here: the keys below are that
/// `RestorePlan` TypedDict's, and adding or renaming one means touching both
/// sides. It is the *whole* reason `mp restore` grew a `--json` mode: the
/// in-app confirm has to name a blast radius exactly, and scraping it out of a
/// prose report would make the copy a guess.
struct RestorePlan: Decodable, Equatable, Sendable {
    /// One destination root, as the archive would leave it.
    struct Root: Decodable, Equatable, Sendable {
        let name: String
        let prefix: String
        let destination: String
        /// Files from the archive that would land here.
        let files: Int
        /// Of those, the ones with nothing at that path yet.
        let added: Int
        /// Of those, the ones already on disk, which the restore overwrites.
        let replaced: Int
        /// Whether the destination holds files at all, which is what a plain
        /// `mp restore` refuses over. Not the same question as `replaced`: a
        /// library full of *other* meetings is occupied and replaces nothing.
        let occupied: Bool
    }

    let archive: String
    /// ISO-8601 with an offset, as `datetime.isoformat()` writes it.
    let createdAt: String
    let audioIncluded: Bool
    /// True when this Mac already has a `config.toml`, so the backup's copy is
    /// skipped and the library stays pointed where it is now.
    let keepsConfigToml: Bool
    let totalFiles: Int
    let added: Int
    let replaced: Int
    let roots: [Root]
    /// Up to `mp.restore.PLAN_SAMPLE_LIMIT` archive-relative paths per bucket.
    /// The counts are exact, so a sample shorter than its count means "and more".
    let addedSample: [String]
    let replacedSample: [String]

    enum CodingKeys: String, CodingKey {
        case archive, roots, added, replaced
        case createdAt = "created_at"
        case audioIncluded = "audio_included"
        case keepsConfigToml = "keeps_config_toml"
        case totalFiles = "total_files"
        case addedSample = "added_sample"
        case replacedSample = "replaced_sample"
    }

    var archiveURL: URL { URL(fileURLWithPath: archive) }
    var archiveName: String { archiveURL.lastPathComponent }

    static func load(from url: URL) -> RestorePlan? {
        guard let data = try? Data(contentsOf: url) else { return nil }
        return try? JSONDecoder().decode(RestorePlan.self, from: data)
    }
}

/// The plan as the confirm dialog says it out loud (STOR5).
///
/// Pure and separate from the view because this is the copy that has to be
/// *honest*: a restore into a live library overwrites files, and the sentence
/// the owner reads before pressing is the only place that can say so. Kept
/// table-testable for the same reason a detection rule is.
enum RestorePreview {

    /// The destructive button's title. Names the number, not just the verb, so
    /// the count is legible even to someone who skimmed the message.
    static func confirmTitle(for plan: RestorePlan) -> String {
        "Restore \(files(plan.totalFiles))"
    }

    /// The blast radius, in the order a person needs it: what this archive is,
    /// what it does to the files already here, what comes back, then the
    /// caveats that only apply sometimes.
    static func message(for plan: RestorePlan) -> String {
        var lines: [String] = ["Backup taken \(taken(plan.createdAt))."]

        // Only the roots that actually receive something: naming the empty ones
        // would pad the blast radius with folders nothing is written into.
        let destinations = plan.roots.filter { $0.files > 0 }.map(\.name)
        let into = destinations.isEmpty ? "this Mac" : list(destinations)
        // "This writes N files", not "N files are written": the subject stays
        // singular, so the sentence is grammatical at one file too, which is the
        // case this button exists for.
        if plan.replaced == 0 {
            lines.append("This writes \(files(plan.totalFiles)) into your \(into). Nothing already on disk is touched.")
        } else {
            lines.append("This writes \(files(plan.totalFiles)) into your \(into), overwriting \(files(plan.replaced)) already there. Files the backup does not carry are left alone.")
        }

        if plan.added > 0, !plan.addedSample.isEmpty {
            lines.append("Comes back: \(sample(plan.addedSample, of: plan.added)).")
        }
        if !plan.audioIncluded {
            lines.append("This backup carries no recordings, so the meetings it restores have no audio.")
        }
        if plan.keepsConfigToml {
            lines.append("Your config.toml is kept, so the library stays where it is. Workflows, roster, and vocabulary are replaced by the backup's copies.")
        }
        lines.append("There is no undo.")
        return lines.joined(separator: "\n\n")
    }

    /// The footer line after a restore lands. Names the archive, because by then
    /// the picker is long gone and "restored" on its own says nothing about what.
    static func summary(for plan: RestorePlan) -> String {
        "Restored \(files(plan.totalFiles)) from \(plan.archiveName)."
    }

    // MARK: Pieces

    /// `library/20260101-120000.wav` reads as `20260101-120000.wav`: the root is
    /// already named a line above, and the prefix is an archive detail.
    static func displayName(_ archivePath: String) -> String {
        guard let slash = archivePath.firstIndex(of: "/") else { return archivePath }
        return String(archivePath[archivePath.index(after: slash)...])
    }

    /// Two names and a remainder. A longer list stops being read.
    private static func sample(_ paths: [String], of total: Int) -> String {
        let shown = paths.prefix(2).map(displayName)
        let rest = total - shown.count
        guard rest > 0 else { return list(shown) }
        return list(shown) + ", and \(count(rest)) more"
    }

    private static func list(_ items: [String]) -> String {
        switch items.count {
        case 0:  return ""
        case 1:  return items[0]
        case 2:  return "\(items[0]) and \(items[1])"
        default: return items.dropLast().joined(separator: ", ") + ", and \(items[items.count - 1])"
        }
    }

    private static func count(_ n: Int) -> String {
        n.formatted(.number.grouping(.automatic))
    }

    /// "1 file" / "1,204 files". Every count in this copy is a file count, and
    /// the agreement has to hold at one, which is a real case: recovering a
    /// single deleted recording is what this button is for.
    private static func files(_ n: Int) -> String {
        n == 1 ? "1 file" : "\(count(n)) files"
    }

    /// The manifest's ISO-8601 timestamp as a date a person reads, through the
    /// one parser that already knows what Python's `isoformat()` actually emits
    /// (microseconds, which `ISO8601DateFormatter` will not take). An unparseable
    /// string falls back to itself rather than to a wrong date.
    static func taken(_ createdAt: String) -> String {
        guard let date = LastBackup.parseISO8601(createdAt) else { return createdAt }
        let out = DateFormatter()
        out.dateStyle = .medium
        out.timeStyle = .short
        return out.string(from: date)
    }
}

/// Which of the Storage pane's two long jobs may start right now (STOR5).
///
/// Backup and restore are mutually exclusive, and not for tidiness: `mp backup`
/// walking the library while `mp restore` writes into it archives a
/// half-restored library, and the reverse hands the restore a moving target.
/// Each disables the other for as long as it runs.
struct StorageBusyGate: Equatable {
    let backupRunning: Bool
    let restoreRunning: Bool
    /// A remembered destination is what `mp backup <dir>` needs. A restore is
    /// handed its archive by the file picker, so it needs none, which is the
    /// one place these two differ.
    let hasBackupDestination: Bool

    var isBusy: Bool { backupRunning || restoreRunning }
    var backupEnabled: Bool { !isBusy && hasBackupDestination }
    var restoreEnabled: Bool { !isBusy }
}

/// The two-step restore behind Preferences ▸ Storage ▸ Restore from backup (STOR5).
///
/// Step one is a dry run and it is not optional: `confirm()` only does anything
/// from `.confirming`, so the real run is unreachable except through a plan the
/// owner has been shown. That is the difference between a preview that is
/// mandatory and a preview that is merely conventional, and it is the reason
/// this lives on its own type instead of inside the view: a SwiftUI `@State`
/// sequence cannot be tested, and this one is the app's most destructive button.
@MainActor
final class RestoreFlow: ObservableObject {

    enum Phase: Equatable {
        case idle
        /// `mp restore --dry-run --json` is walking the archive.
        case previewing
        /// The plan is on screen, waiting for the owner.
        case confirming(RestorePlan)
        /// The real run, over the plan that was confirmed.
        case restoring(RestorePlan)
        /// Landed. Carries the footer line.
        case finished(String)
        case failed(String)
    }

    @Published private(set) var phase: Phase = .idle

    private let launcher: PipelineDriver

    init(launcher: PipelineDriver) {
        self.launcher = launcher
    }

    /// True while either invocation is out, which is what blocks a backup.
    var isBusy: Bool {
        switch phase {
        case .previewing, .restoring: return true
        case .idle, .confirming, .finished, .failed: return false
        }
    }

    /// The plan awaiting a decision, for the confirmation dialog's binding.
    var pendingPlan: RestorePlan? {
        if case .confirming(let plan) = phase { return plan }
        return nil
    }

    /// What the pane's footer should say about restore right now, or nil when it
    /// has nothing to add and the backup line should stand.
    var footerText: String? {
        switch phase {
        case .previewing:            return "Reading the backup…"
        case .restoring(let plan):   return "Restoring \(plan.archiveName)…"
        case .finished(let summary): return summary
        case .failed(let message):   return message
        case .idle, .confirming:     return nil
        }
    }

    var hasFailed: Bool {
        if case .failed = phase { return true }
        return false
    }

    /// Step one: the mandatory dry run. Writes nothing, and refuses nothing, so
    /// the answer is always a plan to show rather than an error to explain.
    func preview(archive: URL) {
        guard !isBusy else { return }
        phase = .previewing
        launcher.restorePreview(archive: archive) { result in
            Task { @MainActor in
                switch result {
                case .success(let plan):
                    self.phase = .confirming(plan)
                case .failure(let error):
                    self.phase = .failed("Could not read that backup: \(PipelineLauncher.diagnostics(for: error))")
                }
            }
        }
    }

    /// Step two, reachable only from a shown plan. The archive comes from the
    /// plan rather than from the picker, so the run cannot be about a different
    /// file than the one the confirm described.
    func confirm() {
        guard case .confirming(let plan) = phase else { return }
        phase = .restoring(plan)
        launcher.restore(archive: plan.archiveURL) { result in
            Task { @MainActor in
                switch result {
                case .success:
                    self.phase = .finished(RestorePreview.summary(for: plan))
                case .failure(let error):
                    self.phase = .failed("Restore failed: \(PipelineLauncher.diagnostics(for: error))")
                }
            }
        }
    }

    /// Dismiss the confirm, or clear a finished / failed line. Never interrupts
    /// a run: there is no safe point to stop a half-written restore at, so the
    /// pane offers no Cancel while one is out.
    func dismiss() {
        guard !isBusy else { return }
        phase = .idle
    }
}
