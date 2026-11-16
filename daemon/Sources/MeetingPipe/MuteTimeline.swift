import Foundation

/// The spans of a recording where the mic was reported muted (the gate verdict
/// indicated an app or hardware mute), as `[start, end)` second ranges relative
/// to recording start. Under capture-first mode the mic is recorded losslessly
/// and these spans are redacted from the consumed artifact offline (TECH-MIC4
/// records them, TECH-MIC5 applies them).
///
/// Only genuine mute spans are recorded, never `silentByRMS` (quiet) or
/// `uncertain`, so redaction can never drop real-but-quiet speech. Pure value
/// type: the recorder feeds it buffer ranges on the render thread; nothing here
/// touches AVFoundation.
struct MuteTimeline: Equatable {

    /// What produced a span. `mute` is the app/hardware-mute oracle (the auto path); `manual` is
    /// an explicit off-the-record toggle (MIC14). The distinction is load-bearing in the redactor:
    /// a `manual` span is explicit intent, so it is always redacted, exempt from the MIC12
    /// speech-bearing withhold that protects against a wrong auto oracle.
    enum SpanSource: String, Codable, Equatable {
        case mute
        case manual
    }

    /// One muted span, in seconds from recording start. `Codable` because it is
    /// the on-disk contract the redactor reads (`MuteTimelineFile`).
    struct Span: Equatable, Codable {
        var startSec: Double
        var endSec: Double
        var source: SpanSource = .mute

        enum CodingKeys: String, CodingKey {
            case startSec = "start_sec"
            case endSec = "end_sec"
            case source
        }

        init(startSec: Double, endSec: Double, source: SpanSource = .mute) {
            self.startSec = startSec
            self.endSec = endSec
            self.source = source
        }

        init(from decoder: Decoder) throws {
            let c = try decoder.container(keyedBy: CodingKeys.self)
            startSec = try c.decode(Double.self, forKey: .startSec)
            endSec = try c.decode(Double.self, forKey: .endSec)
            // Version-1 files predate the source field; those spans are all auto mutes.
            source = try c.decodeIfPresent(SpanSource.self, forKey: .source) ?? .mute
        }
    }

    private(set) var spans: [Span] = []
    private var openStart: Double?
    private var openEnd: Double?
    private var openSource: SpanSource = .mute

    /// True once at least one manual off-the-record span has been recorded (MIC14). Drives the
    /// capture-first timeline write (a manual span is redacted even in default capture-first).
    var hasManualSpan: Bool { spans.contains { $0.source == .manual } || openSource == .manual && openStart != nil }

    /// Record that the half-open range `[startSec, endSec)` carried `muted`, tagged `source`.
    /// Contiguous muted buffers of the SAME source coalesce into one span; a source change (manual
    /// vs auto) closes the open span first so the two never merge; an unmuted buffer closes it.
    /// Buffers arrive in order with no gaps (the frame clock is contiguous), so `endSec` of one
    /// equals `startSec` of the next.
    mutating func add(startSec: Double, endSec: Double, muted: Bool, source: SpanSource = .mute) {
        guard endSec > startSec else { return }
        if muted {
            if openStart != nil && openSource != source { closeOpenSpan() }
            if openStart == nil { openStart = startSec; openSource = source }
            openEnd = endSec
        } else {
            closeOpenSpan()
        }
    }

    /// Close any span still open when the recording stopped.
    mutating func finalize() {
        closeOpenSpan()
    }

    private mutating func closeOpenSpan() {
        if let start = openStart, let end = openEnd, end > start {
            spans.append(Span(startSec: start, endSec: end, source: openSource))
        }
        openStart = nil
        openEnd = nil
        openSource = .mute
    }
}

/// The one rule for which spans a recording persists, and the write that follows it (REC34).
/// `MeetingRecorder` calls it from both exits that can still read the timeline safely: the stop
/// path (after the merge, whether or not the merge produced a final) and the termination flush
/// (after a clean engine teardown). Before REC34 only a stop whose merge produced a final wrote
/// it, so a quit or a failed merge left an off-the-record recording with no timeline and orphan
/// recovery quarantined it instead of redacting it. The file is keyed by stem, so the final need
/// not exist yet.
enum MuteTimelinePersistence {
    /// Which exit wrote it: the `path` attribute on `mute_timeline_written`,
    /// `mute_timeline_write_failed` and `mute_timeline_write_skipped`.
    enum Path: String {
        case stop
        case termination
    }

    enum Result: Equatable {
        /// The mode keeps nothing: the regulated gate cut at capture, or default capture-first
        /// with no off-the-record span.
        case nothingToWrite
        case written
        /// The write failed. The caller keeps the start markers, so the redactor and orphan
        /// recovery fail closed (SEC16).
        case failed
    }

    /// The spans `mode` persists from a finalized timeline, or nil when it persists none.
    /// `.captureFirstRedact` keeps every span; default `.captureFirst` keeps the full mic with no
    /// redaction (TECH-MIC9) except a manual off-record span, which is explicit intent (MIC14);
    /// `.regulatedGate` removed muted audio in real time.
    static func spans(for mode: CaptureMode, from timeline: MuteTimeline) -> [MuteTimeline.Span]? {
        switch mode {
        case .captureFirstRedact:
            return timeline.spans
        case .captureFirst:
            let manual = timeline.spans.filter { $0.source == .manual }
            return manual.isEmpty ? nil : manual
        case .regulatedGate:
            return nil
        }
    }

    /// Write what `mode` persists from `timeline` (already finalized) for `final`, and log it.
    static func persist(
        _ timeline: MuteTimeline, mode: CaptureMode, forFinal final: URL, path: Path
    ) -> Result {
        guard let spans = spans(for: mode, from: timeline) else { return .nothingToWrite }
        guard MuteTimelineFile.write(spans: spans, forFinal: final) else {
            Log.event(category: "recorder", action: "mute_timeline_write_failed", attributes: [
                "file": final.lastPathComponent,
                "path": path.rawValue,
            ])
            return .failed
        }
        var attributes: [String: Any] = ["file": final.lastPathComponent, "path": path.rawValue]
        if mode == .captureFirstRedact {
            attributes["muted_spans"] = spans.count
        } else {
            attributes["manual_spans"] = spans.count
            attributes["source"] = "manual"
        }
        Log.event(category: "recorder", action: "mute_timeline_written", attributes: attributes)
        return .written
    }
}

/// On-disk `<stem>.mute-timeline.json`: the muted spans recorded under
/// capture-first mode (TECH-MIC4), read by the offline redactor (TECH-MIC5).
/// Daemon-internal (the daemon both writes and reads it); not part of the
/// Swift-to-Python sidecar contract, because redaction runs before any consumer.
struct MuteTimelineFile: Codable {
    var version: Int = 2  // bumped by MIC14: `Span` gained a `source` field (mute | manual)
    var spans: [MuteTimeline.Span]

    /// Sidecar path for a final recording URL: `<stem>.mute-timeline.json` next
    /// to `<stem>.wav`. A metadata sibling, not audio, so it is safe to sit in
    /// the Library-scanned tree (unlike the kept full recording).
    static func url(forFinal final: URL) -> URL {
        let stem = final.deletingPathExtension().lastPathComponent
        return final.deletingLastPathComponent().appendingPathComponent("\(stem).mute-timeline.json")
    }

    /// Write the spans for `final`. Never blocks the recording from finishing, but
    /// answers whether it landed (SEC16): a failed write used to be a WARN line and
    /// nothing else, so the recording read as one with nothing to redact. The
    /// recorder now keeps its start-time markers when this returns false, which is
    /// what makes the redactor fail closed on the missing timeline.
    @discardableResult
    static func write(spans: [MuteTimeline.Span], forFinal final: URL) -> Bool {
        let file = MuteTimelineFile(spans: spans)
        do {
            let data = try JSONEncoder().encode(file)
            // Atomic: under MIC14 this file is privacy-load-bearing even in default capture-first
            // (it carries manual off-record spans), so a torn write must not leave a partial
            // timeline that redacts the wrong ranges.
            try data.write(to: url(forFinal: final), options: .atomic)
            return true
        } catch {
            Log.writeLine("recorder", "WARN: could not write mute timeline for \(final.lastPathComponent): \(error.localizedDescription)")
            return false
        }
    }

    /// What is on disk for a final's timeline. `unreadable` is kept apart from
    /// `missing` because the redactor must fail closed on it (SEC16): a corrupt
    /// file used to decode to nil and read as "nothing to redact".
    enum LoadResult {
        case missing
        case unreadable
        case loaded(MuteTimelineFile)
    }

    static func load(forFinal final: URL) -> LoadResult {
        let url = url(forFinal: final)
        guard FileManager.default.fileExists(atPath: url.path) else { return .missing }
        guard let data = try? Data(contentsOf: url),
              let file = try? JSONDecoder().decode(MuteTimelineFile.self, from: data) else {
            return .unreadable
        }
        return .loaded(file)
    }

    /// Read the spans for `final`, or nil when no readable timeline exists (a
    /// regulated recording, an orphan recovered without a stop, a pre-MIC4 file,
    /// or a corrupt one).
    static func read(forFinal final: URL) -> MuteTimelineFile? {
        if case .loaded(let file) = load(forFinal: final) { return file }
        return nil
    }
}

/// Start-time-persisted marker that a recording had at least one manual off-the-record span
/// (MIC14), written next to `<stem>.wav` the moment off-record is first toggled on and removed at
/// a clean stop. It closes the orphan-leak edge: under default capture-first the manual-only
/// timeline is written only at stop, so a crash before stop would leave the off-record audio in a
/// recording that orphan recovery auto-publishes. `OrphanRecordingRecovery.shouldQuarantine` reads
/// this so such a recording is quarantined instead, exactly as a redaction-opt-in orphan is.
enum OffRecordMarker {
    static func url(forFinal final: URL) -> URL {
        let stem = final.deletingPathExtension().lastPathComponent
        return final.deletingLastPathComponent().appendingPathComponent("\(stem).offrecord")
    }

    /// Throws since REC21: a failed write used to be silent, and with a failed timeline write
    /// at stop (or a crash) the recording read as one with nothing to cut.
    static func write(forFinal final: URL) throws {
        try Data().write(to: url(forFinal: final), options: .atomic)
    }

    static func exists(forFinal final: URL) -> Bool {
        FileManager.default.fileExists(atPath: url(forFinal: final).path)
    }

    static func remove(forFinal final: URL) {
        try? FileManager.default.removeItem(at: url(forFinal: final))
    }

    /// REC21: make sure a file beside `final` records that a cut is owed, before the in-memory or
    /// manifest copy of that fact is let go. True when `.offrecord` or a redact-owing
    /// `.capturemode` is already there, or `.offrecord` was written now (the redactor reads it as
    /// "owed" whatever the recording's mode, and `SinkDispatcher` removes it once the cut passes).
    /// False only when nothing on disk says so and the write failed: the caller then keeps the
    /// manifest, or refuses.
    static func persistOwed(forFinal final: URL) -> Bool {
        if exists(forFinal: final) || CaptureMode.readMarker(forFinal: final).owesRedaction { return true }
        do {
            try write(forFinal: final)
            return true
        } catch {
            StartMarkerWriteFailure.report(.offRecord, stem: final.deletingPathExtension().lastPathComponent, error: error)
            return false
        }
    }
}

/// The one report for a start-time redaction marker that did not land (REC21): `.capturemode`
/// at record start, `.offrecord` when a span opens under lossless capture. The recording goes
/// on either way (losing the meeting is worse); the session's `redactionOwed` and the manifest's
/// second copy are what keep it failing closed.
enum StartMarkerWriteFailure {
    enum Marker: String {
        case captureMode = "capturemode"
        case offRecord = "offrecord"
    }

    static func report(_ marker: Marker, stem: String, error: Error) {
        let ns = error as NSError
        Log.writeLine("recorder", "WARN: could not write the \(marker.rawValue) marker for \(stem) (\(ns.domain) \(ns.code)); recording continues, the redaction stays owed")
        Log.event(category: "recorder", action: "start_marker_write_failed", attributes: [
            "marker": marker.rawValue,
            "stem": stem,
            "error_domain": ns.domain,
            "error_code": ns.code,
        ])
    }
}
