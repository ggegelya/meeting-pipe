import Foundation
import os

/// Re-enqueues recordings orphaned by mid-recording termination (crash, kill,
/// rebuild, reinstall). MeetingRecorder.stop() never ran, so .mic.wav / .system.wav
/// intermediates were never merged into the final .wav and would be silently lost.
/// Coordinator requests a sweep at launch and after every job (REC6), one at a time
/// (REC24); each scans and merges off-main and enqueues recovered files on main.
enum OrphanRecordingRecovery {

    /// Max age for recovery. A crash/kill/rebuild orphan is always recent (next launch);
    /// older intermediates are stale test debris that must not be auto-published weeks
    /// later. They remain for the doctor orphan scan.
    static let maxOrphanAge: TimeInterval = 24 * 60 * 60

    /// Failed post-processes after which the after-job sweep stops retrying a stem
    /// (REC24). The count in `<stem>.recordfail.json` includes the stop-time failure, so
    /// 3 is that one plus two after-job re-merges: enough to ride out a transient cause
    /// (a busy disk, an ffmpeg that was briefly missing) and few enough that a merge
    /// failing the same way every time (REC9's too-short refusal, a corrupt intermediate,
    /// a merge that always reaches the 300 s ceiling) stops re-reading about 2 GB per
    /// recorded hour after every job. The launch sweep ignores the cap and tries every
    /// marked stem once per launch, because a rebuild can ship the fix that makes it work.
    static let maxAfterJobAttempts = 3

    /// Which trigger ran the sweep. Only `afterJob` honours `maxAfterJobAttempts`.
    enum Sweep: Equatable {
        case launch
        case afterJob
    }

    /// Recovers one stem's intermediates into a final, or nil. `RecordingPostProcessor.recoverOrphan`
    /// in production; a seam so a test can hold a recovery in flight.
    typealias Recoverer = (_ stem: String, _ directory: URL) async -> URL?

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

    /// Enumerate directory and return orphan stems eligible for recovery (one
    /// contentsOfDirectory call). Returns [] on error.
    ///
    /// `excludingStems` are the stems the recorder owns: REC6 runs this sweep after
    /// every job completion, not only at launch, so a live recording's in-flight
    /// intermediates would otherwise be mistaken for an orphan and merged mid-write.
    /// Pass `MeetingRecorder.ownedStems` (empty at launch, when nothing records), never
    /// `libraryModel.liveRecordingStem`: that UI mirror is set only after `start()`
    /// returns, while `<stem>.mic.wav` exists from before the engine start (REC23).
    ///
    /// The `maxOrphanAge` staleness cutoff drops intermediates with no deliberate
    /// marker (stale test debris that must not auto-publish weeks later), but a stem
    /// carrying a start-time `.recovery.json` manifest or a `.recordfail.json`
    /// post-process-failure breadcrumb is a real interrupted recording and is exempt
    /// (REC6): a launchd daemon can run for days before the next sweep, so the old
    /// 24 h cutoff silently abandoned genuine orphans.
    ///
    /// An `afterJob` sweep also skips a stem whose breadcrumb has reached
    /// `maxAfterJobAttempts` (REC24), whatever other marker it carries; `launch` does not.
    static func scanOrphanStems(
        in directory: URL,
        now: Date = Date(),
        excludingStems: Set<String> = [],
        sweep: Sweep = .launch,
        staleReport: StaleOrphanReport = .process
    ) -> [String] {
        let fm = FileManager.default
        guard let entries = try? fm.contentsOfDirectory(
            at: directory,
            includingPropertiesForKeys: [.contentModificationDateKey],
            options: [.skipsHiddenFiles]
        ) else {
            return []
        }
        let candidates = detectOrphanStems(fileNames: entries.map { $0.lastPathComponent })
            .filter { !excludingStems.contains($0) }
        return candidates.filter { stem in
            if sweep == .afterJob, failedAttempts(stem: stem, in: directory) >= maxAfterJobAttempts {
                return false
            }
            if hasRecoveryMarker(stem: stem, in: directory) {
                return true
            }
            guard let modified = newestIntermediateDate(stem: stem, in: directory) else {
                return false
            }
            if now.timeIntervalSince(modified) <= maxOrphanAge {
                return true
            }
            // REC32: once per process, as an event. This was a `writeLine` on every sweep, which
            // on the owner's laptop logged three June stems 415 times each (12.8% of daemon.log)
            // and reached no surface, since Diagnostics shows events only.
            if staleReport.isFirstSighting(stem) {
                reportStale(stem: stem, in: directory, ageSec: now.timeIntervalSince(modified))
            }
            return false
        }
    }

    /// `coordinator`/`orphan_stale_found` for one stale stem, with what is on disk for it.
    private static func reportStale(stem: String, in directory: URL, ageSec: TimeInterval) {
        var present: [String] = []
        var bytes: Int64 = 0
        for suffix in [".mic.wav", ".system.wav"] {
            let url = directory.appendingPathComponent("\(stem)\(suffix)")
            guard let size = (try? FileManager.default.attributesOfItem(atPath: url.path))?[.size] as? NSNumber else {
                continue
            }
            present.append(String(suffix.dropFirst()))
            bytes += size.int64Value
        }
        let days = (ageSec / 86_400 * 10).rounded() / 10
        Log.event(category: "coordinator", action: "orphan_stale_found", attributes: [
            "stem": stem,
            "age_days": days,
            "intermediates": present,
            "bytes": bytes,
        ])
        Log.writeLine(
            "daemon",
            "stale orphaned recording \(stem): no recovery marker, intermediates \(days) days old; not recovered automatically (reported once per launch)"
        )
    }

    /// Whether a stem carries a deliberate recovery marker that exempts it from the
    /// staleness cutoff: the start-time `.recovery.json` manifest, a `.recordfail.json`
    /// breadcrumb written when a stop-time merge failed (REC6), or the owner's Recover from
    /// the menu (REC32, `.recover-requested`).
    private static func hasRecoveryMarker(stem: String, in directory: URL) -> Bool {
        let fm = FileManager.default
        return fm.fileExists(atPath: directory.appendingPathComponent("\(stem).recovery.json").path)
            || fm.fileExists(atPath: directory.appendingPathComponent("\(stem).recordfail.json").path)
            || fm.fileExists(atPath: directory.appendingPathComponent("\(stem)\(recoverRequestedSuffix)").path)
    }

    // MARK: - Stale orphans the owner resolves (REC32)

    /// The marker the menu's Recover writes beside a stale orphan's intermediates. It exempts the
    /// stem from the staleness cutoff exactly like a `.recordfail.json`, so the next sweep merges
    /// it through the normal path (privacy routing included), and recovery clears it.
    static let recoverRequestedSuffix = ".recover-requested"

    /// Stems the sweep skips as stale: intermediates with no final, no recovery marker, older than
    /// `maxOrphanAge`, and not owned by the recorder. What the menu's stale row counts and acts on.
    static func staleStems(in directory: URL, now: Date = Date(), excludingStems: Set<String> = []) -> [String] {
        guard let names = try? FileManager.default.contentsOfDirectory(atPath: directory.path) else { return [] }
        return detectOrphanStems(fileNames: names)
            .filter { !excludingStems.contains($0) && !hasRecoveryMarker(stem: $0, in: directory) }
            .filter { stem in
                guard let modified = newestIntermediateDate(stem: stem, in: directory) else { return false }
                return now.timeIntervalSince(modified) > maxOrphanAge
            }
    }

    /// Recover: mark each stem so the next sweep takes it. Returns the stems marked.
    @discardableResult
    static func requestRecovery(stems: [String], in directory: URL) -> [String] {
        stems.filter { stem in
            let url = directory.appendingPathComponent("\(stem)\(recoverRequestedSuffix)")
            do {
                try Data().write(to: url, options: .atomic)
                Log.event(category: "coordinator", action: "orphan_stale_recover_requested", attributes: ["stem": stem])
                return true
            } catch {
                Log.writeLine("daemon", "WARN: could not mark stale orphan \(stem) for recovery: \(error.localizedDescription)")
                return false
            }
        }
    }

    /// Discard: move each stem's intermediates into the held folder (`MuteRedactor.quarantine`,
    /// the folder the originals reaper never enters), never a delete. Returns the stems whose
    /// every intermediate moved.
    @discardableResult
    static func discard(stems: [String], in directory: URL, originalsDir: URL? = nil) -> [String] {
        stems.filter { stem in
            var moved: [String] = []
            var failed = false
            for suffix in [".mic.wav", ".system.wav"] {
                let url = directory.appendingPathComponent("\(stem)\(suffix)")
                guard FileManager.default.fileExists(atPath: url.path) else { continue }
                do {
                    _ = try MuteRedactor.quarantine(url, in: originalsDir)
                    moved.append(String(suffix.dropFirst()))
                } catch {
                    failed = true
                    Log.writeLine("daemon", "WARN: could not set aside \(url.lastPathComponent): \(error.localizedDescription)")
                }
            }
            if !failed {
                // REC36: nothing is left to place.
                MergePlacement.remove(forFinal: directory.appendingPathComponent("\(stem).wav"))
            }
            Log.event(category: "coordinator", action: "orphan_stale_discarded", attributes: [
                "stem": stem,
                "moved": moved,
                "complete": !failed,
            ])
            return !failed
        }
    }

    /// Failed post-processes recorded in the stem's `.recordfail.json`, 0 when it has none.
    private static func failedAttempts(stem: String, in directory: URL) -> Int {
        RecordingPostProcessor.readPostProcessFailure(
            final: directory.appendingPathComponent("\(stem).wav")
        )?.attempts ?? 0
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
        /// Finals quarantined instead (`QuarantineReason`): a redaction was owed and the mute
        /// timeline was lost in the interruption, or the manifest or marker that would say so
        /// cannot be read (REC21). They must not be auto-published (TECH-MIC5 review).
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
    ///
    /// `isOwned` asks the recorder, on main, immediately before each stem's merge
    /// (REC23). The scan's exclusion is a snapshot, and an earlier stem's merge can run
    /// for minutes, long enough for a recording to start on a stem the snapshot listed
    /// as an orphan; merging it then deletes the live intermediates and publishes a stub.
    ///
    /// A failure that takes the stem's breadcrumb to `maxAfterJobAttempts` emits
    /// `coordinator`/`orphan_recovery_gave_up` (REC24). Keyed on the persisted count crossing
    /// the cap, so it fires once per stem for the life of the library, not once per launch.
    static func recover(
        stems: [String],
        in directory: URL,
        isOwned: @MainActor (String) -> Bool,
        originalsDir: URL? = nil,
        recoverer: Recoverer = { await RecordingPostProcessor.recoverOrphan(stem: $0, in: $1) }
    ) async -> Recovered {
        var result = Recovered()
        for stem in stems {
            if await isOwned(stem) {
                Log.event(category: "coordinator", action: "orphan_recovery_skipped_owned", attributes: [
                    "stem": stem,
                ])
                Log.writeLine("daemon", "skipping orphan \(stem): the recorder owns it now (a recording started on it after the scan)")
                continue
            }
            let attemptsBefore = failedAttempts(stem: stem, in: directory)
            guard let url = await recoverer(stem, directory) else {
                reportGaveUpIfCapReached(stem: stem, in: directory, attemptsBefore: attemptsBefore)
                continue
            }
            // Read the manifest + capture-mode marker BEFORE clearing the
            // start-time markers below: both feed the routing decision.
            let manifest = RecordingManifest.load(forStem: stem, in: directory)
            let reason = quarantineReason(stem: stem, final: url, in: directory, manifest: manifest)
            if let parsed = manifest.parsed {
                restoreMetaSidecar(parsed.meta, forStem: stem, in: directory)
            }
            guard let reason else {
                cleanupStartMarkers(stem: stem, in: directory)
                result.ready.append(ReadyRecording(url: url, summaryMode: manifest.parsed?.summaryMode ?? .auto))
                continue
            }
            // REC21 (F026): move first, clear the markers only once the move landed. They used to be
            // cleared first, so a failed move left the uncut final in raw/ with nothing saying a cut
            // was owed, and the next launch's stranded-job Retry published it. Kept, they hold that
            // Retry: the redactor fails closed on `.offrecord` / `.capturemode`, and `retryMeeting`
            // refuses an unreadable manifest and carries a parsed one's `redactionOwed`.
            if let kept = quarantine(url, reason: reason, originalsDir: originalsDir) {
                cleanupStartMarkers(stem: stem, in: directory)
                result.quarantined.append(kept)
            } else {
                // The merge succeeded, so the failure breadcrumb is stale either way.
                try? FileManager.default.removeItem(at: directory.appendingPathComponent("\(stem).recordfail.json"))
            }
        }
        return result
    }

    /// Scan, then recover, off main (REC24): the `raw/` listing grows by about ten files a
    /// meeting, and both callers are on main. Nonisolated and async, so awaiting it from a
    /// main-actor Task runs the scan and the merges on the global executor; `isOwned` still
    /// hops back to main per stem.
    static func scanAndRecover(
        in directory: URL,
        excludingStems: Set<String>,
        sweep: Sweep,
        isOwned: @MainActor (String) -> Bool,
        recoverer: Recoverer = { await RecordingPostProcessor.recoverOrphan(stem: $0, in: $1) }
    ) async -> Recovered {
        let stems = scanOrphanStems(in: directory, excludingStems: excludingStems, sweep: sweep)
        guard !stems.isEmpty else { return Recovered() }
        return await recover(stems: stems, in: directory, isOwned: isOwned, recoverer: recoverer)
    }

    private static func reportGaveUpIfCapReached(stem: String, in directory: URL, attemptsBefore: Int) {
        guard let record = RecordingPostProcessor.readPostProcessFailure(
            final: directory.appendingPathComponent("\(stem).wav")
        ), attemptsBefore < maxAfterJobAttempts, record.attempts >= maxAfterJobAttempts else { return }
        Log.event(category: "coordinator", action: "orphan_recovery_gave_up", attributes: [
            "stem": stem,
            "attempts": record.attempts,
            "reason": record.reason as Any,
        ])
        Log.writeLine(
            "daemon",
            "orphan \(stem) failed to merge \(record.attempts) times; no more retries after jobs, the next launch tries once more. Intermediates kept."
        )
    }

    /// Rebuild `<stem>.meta.json` from the manifest's captured payload so the
    /// pipeline arms its egress guard for an NDA / regulated orphan and keeps the
    /// meeting title. Skipped when the payload is empty (a manual, workflow-less,
    /// non-regulated recording the pipeline handles via global config) or when a
    /// sidecar already exists (a `stop()` that wrote one before the merge failed,
    /// or a prior recovery), so a hand-edited or stop-written sidecar is never
    /// clobbered.
    ///
    /// Returns whether a readable sidecar carrying the routing is on disk afterwards
    /// (SEC25): true for an empty payload (nothing to route), a readable existing
    /// sidecar, or a successful write; false when the write failed or the file in the
    /// way cannot be read, which the Library's retry turns into a refusal.
    @discardableResult
    static func restoreMetaSidecar(_ meta: [String: Any], forStem stem: String, in directory: URL) -> Bool {
        guard !meta.isEmpty else { return true }
        let sidecar = directory.appendingPathComponent("\(stem).meta.json")
        switch MeetingMetaRead.load(at: sidecar) {
        case .loaded: return true
        case .unreadable: return false
        case .absent: break
        }
        guard let data = try? JSONSerialization.data(
            withJSONObject: meta, options: [.prettyPrinted, .sortedKeys]
        ) else { return false }
        do {
            try data.write(to: sidecar, options: .atomic)
            Log.event(category: "coordinator", action: "orphan_meta_restored", attributes: [
                "stem": stem,
            ])
            return true
        } catch {
            Log.writeLine("daemon", "WARN: could not restore meta sidecar for orphan \(stem): \(error.localizedDescription)")
            return false
        }
    }

    /// Clear both start-time markers once a stem is recovered: the capture-mode
    /// token and the recovery manifest. Callers read them (for the quarantine
    /// decision and routing) before this runs.
    private static func cleanupStartMarkers(stem: String, in directory: URL) {
        try? FileManager.default.removeItem(at: directory.appendingPathComponent("\(stem).capturemode"))
        try? FileManager.default.removeItem(at: directory.appendingPathComponent("\(stem).offrecord"))
        // REC6: this runs only after a successful re-merge, so a `.recordfail.json`
        // breadcrumb from the failed stop-time merge is now stale - clear it so it
        // stops counting toward the doctor's orphan finding.
        try? FileManager.default.removeItem(at: directory.appendingPathComponent("\(stem).recordfail.json"))
        try? FileManager.default.removeItem(at: directory.appendingPathComponent("\(stem)\(recoverRequestedSuffix)"))
        RecordingManifest.remove(forStem: stem, in: directory)
    }

    /// Why a recovered orphan is quarantined rather than auto-processed (REC21). The raw values
    /// are `orphan_quarantined`'s and `orphan_quarantine_failed`'s `reason`.
    enum QuarantineReason: String, Equatable {
        /// A redaction-opt-in recording (`.captureFirstRedact`, from its marker or its manifest)
        /// whose mute timeline was lost because `stop()` never ran.
        case captureFirstNoTimeline = "capture_first_no_timeline"
        /// A recording that had a manual off-the-record span (MIC14), from its `.offrecord`
        /// marker or its manifest, whose timeline was lost.
        case offRecordNoTimeline = "off_record_no_timeline"
        /// `.capturemode` exists but cannot be read, so it may have named a redaction.
        case markerUnreadable = "marker_unreadable"
        /// `.recovery.json` exists but cannot be read: the routing (BYO, NDA, regulated) and the
        /// redaction facts it carries are unknown.
        case manifestUnreadable = "manifest_unreadable"
    }

    /// Whether, and why, a recovered orphan must be quarantined rather than auto-processed.
    ///
    /// An unreadable manifest quarantines whatever else is on disk, timeline included: it is a
    /// routing failure, not a redaction one, and a recording whose BYO / NDA / regulated intent
    /// is unknown must not take the `.auto` cloud path. The redaction reasons need the timeline
    /// to be missing: a written timeline means the redactor can do its job. A lossless recording
    /// that was meant to have audio cut (redact-opt-in, or a manual off-record span) and lost its
    /// timeline would leak that audio if auto-published (TECH-MIC5 review, MIC14). A plain
    /// capture-first recording keeps the full mic by design (TECH-MIC9), regulated orphans were
    /// gated at capture, and pre-MIC4 / legacy orphans carry no marker: none is quarantined.
    static func quarantineReason(
        stem: String, final: URL, in directory: URL, manifest: RecordingManifest.LoadResult
    ) -> QuarantineReason? {
        if manifest == .unreadable { return .manifestUnreadable }
        guard MuteTimelineFile.read(forFinal: final) == nil else { return nil }
        let marker = CaptureMode.readMarker(forFinal: directory.appendingPathComponent("\(stem).wav"))
        let parsed = manifest.parsed
        if marker == .recorded(.captureFirstRedact) || parsed?.captureMode == .captureFirstRedact {
            return .captureFirstNoTimeline
        }
        if OffRecordMarker.exists(forFinal: final) || parsed?.offRecord == true {
            return .offRecordNoTimeline
        }
        if marker == .unreadable { return .markerUnreadable }
        return nil
    }

    /// `quarantineReason` as a yes or no, reading the manifest itself.
    static func shouldQuarantine(stem: String, final: URL, in directory: URL) -> Bool {
        quarantineReason(
            stem: stem, final: final, in: directory,
            manifest: RecordingManifest.load(forStem: stem, in: directory)
        ) != nil
    }

    /// Move a quarantined orphan to the app-private originals directory (kept for
    /// manual recovery, out of the Library scan and every pipeline glob), 0600.
    /// `originalsDir` nil is the app-private default; a test points it somewhere the move fails.
    private static func quarantine(_ url: URL, reason: QuarantineReason, originalsDir: URL?) -> URL? {
        do {
            // Owner-only + Time-Machine/iCloud excluded, same as the redaction
            // move-aside. Quarantined full audio used to reach Time Machine
            // because this path set 0600 but skipped the exclusion (AUD-19).
            let dest = try MuteRedactor.quarantine(url, in: originalsDir)
            Log.event(category: "coordinator", action: "orphan_quarantined", attributes: [
                "file": url.lastPathComponent,
                "reason": reason.rawValue,
            ])
            Log.writeLine("daemon", "quarantined orphan (\(reason.rawValue)); kept for manual recovery, not auto-published: \(url.lastPathComponent)")
            return dest
        } catch {
            let ns = error as NSError
            Log.event(category: "coordinator", action: "orphan_quarantine_failed", attributes: [
                "stem": url.deletingPathExtension().lastPathComponent,
                "reason": reason.rawValue,
                "error_domain": ns.domain,
                "error_code": ns.code,
            ])
            Log.writeLine("daemon", "WARN: could not quarantine orphan \(url.lastPathComponent) (\(reason.rawValue)): \(error.localizedDescription); its markers and manifest are kept so a Retry stays held")
            return nil
        }
    }
}

/// The stale orphans already reported in this process (REC32), so each is an event once per
/// launch instead of a log line on every sweep. Not persisted on purpose: a relaunch reports
/// them again, which is what keeps them in front of the owner until they are resolved.
final class StaleOrphanReport: Sendable {
    static let process = StaleOrphanReport()

    private let reported = OSAllocatedUnfairLock<Set<String>>(initialState: [])

    /// True the first time `stem` is seen in this report's life, false after.
    func isFirstSighting(_ stem: String) -> Bool {
        reported.withLock { $0.insert(stem).inserted }
    }
}

/// Single flight for the orphan sweep, with at most one coalesced rerun (REC24). Pure: a
/// request answers whether to start now, a finish whether to run once more. Before it, every
/// job completion started its own recovery Task, so a second completion during a long merge
/// merged the same stem again and unlinked the first merge's `<stem>.merging.wav`.
struct OrphanRecoveryLatch: Equatable {
    enum Request: Equatable { case start, coalesced }
    enum Finish: Equatable { case rerun, idle }

    private(set) var isRunning = false
    private(set) var rerunPending = false

    /// Any number of requests during one run collapse into one rerun, which scans afresh and
    /// so covers every orphan those requests could have meant.
    mutating func request() -> Request {
        if isRunning {
            rerunPending = true
            return .coalesced
        }
        isRunning = true
        return .start
    }

    /// On `.rerun` the latch stays running and the caller starts the rerun itself.
    mutating func finish() -> Finish {
        if rerunPending {
            rerunPending = false
            return .rerun
        }
        isRunning = false
        return .idle
    }
}

/// Holds `OrphanRecoveryLatch` on main and drives one sweep at a time (REC24). `run` does one
/// whole sweep (snapshot on main, scan and merge off main, enqueue on main); a rerun is always
/// an after-job sweep, since a launch sweep is the first request of a process and never coalesced.
@MainActor
final class OrphanRecoveryRunner {
    private var latch = OrphanRecoveryLatch()
    private nonisolated let run: @Sendable @MainActor (OrphanRecordingRecovery.Sweep) async -> Void

    nonisolated init(run: @escaping @Sendable @MainActor (OrphanRecordingRecovery.Sweep) async -> Void) {
        self.run = run
    }

    var isRunning: Bool { latch.isRunning }

    func request(_ sweep: OrphanRecordingRecovery.Sweep) {
        guard latch.request() == .start else { return }
        start(sweep)
    }

    private func start(_ sweep: OrphanRecordingRecovery.Sweep) {
        Task { @MainActor in
            await run(sweep)
            if latch.finish() == .rerun {
                start(.afterJob)
            }
        }
    }
}
