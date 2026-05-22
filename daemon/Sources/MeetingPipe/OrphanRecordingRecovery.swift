import Foundation

/// Recovers recordings orphaned when the daemon terminates
/// mid-recording: a crash, a `kill`, a `rebuild.sh` during testing, or
/// the permission-grant restart churn after a reinstall. In every one
/// of those cases `MeetingRecorder.stop()` never runs, so the
/// `<stem>.mic.wav` and `<stem>.system.wav` intermediates are left on
/// disk and never merged into the final `<stem>.wav`. Without recovery
/// the recording, and the meeting it captured, is silently lost and
/// never reaches the pipeline.
///
/// `Coordinator` snapshots the orphan set synchronously at startup,
/// merges each one off the main actor, and enqueues every recovered
/// file for pipeline processing.
enum OrphanRecordingRecovery {

    /// Recovery is bounded to recently orphaned recordings. A crash,
    /// kill, or rebuild orphan is recovered on the very next launch,
    /// so it is always recent; intermediates older than this are stale
    /// test debris from earlier development and must not be swept up
    /// and auto-published weeks later. They stay on disk for the
    /// doctor orphan scan to report.
    static let maxOrphanAge: TimeInterval = 24 * 60 * 60

    /// Pure scan: given the file names present in a recordings
    /// directory, return the stems that have orphaned intermediates (a
    /// `.mic.wav` or `.system.wav`) but no finished `.wav`. Split from
    /// `recoverAll` so the detection logic is unit-testable without
    /// seeding real audio files.
    static func detectOrphanStems(fileNames: [String]) -> [String] {
        var intermediateStems: Set<String> = []
        var finalStems: Set<String> = []
        for name in fileNames {
            // Order matters: a `.mic.wav` name also ends in `.wav`, so
            // the intermediate suffixes must be tested first.
            if name.hasSuffix(".mic.wav") {
                intermediateStems.insert(String(name.dropLast(".mic.wav".count)))
            } else if name.hasSuffix(".system.wav") {
                intermediateStems.insert(String(name.dropLast(".system.wav".count)))
            } else if name.hasSuffix(".wav") {
                finalStems.insert(String(name.dropLast(".wav".count)))
            }
        }
        return intermediateStems.subtracting(finalStems).sorted()
    }

    /// Synchronously enumerate `directory` and return the orphan stems
    /// worth recovering: those with no finished `.wav` AND with
    /// intermediates modified within `maxOrphanAge`. Cheap (one
    /// `contentsOfDirectory` call). The caller runs it before any new
    /// recording can start, so a live recording's in-flight
    /// intermediates are never mistaken for an orphan. Best effort: a
    /// directory that cannot be read yields an empty result.
    static func scanOrphanStems(in directory: URL, now: Date = Date()) -> [String] {
        let fm = FileManager.default
        guard let entries = try? fm.contentsOfDirectory(
            at: directory,
            includingPropertiesForKeys: [.contentModificationDateKey],
            options: [.skipsHiddenFiles]
        ) else {
            return []
        }
        let candidates = detectOrphanStems(fileNames: entries.map { $0.lastPathComponent })
        return candidates.filter { stem in
            guard let modified = newestIntermediateDate(stem: stem, in: directory) else {
                return false
            }
            if now.timeIntervalSince(modified) <= maxOrphanAge {
                return true
            }
            Log.writeLine(
                "daemon",
                "skipping stale orphaned recording \(stem) (intermediates older than \(Int(maxOrphanAge / 3600))h)"
            )
            return false
        }
    }

    /// Newest modification date across a stem's `.mic.wav` /
    /// `.system.wav` intermediates, or nil when neither can be stat'd.
    private static func newestIntermediateDate(stem: String, in directory: URL) -> Date? {
        [".mic.wav", ".system.wav"]
            .map { directory.appendingPathComponent("\(stem)\($0)") }
            .compactMap { url -> Date? in
                (try? url.resourceValues(forKeys: [.contentModificationDateKey]))?
                    .contentModificationDate
            }
            .max()
    }

    /// Merge each orphan stem's intermediates into its final
    /// `<stem>.wav` and return the recovered URLs. Merges run
    /// sequentially so several recovered recordings do not launch a
    /// swarm of concurrent ffmpeg subprocesses.
    static func recover(stems: [String], in directory: URL) async -> [URL] {
        var recovered: [URL] = []
        for stem in stems {
            if let url = await MeetingRecorder.recoverOrphan(stem: stem, in: directory) {
                recovered.append(url)
            }
        }
        return recovered
    }
}
