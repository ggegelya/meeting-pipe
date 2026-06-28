import Foundation

/// Why `mp run-all` finished without producing a summary, from the
/// `<stem>.empty.json` marker's `reason` field. The pipeline writes the marker
/// for the two genuinely-empty skips (LOCAL2); the daemon reads it to show a
/// terminal Library state and an honest completion notice instead of spinning in
/// `.processing` forever (PIPE3 / AUD-16a).
///
/// Single source of truth for the user-facing wording so the Library pill, the
/// detail pane, and the done-notification can't drift.
enum EmptyReason: String {
    case noSpeech = "no_speech"
    case suspectTranscript = "suspect_transcript"

    /// Tolerant parse: an absent or unrecognized reason falls back to
    /// `.noSpeech`, the original single-state behavior before this reason was
    /// distinguished, so a future pipeline-side reason never breaks the read.
    init(marker: String?) {
        self = marker.flatMap(EmptyReason.init(rawValue:)) ?? .noSpeech
    }

    /// Compact trailing-pill label (kept short for the row).
    var pillLabel: String {
        switch self {
        case .noSpeech:          return "No speech"
        case .suspectTranscript: return "Unclear audio"
        }
    }

    /// Longer explanation for the row's help tooltip and the detail pane.
    var detail: String {
        switch self {
        case .noSpeech:
            return "No speech was detected, so there is nothing to summarize."
        case .suspectTranscript:
            return "The transcript looked unreliable (no clear speech, repetition, or garbled audio), so it was not summarized."
        }
    }

    /// Completion-notification title (replaces the misleading "Meeting processed").
    var notificationTitle: String {
        switch self {
        case .noSpeech:          return "No speech detected"
        case .suspectTranscript: return "Transcript looked unreliable"
        }
    }

    /// Completion-notification body.
    var notificationBody: String {
        switch self {
        case .noSpeech:
            return "Nothing to summarize for this meeting."
        case .suspectTranscript:
            return "This meeting was not summarized. Open it in the Library to review."
        }
    }
}

/// Reader for `<stem>.empty.json`, the terminal marker `mp run-all` writes when
/// it finished but intentionally produced no summary. Mirrors
/// `PipelineFailureSidecar`: the pipeline writes (`corrections.write_empty_marker`),
/// the daemon reads. The `reason` string is the only field the daemon consumes.
enum EmptyMarker {

    /// Suffix appended to the meeting stem. `MeetingStore.stem(of:)` splits on the
    /// first dot, so the stem still resolves cleanly.
    static let suffix = ".empty.json"

    static func url(forStem stem: String, in dir: URL) -> URL {
        dir.appendingPathComponent(stem + suffix)
    }

    /// Parse the marker's `reason`. Returns nil for a missing file, unreadable
    /// bytes, or malformed JSON; a present-but-unknown reason resolves to
    /// `.noSpeech` via `EmptyReason(marker:)`.
    static func read(at url: URL) -> EmptyReason? {
        guard let data = try? Data(contentsOf: url),
              let obj = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] else {
            return nil
        }
        return EmptyReason(marker: obj["reason"] as? String)
    }

    static func read(stem: String, in dir: URL) -> EmptyReason? {
        read(at: url(forStem: stem, in: dir))
    }
}
