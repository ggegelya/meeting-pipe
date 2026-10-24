import Foundation

/// END17's keep-then-trim, the reading half. A held end that confirmed under a lossless capture
/// keeps its tail in the WAV and records where the hold began in `<stem>.meta.json`
/// (`held_end_trim_sec`); everything that reads the meeting's words reads them only up to there.
///
/// Applied to the transcript rather than to the audio because the audio is the recovery copy: a
/// wrong end is undone by dropping the key and transcribing again (`MeetingLibraryService
/// .restoreHeldTail`), which only works while the tail still exists. Pure, so the cut is pinned by
/// tests without a runner.
enum HeldEndTrim {

    /// The `<stem>.meta.json` key. Python reads it as informational (`mp.workflow`).
    static let metaKey = "held_end_trim_sec"

    /// The suggested trim recorded beside `audio`, or nil when there is none.
    static func trimSeconds(forAudio audio: URL) -> Double? {
        let stem = MeetingStore.stem(of: audio)
        let meta = audio.deletingLastPathComponent().appendingPathComponent("\(stem).meta.json")
        guard let data = try? Data(contentsOf: meta),
              let dict = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any]
        else { return nil }
        return trimSeconds(meta: dict)
    }

    static func trimSeconds(meta: [String: Any]) -> Double? {
        guard let seconds = (meta[metaKey] as? NSNumber)?.doubleValue, seconds > 0 else { return nil }
        return seconds
    }

    /// The Audio tab's line for a trimmed recording. Minutes, rounded up so a 20 s tail never
    /// reads as "0 min"; the clock time of the cut when the length is unknown.
    static func caption(trimSec: Double, durationSec: Double?) -> String {
        if let durationSec = durationSec, durationSec > trimSec {
            let minutes = max(1, Int(((durationSec - trimSec) / 60.0).rounded(.up)))
            return "Trimmed \(minutes) min after the call ended. The recording still has it."
        }
        return "Trimmed after \(WaveformTimecode.format(trimSec)), where the call ended. The recording still has the rest."
    }

    /// `sidecar` with nothing at or after `seconds`. A segment that straddles the cut keeps the
    /// words that start before it, and a voiceprint whose speaker only talked in the tail is
    /// dropped with them, so the tail cannot enrol or match a voice either. `audioSeconds` stays
    /// the file's real length, because the file still has it.
    static func apply(_ sidecar: TranscriptSidecar, at seconds: Double) -> TranscriptSidecar {
        var trimmed = sidecar
        trimmed.segments = sidecar.segments.compactMap { segment in
            guard segment.start < seconds else { return nil }
            guard segment.end > seconds else { return segment }
            var cut = segment
            cut.words = segment.words.filter { $0.start < seconds }
            cut.end = seconds
            if !segment.words.isEmpty {
                guard !cut.words.isEmpty else { return nil }
                cut.text = cut.words.map(\.word).joined().trimmingCharacters(in: .whitespaces)
            }
            return cut
        }
        if let embeddings = sidecar.speakerEmbeddings {
            let speakers = Set(trimmed.segments.map(\.speaker))
            let kept = embeddings.filter { speakers.contains($0.key) }
            trimmed.speakerEmbeddings = kept.isEmpty ? nil : kept
        }
        return trimmed
    }
}
