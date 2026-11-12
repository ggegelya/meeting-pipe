import Foundation

/// What the Preferences Storage section reports (STOR1). A pure snapshot: every
/// number is a byte count someone can verify with `du`.
struct StorageStats: Equatable {
    /// The `raw/` library: recordings plus every sidecar.
    var libraryBytes = 0
    /// Just the recordings inside `libraryBytes`, split by codec so the owner can
    /// see what a `compress` policy bought.
    var wavBytes = 0
    var flacBytes = 0
    /// Free space on the volume holding the library.
    var freeBytes = 0
    /// Kept full recordings under `originals/` (ADR 0016, reaped by MIC13).
    var originalsBytes = 0
    /// The waveform peaks cache. Rebuildable; safe to clear.
    var waveformCacheBytes = 0
    /// One HuggingFace hub entry, and whether the current config still points at it.
    var models: [ModelEntry] = []

    struct ModelEntry: Equatable, Identifiable {
        /// `mlx-community/Qwen2.5-7B-Instruct-4bit`, un-sanitized back from the
        /// `models--` directory name.
        let repoID: String
        let directory: URL
        let bytes: Int
        /// True when `summarization.local_model` names this repo. Everything else
        /// is evictable: a re-download is a `mp prefetch-model` away.
        let inUse: Bool

        var id: String { repoID }
    }

    var modelCacheBytes: Int { models.reduce(0) { $0 + $1.bytes } }
    var evictableModelBytes: Int { models.filter { !$0.inUse }.reduce(0) { $0 + $1.bytes } }

    /// Per-policy library breakdown, resolved by joining each meeting's
    /// `workflow_id` to its workflow's retention.
    var byPolicy: [RetentionPolicy: Int] = [:]
    /// Bytes belonging to meetings whose workflow no longer exists, which are always
    /// keep-forever. A meeting with no workflow at all counts under the default
    /// workflow's policy, which governs it (REC20).
    var unassignedBytes = 0
    /// REC20 item 4: what the library grew by over the last 30 days, and how long the
    /// free space lasts at that rate.
    var growth = LibraryGrowth.Projection(bytesInWindow: 0, freeBytes: 0)
}

/// REC20 item 4: where the library's growth is heading, from the library's own last 30 days rather
/// than a constant, because the owner's pace is the only one that predicts the owner's disk.
///
/// Growth is every top-level file in the library whose name starts with a recording stem
/// (`YYYYMMDD-HHMMSS`) dated inside the window: the recording and all of its sidecars. Files under
/// subfolders, anything not named for a stem, and a recording's working files (`transientSuffixes`)
/// are not growth. `mp doctor` computes the same
/// thing (`mp.storage.library_growth`) and warns under `warnDays`; the two must agree.
enum LibraryGrowth {

    static let windowDays = 30
    /// `mp doctor` warns below this many days of free space at the current rate.
    static let warnDays = 30

    struct Projection: Equatable {
        /// Bytes added by meetings started in the window.
        let bytesInWindow: Int
        let freeBytes: Int

        var bytesPerDay: Double { Double(bytesInWindow) / Double(LibraryGrowth.windowDays) }

        /// Days until the free space is gone at this rate; nil when nothing grew in the window
        /// (no rate, so no projection) or when the free space could not be read (zero).
        var daysOfFreeSpace: Double? {
            guard bytesPerDay > 0, freeBytes > 0 else { return nil }
            return Double(freeBytes) / bytesPerDay
        }
    }

    /// The window's growth over `(started, bytes)` pairs, one per file.
    static func project(files: [(startedAt: Date, bytes: Int)], freeBytes: Int, now: Date) -> Projection {
        let cutoff = now.addingTimeInterval(-Double(windowDays) * 24 * 60 * 60)
        let inWindow = files
            .filter { $0.startedAt > cutoff && $0.startedAt <= now }
            .reduce(0) { $0 + $1.bytes }
        return Projection(bytesInWindow: inWindow, freeBytes: freeBytes)
    }

    /// A live or interrupted recording's working files: the two capture intermediates and the
    /// merge in progress. About 2 GB an hour while a meeting runs and gone minutes after it stops,
    /// so counting them would make a projection read mid-meeting cry wolf. Mirrors
    /// `mp.storage.TRANSIENT_SUFFIXES`.
    static let transientSuffixes = [".mic.wav", ".system.wav", ".merging.wav"]

    /// The stem date a library file belongs to, from the first 15 characters of its name, or nil
    /// for a file that is not growth. A titled stem (`20260722-140312 Export.wav`) still dates by
    /// its prefix.
    static func stemDate(ofFileNamed name: String) -> Date? {
        guard !transientSuffixes.contains(where: { name.hasSuffix($0) }) else { return nil }
        return MeetingStore.parseStem(String(name.prefix(15)))
    }

    /// The pane's sentence for a projection, or nil when there is nothing to project.
    static func sentence(_ projection: Projection) -> String {
        guard projection.bytesInWindow > 0 else {
            return "No meetings in the last 30 days, so there is no rate to project."
        }
        guard let days = projection.daysOfFreeSpace else {
            return "Free space could not be read, so there is no projection."
        }
        if days >= 365 * 2 {
            return "At this rate the free space lasts more than two years."
        }
        if days >= 60 {
            return "At this rate the free space lasts about \(Int(days / 30)) months."
        }
        return "At this rate the free space lasts about \(max(0, Int(days))) days."
    }
}

/// Blocking disk scan behind `StorageStats`. Its own type with explicit inputs so
/// it is testable against a `tmp` tree and never needs a running app. Off-main
/// callers only.
enum StorageScanner {

    /// HuggingFace caches at `~/.cache/huggingface/hub/models--<repo with / as -->`.
    static func hubRoot(home: URL) -> URL {
        home.appendingPathComponent(".cache/huggingface/hub", isDirectory: true)
    }

    static func scan(
        libraryDir: URL,
        originalsDir: URL,
        waveformCacheDir: URL,
        hubRoot: URL,
        activeModelID: String,
        retentionByWorkflow: [UUID: RetentionPolicy],
        defaultPolicy: RetentionPolicy?,
        now: Date = Date()
    ) -> StorageStats {
        var stats = StorageStats()
        stats.libraryBytes = bytesOnDisk(libraryDir)
        stats.originalsBytes = bytesOnDisk(originalsDir)
        stats.waveformCacheBytes = bytesOnDisk(waveformCacheDir)
        stats.freeBytes = freeBytes(on: libraryDir)
        stats.models = models(in: hubRoot, activeModelID: activeModelID)

        let (byPolicy, unassigned, wav, flac) = audioBreakdown(
            in: libraryDir, retentionByWorkflow: retentionByWorkflow, defaultPolicy: defaultPolicy
        )
        stats.byPolicy = byPolicy
        stats.unassignedBytes = unassigned
        stats.wavBytes = wav
        stats.flacBytes = flac
        stats.growth = LibraryGrowth.project(
            files: stemDatedFiles(in: libraryDir), freeBytes: stats.freeBytes, now: now
        )
        return stats
    }

    /// Every top-level file in the library named for a recording stem, with that stem's date and
    /// the file's size (REC20's growth input).
    static func stemDatedFiles(in libraryDir: URL) -> [(startedAt: Date, bytes: Int)] {
        guard let entries = try? FileManager.default.contentsOfDirectory(
            at: libraryDir, includingPropertiesForKeys: [.fileSizeKey, .isRegularFileKey], options: []
        ) else { return [] }
        return entries.compactMap { url in
            guard let started = LibraryGrowth.stemDate(ofFileNamed: url.lastPathComponent),
                  let values = try? url.resourceValues(forKeys: [.fileSizeKey, .isRegularFileKey]),
                  values.isRegularFile == true
            else { return nil }
            return (started, values.fileSize ?? 0)
        }
    }

    /// Recursive byte total, skipping symlinks so the HuggingFace snapshot links
    /// (which point back into `blobs/`) are not counted twice.
    static func bytesOnDisk(_ url: URL) -> Int {
        let fm = FileManager.default
        guard let enumerator = fm.enumerator(
            at: url,
            includingPropertiesForKeys: [.fileSizeKey, .isRegularFileKey, .isSymbolicLinkKey],
            options: []
        ) else { return 0 }
        var total = 0
        for case let child as URL in enumerator {
            guard let values = try? child.resourceValues(
                forKeys: [.fileSizeKey, .isRegularFileKey, .isSymbolicLinkKey]
            ),
                values.isSymbolicLink != true,
                values.isRegularFile == true
            else { continue }
            total += values.fileSize ?? 0
        }
        return total
    }

    static func freeBytes(on url: URL) -> Int {
        let values = try? url.resourceValues(forKeys: [.volumeAvailableCapacityForImportantUsageKey])
        return Int(values?.volumeAvailableCapacityForImportantUsage ?? 0)
    }

    /// Every `models--*` entry in the hub root, sized, with the configured local
    /// model marked in-use.
    static func models(in hubRoot: URL, activeModelID: String) -> [StorageStats.ModelEntry] {
        let fm = FileManager.default
        guard let entries = try? fm.contentsOfDirectory(
            at: hubRoot, includingPropertiesForKeys: nil, options: [.skipsHiddenFiles]
        ) else { return [] }
        let activeDirName = "models--" + activeModelID.replacingOccurrences(of: "/", with: "--")
        return entries
            .filter { $0.lastPathComponent.hasPrefix("models--") }
            .map { dir in
                StorageStats.ModelEntry(
                    repoID: repoID(fromDirectoryName: dir.lastPathComponent),
                    directory: dir,
                    bytes: bytesOnDisk(dir),
                    inUse: dir.lastPathComponent == activeDirName
                )
            }
            .sorted { $0.bytes > $1.bytes }
    }

    /// `models--mlx-community--Qwen2.5-7B` back to `mlx-community/Qwen2.5-7B`. The
    /// mapping is lossy in principle (a repo name containing `--` round-trips
    /// wrong), so this is display-only; eviction matches on the directory name.
    static func repoID(fromDirectoryName name: String) -> String {
        String(name.dropFirst("models--".count)).replacingOccurrences(of: "--", with: "/")
    }

    /// Split the library's recordings across the retention policies that govern
    /// them. A meeting whose `<stem>.meta.json` names no workflow follows the
    /// default workflow's policy (`defaultPolicy`, REC20), the way the sweep treats
    /// it; one whose workflow no longer exists counts as unassigned and is never
    /// reaped. With no default, a workflow-less meeting is unassigned too.
    static func audioBreakdown(
        in libraryDir: URL,
        retentionByWorkflow: [UUID: RetentionPolicy],
        defaultPolicy: RetentionPolicy? = nil
    ) -> (byPolicy: [RetentionPolicy: Int], unassigned: Int, wavBytes: Int, flacBytes: Int) {
        let fm = FileManager.default
        guard let entries = try? fm.contentsOfDirectory(
            at: libraryDir,
            includingPropertiesForKeys: [.fileSizeKey],
            options: [.skipsHiddenFiles]
        ) else { return ([:], 0, 0, 0) }

        var byPolicy: [RetentionPolicy: Int] = [:]
        var unassigned = 0
        var wavBytes = 0
        var flacBytes = 0
        for url in entries where MeetingStore.isFinalRecording(url) {
            let bytes = (try? url.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0
            if url.pathExtension == "flac" { flacBytes += bytes } else { wavBytes += bytes }

            let stem = MeetingStore.stem(of: url)
            let metaURL = libraryDir.appendingPathComponent("\(stem).meta.json")
            let workflowID = (try? Data(contentsOf: metaURL))
                .flatMap { try? JSONSerialization.jsonObject(with: $0) }
                .flatMap { $0 as? [String: Any] }
                .flatMap { $0["workflow_id"] as? String }
                .flatMap(UUID.init(uuidString:))
            if let workflowID = workflowID, let policy = retentionByWorkflow[workflowID] {
                byPolicy[policy, default: 0] += bytes
            } else if workflowID == nil, let policy = defaultPolicy {
                byPolicy[policy, default: 0] += bytes
            } else {
                unassigned += bytes
            }
        }
        return (byPolicy, unassigned, wavBytes, flacBytes)
    }
}
