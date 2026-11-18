import Foundation

/// DIAR8: the one-line notice the Transcript tab shows when the daemon's diarizer threw. The wording is
/// decided here, off any view, so a test can pin it (the UI cannot be screenshotted).
///
/// Three transcripts exist: one written before this change (`diarization_failed` true, no
/// `speaker_fallback`: no speakers were labelled), and the two the finalizer now writes. The notice
/// is gated on `diarization_failed` alone, never on `speaker_fallback`: the fallback key is also written
/// on a healthy transcript that happened to take the channel path.
struct TranscriptDiarizationNote: Equatable {
    /// The finalizer labelled the turns by microphone and system channel rather than leaving them unlabelled.
    let labelledByChannel: Bool
    /// What the diarizer threw, for the notice's help text. nil when the transcript carries none.
    let reason: String?

    /// nil unless the transcript says its diarizer failed. Absent keys, a non-bool flag and an
    /// empty reason all read as "no notice" or "no reason", never as an error.
    static func parse(_ obj: [String: Any]) -> TranscriptDiarizationNote? {
        guard (obj["diarization_failed"] as? Bool) == true else { return nil }
        let reason = (obj["diarization_failure_reason"] as? String)?
            .trimmingCharacters(in: .whitespacesAndNewlines)
        return TranscriptDiarizationNote(
            labelledByChannel: (obj["speaker_fallback"] as? String) == "channel",
            reason: (reason?.isEmpty == false) ? reason : nil
        )
    }

    var text: String {
        labelledByChannel
            ? "Speakers could not be told apart; labeled by microphone and system audio instead."
            : "Speakers could not be told apart, so these lines are not attributed to anyone."
    }

    var help: String {
        guard let reason else { return text }
        return "\(text) Reason: \(reason)"
    }
}
