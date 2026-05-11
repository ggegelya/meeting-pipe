import AppKit
import Combine
import Foundation

/// One row in the Library list. Materialized from the on-disk sidecars
/// that the pipeline writes next to the `<stem>.wav`. Held in memory by
/// `MeetingStore`; cheap to copy by value because every field is small.
struct Meeting: Identifiable, Hashable {

    /// Coarse lifecycle state derived from which sidecars exist on disk.
    /// We don't have a single per-meeting status file (yet), so this is
    /// inferred from presence/absence of `<stem>.summary.json`,
    /// `<stem>.READY_FOR_MANUAL.md`, etc.
    enum Status: String, Hashable {
        case recording            // currently being written (live)
        case processing           // wav present, no summary yet
        case manualPasteReady     // long-meeting bundle waiting on user paste
        case done                 // summary.json on disk
        case unknown
    }

    let stem: String
    let startedAt: Date
    let wavURL: URL
    let recordingsDir: URL

    let summaryTitle: String?     // from <stem>.summary.json["title"]
    let meetingTitle: String?     // from <stem>.meta.json["meeting_title"]

    let sourceBundleID: String?
    let sourceDisplayName: String?
    let sourceKind: AppSourceKind?

    /// Filled when TECH-B starts writing `workflow_name` into the meta
    /// sidecar. Hidden in the row until non-nil so the chip never shows
    /// a placeholder.
    let workflowName: String?
    let workflowColor: String?

    let durationSec: TimeInterval?
    let backend: String?
    let modelId: String?

    let status: Status

    /// Stable identity. Stems are unique per recording (datetime-derived).
    var id: String { stem }

    /// Best-effort human-readable label for the row's primary line.
    /// Summary title > meta-derived meeting title > "{source} at HH:mm"
    /// > raw stem. Never empty.
    var displayTitle: String {
        if let t = summaryTitle, !t.isEmpty { return t }
        if let t = meetingTitle, !t.isEmpty { return t }
        let time = MeetingFormatters.shortTime.string(from: startedAt)
        if let src = sourceDisplayName, !src.isEmpty {
            return "\(src) at \(time)"
        }
        return stem
    }

    /// Returns a synthesized `AppSource` so `AppGlyphView` can pick a
    /// glyph. Returns nil for meetings recorded without a detected
    /// source (e.g. manual `⌃⌥M` recordings).
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

/// Lazily-built directory cache + filesystem watcher backing the Library
/// list view. One instance per recordings directory; held by the
/// `LibraryWindowModel`.
///
/// Threading: rescans run on a private serial queue; published mutations
/// are dispatched back to the main queue. The dispatch source watching
/// the directory coalesces a burst of writes into a single rescan via
/// a 500 ms debounce.
final class MeetingStore: ObservableObject {

    @Published private(set) var meetings: [Meeting] = []
    /// True for the initial scan. Subsequent rescans don't flip this so
    /// the list doesn't flash to "loading" each time a file lands.
    @Published private(set) var hasLoadedOnce: Bool = false

    private let recordingsDir: URL
    private let scanQueue = DispatchQueue(
        label: "com.meetingpipe.MeetingStore.scan",
        qos: .userInitiated
    )
    private var watcher: DispatchSourceFileSystemObject?
    private var watcherFD: CInt = -1

    /// At most one rescan in flight; further refresh() calls fold into
    /// a single follow-up scan so a burst of writes (Coordinator drops
    /// .wav / .json / .summary.json in quick succession) doesn't fan
    /// out into N+1 scans.
    private var scanRunning = false
    private var pendingRescan = false

    /// Debounce window for filesystem events. Half a second balances the
    /// acceptance criterion (1 s new-meeting visibility) against bursty
    /// pipeline writes that all land within a couple-of-second window.
    private static let debounceSec: TimeInterval = 0.5
    private var debounceWork: DispatchWorkItem?

    init(recordingsDir: URL) {
        self.recordingsDir = recordingsDir
    }

    deinit {
        detachWatcher()
    }

    /// Begin watching the recordings directory and trigger an initial
    /// scan. Idempotent.
    func start() {
        attachWatcher()
        refresh()
    }

    /// Force a rescan now. Used by manual refresh actions; the filesystem
    /// watcher calls this internally via the debounce path.
    func refresh() {
        if scanRunning {
            pendingRescan = true
            return
        }
        scanRunning = true
        let dir = recordingsDir
        scanQueue.async { [weak self] in
            let result = MeetingStore.scan(directory: dir)
            DispatchQueue.main.async {
                guard let self = self else { return }
                self.meetings = result
                if !self.hasLoadedOnce { self.hasLoadedOnce = true }
                self.scanRunning = false
                if self.pendingRescan {
                    self.pendingRescan = false
                    self.refresh()
                }
            }
        }
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

    private static func scan(directory: URL) -> [Meeting] {
        let fm = FileManager.default
        let keys: [URLResourceKey] = [.contentModificationDateKey, .fileSizeKey]
        guard let entries = try? fm.contentsOfDirectory(
            at: directory,
            includingPropertiesForKeys: keys,
            options: [.skipsHiddenFiles]
        ) else {
            return []
        }

        // Group every file under its meeting stem (the substring before
        // the first '.'). One pass — O(N) over the directory.
        var byStem: [String: [URL]] = [:]
        for url in entries {
            let stem = MeetingStore.stem(of: url)
            if stem.isEmpty { continue }
            byStem[stem, default: []].append(url)
        }

        var out: [Meeting] = []
        out.reserveCapacity(byStem.count)
        for (stem, files) in byStem {
            // A row only exists when the wav exists. Without it there's
            // no "meeting" to surface — leftover sidecars from manual
            // deletes shouldn't populate the list.
            guard let wav = files.first(where: { $0.pathExtension == "wav" }) else {
                continue
            }
            guard let startedAt = MeetingStore.parseStem(stem) else { continue }

            let metaURL = files.first { $0.lastPathComponent.hasSuffix(".meta.json") }
            let runURL = files.first { $0.lastPathComponent.hasSuffix(".run.json") }
            let summaryURL = files.first { $0.lastPathComponent.hasSuffix(".summary.json") }
            let pasteReadyURL = files.first { $0.lastPathComponent.hasSuffix(".READY_FOR_MANUAL.md") }
            let transcriptJSON = files.first { url in
                let lc = url.lastPathComponent
                return lc.hasSuffix(".json")
                    && !lc.hasSuffix(".meta.json")
                    && !lc.hasSuffix(".run.json")
                    && !lc.hasSuffix(".summary.json")
                    && !lc.hasSuffix(".notion.json")
            }

            let meta = metaURL.flatMap { readJSON(at: $0) }
            let run = runURL.flatMap { readJSON(at: $0) }
            let summary = summaryURL.flatMap { readJSON(at: $0) }

            let wavMtime = (try? wav.resourceValues(forKeys: [.contentModificationDateKey])
                .contentModificationDate)
            let duration: TimeInterval?
            if let m = wavMtime, m > startedAt {
                duration = m.timeIntervalSince(startedAt)
            } else {
                duration = nil
            }

            let status: Meeting.Status
            if summaryURL != nil {
                status = .done
            } else if pasteReadyURL != nil {
                status = .manualPasteReady
            } else if transcriptJSON != nil {
                status = .processing
            } else {
                // wav-only — could be in-flight transcription, or could be a
                // leftover from a failed run. We treat as processing here;
                // active-recording overlay is layered on top by the live
                // model in `LibraryWindowModel`.
                status = .processing
            }

            let sourceKindRaw = meta?["source_kind"] as? String
            let kind: AppSourceKind?
            switch sourceKindRaw {
            case "browser": kind = .browser
            case "native":  kind = .native
            default:        kind = nil
            }

            out.append(Meeting(
                stem: stem,
                startedAt: startedAt,
                wavURL: wav,
                recordingsDir: directory,
                summaryTitle: (summary?["title"] as? String),
                meetingTitle: (meta?["meeting_title"] as? String),
                sourceBundleID: (meta?["source_bundle_id"] as? String),
                sourceDisplayName: (meta?["source_display_name"] as? String),
                sourceKind: kind,
                workflowName: (meta?["workflow_name"] as? String),
                workflowColor: (meta?["workflow_color"] as? String),
                durationSec: duration,
                backend: (run?["backend"] as? String),
                modelId: (run?["model"] as? String),
                status: status
            ))
        }
        // Newest first. Equal starts (rare) fall back to stem so order is
        // stable across rescans.
        out.sort { lhs, rhs in
            if lhs.startedAt != rhs.startedAt { return lhs.startedAt > rhs.startedAt }
            return lhs.stem > rhs.stem
        }
        return out
    }

    static func stem(of url: URL) -> String {
        let name = url.lastPathComponent
        if let dot = name.firstIndex(of: ".") {
            return String(name[..<dot])
        }
        return name
    }

    /// Parse "YYYYMMDD-HHmmss" → Date in the user's local time. Returns
    /// nil for stems that don't match the expected pattern (the daemon
    /// only emits this form, so a miss means the file is unrelated).
    static func parseStem(_ stem: String) -> Date? {
        return MeetingFormatters.stem.date(from: stem)
    }

    private static func readJSON(at url: URL) -> [String: Any]? {
        guard let data = try? Data(contentsOf: url) else { return nil }
        return (try? JSONSerialization.jsonObject(with: data)) as? [String: Any]
    }
}

/// Shared formatters held in one place so list rendering doesn't pay
/// the DateFormatter construction tax per row. Read-only, thread-safe.
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

    /// "Mon May 12, 2:31 PM" - the detail header's primary date stamp.
    static let fullDateTime: DateFormatter = {
        let f = DateFormatter()
        f.dateStyle = .medium
        f.timeStyle = .short
        return f
    }()
}
