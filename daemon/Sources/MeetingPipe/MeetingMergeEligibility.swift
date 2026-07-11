import Foundation

/// Pure guardrail for FEAT9 "merge fragmented recordings": decides whether a
/// multi-selection may be concatenated into one meeting, and if so which stem is
/// the primary (the one that survives) and the chronological fragment order.
///
/// A dropped-and-rejoined call yields two stems that belong together; an
/// arbitrary multi-selection does not. The guardrails keep a merge from doing
/// something the user cannot undo cleanly: it refuses across workflows (semantic
/// mismatch) and across privacy postures (merging an NDA/regulated recording
/// with a cloud one would blur the zero-egress boundary). No AVFoundation /
/// filesystem here, so it unit-tests off plain `Meeting` values.
enum MeetingMergeEligibility {

    struct Plan: Equatable {
        /// The meeting that survives: its stem, page, and sidecars are reused.
        let primary: Meeting
        /// The later fragments, chronological, folded into the primary and then
        /// soft-deleted once the merge lands.
        let fragments: [Meeting]

        static func == (lhs: Plan, rhs: Plan) -> Bool {
            lhs.primary.id == rhs.primary.id && lhs.fragments.map(\.id) == rhs.fragments.map(\.id)
        }
    }

    enum Ineligible: Error, Equatable {
        case tooFew
        case notAllDone
        case missingAudio
        case mixedWorkflows
        case mixedPrivacy

        /// Why the merge card is disabled, shown to the user so a selection that
        /// looks mergeable but is not explains itself.
        var reason: String {
            switch self {
            case .tooFew:
                return "Select two or more recordings from the same meeting."
            case .notAllDone:
                return "Every selected meeting must be finished processing first."
            case .missingAudio:
                return "A selected meeting has no audio to merge."
            case .mixedWorkflows:
                return "Only recordings in the same workflow can be merged."
            case .mixedPrivacy:
                return "Local-only and cloud recordings can't be merged together."
            }
        }
    }

    static func decide(_ meetings: [Meeting]) -> Result<Plan, Ineligible> {
        guard meetings.count >= 2 else { return .failure(.tooFew) }
        guard meetings.allSatisfy({ $0.status == .done }) else { return .failure(.notAllDone) }
        guard meetings.allSatisfy({ $0.audioURL != nil }) else { return .failure(.missingAudio) }

        // Same-workflow only. Compare the stable workflow UUID; all-nil (manual,
        // workflow-less recordings) is a single valid group.
        let workflows = Set(meetings.map { $0.workflowID ?? "" })
        guard workflows.count == 1 else { return .failure(.mixedWorkflows) }

        // NDA / regulated pairing must match: never blur the zero-egress boundary.
        let postures = Set(meetings.map(\.isZeroEgress))
        guard postures.count == 1 else { return .failure(.mixedPrivacy) }

        let ordered = meetings.sorted { $0.startedAt < $1.startedAt }
        return .success(Plan(primary: ordered[0], fragments: Array(ordered.dropFirst())))
    }
}
