import Foundation

/// Owner of the WF8 correction pairs (AI9). One JSON array at
/// `~/.config/meeting-pipe/workflow_corrections.json`.
///
/// The `ConsentStore` / `SavedSearchStore` single-file idiom rather than
/// `WorkflowStore`'s file-per-item TOML, for the same reasons: this is daemon
/// state with no per-item override pin, the pipeline never reads it, and an
/// append rewrites the whole (small) set anyway.
///
/// Not an `ObservableObject`. The one reader is the detection prompt, which asks
/// once as the panel is raised; there is no SwiftUI surface to invalidate, and a
/// `@Published` array here would be state nothing observes.
///
/// The file starts empty on every existing install and stays empty until the
/// owner corrects a routing decision. That is the intended shape: there is no
/// backfill because there is nothing to backfill from. `events.jsonl` holds the
/// only historical trace and it rotates, so reconstructing counts from it would
/// produce a number that shrinks on its own.
final class WorkflowCorrectionStore {

    /// Oldest pairs are dropped past this. Corrections arrive a handful per
    /// quarter, so the cap is insurance against an unbounded append-only file
    /// rather than a real ceiling anyone reaches.
    static let maxCorrections = 500

    private(set) var corrections: [WorkflowCorrection] = []

    private let url: URL
    private let writeQueue = DispatchQueue(
        label: "com.meetingpipe.workflowcorrectionstore.write",
        qos: .utility
    )

    /// Default location, sibling to `config.toml` and the `workflows/` directory.
    static let defaultURL: URL = {
        FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".config/meeting-pipe/workflow_corrections.json")
    }()

    init(url: URL = WorkflowCorrectionStore.defaultURL) {
        self.url = url
    }

    /// Does not load on init (the `WorkflowStore` / `SavedSearchStore` precedent):
    /// the Coordinator calls this explicitly, so a headless test never reads the
    /// real file.
    func load() {
        guard let data = try? Data(contentsOf: url) else {
            corrections = []
            return
        }
        do {
            let decoder = JSONDecoder()
            decoder.dateDecodingStrategy = .iso8601   // matches `persist`
            corrections = try decoder.decode([WorkflowCorrection].self, from: data)
        } catch {
            // A corrupt or hand-broken file must not take detection down with it;
            // the worst case is a prompt that stops suggesting.
            Log.main.warning(
                "WorkflowCorrectionStore: ignoring unreadable \(self.url.lastPathComponent): \(error.localizedDescription)"
            )
            corrections = []
        }
    }

    /// Record one correction, or ignore it.
    ///
    /// Ignored when the meeting has no source bundle id: a manual recording is
    /// still a real correction, but it can never be keyed back to a detection, so
    /// storing it would grow a file nothing can read.
    ///
    /// Returns whether it was stored, so the caller can keep the event log honest.
    @discardableResult
    func record(
        bundleID: String,
        meetingTitle: String?,
        workflow: Workflow,
        at date: Date = Date()
    ) -> Bool {
        let bundle = bundleID.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !bundle.isEmpty else { return false }
        corrections.append(
            WorkflowCorrection(
                bundleID: bundle,
                titleKey: WorkflowRoutingHint.normalizeTitle(meetingTitle),
                workflowID: workflow.id,
                workflowName: workflow.name,
                at: date
            )
        )
        if corrections.count > Self.maxCorrections {
            corrections.removeFirst(corrections.count - Self.maxCorrections)
        }
        persist()
        return true
    }

    // MARK: - Disk

    private func persist() {
        let snapshot = corrections
        let target = url
        writeQueue.async {
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
            encoder.dateEncodingStrategy = .iso8601
            guard let data = try? encoder.encode(snapshot) else { return }
            do {
                try FileManager.default.createDirectory(
                    at: target.deletingLastPathComponent(),
                    withIntermediateDirectories: true
                )
                try data.write(to: target, options: .atomic)
            } catch {
                Log.main.warning("WorkflowCorrectionStore: write failed: \(error.localizedDescription)")
            }
        }
    }
}
