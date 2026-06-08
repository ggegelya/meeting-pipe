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

    /// Outcome of recovering orphan stems.
    struct Recovered {
        /// Merged finals safe to auto-process: default capture-first orphans (full
        /// mic, no redaction intended), regulated orphans gated at capture, and
        /// pre-MIC4 / legacy orphans with no capture-mode marker.
        var ready: [URL] = []
        /// Redaction-opt-in (`.captureFirstRedact`) finals quarantined because
        /// their mute timeline was lost in the interruption, so they cannot be
        /// redacted and must not be auto-published un-redacted (TECH-MIC5 review).
        var quarantined: [URL] = []
    }

    /// Merge orphan intermediates into final .wav files. Sequential to avoid
    /// concurrent ffmpeg swarms. Redaction-opt-in orphans with no mute timeline
    /// are quarantined (fail closed) instead of returned for auto-processing.
    static func recover(stems: [String], in directory: URL) async -> Recovered {
        var result = Recovered()
        for stem in stems {
            guard let url = await MeetingRecorder.recoverOrphan(stem: stem, in: directory) else { continue }
            let quarantineNeeded = shouldQuarantine(stem: stem, final: url, in: directory)
            try? FileManager.default.removeItem(at: directory.appendingPathComponent("\(stem).capturemode"))
            if quarantineNeeded {
                if let kept = quarantine(url) {
                    result.quarantined.append(kept)
                }
            } else {
                result.ready.append(url)
            }
        }
        return result
    }

    /// Whether a recovered orphan must be quarantined rather than auto-processed:
    /// a redaction-opt-in recording (`.captureFirstRedact`, per its start-time
    /// `<stem>.capturemode` marker) whose mute timeline was lost because `stop()`
    /// never ran. Such a recording is lossless and was meant to have muted spans
    /// redacted, so publishing it un-redacted would leak muted audio
    /// (TECH-MIC5 review). The default `.captureFirst` keeps the full mic with no
    /// redaction (TECH-MIC9), so it is safe to auto-process; regulated orphans
    /// were gated at capture; pre-MIC4 / legacy orphans carry no marker; none of
    /// those is quarantined.
    static func shouldQuarantine(stem: String, final: URL, in directory: URL) -> Bool {
        let markerURL = directory.appendingPathComponent("\(stem).capturemode")
        let mode = (try? String(contentsOf: markerURL, encoding: .utf8)).flatMap(CaptureMode.init(marker:))
        return mode == .captureFirstRedact && MuteTimelineFile.read(forFinal: final) == nil
    }

    /// Move a quarantined orphan to the app-private originals directory (kept for
    /// manual recovery, out of the Library scan and every pipeline glob), 0600.
    private static func quarantine(_ url: URL) -> URL? {
        let dest = MuteRedactor.originalsURL(for: url)
        do {
            try FileManager.default.createDirectory(
                at: MuteRedactor.originalsDirectory(), withIntermediateDirectories: true
            )
            try? FileManager.default.removeItem(at: dest)
            try FileManager.default.moveItem(at: url, to: dest)
            try? FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: dest.path)
            Log.event(category: "coordinator", action: "orphan_quarantined", attributes: [
                "file": url.lastPathComponent,
                "reason": "capture_first_no_timeline",
            ])
            Log.writeLine("daemon", "quarantined capture-first orphan (mute timeline lost in the interruption); kept for manual recovery, not auto-published: \(url.lastPathComponent)")
            return dest
        } catch {
            Log.writeLine("daemon", "WARN: could not quarantine orphan \(url.lastPathComponent): \(error.localizedDescription)")
            return nil
        }
    }
}
