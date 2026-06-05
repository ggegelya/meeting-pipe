import AppKit
import Combine
import Foundation

/// One row in the Library list, materialized from on-disk sidecars alongside `<stem>.wav`.
struct Meeting: Identifiable, Hashable {

    /// Coarse lifecycle state derived from which sidecars exist on disk. `.failed` uses a precise `<stem>.error.json` signal; other states infer from presence/absence of summary/paste-ready sidecars, with an age fallback when no sidecar was written.
    enum Status: String, Hashable {
        case recording            // currently being written (live)
        case processing           // wav present, no summary yet
        case manualPasteReady     // long-meeting bundle waiting on user paste
        case done                 // summary.json on disk
        case failed               // error sidecar present, or stalled past the age window
        case unknown
    }

    /// A meeting with no summary older than this is considered stalled (crash, restart, config error) and flips from `.processing` to `.failed`. Two hours is generous: even a 3-hour transcript + 32B-Qwen local summary finishes inside it.
    static let staleProcessingThresholdSec: TimeInterval = 2 * 60 * 60

    let stem: String
    let startedAt: Date
    let wavURL: URL
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

    /// Publish outcome from `<stem>.run.json["publish_state"]` (TECH-I6): "full"
    /// / "partial" / "none", nil for never-published rows. The pipeline writes it
    /// after fanout; drives the Library partial-publish badge. Defaulted so test
    /// constructors need not supply it.
    var publishState: String? = nil

    var id: String { stem } // stems are unique per recording (datetime-derived)

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

        // Newest first; equal starts fall back to stem for stable ordering.
        out.sort { lhs, rhs in
            if lhs.startedAt != rhs.startedAt { return lhs.startedAt > rhs.startedAt }
            return lhs.stem > rhs.stem
        }
        return out
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
    private static func buildMeeting(
        stem: String,
        files: [URL],
        directory: URL
    ) -> (meeting: Meeting, cacheable: Bool)? {
        // No wav = no meeting row; leftover sidecars from manual deletes shouldn't appear.
        guard let wav = files.first(where: { $0.pathExtension == "wav" }) else {
            return nil
        }
        guard let startedAt = MeetingStore.parseStem(stem) else { return nil }

        let metaURL = files.first { $0.lastPathComponent.hasSuffix(".meta.json") }
        let runURL = files.first { $0.lastPathComponent.hasSuffix(".run.json") }
        let summaryURL = files.first { $0.lastPathComponent.hasSuffix(".summary.json") }
        let pasteReadyURL = files.first { $0.lastPathComponent.hasSuffix(".READY_FOR_MANUAL.md") }
        let errorURL = files.first {
            $0.lastPathComponent.hasSuffix(PipelineFailureSidecar.suffix)
        }
        let transcriptJSON = files.first { url in
            let lc = url.lastPathComponent
            return lc.hasSuffix(".json")
                && !lc.hasSuffix(".meta.json")
                && !lc.hasSuffix(".run.json")
                && !lc.hasSuffix(".summary.json")
                && !lc.hasSuffix(".summary.candidate.json")   // TECH-A16 preview sidecar
                && !lc.hasSuffix(".notion.json")
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

        let wavMtime = (try? wav.resourceValues(forKeys: [.contentModificationDateKey])
            .contentModificationDate)
        let duration: TimeInterval?
        if let m = wavMtime, m > startedAt {
            duration = m.timeIntervalSince(startedAt)
        } else {
            duration = nil
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
        } else {
            // No summary, no failure sidecar: in-flight, never started, or stalled. Use age as a proxy; anything older than the staleness window is `.failed`. The live-recording overlay supersedes this via `LibraryWindowModel.liveRecordingStem`. Age-derived, so not cacheable.
            let age = Date().timeIntervalSince(startedAt)
            if age > Meeting.staleProcessingThresholdSec {
                status = .failed
            } else {
                status = .processing
            }
            cacheable = false
            _ = transcriptJSON  // currently informational only
        }

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
            wavURL: wav,
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
            publishState: (run?["publish_state"] as? String)
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

    /// Stems with a failure sidecar but no summary (unrecovered failures). Filename-only so the status-bar count stays cheap and unit-testable. Mirrors `scan`'s precedence: a present summary supersedes a stale failure sidecar.
    static func unrecoveredFailureStems(fileNames: [String]) -> [String] {
        var failed: Set<String> = []
        var summarised: Set<String> = []
        for name in fileNames {
            if name.hasSuffix(".summary.json") {
                summarised.insert(String(name.dropLast(".summary.json".count)))
            } else if name.hasSuffix(PipelineFailureSidecar.suffix) {
                failed.insert(String(name.dropLast(PipelineFailureSidecar.suffix.count)))
            }
        }
        return failed.subtracting(summarised).sorted()
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
