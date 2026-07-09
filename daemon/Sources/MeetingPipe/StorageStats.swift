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
    /// Bytes belonging to meetings with no workflow, which are always keep-forever.
    var unassignedBytes = 0
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
        retentionByWorkflow: [UUID: RetentionPolicy]
    ) -> StorageStats {
        var stats = StorageStats()
        stats.libraryBytes = bytesOnDisk(libraryDir)
        stats.originalsBytes = bytesOnDisk(originalsDir)
        stats.waveformCacheBytes = bytesOnDisk(waveformCacheDir)
        stats.freeBytes = freeBytes(on: libraryDir)
        stats.models = models(in: hubRoot, activeModelID: activeModelID)

        let (byPolicy, unassigned, wav, flac) = audioBreakdown(
            in: libraryDir, retentionByWorkflow: retentionByWorkflow
        )
        stats.byPolicy = byPolicy
        stats.unassignedBytes = unassigned
        stats.wavBytes = wav
        stats.flacBytes = flac
        return stats
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
    /// them. A meeting whose `<stem>.meta.json` names no workflow, or one whose
    /// workflow no longer exists, counts as unassigned and is never reaped.
    static func audioBreakdown(
        in libraryDir: URL,
        retentionByWorkflow: [UUID: RetentionPolicy]
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
            } else {
                unassigned += bytes
            }
        }
        return (byPolicy, unassigned, wavBytes, flacBytes)
    }
}
