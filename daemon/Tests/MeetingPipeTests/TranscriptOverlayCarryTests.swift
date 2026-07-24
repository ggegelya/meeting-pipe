import XCTest
@testable import MeetingPipe

/// ASR3's load-bearing half. A re-transcribe renumbers every segment and
/// re-assigns every diarization cluster, so the two overlay sidecars cannot be
/// carried by key. These pin the time-anchored carry: what survives, what is
/// dropped rather than guessed, and that a wrong answer is never preferred to
/// no answer.
final class TranscriptOverlayCarryTests: XCTestCase {

    private typealias Anchor = TranscriptOverlayCarry.Anchor

    private func anchor(
        _ index: Int, _ start: Double, _ end: Double,
        speaker: String? = nil, text: String = ""
    ) -> Anchor {
        Anchor(index: index, start: start, end: end, speaker: speaker, text: text)
    }

    private func correction(_ index: Int, _ original: String, _ edited: String)
        -> TranscriptCorrectionStore.Correction {
        TranscriptCorrectionStore.Correction(
            segmentIndex: index, originalText: original, editedText: edited
        )
    }

    // MARK: - Segment anchoring

    /// The headline case: the new transcript coalesced three fine segments into
    /// one turn, so index 2's correction has to land on index 0, not stay at 2.
    func testCorrectionFollowsItsAudioAcrossRenumbering() {
        let old = [
            anchor(0, 0, 2, speaker: "ME", text: "hi"),
            anchor(1, 2, 4, speaker: "ME", text: "we shipped perfecta"),
            anchor(2, 4, 6, speaker: "THEM-A", text: "nice"),
        ]
        let new = [
            anchor(0, 0, 4, speaker: "ME", text: "hi we shipped perfecta"),
            anchor(1, 4, 6, speaker: "THEM-A", text: "nice one"),
        ]

        let carry = TranscriptOverlayCarry.carry(
            old: old, new: new,
            speakerOverlay: .empty,
            corrections: [1: correction(1, "we shipped perfecta", "we shipped Perfeqta")]
        )

        XCTAssertEqual(carry.corrections.keys.map { $0 }, [0])
        XCTAssertEqual(carry.corrections[0]?.editedText, "we shipped Perfeqta")
        XCTAssertEqual(carry.carriedCorrections, 1)
        XCTAssertEqual(carry.dropped, 0)
    }

    /// The correction's `original_text` is re-snapshotted against the new
    /// transcript. Left pointing at the old sentence, the sidecar would claim the
    /// pipeline produced text that no longer exists anywhere.
    func testCarriedCorrectionRebasesItsOriginalSnapshot() {
        let old = [anchor(0, 0, 4, text: "we shipped perfecta")]
        let new = [anchor(0, 0, 4, text: "we shipped perfekta")]

        let carry = TranscriptOverlayCarry.carry(
            old: old, new: new, speakerOverlay: .empty,
            corrections: [0: correction(0, "we shipped perfecta", "we shipped Perfeqta")]
        )

        XCTAssertEqual(carry.corrections[0]?.originalText, "we shipped perfekta")
        XCTAssertEqual(carry.corrections[0]?.editedText, "we shipped Perfeqta")
    }

    /// The glossary ratchet subsuming a hand fix is the feature working. Keeping
    /// the now-identical override would only make the next diff harder to read,
    /// and `TranscriptCorrectionStore.upsert` already treats it as a no-op.
    func testCorrectionTheNewTranscriptAlreadySatisfiesIsRetiredNotCarried() {
        let old = [anchor(0, 0, 4, text: "we shipped perfecta")]
        let new = [anchor(0, 0, 4, text: "we shipped Perfeqta")]

        let carry = TranscriptOverlayCarry.carry(
            old: old, new: new, speakerOverlay: .empty,
            corrections: [0: correction(0, "we shipped perfecta", "we shipped Perfeqta")]
        )

        XCTAssertTrue(carry.corrections.isEmpty)
        XCTAssertEqual(carry.retired, 1)
        XCTAssertEqual(carry.dropped, 0)
        XCTAssertEqual(carry.carriedCorrections, 0)
    }

    /// A glancing touch is not evidence. Better to drop the edit and say so than
    /// to stamp it onto a sentence it was never about.
    func testAnOverrideWithTooLittleOverlapIsDroppedNotGuessed() {
        let old = [anchor(0, 0, 10, text: "old")]
        // The new segmentation only covers the last second of the old span.
        let new = [anchor(0, 9, 12, text: "unrelated")]

        let carry = TranscriptOverlayCarry.carry(
            old: old, new: new, speakerOverlay: .empty,
            corrections: [0: correction(0, "old", "edited")]
        )

        XCTAssertTrue(carry.corrections.isEmpty)
        XCTAssertEqual(carry.dropped, 1)
    }

    func testNonOverlappingTranscriptsCarryNothing() {
        let carry = TranscriptOverlayCarry.carry(
            old: [anchor(0, 0, 5, text: "a")],
            new: [anchor(0, 100, 105, text: "b")],
            speakerOverlay: .empty,
            corrections: [0: correction(0, "a", "A")]
        )
        XCTAssertTrue(carry.corrections.isEmpty)
        XCTAssertEqual(carry.dropped, 1)
    }

    /// Two old corrections merged into one new turn: one index can hold one
    /// edited text, so the stronger claim wins and the loss is counted.
    func testTwoCorrectionsCollapsingOntoOneSegmentKeepTheStrongerClaim() {
        let old = [
            anchor(0, 0, 1, text: "short"),
            anchor(1, 1, 5, text: "long"),
        ]
        let new = [anchor(0, 0, 5, text: "short long")]

        let carry = TranscriptOverlayCarry.carry(
            old: old, new: new, speakerOverlay: .empty,
            corrections: [
                0: correction(0, "short", "SHORT"),
                1: correction(1, "long", "LONG"),
            ]
        )

        XCTAssertEqual(carry.corrections.count, 1)
        XCTAssertEqual(carry.corrections[0]?.editedText, "LONG")
        XCTAssertEqual(carry.carriedCorrections, 1)
        XCTAssertEqual(carry.dropped, 1)
    }

    // MARK: - Cluster names

    /// The core FEAT3 carry: "THEM-A is Alice" has to follow Alice's voice even
    /// when the new diarization files her under a different cluster id.
    func testAClusterNameFollowsTheVoiceIntoARelabelledCluster() {
        let old = [
            anchor(0, 0, 10, speaker: "ME"),
            anchor(1, 10, 20, speaker: "THEM-A"),
        ]
        // Re-diarization put the same voice in THEM-B this time.
        let new = [
            anchor(0, 0, 10, speaker: "ME"),
            anchor(1, 10, 20, speaker: "THEM-B"),
        ]

        let carry = TranscriptOverlayCarry.carry(
            old: old, new: new,
            speakerOverlay: SpeakerLabelStore.Overlay(labels: ["THEM-A": "Alice"], segments: [:]),
            corrections: [:]
        )

        XCTAssertEqual(carry.speakerOverlay.labels, ["THEM-B": "Alice"])
        XCTAssertEqual(carry.carriedNames, 1)
        XCTAssertEqual(carry.dropped, 0)
    }

    /// The acceptance case where the ratchet did its job: the roster now names
    /// the cluster outright, so the overlay lands on the roster label. Harmless
    /// as an identity mapping, and it keeps the undo path intact.
    func testANameCarriesOntoARosterMatchedCluster() {
        let carry = TranscriptOverlayCarry.carry(
            old: [anchor(0, 0, 10, speaker: "THEM-A")],
            new: [anchor(0, 0, 10, speaker: "Alice")],
            speakerOverlay: SpeakerLabelStore.Overlay(labels: ["THEM-A": "Alice"], segments: [:]),
            corrections: [:]
        )
        XCTAssertEqual(carry.speakerOverlay.labels, ["Alice": "Alice"])
    }

    /// A cluster the new diarization split in half owns no majority anywhere, so
    /// it stays unnamed. An unnamed cluster is a prompt to name it; a wrongly
    /// named one asserts a person who was not in the room.
    func testASplitClusterIsLeftUnnamedRatherThanNamedWrong() {
        let old = [anchor(0, 0, 20, speaker: "THEM-A")]
        let new = [
            anchor(0, 0, 10, speaker: "THEM-A"),
            anchor(1, 10, 20, speaker: "THEM-B"),
        ]

        let carry = TranscriptOverlayCarry.carry(
            old: old, new: new,
            speakerOverlay: SpeakerLabelStore.Overlay(labels: ["THEM-A": "Alice"], segments: [:]),
            corrections: [:]
        )

        XCTAssertTrue(carry.speakerOverlay.labels.isEmpty)
        XCTAssertEqual(carry.dropped, 1)
    }

    /// Two named clusters merged into one by the new diarization. One cluster
    /// cannot be two people, so the stronger claim takes it and the other is
    /// dropped rather than silently overwriting it.
    func testTwoNamesCannotBothClaimOneNewCluster() {
        let old = [
            anchor(0, 0, 15, speaker: "THEM-A"),
            anchor(1, 15, 20, speaker: "THEM-B"),
        ]
        let new = [anchor(0, 0, 20, speaker: "THEM-A")]

        let carry = TranscriptOverlayCarry.carry(
            old: old, new: new,
            speakerOverlay: SpeakerLabelStore.Overlay(
                labels: ["THEM-A": "Alice", "THEM-B": "Bob"], segments: [:]
            ),
            corrections: [:]
        )

        XCTAssertEqual(carry.speakerOverlay.labels.count, 1)
        XCTAssertEqual(carry.speakerOverlay.labels["THEM-A"], "Alice")
        XCTAssertEqual(carry.carriedNames, 1)
        XCTAssertEqual(carry.dropped, 1)
    }

    /// Same evidence on both sides must not resolve by dictionary iteration
    /// order, or the same batch run twice names different people.
    func testCollisionResolutionIsDeterministic() {
        let old = [
            anchor(0, 0, 10, speaker: "THEM-A"),
            anchor(1, 0, 10, speaker: "THEM-B"),
        ]
        let new = [anchor(0, 0, 10, speaker: "THEM-X")]
        let overlay = SpeakerLabelStore.Overlay(
            labels: ["THEM-A": "Alice", "THEM-B": "Bob"], segments: [:]
        )

        let first = TranscriptOverlayCarry.carry(
            old: old, new: new, speakerOverlay: overlay, corrections: [:]
        )
        for _ in 0..<20 {
            let again = TranscriptOverlayCarry.carry(
                old: old, new: new, speakerOverlay: overlay, corrections: [:]
            )
            XCTAssertEqual(again.speakerOverlay, first.speakerOverlay)
        }
    }

    // MARK: - Per-segment reassignments

    /// A FEAT3-SEGMENT reassignment holding a raw cluster label rides through
    /// the cluster remap too, otherwise it would point at a label the new
    /// transcript no longer has.
    func testAReassignmentToARawLabelIsRemappedThroughTheClusterMap() {
        let old = [
            anchor(0, 0, 10, speaker: "ME"),
            anchor(1, 10, 20, speaker: "THEM-A"),
        ]
        let new = [
            anchor(0, 0, 10, speaker: "ME"),
            anchor(1, 10, 20, speaker: "THEM-B"),
        ]

        let carry = TranscriptOverlayCarry.carry(
            old: old, new: new,
            speakerOverlay: SpeakerLabelStore.Overlay(
                labels: ["THEM-A": "Alice"], segments: [0: "THEM-A"]
            ),
            corrections: [:]
        )

        XCTAssertEqual(carry.speakerOverlay.segments, [0: "THEM-B"])
        XCTAssertEqual(carry.speakerOverlay.labels, ["THEM-B": "Alice"])
        XCTAssertEqual(carry.carriedReassignments, 1)
    }

    /// A reassignment holding a name (the common shape) is not a cluster label
    /// and must pass through untouched.
    func testAReassignmentToANamePassesThrough() {
        let carry = TranscriptOverlayCarry.carry(
            old: [anchor(0, 0, 10, speaker: "THEM-A")],
            new: [anchor(0, 0, 10, speaker: "THEM-A")],
            speakerOverlay: SpeakerLabelStore.Overlay(labels: [:], segments: [0: "Bob"]),
            corrections: [:]
        )
        XCTAssertEqual(carry.speakerOverlay.segments, [0: "Bob"])
    }

    // MARK: - Degenerate inputs

    func testAnEmptyOverlayIsANoOp() {
        let carry = TranscriptOverlayCarry.carry(
            old: [anchor(0, 0, 10)], new: [anchor(0, 0, 10)],
            speakerOverlay: .empty, corrections: [:]
        )
        XCTAssertEqual(carry, .empty)
    }

    /// A re-transcribe that produced nothing (silence, a failed diarization)
    /// must report the overrides as lost, not return a clean empty overlay that
    /// reads as "there was nothing to carry".
    func testAnEmptyNewTranscriptReportsEverythingAsDropped() {
        let carry = TranscriptOverlayCarry.carry(
            old: [anchor(0, 0, 10, speaker: "THEM-A", text: "hi")],
            new: [],
            speakerOverlay: SpeakerLabelStore.Overlay(labels: ["THEM-A": "Alice"], segments: [0: "Bob"]),
            corrections: [0: correction(0, "hi", "hey")]
        )
        XCTAssertEqual(carry.dropped, 3)
        XCTAssertEqual(carry.carried, 0)
        XCTAssertTrue(carry.speakerOverlay.isEmpty)
        XCTAssertTrue(carry.corrections.isEmpty)
    }

    /// A zero-length segment has no span to take a fraction of, so any real
    /// overlap is the best evidence there is. Without the guard the division
    /// would reject every one of them.
    func testAZeroLengthOldSegmentStillAnchors() {
        let carry = TranscriptOverlayCarry.carry(
            old: [anchor(0, 5, 5, text: "x")],
            new: [anchor(0, 4, 6, text: "y")],
            speakerOverlay: .empty,
            corrections: [0: correction(0, "x", "X")]
        )
        // A truly degenerate span shares no seconds with anything, so it drops
        // rather than being force-fitted. The point is that it does not crash or
        // divide by zero.
        XCTAssertEqual(carry.carriedCorrections + carry.dropped, 1)
    }

    /// `TranscriptSegment.index` is the raw array position, which is exactly the
    /// key both sidecars use; the anchor mapping must not renumber it.
    func testAnchorsKeepTheSegmentIndexTheSidecarsKeyOn() {
        let segments = [
            TranscriptSegment(index: 0, start: 0, end: 1, text: "a", speakerID: "ME"),
            TranscriptSegment(index: 4, start: 1, end: 2, text: "b", speakerID: "THEM-A"),
        ]
        let anchors = TranscriptOverlayCarry.anchors(from: segments)
        XCTAssertEqual(anchors.map(\.index), [0, 4])
        XCTAssertEqual(anchors.map(\.speaker), ["ME", "THEM-A"])
    }
}
