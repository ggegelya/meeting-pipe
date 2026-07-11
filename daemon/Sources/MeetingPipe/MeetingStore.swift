import AppKit
import Combine
import Foundation

/// One row in the Library list, materialized from on-disk sidecars alongside the recording.
struct Meeting: Identifiable, Hashable {

    /// Coarse lifecycle state derived from which sidecars exist on disk. `.failed` uses a precise `<stem>.error.json` signal; other states infer from presence/absence of summary/paste-ready sidecars, with an age fallback when no sidecar was written.
    enum Status: String, Hashable {
        case recording            // currently being written (live)
        case processing           // wav present, no summary yet
        case manualPasteReady     // long-meeting bundle waiting on user paste
        case done                 // summary.json on disk
        case empty                // pipeline finished with no speech to summarize (.empty.json marker)
        case failed               // error sidecar present, or stalled past the age window
        case unknown
    }

    /// A meeting with no summary older than this is considered stalled (crash, restart, config error) and flips from `.processing` to `.failed`. Two hours is generous: even a 3-hour transcript + 32B-Qwen local summary finishes inside it.
    static let staleProcessingThresholdSec: TimeInterval = 2 * 60 * 60

    let stem: String
    let startedAt: Date
    /// The meeting's recording, `<stem>.wav` or `<stem>.flac` (STOR1 compresses a
    /// settled meeting's audio in place). Nil when a `drop` retention policy
    /// reclaimed the audio and only the transcript + summary remain, so every
    /// audio affordance has to gate on it rather than assume a file.
    let audioURL: URL?
    let recordingsDir: URL

    let summaryTitle: String?     // from <stem>.summary.json["title"]
    let meetingTitle: String?     // from <stem>.meta.json["meeting_title"]

    let sourceBundleID: String?
    let sourceDisplayName: String?
    let sourceKind: AppSourceKind?

    /// Written by TECH-B into the meta sidecar. Nil until set, so the chip never shows a placeholder.
    let workflowName: String?
    let workflowColor: String?

    let durationSec: TimeInterval?
    let backend: String?
    let modelId: String?

    let status: Status

    /// From `<stem>.error.json` when that sidecar is the source of `.failed`. Both nil for staleness-age-inferred failures and for non-failed rows.
    let failureReason: String?
    let failureStage: String?

    /// PIPE6: true when the failure was a deterministic backend rejection (Apple Intelligence declining the transcript's language) that a same-backend retry cannot fix, so the failed-state view offers a local re-summarize instead. Matches the marker `AppleIntelligenceError` stamps into the reason, so producer and consumer cannot drift.
    var failureSuggestsLocalReSummarize: Bool {
        guard let reason = failureReason else { return false }
        return reason.range(
            of: AppleIntelligenceError.unsupportedLanguageMarker, options: .caseInsensitive
        ) != nil
    }

    /// Lowercased search corpus (TECH-A14): title + summary bullets + decisions + action tasks. Built once per scan so the filter loop never re-reads JSON. Transcripts excluded to keep the corpus bounded; full-transcript search is the FTS5 upgrade (TECH-A3).
    let searchableText: String

    /// True when the summary sidecar is newer than the newest publish sidecar (`.notion.json` / `.obsidian.json`), i.e. the meeting was edited or regenerated since it was last published, so the row offers an inline Republish (TECH-UX2). False when never published. Computed during the scan from prefetched file mtimes; defaulted so test constructors need not supply it.
    var needsRepublish: Bool = false

    /// ISO code from `<stem>.summary.json["detected_language"]`, lifted into the row so the detail header can show a language chip (TECH-UI-4). Nil when unknown. Defaulted so test constructors need not supply it.
    var detectedLanguage: String? = nil

    /// Resolved zero-egress flags read from `<stem>.meta.json` (TECH-DSN6): the
    /// workflow's NDA flag and the global regulated flag captured at record time.
    /// The Library badge reads these instead of inferring NDA from the backend.
    /// Defaulted so test constructors need not supply them.
    var workflowNDAMode: Bool? = nil
    var regulatedMode: Bool? = nil

    /// The input device the recorder captured, from `<stem>.meta.json["mic_device_name"]`
    /// (MIC15). Shown in the detail pane so the user can tell which mic a recording used. Nil for
    /// pre-MIC15 recordings and manual workflow-less runs. Defaulted so test constructors need
    /// not supply it.
    var micDeviceName: String? = nil

    /// True when the post-stop dead-mic gate fired (`<stem>.meta.json["mic_silent"]`, MIC15): the
    /// mic stayed at the noise floor while the system side was live. Drives the row warning pill.
    /// Defaulted so test constructors need not supply it.
    var micWarning: Bool = false

    /// Publish outcome from `<stem>.run.json["publish_state"]` (TECH-I6): "full"
    /// / "partial" / "none", nil for never-published rows. The pipeline writes it
    /// after fanout; drives the Library partial-publish badge. Defaulted so test
    /// constructors need not supply it.
    var publishState: String? = nil

    /// Why a `.empty` row produced no summary, from `<stem>.empty.json` (PIPE3).
    /// Lets the row distinguish "No speech" from an unreliable transcript instead
    /// of the single hard-coded label. Nil for every non-`.empty` row. Defaulted
    /// so test constructors need not supply it.
    var emptyReason: EmptyReason? = nil

    /// Sidecar presence captured during the scan so the row's context menu can gate
    /// Republish / Regenerate without a per-row `FileManager` stat on the scroll
    /// path. Derived from the prefetched file list; defaulted so test constructors
    /// need not supply them.
    var hasSummaryJSON: Bool = false
    var hasTranscriptMD: Bool = false

    /// True when the meeting has a local summary-correction record with an
    /// `edited` verdict (`CorrectionStore`), i.e. the summary was edited on this
    /// Mac. Drives the "Summary edited locally" marker (UX15); grades (good/bad)
    /// are excluded. Applied as a post-scan overlay because corrections live
    /// outside the recordings dir, so it rides on top of the per-stem file-mtime
    /// cache rather than inside it. Defaulted so test constructors need not supply it.
    var hasCorrections: Bool = false

    var id: String { stem } // stems are unique per recording (datetime-derived)

    /// A file to select in Finder for "Reveal" / "Open folder". Prefers the
    /// recording; falls back to the summary or transcript when a `drop` retention
    /// policy reclaimed the audio, and to the directory itself when nothing else
    /// survives. Stats the disk, so only call it from a user action, never the
    /// scroll path.
    var revealURL: URL {
        if let audio = audioURL { return audio }
        let fm = FileManager.default
        for name in ["\(stem).summary.md", "\(stem).md", "\(stem).json"] {
            let candidate = recordingsDir.appendingPathComponent(name)
            if fm.fileExists(atPath: candidate.path) { return candidate }
        }
        return recordingsDir
    }

    /// True when the meeting was recorded zero-egress, i.e. forced on-device and
    /// local-only by an NDA workflow or global regulated mode. Drives the
    /// "Local only" privacy badge, which must never be inferred (TECH-DSN6).
    var isZeroEgress: Bool { (workflowNDAMode ?? false) || (regulatedMode ?? false) }

    /// Best-effort display label: summary title > meeting title > "{source} at HH:mm" > raw stem. Never empty.
    var displayTitle: String {
        if let t = summaryTitle, !t.isEmpty { return t }
        if let t = meetingTitle, !t.isEmpty { return t }
        let time = MeetingFormatters.shortTime.string(from: startedAt)
        if let src = sourceDisplayName, !src.isEmpty {
            return "\(src) at \(time)"
        }
        return stem
    }

    /// Synthesized `AppSource` for glyph resolution. Nil for manual recordings (no detected source).
    var appSource: AppSource? {
        guard let bid = sourceBundleID, let name = sourceDisplayName else { return nil }
        return AppSource(
            bundleID: bid,
            displayName: name,
            kind: sourceKind ?? .native,
            meetingTitle: meetingTitle
        )
    }
}

/// Directory cache + filesystem watcher backing the Library list. Threading: rescans run on a private serial queue; published mutations dispatch to main. A 500 ms debounce coalesces burst writes into a single rescan.
final class MeetingStore: ObservableObject {

    @Published private(set) var meetings: [Meeting] = []
    /// True only for the initial scan; subsequent rescans don't flip it so the list doesn't flash to "loading" on each file change.
    @Published private(set) var hasLoadedOnce: Bool = false

    /// Monotonically-increasing fingerprint bumped on every successful rescan. Views cache derived values (counts, facets, groups) by this value instead of comparing full arrays; two 200-Meeting array comparisons per render would defeat memoization. Increments even when only a middle row flips status, since the whole array is replaced wholesale.
    @Published private(set) var revision: Int = 0

    private let recordingsDir: URL
    private let scanQueue = DispatchQueue(
        label: "com.meetingpipe.MeetingStore.scan",
        qos: .userInitiated
    )
    private var watcher: DispatchSourceFileSystemObject?
    private var watcherFD: CInt = -1

    /// At most one rescan in flight; further calls fold into a single follow-up so a burst of pipeline writes doesn't fan out into N+1 scans.
    private var scanRunning = false
    private var pendingRescan = false

    /// 500 ms debounce balances the 1 s new-meeting visibility target against bursty pipeline writes that land within a few seconds of each other.
    private static let debounceSec: TimeInterval = 0.5
    private var debounceWork: DispatchWorkItem?

    /// Per-stem parse cache (TECH-A12). A `.done` row re-parsed every 500 ms scan during recording was the audit perf finding: with 500+ meetings each rescan re-read summary.json + run.json + meta.json for every row. We keep the built `Meeting` keyed by a signature of the stem's on-disk file mtimes; an unchanged signature skips the JSON parse entirely. Only terminal rows are cached (a `.processing` row's status is age-derived, so it must re-evaluate each scan even when no file changed). Touched only on `scanQueue` (serial), so no extra locking.
    private struct CacheEntry {
        let signature: [String: Date]
        let meeting: Meeting
    }
    private var scanCache: [String: CacheEntry] = [:]

    /// Edited-correction stems for the "Summary edited locally" overlay (UX15),
    /// refreshed only when the corrections directory's mtime changes (a write is
    /// temp-file + rename, which bumps it), so a 500 ms scan storm during
    /// recording does not re-parse every record. Touched only on `scanQueue`
    /// (serial), like `scanCache`, so no extra locking.
    private var editedStemsCache: (mtime: Date, stems: Set<String>)?

    init(recordingsDir: URL) {
        self.recordingsDir = recordingsDir
    }

    deinit {
        detachWatcher()
    }

    /// Begin watching the recordings directory and trigger an initial scan. Idempotent.
    func start() {
        attachWatcher()
        refresh()
    }

    /// Force a rescan. Also called internally by the debounced filesystem watcher.
    func refresh() {
        if scanRunning {
            pendingRescan = true
            return
        }
        scanRunning = true
        let dir = recordingsDir
        scanQueue.async { [weak self] in
            guard let self = self else { return }
            let result = self.performScan(directory: dir)
            DispatchQueue.main.async {
                self.meetings = result
                self.revision &+= 1
                if !self.hasLoadedOnce { self.hasLoadedOnce = true }
                self.scanRunning = false
                if self.pendingRescan {
                    self.pendingRescan = false
                    self.refresh()
                }
            }
        }
    }

    /// Tear down the directory watcher. Paired with `start()` so the LibraryWindow can suspend scanning while hidden. Without this the watcher fires rescans into an invisible tree, dragging the main queue along (the model is not released when the window closes).
    func stop() {
        detachWatcher()
        debounceWork?.cancel()
        debounceWork = nil
    }

    // MARK: Watcher

    private func attachWatcher() {
        if watcher != nil { return }
        try? FileManager.default.createDirectory(
            at: recordingsDir,
            withIntermediateDirectories: true
        )
        let fd = open(recordingsDir.path, O_EVTONLY)
        guard fd >= 0 else { return }
        watcherFD = fd
        let src = DispatchSource.makeFileSystemObjectSource(
            fileDescriptor: fd,
            eventMask: [.write, .delete, .rename, .extend],
            queue: scanQueue
        )
        src.setEventHandler { [weak self] in
            DispatchQueue.main.async { self?.scheduleDebouncedRefresh() }
        }
        src.setCancelHandler { [weak self] in
            guard let self = self else {
                close(fd)
                return
            }
            if self.watcherFD >= 0 {
                close(self.watcherFD)
                self.watcherFD = -1
            }
        }
        watcher = src
        src.resume()
    }

    private func detachWatcher() {
        watcher?.cancel()
        watcher = nil
    }

    private func scheduleDebouncedRefresh() {
        debounceWork?.cancel()
        let work = DispatchWorkItem { [weak self] in self?.refresh() }
        debounceWork = work
        DispatchQueue.main.asyncAfter(
            deadline: .now() + Self.debounceSec,
            execute: work
        )
    }

    // MARK: Scan

    /// Enumerate the recordings dir and materialize `Meeting` rows, reusing cached rows whose on-disk signature is unchanged since the last scan. Instance method (not static) because it reads and updates `scanCache`. Runs on `scanQueue`; also the entry point unit tests drive directly.
    func performScan(directory: URL) -> [Meeting] {
        let fm = FileManager.default
        let keys: [URLResourceKey] = [.contentModificationDateKey, .fileSizeKey]
        guard let entries = try? fm.contentsOfDirectory(
            at: directory,
            includingPropertiesForKeys: keys,
            options: [.skipsHiddenFiles]
        ) else {
            scanCache.removeAll()
            return []
        }

        // Group files by stem (substring before the first '.'). One O(N) pass.
        var byStem: [String: [URL]] = [:]
        for url in entries {
            let stem = MeetingStore.stem(of: url)
            if stem.isEmpty { continue }
            byStem[stem, default: []].append(url)
        }

        var out: [Meeting] = []
        out.reserveCapacity(byStem.count)
        var nextCache: [String: CacheEntry] = [:]
        for (stem, files) in byStem {
            let signature = MeetingStore.signature(of: files)
            // The cache holds only terminal rows, so a signature match is always safe to reuse and skips the per-sidecar JSON parse (the audit's perf finding).
            if let cached = scanCache[stem], cached.signature == signature {
                out.append(cached.meeting)
                nextCache[stem] = cached
                continue
            }
            guard let built = MeetingStore.buildMeeting(stem: stem, files: files, directory: directory) else {
                continue
            }
            out.append(built.meeting)
            if built.cacheable {
                nextCache[stem] = CacheEntry(signature: signature, meeting: built.meeting)
            }
        }
        // Replacing wholesale prunes cache entries for stems whose files were deleted.
        scanCache = nextCache

        // Overlay the "Summary edited locally" flag (UX15). Corrections live
        // outside the recordings dir, so this rides on top of the file-mtime
        // cache rather than inside the per-stem signature: it re-applies every
        // scan against a mtime-cached stem set.
        let edited = editedStemsOverlay()
        if !edited.isEmpty {
            for i in out.indices where edited.contains(out[i].stem) {
                out[i].hasCorrections = true
            }
        }

        // Newest first; equal starts fall back to stem for stable ordering.
        out.sort { lhs, rhs in
            if lhs.startedAt != rhs.startedAt { return lhs.startedAt > rhs.startedAt }
            return lhs.stem > rhs.stem
        }
        return out
    }

    /// Stems the "Summary edited locally" marker applies to (UX15), cached by the
    /// corrections-dir mtime so a scan storm during recording does not re-read the
    /// records. Runs on `scanQueue` (serial), so touching `editedStemsCache` needs
    /// no lock.
    private func editedStemsOverlay() -> Set<String> {
        guard let dir = try? CorrectionStore.directory() else { return [] }
        let mtime = MeetingStore.mtime(of: dir)
        if let cached = editedStemsCache, cached.mtime == mtime {
            return cached.stems
        }
        let stems = CorrectionStore.editedStems(directoryOverride: dir)
        editedStemsCache = (mtime: mtime, stems: stems)
        return stems
    }

    /// Signature of a stem's on-disk files: filename -> content-modification date. The directory enumeration prefetched `.contentModificationDateKey`, so reading it here is cache-cheap (no extra stat syscall). Any added/removed file or any mtime bump (a title edit, a correction, a summary landing) changes the signature and forces a re-parse for that stem.
    private static func signature(of files: [URL]) -> [String: Date] {
        var sig: [String: Date] = [:]
        for url in files {
            let mtime = (try? url.resourceValues(forKeys: [.contentModificationDateKey]))?
                .contentModificationDate ?? .distantPast
            sig[url.lastPathComponent] = mtime
        }
        return sig
    }

    /// Build a single `Meeting` from its on-disk file group. `cacheable` is true only for terminal rows (summary present, error sidecar present, or paste-ready). A `.processing` / age-inferred `.failed` row derives its status from the wall clock, so it is never cached: it must be rebuilt each scan to catch the staleness transition.
    /// How recently a `.mic.wav` must have been written to count as a live
    /// capture rather than a dead orphan. A recording writes the mic file every
    /// audio buffer, so a live capture's mtime is sub-second fresh; an orphan
    /// from a failed start is minutes+ stale. Generous vs the per-buffer cadence.
    static let liveCaptureFreshnessSec: TimeInterval = 60

    /// Extensions a final recording can carry, in resolution order. `wav` is what
    /// the recorder writes; `flac` is what STOR1's `compress` retention policy
    /// leaves behind. Lossless both ways, and both decode through `AVAudioFile`
    /// (playback, waveform) and `soundfile` (the pipeline's channel reads), so a
    /// compressed meeting stays fully reprocessable.
    static let finalRecordingExtensions = ["wav", "flac"]

    /// The final merged recording (`<stem>.wav` or `<stem>.flac`), excluding the
    /// `.mic.wav` / `.system.wav` capture intermediates that also carry the `wav`
    /// extension.
    static func isFinalRecording(_ url: URL) -> Bool {
        let name = url.lastPathComponent
        return finalRecordingExtensions.contains(url.pathExtension)
            && !name.hasSuffix(".mic.wav")
            && !name.hasSuffix(".system.wav")
    }

    /// Resolve a stem's final recording on disk, whichever extension it carries.
    /// Nil when the audio was never written or a `drop` policy reclaimed it. The
    /// one place that reconstructs a recording path from a stem, so a new codec
    /// lands in `finalRecordingExtensions` and nowhere else.
    static func finalRecordingURL(stem: String, in directory: URL) -> URL? {
        let fm = FileManager.default
        for ext in finalRecordingExtensions {
            let url = directory.appendingPathComponent("\(stem).\(ext)")
            if fm.fileExists(atPath: url.path) { return url }
        }
        return nil
    }

    /// Best-effort one-time tightening of the library's text artifacts to 0600 (SEC14).
    /// New transcript writes are already 0600 (`TranscriptSidecar.write`) and the pipeline
    /// chmods its summaries, so this only self-heals files that predate those changes
    /// (transcripts and summaries were created 0644, unlike `originals/` and the logs).
    /// Call once at startup; runs off-main since the library can hold many files.
    static func tightenArtifactPermissions(in directory: URL) {
        guard let items = try? FileManager.default.contentsOfDirectory(
            at: directory, includingPropertiesForKeys: nil
        ) else { return }
        for url in items where url.pathExtension == "json" || url.pathExtension == "md" {
            try? FileManager.default.setAttributes(
                [.posixPermissions: 0o600], ofItemAtPath: url.path
            )
        }
    }

    /// A recording-shaped path for callers that only derive *sibling sidecar*
    /// paths from it (`<stem>.embeddings.json`, `<stem>.meta.json`) and never open
    /// the file: `mp roster enroll --wav` and `PipelineLauncher.appleContext`. Uses
    /// the real recording when one exists, and the conventional `.wav` path when
    /// retention reclaimed it, since only the stem and the directory are read.
    static func sidecarAnchorURL(stem: String, in directory: URL) -> URL {
        finalRecordingURL(stem: stem, in: directory)
            ?? directory.appendingPathComponent("\(stem).wav")
    }

    /// A `.mic.wav` capture intermediate modified within `liveCaptureFreshnessSec`,
    /// i.e. one an in-progress recording is actively writing. Returns nil for a
    /// stale intermediate so an orphaned/failed capture is not surfaced as a row.
    static func freshCaptureIntermediate(in files: [URL]) -> URL? {
        guard let mic = files.first(where: { $0.lastPathComponent.hasSuffix(".mic.wav") }),
              let mtime = try? mic.resourceValues(forKeys: [.contentModificationDateKey])
                  .contentModificationDate,
              Date().timeIntervalSince(mtime) < liveCaptureFreshnessSec
        else { return nil }
        return mic
    }

    private static func buildMeeting(
        stem: String,
        files: [URL],
        directory: URL
    ) -> (meeting: Meeting, cacheable: Bool)? {
        // The merged recording is `<stem>.wav` (or `<stem>.flac` once STOR1's
        // `compress` policy has run). The `.mic.wav` / `.system.wav` capture
        // intermediates also end in `.wav`, but exist only mid-recording (merged
        // then deleted at stop) or as orphans an interrupted / failed start left
        // behind. Prefer the final recording; fall back to a *fresh* intermediate
        // so a live recording still shows a row, but never to a stale one.
        // Otherwise a dead orphan (e.g. the burst a mid-meeting input device
        // change can trigger) surfaces as a phantom `.processing` row that
        // animates a spinner and re-evaluates every scan, burning CPU and janking
        // the list (TECH-A17).
        let audio: URL? = files.first(where: { MeetingStore.isFinalRecording($0) })
            ?? MeetingStore.freshCaptureIntermediate(in: files)
        guard let startedAt = MeetingStore.parseStem(stem) else { return nil }

        let metaURL = files.first { $0.lastPathComponent.hasSuffix(".meta.json") }
        let runURL = files.first { $0.lastPathComponent.hasSuffix(".run.json") }
        let summaryURL = files.first { $0.lastPathComponent.hasSuffix(".summary.json") }
        let pasteReadyURL = files.first { $0.lastPathComponent.hasSuffix(".READY_FOR_MANUAL.md") }
        let emptyURL = files.first { $0.lastPathComponent.hasSuffix(".empty.json") }
        let errorURL = files.first {
            $0.lastPathComponent.hasSuffix(PipelineFailureSidecar.suffix)
        }
        let transcriptJSON = files.first { url in
            let lc = url.lastPathComponent
            return lc.hasSuffix(".json")
                && !lc.hasSuffix(".meta.json")
                && !lc.hasSuffix(".run.json")
                && !lc.hasSuffix(".empty.json")
                && !lc.hasSuffix(".summary.json")
                && !lc.hasSuffix(".summary.candidate.json")   // TECH-A16 preview sidecar
                && !lc.hasSuffix(".notion.json")
                && !lc.hasSuffix(".publish.json")             // PIPE1 run-scoped publish result
                && !lc.hasSuffix(PipelineFailureSidecar.suffix)
        }

        let meta = metaURL.flatMap { readJSON(at: $0) }
        let run = runURL.flatMap { readJSON(at: $0) }
        let summary: MeetingSummary? = summaryURL.flatMap { MeetingSummary.load(from: $0) }
        // A present summary supersedes the failure sidecar: the meeting was produced, so the error is stale.
        let failure: PipelineFailureSidecar.Failure?
        if summaryURL == nil, let errorURL = errorURL {
            failure = PipelineFailureSidecar.read(at: errorURL)
        } else {
            failure = nil
        }

        // Duration is the recording's last-write minus the stem's start time. When
        // a `drop` policy reclaimed the audio there is nothing to stat, so fall
        // back to the transcript sidecar's `audio_seconds`, which the transcriber
        // recorded from the file that no longer exists. Only read on that rare
        // path: parsing a full transcript to recover one number is not worth it
        // for the common case, and the result is cached with the `.done` row.
        let duration: TimeInterval?
        if let audio = audio {
            let mtime = (try? audio.resourceValues(forKeys: [.contentModificationDateKey])
                .contentModificationDate)
            duration = mtime.flatMap { $0 > startedAt ? $0.timeIntervalSince(startedAt) : nil }
        } else {
            duration = transcriptJSON
                .flatMap { readJSON(at: $0) }
                .flatMap { $0["audio_seconds"] as? Double }
        }

        let status: Meeting.Status
        let cacheable: Bool
        if summaryURL != nil {
            status = .done
            cacheable = true
        } else if failure != nil {
            status = .failed
            cacheable = true
        } else if pasteReadyURL != nil {
            status = .manualPasteReady
            cacheable = true
        } else if emptyURL != nil {
            // Pipeline finished but found no speech to summarize: a terminal,
            // cacheable state, not an in-flight `.processing` that would age into
            // a misleading `.failed`.
            status = .empty
            cacheable = true
        } else {
            // No summary, no failure sidecar: in-flight, never started, or stalled. Use age as a proxy; anything older than the staleness window is `.failed`. The live-recording overlay supersedes this via `LibraryWindowModel.liveRecordingStem`. Age-derived, so not cacheable.
            let age = Date().timeIntervalSince(startedAt)
            if age > Meeting.staleProcessingThresholdSec {
                status = .failed
            } else {
                status = .processing
            }
            cacheable = false
        }

        // A stem with neither audio nor a terminal sidecar is a dead orphan, not a
        // meeting: no row (TECH-A17). A terminal row whose audio a `drop` policy
        // reclaimed still has a transcript and a summary worth showing, so it
        // survives the guard the old "no wav at all = no row" rule would have
        // failed it on.
        let hasTerminalSidecar = summaryURL != nil
            || errorURL != nil
            || pasteReadyURL != nil
            || emptyURL != nil
        guard audio != nil || hasTerminalSidecar else { return nil }

        // The marker's reason distinguishes "No speech" from a degenerate
        // transcript so the row reads honestly (PIPE3). Read only for `.empty`
        // rows; an unreadable / pre-reason marker falls back to `.noSpeech`.
        let emptyReason: EmptyReason? = (status == .empty)
            ? (emptyURL.flatMap { EmptyMarker.read(at: $0) } ?? .noSpeech)
            : nil

        let sourceKindRaw = meta?["source_kind"] as? String
        let kind: AppSourceKind?
        switch sourceKindRaw {
        case "browser": kind = .browser
        case "native":  kind = .native
        default:        kind = nil
        }

        let searchable = MeetingStore.buildSearchableText(
            meetingTitle: meta?["meeting_title"] as? String,
            sourceDisplayName: meta?["source_display_name"] as? String,
            summary: summary
        )
        let meeting = Meeting(
            stem: stem,
            startedAt: startedAt,
            audioURL: audio,
            recordingsDir: directory,
            summaryTitle: (summary?.title).flatMap { $0.isEmpty ? nil : $0 },
            meetingTitle: (meta?["meeting_title"] as? String),
            sourceBundleID: (meta?["source_bundle_id"] as? String),
            sourceDisplayName: (meta?["source_display_name"] as? String),
            sourceKind: kind,
            workflowName: (meta?["workflow_name"] as? String),
            workflowColor: (meta?["workflow_color"] as? String),
            durationSec: duration,
            backend: (run?["backend"] as? String),
            modelId: (run?["model"] as? String),
            status: status,
            failureReason: failure?.reason,
            failureStage: failure?.stage.rawValue,
            searchableText: searchable,
            needsRepublish: MeetingStore.needsRepublish(files: files, summaryURL: summaryURL),
            detectedLanguage: (summary?.detectedLanguage).flatMap { $0.isEmpty ? nil : $0 },
            workflowNDAMode: (meta?["workflow_nda_mode"] as? Bool),
            regulatedMode: (meta?["regulated_mode"] as? Bool),
            micDeviceName: (meta?["mic_device_name"] as? String),
            micWarning: (meta?["mic_silent"] as? Bool) ?? false,
            publishState: (run?["publish_state"] as? String),
            emptyReason: emptyReason,
            hasSummaryJSON: summaryURL != nil,
            hasTranscriptMD: files.contains { $0.lastPathComponent == "\(stem).md" }
        )
        return (meeting, cacheable)
    }

    /// Content-modification date for a file, `.distantPast` when unreadable. The
    /// directory enumeration prefetched `.contentModificationDateKey`, so this
    /// is cache-cheap.
    private static func mtime(of url: URL) -> Date {
        (try? url.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate) ?? .distantPast
    }

    /// True when a publish sidecar exists and the summary is newer than the
    /// newest of them, i.e. the meeting changed since its last publish
    /// (TECH-UX2). A never-published meeting returns false: Republish is for
    /// re-syncing edits, not first publish.
    private static func needsRepublish(files: [URL], summaryURL: URL?) -> Bool {
        guard let summaryURL = summaryURL else { return false }
        let publishURLs = files.filter {
            let lc = $0.lastPathComponent
            return lc.hasSuffix(".notion.json") || lc.hasSuffix(".obsidian.json")
        }
        guard !publishURLs.isEmpty else { return false }
        let latestPublish = publishURLs.map { mtime(of: $0) }.max() ?? .distantPast
        return mtime(of: summaryURL) > latestPublish
    }

    /// Build the lowercased filter haystack from user-visible fields (titles, source app, summary bullets, decisions, action tasks). Internal so tests can drive it directly.
    static func buildSearchableText(
        meetingTitle: String?,
        sourceDisplayName: String?,
        summary: MeetingSummary?
    ) -> String {
        var parts: [String] = []
        if let s = summary?.title, !s.isEmpty { parts.append(s) }
        if let s = meetingTitle, !s.isEmpty { parts.append(s) }
        if let s = sourceDisplayName, !s.isEmpty { parts.append(s) }
        if let s = summary {
            parts.append(contentsOf: s.summary.filter { !$0.isEmpty })
            parts.append(contentsOf: s.decisions.filter { !$0.isEmpty })
            parts.append(contentsOf: s.questions.filter { !$0.isEmpty })
            parts.append(contentsOf: s.actions.map { $0.task }.filter { !$0.isEmpty })
        }
        return parts.joined(separator: " \n ").lowercased()
    }

    static func stem(of url: URL) -> String {
        let name = url.lastPathComponent
        if let dot = name.firstIndex(of: ".") {
            return String(name[..<dot])
        }
        return name
    }

    /// Parse "YYYYMMDD-HHmmss" → local Date. The length guard is required: newer SDKs return an epoch-anchored Date for short inputs rather than failing, and real stems are exactly 15 chars.
    static func parseStem(_ stem: String) -> Date? {
        guard stem.count == 15 else { return nil }
        return MeetingFormatters.stem.date(from: stem)
    }

    /// Stems the menu-bar failed badge should count. Two classes, matching
    /// `buildMeeting`'s `.failed` precedence so the badge and the Library list
    /// agree (PIPE3 / AUD-16b, which flagged that age-inferred stalls were
    /// excluded from the badge):
    ///   1. an explicit `<stem>.error.json` failure with no superseding summary, and
    ///   2. an age-inferred stall: a final recording with no terminal sidecar whose
    ///      stem start time is older than `Meeting.staleProcessingThresholdSec`.
    /// Filename-only (plus the stem's encoded start time) so it stays cheap enough
    /// to run on every menu open and is unit-testable. `now` is injected for tests.
    static func unrecoveredFailureStems(fileNames: [String], now: Date = Date()) -> [String] {
        struct Flags {
            var summary = false
            var error = false
            var paste = false
            var empty = false
            var finalRecording = false
        }
        var byStem: [String: Flags] = [:]
        for name in fileNames {
            guard let dot = name.firstIndex(of: ".") else { continue }
            let stem = String(name[..<dot])
            if stem.isEmpty { continue }
            var f = byStem[stem] ?? Flags()
            if name.hasSuffix(".summary.json") {
                f.summary = true
            } else if name.hasSuffix(PipelineFailureSidecar.suffix) {
                f.error = true
            } else if name.hasSuffix(".READY_FOR_MANUAL.md") {
                f.paste = true
            } else if name.hasSuffix(EmptyMarker.suffix) {
                f.empty = true
            }
            if finalRecordingExtensions.contains(where: { name.hasSuffix(".\($0)") }),
               !name.hasSuffix(".mic.wav"), !name.hasSuffix(".system.wav") {
                f.finalRecording = true
            }
            byStem[stem] = f
        }
        var failed: [String] = []
        for (stem, f) in byStem {
            if f.summary { continue }                     // produced: supersedes a stale error
            if f.error { failed.append(stem); continue }  // explicit failure sidecar
            if f.paste || f.empty { continue }            // terminal benign skip
            // Age-inferred stall: a merged recording whose pipeline wrote no
            // terminal sidecar and is past the staleness window. Mirrors
            // `buildMeeting`'s age-inferred `.failed` via the same constant.
            guard f.finalRecording, let started = parseStem(stem),
                  now.timeIntervalSince(started) > Meeting.staleProcessingThresholdSec else {
                continue
            }
            failed.append(stem)
        }
        return failed.sorted()
    }

    private static func readJSON(at url: URL) -> [String: Any]? {
        guard let data = try? Data(contentsOf: url) else { return nil }
        return (try? JSONSerialization.jsonObject(with: data)) as? [String: Any]
    }
}

/// Shared DateFormatter instances. Construction is expensive; one-time init here avoids paying it per row.
enum MeetingFormatters {
    static let stem: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "yyyyMMdd-HHmmss"
        f.locale = Locale(identifier: "en_US_POSIX")
        f.timeZone = TimeZone.current
        return f
    }()

    static let shortTime: DateFormatter = {
        let f = DateFormatter()
        f.dateStyle = .none
        f.timeStyle = .short
        return f
    }()

    static let weekday: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "EEEE"
        return f
    }()

    static let monthYear: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "MMMM yyyy"
        return f
    }()

    /// "Mon May 12, 2:31 PM" - detail header primary date stamp.
    static let fullDateTime: DateFormatter = {
        let f = DateFormatter()
        f.dateStyle = .medium
        f.timeStyle = .short
        return f
    }()

    /// "Mon" / "Tue" - row trailing day stack for meetings 2-7 days old.
    static let shortWeekday: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "EEE"
        return f
    }()
}
