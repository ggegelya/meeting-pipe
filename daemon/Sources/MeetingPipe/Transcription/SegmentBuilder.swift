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
