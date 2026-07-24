import Foundation

/// Carries the reversible transcript overlays across a re-transcribe (ASR3).
///
/// Both overlays key on something a re-transcribe re-derives from scratch:
/// `TranscriptCorrectionStore` and the per-segment half of `SpeakerLabelStore`
/// key on the segment's array index, and the cluster half keys on the
/// diarization label (`THEM-A`, ...). Re-running ASR + diarization renumbers the
/// segments and re-assigns the clusters, so keeping the sidecars as they are
/// would land a name or a text edit on a different sentence. Deleting them
/// instead throws away work the owner did by hand.
///
/// So the carry re-anchors on time, which is the one thing both transcripts
/// agree about because they describe the same audio:
///
///  - A new segment inherits an old segment's overrides when it covers at least
///    `minSegmentOverlap` of that old segment's span.
///  - A new cluster inherits an old cluster's name when it owns at least
///    `minClusterDominance` of that old cluster's speaking time.
///
/// Both mappings are injective: a new slot can only be claimed once, because
/// one segment has one speaker and one edited text. A collision resolves to the
/// larger overlap, and everything that fails to anchor is **dropped and
/// counted**, never guessed. The counts surface in the UI, so a carry that lost
/// something says so rather than quietly under-delivering.
///
/// Pure, no I/O: the host reads both transcripts and writes the sidecars.
enum TranscriptOverlayCarry {

    /// One segment reduced to what the carry reasons about.
    struct Anchor: Equatable {
        /// Position in the transcript's `segments` array, i.e. the key both
        /// overlays use.
        let index: Int
        let start: Double
        let end: Double
        /// Raw diarization / finalized label (`ME`, `THEM-A`, a roster name).
        let speaker: String?
        let text: String

        var duration: Double { max(0, end - start) }
    }

    /// The carried overlays plus what did not survive.
    struct Result: Equatable {
        var speakerOverlay: SpeakerLabelStore.Overlay
        var corrections: [Int: TranscriptCorrectionStore.Correction]
        /// Cluster names re-anchored to a new cluster.
        var carriedNames: Int
        /// Per-segment speaker reassignments re-anchored to a new segment.
        var carriedReassignments: Int
        /// Text corrections re-anchored to a new segment.
        var carriedCorrections: Int
        /// Overrides that could not be anchored to anything in the new
        /// transcript, across all three kinds.
        var dropped: Int
        /// Corrections the new transcript already reads the way the owner
        /// edited it to. Not a loss: the ratchet subsumed the fix, and keeping
        /// a no-op override would only make the next diff harder to read.
        var retired: Int

        static let empty = Result(
            speakerOverlay: .empty, corrections: [:],
            carriedNames: 0, carriedReassignments: 0, carriedCorrections: 0,
            dropped: 0, retired: 0
        )

        var carried: Int { carriedNames + carriedReassignments + carriedCorrections }
    }

    /// Share of an old segment's duration a new segment must cover to inherit
    /// its index-keyed overrides. Half is deliberate: `SegmentBuilder.coalesce`
    /// merges fragments into turns, so a new segment is usually longer than the
    /// old one it replaces, and requiring the *old* span to be mostly covered
    /// keeps that direction cheap while still refusing a glancing touch.
    static let minSegmentOverlap = 0.5

    /// Share of an old cluster's speaking time one new cluster must own to
    /// inherit its name. Compared **strictly**, so this is a majority test, not
    /// a coverage one: a cluster the new diarization split down the middle has
    /// no majority owner and stays unnamed, and picking one half anyway would be
    /// a coin flip wearing a deterministic tiebreak. That is the right way
    /// round, because an unnamed cluster is a prompt to name it while a
    /// wrongly-named one asserts a person who was not in the room.
    static let minClusterDominance = 0.5

    /// Reduce parsed segments to anchors. `TranscriptSegment.index` is already
    /// the raw array position (`TranscriptLoader.parse` keeps it across the
    /// empty-text skip), so it is the same key both sidecars use.
    static func anchors(from segments: [TranscriptSegment]) -> [Anchor] {
        segments.map {
            Anchor(index: $0.index, start: $0.start, end: $0.end, speaker: $0.speakerID, text: $0.text)
        }
    }

    static func carry(
        old: [Anchor],
        new: [Anchor],
        speakerOverlay: SpeakerLabelStore.Overlay,
        corrections: [Int: TranscriptCorrectionStore.Correction]
    ) -> Result {
        guard !speakerOverlay.isEmpty || !corrections.isEmpty else { return .empty }
        // Nothing to anchor to: report everything as dropped rather than
        // silently returning an empty overlay that reads like "nothing to do".
        guard !old.isEmpty, !new.isEmpty else {
            return Result(
                speakerOverlay: .empty, corrections: [:],
                carriedNames: 0, carriedReassignments: 0, carriedCorrections: 0,
                dropped: speakerOverlay.labels.count + speakerOverlay.segments.count + corrections.count,
                retired: 0
            )
        }

        let clusterMap = clusterMapping(old: old, new: new, named: Set(speakerOverlay.labels.keys))
        let segmentMap = segmentMapping(old: old, new: new)
        let newByIndex = Dictionary(new.map { ($0.index, $0) }, uniquingKeysWith: { a, _ in a })

        var result = Result.empty

        // Cluster names. `clusterMapping` is already injective, so two old
        // clusters can never both land on one new cluster here.
        var labels: [String: String] = [:]
        for (oldLabel, name) in speakerOverlay.labels {
            if let newLabel = clusterMap[oldLabel] {
                labels[newLabel] = name
                result.carriedNames += 1
            } else {
                result.dropped += 1
            }
        }

        // Per-segment reassignments. The stored value can be a raw cluster
        // label, so it rides through the same cluster map; a value that is a
        // name (the common case after FEAT3-SEGMENT) passes through untouched.
        var segments: [Int: String] = [:]
        var reassignmentOverlap: [Int: Double] = [:]
        for (oldIndex, value) in speakerOverlay.segments.sorted(by: { $0.key < $1.key }) {
            guard let match = segmentMap[oldIndex] else {
                result.dropped += 1
                continue
            }
            let resolved = clusterMap[value] ?? value
            if let existing = segments[match.newIndex] {
                // Two old segments merged into one new turn. Keep the stronger
                // claim; only count a loss when they actually disagreed.
                if existing != resolved { result.dropped += 1 }
                if match.overlap > (reassignmentOverlap[match.newIndex] ?? 0), existing != resolved {
                    segments[match.newIndex] = resolved
                    reassignmentOverlap[match.newIndex] = match.overlap
                }
                continue
            }
            segments[match.newIndex] = resolved
            reassignmentOverlap[match.newIndex] = match.overlap
            result.carriedReassignments += 1
        }

        // Text corrections.
        var carriedCorrections: [Int: TranscriptCorrectionStore.Correction] = [:]
        var correctionOverlap: [Int: Double] = [:]
        for (oldIndex, correction) in corrections.sorted(by: { $0.key < $1.key }) {
            guard let match = segmentMap[oldIndex], let target = newByIndex[match.newIndex] else {
                result.dropped += 1
                continue
            }
            if target.text == correction.editedText {
                result.retired += 1
                continue
            }
            let rebased = TranscriptCorrectionStore.Correction(
                segmentIndex: match.newIndex,
                // Re-snapshot against what the new transcript actually says, so
                // the sidecar keeps meaning "this is what the pipeline produced"
                // rather than pointing at a sentence that no longer exists.
                originalText: target.text,
                editedText: correction.editedText
            )
            if carriedCorrections[match.newIndex] != nil {
                result.dropped += 1
                if match.overlap > (correctionOverlap[match.newIndex] ?? 0) {
                    carriedCorrections[match.newIndex] = rebased
                    correctionOverlap[match.newIndex] = match.overlap
                }
                continue
            }
            carriedCorrections[match.newIndex] = rebased
            correctionOverlap[match.newIndex] = match.overlap
            result.carriedCorrections += 1
        }

        result.speakerOverlay = SpeakerLabelStore.Overlay(labels: labels, segments: segments)
        result.corrections = carriedCorrections
        return result
    }

    // MARK: - Mappings

    struct SegmentMatch: Equatable {
        let newIndex: Int
        let overlap: Double
    }

    /// Old segment index -> the new segment that covers it, when one covers at
    /// least `minSegmentOverlap` of it.
    static func segmentMapping(old: [Anchor], new: [Anchor]) -> [Int: SegmentMatch] {
        var out: [Int: SegmentMatch] = [:]
        for a in old {
            var best: SegmentMatch?
            for b in new {
                let seconds = overlapSeconds(a, b)
                guard seconds > 0 else { continue }
                if seconds > (best?.overlap ?? 0) {
                    best = SegmentMatch(newIndex: b.index, overlap: seconds)
                }
            }
            guard let match = best else { continue }
            // A zero-length old segment (a marker-ish row) has no span to
            // measure, so any real overlap is the best evidence available.
            let required = a.duration > 0 ? a.duration * minSegmentOverlap : 0
            if match.overlap >= required { out[a.index] = match }
        }
        return out
    }

    /// Old cluster label -> the new cluster that dominates it. Restricted to
    /// `named` (the clusters an overlay actually names), because an unnamed
    /// cluster has nothing to carry and would only compete for the injective
    /// slots.
    static func clusterMapping(old: [Anchor], new: [Anchor], named: Set<String>) -> [String: String] {
        guard !named.isEmpty else { return [:] }
        var totals: [String: Double] = [:]
        for a in old {
            guard let label = a.speaker, named.contains(label) else { continue }
            totals[label, default: 0] += a.duration
        }
        guard !totals.isEmpty else { return [:] }

        var overlaps: [String: [String: Double]] = [:]
        for a in old {
            guard let oldLabel = a.speaker, named.contains(oldLabel) else { continue }
            for b in new {
                guard let newLabel = b.speaker else { continue }
                let seconds = overlapSeconds(a, b)
                guard seconds > 0 else { continue }
                overlaps[oldLabel, default: [:]][newLabel, default: 0] += seconds
            }
        }

        // Rank every (old, new) candidate by how much of the old cluster the new
        // one owns, then take them greedily. Greedy-by-ratio is the injective
        // resolution: the strongest claim on a new cluster wins it, and the
        // runner-up is left unmapped rather than sharing.
        struct Candidate { let old: String; let new: String; let ratio: Double }
        var candidates: [Candidate] = []
        for (oldLabel, perNew) in overlaps {
            let total = totals[oldLabel] ?? 0
            guard total > 0 else { continue }
            for (newLabel, seconds) in perNew {
                let ratio = seconds / total
                if ratio > minClusterDominance {
                    candidates.append(Candidate(old: oldLabel, new: newLabel, ratio: ratio))
                }
            }
        }
        // Ties break on the label pair so the mapping is deterministic; two
        // clusters with identical evidence must not depend on dictionary order.
        candidates.sort {
            $0.ratio != $1.ratio ? $0.ratio > $1.ratio
                : ($0.old != $1.old ? $0.old < $1.old : $0.new < $1.new)
        }

        var out: [String: String] = [:]
        var claimed: Set<String> = []
        for c in candidates where out[c.old] == nil && !claimed.contains(c.new) {
            out[c.old] = c.new
            claimed.insert(c.new)
        }
        return out
    }

    /// Seconds two spans share. Zero when they merely touch.
    static func overlapSeconds(_ a: Anchor, _ b: Anchor) -> Double {
        max(0, min(a.end, b.end) - max(a.start, b.start))
    }
}
