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

    /// What `<stem>.meta.json` says about a trim, in the three outcomes SEC25 gave the sidecar.
    enum Lookup: Equatable {
        /// No sidecar, or one with no trim: transcribe every word.
        case none
        case trim(Double)
        /// The sidecar is there and could not be read or parsed. Never "no trim" (SEC37): a
        /// dataless iCloud sidecar would otherwise put the post-call tail into `<stem>.json`.
        case unreadable(kind: MeetingMetaRead.FailureKind, domain: String, code: Int)
    }

    /// The suggested trim recorded beside `audio`, read through `MeetingMetaRead` like every
    /// other sidecar reader that decides what leaves the machine or the transcript.
    static func trimSeconds(forAudio audio: URL) -> Lookup {
        switch MeetingMetaRead.load(stem: MeetingStore.stem(of: audio), in: audio.deletingLastPathComponent()) {
        case .absent:
            return .none
        case .loaded(let meta):
            return trimSeconds(meta: meta).map(Lookup.trim) ?? .none
        case .unreadable(let kind, let domain, let code):
            return .unreadable(kind: kind, domain: domain, code: code)
        }
    }

    /// SEC37: the job failure for an unreadable sidecar. Opens with a prefix
    /// `FailurePresentation.isValidation` already knows, so the Library row shows this text.
    struct UnreadableSidecar: LocalizedError, Equatable {
        let kind: MeetingMetaRead.FailureKind
        let domain: String
        let code: Int

        var errorDescription: String? {
            "Transcription did not finish: this meeting's settings file could not be read, so the end of the call could not be left out. Retry once it is available; it may still be downloading from iCloud."
        }
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
