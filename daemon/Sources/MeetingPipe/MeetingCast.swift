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

    /// The speaker one transcript row belongs to, and what its menu may do about them
    /// (UX57).
    ///
    /// A line carries two identities, and the row used to read a different one for each
    /// job: its **name** resolved through the overlay, while its **menu** and its
    /// enrollment gate read the raw diarization label, which a per-line reassignment
    /// never changes by design (FEAT3-SEGMENT leaves `<stem>.json` alone so every naming
    /// stays reversible). A line moved off Sudip onto Unknown E therefore read
    /// "Unknown E" and still offered Rename for **Sudip**, and taking that offer would
    /// have re-enrolled Sudip's voiceprint under the typed name and renamed Sudip on
    /// every other line of the meeting: a silent wrong-target write into the roster, not
    /// a display defect.
    ///
    /// So this is the row's one identity read, and each action carries the label it
    /// writes to rather than leaving the call site to pick one.
    struct RowSpeaker: Equatable {
        /// The label every action here targets, and the identity this row has: the
        /// per-segment reassignment when the line carries one, else the raw diarization
        /// label. Never the cluster a reassigned line came from. `nil` for a line the
        /// diarizer gave no speaker at all.
        let label: String?
        /// The in-app name for `label` (`overlay.labels[label]`), or nil when the label
        /// renders itself. This is the "old name" a rename or an un-name hands
        /// `MeetingLibraryService`.
        let assignedName: String?
        /// What the row's speaker menu offers, in order. Empty means no speaker item at
        /// all, which is a real answer: a per-segment "New person" has no whole-voice
        /// name to change and no voiceprint to enroll.
        let actions: [Action]

        /// What the row shows. Same resolution `members` groups the cast by
        /// (`overlay.labels[base] ?? base`, through `TranscriptDisplay`), so the row and
        /// the cast strip cannot disagree about who a line belongs to.
        var displayName: String {
            TranscriptDisplay.displayName(for: assignedName ?? label)
        }

        /// One item in the row's speaker menu, carrying the label it writes to so the
        /// view cannot reach past it for a different one.
        enum Action: Hashable {
            /// FEAT3-ROSTER: enroll this voice into the roster under a name.
            case name(label: String)
            /// FEAT3-UNDO: re-enroll under a new name and forget the old one.
            case rename(label: String, currentName: String)
            /// FEAT3-UNDO: drop the overlay entry and un-enroll the voice.
            case unname(label: String, currentName: String)
        }
    }

    /// Resolve one row's speaker, and what its menu offers against that speaker.
    ///
    /// Each gate is the one the service behind the action already enforces, and they
    /// match `VoiceResolutionBar.actions(for:)` so a row and a cast chip never disagree
    /// about the same person:
    ///
    /// - a name in the overlay's `labels` map is a whole-cluster naming, so it is
    ///   renameable and un-nameable;
    /// - an unnamed cluster with a voiceprint can be enrolled. `isUnnamedCluster` keeps
    ///   an already-named person (a baked `Heorhii`, a roster match `Rana`) out of the
    ///   enroll flow, and the voiceprint gate keeps `mp roster enroll` off a label with
    ///   no embedding, which used to exit 2;
    /// - a per-segment "New person" name (FEAT3-SEGMENT) is neither: no `labels` entry
    ///   holds it, so an un-name would drop nothing and the row would not move, and it
    ///   has no embedding to enroll. The way back for that line is "Reset to original
    ///   label", which the assign menu offers already.
    static func rowSpeaker(
        for segment: TranscriptSegment,
        overlay: SpeakerLabelStore.Overlay,
        voiceprintLabels: Set<String>
    ) -> RowSpeaker {
        // The same base `SpeakerLabelStore.displayLabel` resolves from, kept unresolved
        // because the cluster-name table is keyed on it: it is what an action writes.
        guard let label = overlay.segments[segment.index] ?? segment.speakerID else {
            return RowSpeaker(label: nil, assignedName: nil, actions: [])
        }
        if let name = overlay.labels[label] {
            return RowSpeaker(
                label: label,
                assignedName: name,
                actions: [
                    .rename(label: label, currentName: name),
                    .unname(label: label, currentName: name),
                ]
            )
        }
        let enrollable = voiceprintLabels.contains(label) && isUnnamedCluster(label)
        return RowSpeaker(
            label: label,
            assignedName: nil,
            actions: enrollable ? [.name(label: label)] : []
        )
    }

    /// The palette slot for one person in this meeting: their position in the cast
    /// (UX58). `TranscriptDisplay.color(atCastIndex:)` is the render side.
    ///
    /// The rule this replaced keyed the transcript's speaker tint on the raw diarization
    /// label and picked the slot with `abs(label.hashValue) % 8`, which was wrong three
    /// ways at once:
    ///
    ///   - colour never followed a per-line reassignment, because `segment.speakerID` is
    ///     exactly what FEAT3-SEGMENT leaves alone (the owner's report: "once I assign
    ///     Sudip, then want to re-assign wrong replica from Sudip to someone else, color
    ///     remains on sudip");
    ///   - Swift seeds string hashing per process and nothing here sets
    ///     `SWIFT_DETERMINISTIC_HASHING`, so every speaker changed colour on every
    ///     launch (measured 2026-08-03: `THEM-A` landed on slot 3, then 4, then 7 across
    ///     three processes);
    ///   - two people collided about 92% of the time in a 6-voice meeting, which is the
    ///     one job the dot has.
    ///
    /// Position in `members(segments:overlay:)` fixes all three, because that order is a
    /// pure function of the meeting's own files: first-appearance order over the
    /// segments, so it is identical on every launch and distinct per person. Naming
    /// somebody does not move them either, since the rename lands on a member that is
    /// already in the list rather than appending a new one.
    ///
    /// Past the palette's size the slots wrap and two people do share a hue. That is
    /// accepted rather than fixed: the eight are UX14's contrast-tuned set, and a wider
    /// palette would trade a legible hue for a rare meeting.
    ///
    /// `nil` means "nobody in this cast", which the render side draws muted.
    static func colorIndex(displayName: String, in cast: [CastMember]) -> Int? {
        cast.firstIndex { $0.displayName == displayName }
    }

    /// The palette slot for one transcript row, keyed on the identity the row *shows*
    /// (`rowSpeaker`'s resolution, UX57) rather than on its raw label, so a reassigned
    /// line takes its new speaker's colour in the same refresh it takes their name.
    static func colorIndex(for speaker: RowSpeaker, in cast: [CastMember]) -> Int? {
        // A line the diarizer gave no speaker at all is nobody, and must not borrow the
        // slot of a `THEM-` cluster that happens to render "Unknown" too.
        guard speaker.label != nil else { return nil }
        return colorIndex(displayName: speaker.displayName, in: cast)
    }
}
