import Foundation

/// FluidAudio-free inputs so grouping logic is unit-testable without a model.
/// FluidAudioRunner adapts the SDK's TokenTiming / TimedSpeakerSegment into these.
struct AsrToken: Equatable {
    var text: String
    var start: Double
    var end: Double
}

struct SpeakerSpan: Equatable {
    var speakerId: String
    var start: Double
    var end: Double
}

/// Groups a flat Parakeet TDT token stream into segments matching Whisper-style
/// VAD chunking. Downstream code reads the segment shape, not raw tokens.
enum SegmentBuilder {

    /// Thresholds tuned to match Whisper/MLX-Whisper paragraph granularity pre/post migration.
    struct Config {
        /// Treat as a hard sentence boundary when a token ends with one of these.
        var sentenceTerminators: Set<Character> = [".", "?", "!"]
        /// Treat as a soft boundary when the gap to the next token exceeds this.
        var gapBreakSeconds: Double = 0.7
        /// Hard ceiling on a single segment's duration.
        var maxSegmentSeconds: Double = 20.0
        /// Discard tokens whose text strips to empty after trimming.
        var dropEmptyTokens: Bool = true

        /// `coalesce` merges consecutive same-speaker segments into one readable
        /// turn when the inter-segment gap is at most this. The builder splits on
        /// every sentence terminator, so a monologue arrives as one row per
        /// sentence; folding those back into turns is what fixes the mid-thought
        /// splits and absorbs the sub-second fragments.
        var mergeGapSeconds: Double = 1.2
        /// Ceiling on a coalesced turn, so a long monologue stays several
        /// readable rows rather than one wall of text (and per-segment markers /
        /// reassignment keep usable granularity).
        var maxTurnSeconds: Double = 30.0
        /// `coalesce` drops a segment whose text carries no letter or number: the
        /// lone `.` (0.16-0.32 s) the ASR emits as phantom punctuation, which
        /// clutters the transcript and credits a near-empty span to nobody.
        var dropPunctuationOnlySegments: Bool = true

        static let `default` = Config()
    }

    /// Build segments from tokens and a diarization timeline. Empty speakers list
    /// assigns the fallback label (matches Python's _UNKNOWN_SPEAKER for schema uniformity).
    static func build(
        tokens: [AsrToken],
        speakers: [SpeakerSpan],
        unknownSpeaker: String = "speaker_unknown",
        config: Config = .default
    ) -> [SidecarSegment] {
        let cleaned = config.dropEmptyTokens
            ? tokens.filter { !$0.text.trimmingCharacters(in: .whitespaces).isEmpty }
            : tokens
        guard !cleaned.isEmpty else { return [] }

        var segments: [SidecarSegment] = []
        var bucket: [AsrToken] = []

        func flush() {
            guard !bucket.isEmpty else { return }
            let words = bucket.map {
                SidecarWord(word: $0.text, start: $0.start, end: $0.end)
            }
            let text = bucket.map(\.text).joined().trimmingCharacters(in: .whitespaces)
            let start = bucket.first!.start
            let end = bucket.last!.end
            let speaker = assignSpeaker(
                segmentStart: start, segmentEnd: end,
                speakers: speakers, fallback: unknownSpeaker
            )
            segments.append(SidecarSegment(
                start: start, end: end, text: text, words: words, speaker: speaker
            ))
            bucket.removeAll(keepingCapacity: true)
        }

        for token in cleaned {
            if let last = bucket.last {
                let gap = token.start - last.end
                let bucketStart = bucket.first!.start
                let runDuration = token.end - bucketStart
                if gap >= config.gapBreakSeconds || runDuration >= config.maxSegmentSeconds {
                    flush()
                }
            }
            bucket.append(token)

            let trimmed = token.text.trimmingCharacters(in: .whitespaces)
            if let lastChar = trimmed.last, config.sentenceTerminators.contains(lastChar) {
                flush()
            }
        }
        flush()
        return segments
    }

    /// Clean `build`'s fine-grained stream for readability: drop phantom
    /// punctuation-only segments, then merge consecutive same-speaker segments
    /// into readable turns, bounded by an inter-segment gap and a maximum turn
    /// duration. Pure and FluidAudio-free, applied by `FluidAudioRunner` after
    /// `build`; kept separate so the split primitive stays independently tested.
    static func coalesce(_ segments: [SidecarSegment], config: Config = .default) -> [SidecarSegment] {
        let kept = config.dropPunctuationOnlySegments
            ? segments.filter { hasSpeech($0.text) }
            : segments
        var out: [SidecarSegment] = []
        for segment in kept {
            guard var last = out.last,
                  last.speaker == segment.speaker,
                  segment.start - last.end <= config.mergeGapSeconds,
                  segment.end - last.start <= config.maxTurnSeconds
            else {
                out.append(segment)
                continue
            }
            last.words.append(contentsOf: segment.words)
            last.text = last.words.map(\.word).joined().trimmingCharacters(in: .whitespaces)
            last.end = segment.end
            out[out.count - 1] = last
        }
        return out
    }

    /// True when the text carries at least one letter or number. A segment that
    /// strips to only punctuation / whitespace is phantom ASR output; `isLetter`
    /// is Unicode-aware, so Cyrillic (the uk / ru archive) still counts as speech.
    private static func hasSpeech(_ text: String) -> Bool {
        text.contains { $0.isLetter || $0.isNumber }
    }

    /// Assign the speaker with the largest overlap; ties broken by earliest span start.
    /// Mirrors assign_speakers in pipeline/src/mp/transcribe.py.
    static func assignSpeaker(
        segmentStart: Double,
        segmentEnd: Double,
        speakers: [SpeakerSpan],
        fallback: String
    ) -> String {
        guard !speakers.isEmpty else { return fallback }
        var best: (id: String, overlap: Double, start: Double)? = nil
        for span in speakers {
            let lo = max(segmentStart, span.start)
            let hi = min(segmentEnd, span.end)
            let overlap = max(0, hi - lo)
            if overlap <= 0 { continue }
            if let b = best {
                if overlap > b.overlap || (overlap == b.overlap && span.start < b.start) {
                    best = (span.speakerId, overlap, span.start)
                }
            } else {
                best = (span.speakerId, overlap, span.start)
            }
        }
        return best?.id ?? fallback
    }
}
