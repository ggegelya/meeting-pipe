import Foundation

/// The one expensive field of a Library row, kept across launches (PERF22).
///
/// `MeetingStore`'s per-stem row cache is in memory only, so each launch's first scan rebuilt every
/// row, and since UX74 a row's length comes first from the transcript's `audio_seconds`, which is a
/// `JSONSerialization` parse of the whole word-level `<stem>.json` for one top-level key (mean 260 KB
/// on the owner's Mac, about 110 MB of JSON per launch at the work library's 434 meetings). This maps
/// a stem to the answer plus the identity (name, mtime, size) of the transcript and the audio it was
/// computed from, so a launch re-derives only the rows whose files moved.
///
/// A rebuildable cache under `~/Library/Caches/MeetingPipe/` (ADR 0003, beside the search index and
/// the waveform peaks): deleting it costs one cold scan and nothing else. Only *measurements* are
/// kept (UX74's first two sources); the mtime-span fallback is recomputed, so a header that failed to
/// read once is retried on the next rebuild rather than pinned. A capture intermediate is never kept,
/// since a live recording's file changes on every scan. Pure value type; `MeetingStore` owns the one
/// instance and touches it only on its scan queue.
struct MeetingDurationCache: Equatable {

    /// What a duration was computed from. Size as well as mtime, since a copy or restore can keep an
    /// mtime while replacing the bytes.
    struct FileIdentity: Codable, Equatable {
        let name: String
        let mtime: Double
        let size: Int64

        /// From the resource values the directory enumeration prefetched, so no extra stat. Nil for
        /// no file. A file whose values cannot be read gets mtime 0 and size -1, which matches a
        /// stored entry only if that entry was taken from an equally unreadable file.
        init?(of url: URL?) {
            guard let url else { return nil }
            let values = try? url.resourceValues(forKeys: [.contentModificationDateKey, .fileSizeKey])
            name = url.lastPathComponent
            mtime = values?.contentModificationDate?.timeIntervalSinceReferenceDate ?? 0
            size = Int64(values?.fileSize ?? -1)
        }

        init(name: String, mtime: Double, size: Int64) {
            self.name = name
            self.mtime = mtime
            self.size = size
        }
    }

    struct Entry: Codable, Equatable {
        let seconds: Double
        let transcript: FileIdentity?
        let audio: FileIdentity?
    }

    private struct OnDisk: Codable {
        let version: Int
        let entries: [String: Entry]
    }

    /// Bumped when the meaning of an entry changes; a mismatched file loads as empty.
    static let schemaVersion = 1

    private(set) var entries: [String: Entry] = [:]

    init(entries: [String: Entry] = [:]) {
        self.entries = entries
    }

    static func defaultURL() -> URL {
        let base = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask).first
            ?? FileManager.default.temporaryDirectory
        return base.appendingPathComponent("MeetingPipe/durations.json")
    }

    /// The stored seconds for `stem`, only when both files are the ones it was computed from.
    func seconds(stem: String, transcript: FileIdentity?, audio: FileIdentity?) -> Double? {
        guard let entry = entries[stem], entry.transcript == transcript, entry.audio == audio else {
            return nil
        }
        return entry.seconds
    }

    mutating func set(_ entry: Entry?, for stem: String) {
        entries[stem] = entry
    }

    /// Drop every stem not in `live`. Called only after a scan that listed the directory, so an
    /// unreadable root never empties the cache (the PERF20 lesson for the search index).
    mutating func prune(keeping live: Set<String>) {
        entries = entries.filter { live.contains($0.key) }
    }

    /// Missing, unreadable, corrupt or another schema: empty, which is one cold scan.
    static func load(from url: URL) -> MeetingDurationCache {
        guard let data = try? Data(contentsOf: url),
              let disk = try? JSONDecoder().decode(OnDisk.self, from: data),
              disk.version == schemaVersion else {
            return MeetingDurationCache()
        }
        return MeetingDurationCache(entries: disk.entries)
    }

    func write(to url: URL) throws {
        try FileManager.default.createDirectory(
            at: url.deletingLastPathComponent(), withIntermediateDirectories: true
        )
        let data = try JSONEncoder().encode(OnDisk(version: Self.schemaVersion, entries: entries))
        try data.write(to: url, options: .atomic)
    }
}
