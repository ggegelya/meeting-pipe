import Foundation

/// Re-enqueues recordings orphaned by mid-recording termination (crash, kill,
/// rebuild, reinstall). MeetingRecorder.stop() never ran, so .mic.wav / .system.wav
/// intermediates were never merged into the final .wav and would be silently lost.
/// Coordinator snapshots the orphan set synchronously at startup, merges off-main,
/// and enqueues recovered files for pipeline processing.
enum OrphanRecordingRecovery {

    /// Max age for recovery. A crash/kill/rebuild orphan is always recent (next launch);
    /// older intermediates are stale test debris that must not be auto-published weeks
    /// later. They remain for the doctor orphan scan.
    static let maxOrphanAge: TimeInterval = 24 * 60 * 60

    /// Pure scan: stems with .mic.wav or .system.wav but no finished .wav.
    /// Split from recoverAll so detection is unit-testable without real audio files.
    static func detectOrphanStems(fileNames: [String]) -> [String] {
        var intermediateStems: Set<String> = []
        var finalStems: Set<String> = []
        for name in fileNames {
            // .mic.wav also ends in .wav; test intermediate suffixes first.
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

    /// Enumerate directory and return orphan stems within maxOrphanAge (one
    /// contentsOfDirectory call). Must be called before any new recording starts
    /// so live in-flight intermediates are never mistaken for orphans. Returns [] on error.
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

    /// Newest mtime across a stem's .mic.wav / .system.wav, or nil if neither can be stat'd.
    private static func newestIntermediateDate(stem: String, in directory: URL) -> Date? {
        [".mic.wav", ".system.wav"]
            .map { directory.appendingPathComponent("\(stem)\($0)") }
            .compactMap { url -> Date? in
                (try? url.resourceValues(forKeys: [.contentModificationDateKey]))?
                    .contentModificationDate
            }
            .max()
    }

    /// Merge orphan intermediates into final .wav files. Sequential to avoid concurrent ffmpeg swarms.
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
