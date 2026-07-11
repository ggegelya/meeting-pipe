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

    /// A recovered final ready to enqueue, paired with the summary mode it was
    /// started under (REC2 / AUD-6). A BYO orphan carries `.byo` so it produces a
    /// paste bundle instead of an Anthropic+Notion auto-summary; everything else
    /// is `.auto` (the legacy default), with NDA / regulated kept on-device by the
    /// restored `<stem>.meta.json` arming the pipeline's egress guard.
    struct ReadyRecording: Equatable {
        let url: URL
        let summaryMode: SummaryMode
    }

    /// Outcome of recovering orphan stems.
    struct Recovered {
        /// Merged finals safe to auto-process: default capture-first orphans (full
        /// mic, no redaction intended), regulated orphans gated at capture, and
        /// pre-MIC4 / legacy orphans with no capture-mode marker. Each carries the
        /// summary mode from its start-time manifest.
        var ready: [ReadyRecording] = []
        /// Redaction-opt-in (`.captureFirstRedact`) finals quarantined because
        /// their mute timeline was lost in the interruption, so they cannot be
        /// redacted and must not be auto-published un-redacted (TECH-MIC5 review).
        var quarantined: [URL] = []
    }

    /// Merge orphan intermediates into final .wav files. Sequential to avoid
    /// concurrent ffmpeg swarms. Redaction-opt-in orphans with no mute timeline
    /// are quarantined (fail closed) instead of returned for auto-processing.
    ///
    /// Each recovered stem replays its start-time manifest (REC2 / AUD-6):
    /// `<stem>.meta.json` is rebuilt from it (so an NDA / regulated orphan arms
    /// the pipeline egress guard and the meeting title survives) and the recorded
    /// summary mode rides back so a BYO orphan is enqueued `.byo`, not `.auto`.
    static func recover(stems: [String], in directory: URL) async -> Recovered {
        var result = Recovered()
        for stem in stems {
            guard let url = await MeetingRecorder.recoverOrphan(stem: stem, in: directory) else { continue }
            // Read the manifest + capture-mode marker BEFORE clearing the
            // start-time markers below: both feed the routing decision.
            let manifest = RecordingManifest.read(forStem: stem, in: directory)
            let quarantineNeeded = shouldQuarantine(stem: stem, final: url, in: directory)
            if let manifest = manifest {
                restoreMetaSidecar(manifest.meta, forStem: stem, in: directory)
            }
            cleanupStartMarkers(stem: stem, in: directory)
            if quarantineNeeded {
                if let kept = quarantine(url) {
                    result.quarantined.append(kept)
                }
            } else {
                result.ready.append(ReadyRecording(
                    url: url,
                    summaryMode: manifest?.summaryMode ?? .auto
                ))
            }
        }
        return result
    }

    /// Rebuild `<stem>.meta.json` from the manifest's captured payload so the
    /// pipeline arms its egress guard for an NDA / regulated orphan and keeps the
    /// meeting title. Skipped when the payload is empty (a manual, workflow-less,
    /// non-regulated recording the pipeline handles via global config) or when a
    /// sidecar already exists (a `stop()` that wrote one before the merge failed,
    /// or a prior recovery), so a hand-edited or stop-written sidecar is never
    /// clobbered.
    static func restoreMetaSidecar(_ meta: [String: Any], forStem stem: String, in directory: URL) {
        guard !meta.isEmpty else { return }
        let sidecar = directory.appendingPathComponent("\(stem).meta.json")
        guard !FileManager.default.fileExists(atPath: sidecar.path) else { return }
        guard let data = try? JSONSerialization.data(
            withJSONObject: meta, options: [.prettyPrinted, .sortedKeys]
        ) else { return }
        do {
            try data.write(to: sidecar, options: .atomic)
            Log.event(category: "coordinator", action: "orphan_meta_restored", attributes: [
                "stem": stem,
            ])
        } catch {
            Log.writeLine("daemon", "WARN: could not restore meta sidecar for orphan \(stem): \(error.localizedDescription)")
        }
    }

    /// Clear both start-time markers once a stem is recovered: the capture-mode
    /// token and the recovery manifest. Callers read them (for the quarantine
    /// decision and routing) before this runs.
    private static func cleanupStartMarkers(stem: String, in directory: URL) {
        try? FileManager.default.removeItem(at: directory.appendingPathComponent("\(stem).capturemode"))
        try? FileManager.default.removeItem(at: directory.appendingPathComponent("\(stem).offrecord"))
        RecordingManifest.remove(forStem: stem, in: directory)
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
        // A written timeline means stop() ran and the redactor can do its job: never quarantine.
        guard MuteTimelineFile.read(forFinal: final) == nil else { return false }
        let markerURL = directory.appendingPathComponent("\(stem).capturemode")
        let mode = (try? String(contentsOf: markerURL, encoding: .utf8)).flatMap(CaptureMode.init(marker:))
        // Quarantine a redaction-opt-in recording (as before), OR any recording that had a manual
        // off-record span (MIC14): both were meant to have audio redacted, and the lost timeline
        // means auto-publishing would leak it. A plain capture-first recording with no manual span
        // keeps the full mic by design, so it still auto-processes.
        return mode == .captureFirstRedact || OffRecordMarker.exists(forFinal: final)
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
            // Owner-only + Time-Machine/iCloud excluded, same as the redaction
            // move-aside. Quarantined full audio used to reach Time Machine
            // because this path set 0600 but skipped the exclusion (AUD-19).
            MuteRedactor.protectOriginalAtRest(dest)
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
