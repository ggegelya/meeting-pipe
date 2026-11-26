import Foundation

/// Move the meeting library out of a cloud-synced folder (SEC12).
///
/// Guided and never silent: the caller shows the plan, the byte count, and a
/// confirmation before anything is touched. Two refusals are non-negotiable, since
/// a library moved out from under a live recording is a lost meeting:
///
///   1. A recording is in progress.
///   2. A pipeline job is still processing a meeting.
///
/// The move takes the recordings directory and, when it sits beside it, the
/// `digests/` sibling. It does not touch the `published/` sink directory, which
/// the daemon does not model in `ConfigStore`; `mp doctor` reports that root
/// separately so a summary left inside iCloud is still visible.
enum LibraryMover {

    enum MoveError: LocalizedError, Equatable {
        case busy(String)
        case destinationIsSynced(String)
        case destinationOccupied(String)

        var errorDescription: String? {
            switch self {
            case .busy(let reason):
                return "Can't move the library right now: \(reason)."
            case .destinationIsSynced(let provider):
                return "That folder is also synced by \(provider). Pick one outside every sync folder."
            case .destinationOccupied(let name):
                return "\(name) already exists at the destination. Pick an empty folder."
            }
        }
    }

    /// What a move would do, so the confirmation names it exactly.
    struct Plan: Equatable {
        let source: URL
        let destination: URL
        /// The `digests/` sibling, when it exists and rides along.
        let digestsSource: URL?
        let digestsDestination: URL?
        let fileCount: Int
        let bytes: Int
    }

    /// Why the library cannot be moved right now, or nil when it can.
    ///
    /// The fallback since STOR16: `LibraryMoveGuard` asks the recorder and the pipeline lane first,
    /// and this covers work neither owns (another app's process, a crash's leftovers).
    /// Filesystem-only, so it needs no reference to the running `Coordinator`: a
    /// freshly-written `.mic.wav` is a live capture, and a stem with a recording
    /// but no terminal sidecar, inside the staleness window, is a meeting the
    /// pipeline still owns.
    static func inFlightReason(in directory: URL, now: Date = Date()) -> String? {
        let fm = FileManager.default
        let entries: [URL]
        do {
            entries = try fm.contentsOfDirectory(
                at: directory, includingPropertiesForKeys: [.contentModificationDateKey], options: [.skipsHiddenFiles]
            )
        } catch {
            // OBS3: an absent folder has nothing in flight; one that will not list cannot be judged
            // safe to move, so the move is refused with the reason instead of read as "not busy".
            let ns = error as NSError
            if ns.domain == NSCocoaErrorDomain, ns.code == NSFileReadNoSuchFileError { return nil }
            if ns.domain == NSPOSIXErrorDomain, ns.code == Int(ENOENT) { return nil }
            return "the library folder could not be read (\(ns.domain) \(ns.code))"
        }

        if MeetingStore.freshCaptureIntermediate(in: entries) != nil {
            return "a recording is in progress"
        }

        // ARCH20: "still being processed" is `MeetingStatus.decide`'s `.processing`, read from
        // filenames alone (no sidecar is opened: any error sidecar ends processing).
        var facts: [String: MeetingStatus.Facts] = [:]
        // STOR16: the processing window runs from the stem's newest write, not from its start. A
        // 2.5 h meeting that has just stopped is mid-pipeline, and its start is outside 2 h.
        var newestWrite: [String: Date] = [:]
        for url in entries {
            let stem = MeetingStore.stem(of: url)
            if let mtime = try? url.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate {
                newestWrite[stem] = max(newestWrite[stem] ?? .distantPast, mtime)
            }
            var f = facts[stem] ?? MeetingStatus.Facts()
            if MeetingStore.isFinalRecording(url) { f.audio = .finalRecording }
            let name = url.lastPathComponent
            if name.hasSuffix(".summary.json") { f.hasSummary = true }
            if name.hasSuffix(PipelineFailureSidecar.suffix) { f.error = .unopened }
            if name.hasSuffix(".READY_FOR_MANUAL.md") { f.hasPasteReady = true }
            if name.hasSuffix(EmptyMarker.suffix) { f.hasEmptyMarker = true }
            facts[stem] = f
        }
        for (stem, var f) in facts where f.audio == .finalRecording {
            guard MeetingStore.parseStem(stem) != nil, let newest = newestWrite[stem] else { continue }
            f.startedAt = newest
            if MeetingStatus.decide(f, now: now)?.status == .processing {
                return "a meeting is still being processed"
            }
        }
        return nil
    }

    /// Build the plan, refusing anything unsafe. `destinationParent` is the folder
    /// the user picked; the recordings directory keeps its own name inside it.
    static func plan(
        source: URL,
        destinationParent: URL,
        home: URL = FileManager.default.homeDirectoryForCurrentUser,
        now: Date = Date()
    ) throws -> Plan {
        if let reason = inFlightReason(in: source, now: now) {
            throw MoveError.busy(reason)
        }
        if let provider = CloudSyncDetector.detect(path: destinationParent, home: home) {
            throw MoveError.destinationIsSynced(provider.name)
        }

        let fm = FileManager.default
        let destination = destinationParent.appendingPathComponent(source.lastPathComponent, isDirectory: true)
        if fm.fileExists(atPath: destination.path) {
            throw MoveError.destinationOccupied(source.lastPathComponent)
        }

        // `digests/` is a sibling of the recordings dir, not a child (see digest.py).
        // It holds generated summaries, so leaving it behind would leave notes in
        // the synced folder the user is trying to escape.
        let digestsSource = source.deletingLastPathComponent()
            .appendingPathComponent("digests", isDirectory: true)
        let digestsRides = fm.fileExists(atPath: digestsSource.path)
        let digestsDestination = destinationParent.appendingPathComponent("digests", isDirectory: true)
        if digestsRides, fm.fileExists(atPath: digestsDestination.path) {
            throw MoveError.destinationOccupied("digests")
        }

        var fileCount = 0
        var bytes = 0
        for root in [source] + (digestsRides ? [digestsSource] : []) {
            let (files, size) = measure(root)
            fileCount += files
            bytes += size
        }
        return Plan(
            source: source,
            destination: destination,
            digestsSource: digestsRides ? digestsSource : nil,
            digestsDestination: digestsRides ? digestsDestination : nil,
            fileCount: fileCount,
            bytes: bytes
        )
    }

    /// Execute a plan. `moveItem` is atomic within a volume and falls back to a
    /// copy across volumes, both handled by `FileManager`. Blocking IO; off-main
    /// callers only.
    static func execute(_ plan: Plan) throws {
        let fm = FileManager.default
        // SEC22: a parent created for the new location is 0700, like every library folder.
        try OwnerOnlyFiles.createDirectory(at: plan.destination.deletingLastPathComponent())
        try fm.moveItem(at: plan.source, to: plan.destination)
        if let digestsSource = plan.digestsSource, let digestsDestination = plan.digestsDestination {
            do {
                try fm.moveItem(at: digestsSource, to: digestsDestination)
            } catch {
                // The recordings landed; a failed digests move is worth a warning,
                // not a rollback that would put the recordings back in iCloud.
                Log.writeLine("daemon", "WARN: library moved but digests/ stayed behind: \(error.localizedDescription)")
            }
        }
        Log.event(category: "coordinator", action: "library_moved", attributes: [
            "files": plan.fileCount,
            "bytes": plan.bytes,
            "digests_moved": plan.digestsSource != nil,
        ])
    }

    private static func measure(_ root: URL) -> (files: Int, bytes: Int) {
        guard let enumerator = FileManager.default.enumerator(
            at: root, includingPropertiesForKeys: [.fileSizeKey, .isRegularFileKey], options: []
        ) else { return (0, 0) }
        var files = 0
        var bytes = 0
        for case let url as URL in enumerator {
            guard let values = try? url.resourceValues(forKeys: [.fileSizeKey, .isRegularFileKey]),
                  values.isRegularFile == true
            else { continue }
            files += 1
            bytes += values.fileSize ?? 0
        }
        return (files, bytes)
    }
}
