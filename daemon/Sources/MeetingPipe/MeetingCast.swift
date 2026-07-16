import Foundation

/// The people in one meeting, resolved for display (FEAT3-SEGMENT / FEAT3-ROSTER).
///
/// Why this exists: a raw diarization label is NOT a person's identity, and the UI
/// used to treat it as one. The raw labels in `<stem>.json` are already a mix of
/// three different things:
///
///   - **real names the pipeline baked in**: the user's own voice (`Heorhii`,
///     stamped by `diarize.label_me_speaker` from `summarization.user_label`) and
///     roster matches (`Rana`, `Sudip`);
///   - **unnamed clusters**: `THEM-A`;
///   - **the junk drawer**: `speaker_unknown`, which is not one person at all.
///
/// The overlay then stacks more names on top (cluster renames in `labels`, per-line
/// overrides in `segments`). Reading identity off the raw label produced four bugs:
/// a "New person" name could never be picked again (it lives only as a per-segment
/// value, so a raw-label scan never saw it), and a person could vanish from their own
/// line's list (the filter compared raw labels, so a line whose raw label was
/// `Heorhii` but which displayed as something else hid Heorhii).
///
/// So resolve first, then group by who the person actually is.
struct CastMember: Equatable, Identifiable {
    /// What the user sees: "Heorhii", "Anisha", "Unknown B".
    let displayName: String
    /// What to write into `SpeakerLabelStore`'s `segments` to assign a line to this
    /// person. Prefers a raw cluster label when they have one, so a later cluster
    /// rename carries the assignment with it; falls back to the literal name for
    /// someone who only exists as a per-segment override (the "New person" case).
    let assignKey: String
    /// The `speaker_unknown` catch-all: speech the diarizer credited to nobody.
    /// Never an assignment target (assigning *to* the junk drawer is meaningless;
    /// "Reset to original label" is the way back).
    let isUnattributed: Bool

    var id: String { assignKey }
}

enum MeetingCast {

    /// Raw labels that mean "the diarizer did not resolve a person", as opposed to a
    /// name it (or the user) resolved. `speaker_unknown` is the catch-all bucket;
    /// `THEM-A` is a distinct-but-unnamed voice; `speaker_3` is a raw id that never
    /// clustered.
    static func isUnattributedLabel(_ raw: String) -> Bool {
        raw == "speaker_unknown"
    }

    /// True for a label that names nobody yet, i.e. one the roster can still enroll
    /// under a name. A baked name (`Heorhii`) or a roster match (`Rana`) is already a
    /// person and must not be offered for enrollment as if it were anonymous.
    static func isUnnamedCluster(_ raw: String) -> Bool {
        raw.hasPrefix("THEM-") || raw.hasPrefix("speaker_")
    }

    /// The meeting's cast, in first-appearance order.
    ///
    /// Every segment is resolved through the same overlay resolution the rows render
    /// with (`SpeakerLabelStore.displayLabel` then `TranscriptDisplay.displayName`),
    /// then grouped by that resolved name. Two segments showing "Heorhii" are one
    /// person whether one got there from a baked raw label and the other from a
    /// per-segment override.
    static func members(
        segments: [TranscriptSegment],
        overlay: SpeakerLabelStore.Overlay
    ) -> [CastMember] {
        // displayName -> the best assignKey seen so far, plus its ordering.
        var order: [String] = []
        var keyFor: [String: String] = [:]
        var keyIsRawCluster: [String: Bool] = [:]
        var unattributed: [String: Bool] = [:]

        for seg in segments {
            guard let base = overlay.segments[seg.index] ?? seg.speakerID else { continue }
            let resolved = overlay.labels[base] ?? base
            let display = TranscriptDisplay.displayName(for: resolved)
            // A raw cluster key (the segment carries no per-segment override) is the
            // durable one: point future assignments at it and a cluster rename moves
            // them too. A per-segment override value is only a fallback.
            let isRawCluster = overlay.segments[seg.index] == nil

            if order.contains(display) == false {
                order.append(display)
                keyFor[display] = base
                keyIsRawCluster[display] = isRawCluster
                unattributed[display] = isUnattributedLabel(base)
            } else if isRawCluster, keyIsRawCluster[display] != true {
                // Upgrade a name-only key to the raw cluster key once we meet it.
                keyFor[display] = base
                keyIsRawCluster[display] = true
                unattributed[display] = isUnattributedLabel(base)
            }
        }

        return order.map { display in
            CastMember(
                displayName: display,
                assignKey: keyFor[display] ?? display,
                isUnattributed: unattributed[display] ?? false
            )
        }
    }

    /// The people a line can be assigned to: everyone in the cast except the person
    /// the line already resolves to, and except the unattributed bucket.
    ///
    /// Excluding by resolved *identity* rather than by raw label is load-bearing: a
    /// line whose raw label is `Heorhii` but which currently displays "Aditya" (an
    /// overlay cluster rename) must still offer Heorhii, which the old raw-label
    /// filter hid.
    static func assignTargets(
        for segment: TranscriptSegment,
        cast: [CastMember],
        overlay: SpeakerLabelStore.Overlay
    ) -> [CastMember] {
        let current = TranscriptDisplay.displayName(
            for: SpeakerLabelStore.displayLabel(for: segment, using: overlay)
        )
        return cast.filter { !$0.isUnattributed && $0.displayName != current }
    }
}
