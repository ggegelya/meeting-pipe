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

    /// Write the spans for `final`. Best-effort: a failed write degrades to "no
    /// redaction" (the kept full recording is still intact), it never blocks the
    /// recording from finishing.
    static func write(spans: [MuteTimeline.Span], forFinal final: URL) {
        let file = MuteTimelineFile(spans: spans)
        do {
            let data = try JSONEncoder().encode(file)
            // Atomic: under MIC14 this file is privacy-load-bearing even in default capture-first
            // (it carries manual off-record spans), so a torn write must not leave a partial
            // timeline that redacts the wrong ranges.
            try data.write(to: url(forFinal: final), options: .atomic)
        } catch {
            Log.writeLine("recorder", "WARN: could not write mute timeline for \(final.lastPathComponent): \(error.localizedDescription)")
        }
    }

    /// Read the spans for `final`, or nil when no timeline exists (a regulated
    /// recording, an orphan recovered without a stop, or a pre-MIC4 file).
    static func read(forFinal final: URL) -> MuteTimelineFile? {
        let url = url(forFinal: final)
        guard let data = try? Data(contentsOf: url) else { return nil }
        return try? JSONDecoder().decode(MuteTimelineFile.self, from: data)
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

    static func write(forFinal final: URL) {
        try? Data().write(to: url(forFinal: final), options: .atomic)
    }

    static func exists(forFinal final: URL) -> Bool {
        FileManager.default.fileExists(atPath: url(forFinal: final).path)
    }

    static func remove(forFinal final: URL) {
        try? FileManager.default.removeItem(at: url(forFinal: final))
    }
}
