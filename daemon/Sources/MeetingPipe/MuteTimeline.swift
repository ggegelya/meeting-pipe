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

    /// One muted span, in seconds from recording start. `Codable` because it is
    /// the on-disk contract the redactor reads (`MuteTimelineFile`).
    struct Span: Equatable, Codable {
        var startSec: Double
        var endSec: Double

        enum CodingKeys: String, CodingKey {
            case startSec = "start_sec"
            case endSec = "end_sec"
        }
    }

    private(set) var spans: [Span] = []
    private var openStart: Double?
    private var openEnd: Double?

    /// Record that the half-open range `[startSec, endSec)` carried `muted`.
    /// Contiguous muted buffers coalesce into one span; an unmuted buffer closes
    /// the open span. Buffers arrive in order with no gaps (the frame clock is
    /// contiguous), so `endSec` of one equals `startSec` of the next.
    mutating func add(startSec: Double, endSec: Double, muted: Bool) {
        guard endSec > startSec else { return }
        if muted {
            if openStart == nil { openStart = startSec }
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
            spans.append(Span(startSec: start, endSec: end))
        }
        openStart = nil
        openEnd = nil
    }
}

/// On-disk `<stem>.mute-timeline.json`: the muted spans recorded under
/// capture-first mode (TECH-MIC4), read by the offline redactor (TECH-MIC5).
/// Daemon-internal (the daemon both writes and reads it); not part of the
/// Swift-to-Python sidecar contract, because redaction runs before any consumer.
struct MuteTimelineFile: Codable {
    var version: Int = 1
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
            try data.write(to: url(forFinal: final))
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
