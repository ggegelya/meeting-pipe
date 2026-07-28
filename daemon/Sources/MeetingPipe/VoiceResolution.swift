import Foundation

/// Who the pipeline actually resolved in one meeting, and who it did not (FEAT11).
///
/// The naming instruments already existed (TranscriptTab enrolls a voiceprint,
/// Preferences ▸ Pipeline manages the roster) and the roster was populated, yet a
/// meeting could still surface `THEM-B` / `THEM-C` with nothing anywhere saying
/// whether roster matching had run, matched, or missed. That left "this person is not
/// enrolled" indistinguishable from "this person is enrolled and the match missed",
/// which are opposite fixes: name them here, versus DIAR2's matching quality.
///
/// No new sidecar was needed. `<stem>.embeddings.json` is already keyed by the FINAL
/// label the finalizer assigned (`orchestrate._write_embeddings_sidecar`), so its keys
/// ARE the durable record of the pipeline's outcome: the owner's own name, a roster
/// name it matched, or a `THEM-x` cluster it could not. In-app naming writes the
/// reversible overlay and never rewrites that sidecar, so the record stays honest
/// about what the pipeline itself did even after the user has renamed everyone.
enum VoiceResolution {

    /// How this voice got the name it shows.
    enum Origin: Equatable {
        /// The owner, stamped from `summarization.user_label`.
        case you
        /// The pipeline matched an enrolled roster voice.
        case roster
        /// Still a raw cluster label; nobody has claimed it.
        case unresolved
        /// Named in the app after the fact, so it lives in the speaker overlay rather
        /// than in what the pipeline resolved.
        case namedHere
        /// The `speaker_unknown` junk drawer: speech credited to nobody. Not a person,
        /// so it is never counted and never offered for naming.
        case unattributed
    }

    struct Voice: Identifiable, Equatable {
        let displayName: String
        /// The raw label to hand the naming flow, i.e. `CastMember.assignKey`.
        let assignKey: String
        let origin: Origin
        /// Whether `<stem>.embeddings.json` carries a voiceprint for this label, which
        /// is what decides whether naming it can enroll a cross-meeting voice or is
        /// only a per-line label (enrolling a label with no embedding hard-failed with
        /// "pipeline exited 2", which is why this gate exists at all).
        let canEnroll: Bool

        var id: String { assignKey }

        /// Offer the naming flow only for a voice that is still anonymous AND has a
        /// voiceprint to enroll. Everything else is either already a person or has no
        /// voice to remember.
        var offersNaming: Bool { origin == .unresolved && canEnroll }
    }

    /// The meeting's voices plus the counts the summary line reads from.
    struct Outcome: Equatable {
        let voices: [Voice]
        let rosterMatched: Int
        let namedHere: Int
        let unresolved: Int
        /// True when the roster has nobody enrolled at all. Then "matched 0 of 3" is a
        /// misleading way to say "matching had nothing to match against", and the two
        /// need different fixes.
        let rosterIsEmpty: Bool

        static let empty = Outcome(
            voices: [], rosterMatched: 0, namedHere: 0, unresolved: 0, rosterIsEmpty: true
        )

        /// Voices that are somebody other than the owner, i.e. the ones matching could
        /// have applied to. The owner is identified by the voiceprint, not the roster,
        /// and the unattributed bucket is not a person.
        var others: Int { rosterMatched + namedHere + unresolved }

        /// The one-line honest statement of what roster matching did for this meeting.
        var headline: String {
            if others == 0 {
                return "No other voices in this meeting."
            }
            if rosterIsEmpty {
                return "No named voices yet, so nothing could be matched. Name a voice below to start."
            }
            let matched = rosterMatched + namedHere
            return "\(matched) of \(others) \(others == 1 ? "voice" : "voices") named."
        }

        /// The follow-up clause, or nil when there is nothing left to do.
        var detail: String? {
            guard unresolved > 0 else { return nil }
            return unresolved == 1
                ? "1 voice is still unnamed."
                : "\(unresolved) voices are still unnamed."
        }
    }

    /// Classify the meeting's cast.
    ///
    /// - Parameters:
    ///   - cast: the resolved cast from `MeetingCast.members`, which has already folded
    ///     the speaker overlay in, so `displayName` is what the transcript shows and
    ///     `assignKey` is the underlying label.
    ///   - voiceprintLabels: keys of `<stem>.embeddings.json`, i.e. the labels the
    ///     pipeline itself assigned to a voice it had an embedding for.
    ///   - rosterNames: the enrolled people. Only used to tell an empty roster from a
    ///     populated one; whether a given voice was matched is read off the sidecar,
    ///     not off today's roster, so removing somebody does not rewrite history.
    ///   - userLabel: `summarization.user_label`.
    static func derive(
        cast: [CastMember],
        voiceprintLabels: Set<String>,
        rosterNames: [String],
        userLabel: String
    ) -> Outcome {
        let owner = userLabel.trimmingCharacters(in: .whitespacesAndNewlines)
        var voices: [Voice] = []
        var rosterMatched = 0
        var namedHere = 0
        var unresolved = 0

        for member in cast {
            let key = member.assignKey
            let canEnroll = voiceprintLabels.contains(key)
            let origin: Origin

            if member.isUnattributed {
                origin = .unattributed
            } else if MeetingCast.isUnnamedCluster(key) {
                // A cluster the pipeline left anonymous. It still shows a name when the
                // user renamed the cluster in-app, which the overlay carries; compare
                // against what the raw label would render as to tell the two apart.
                origin = member.displayName == TranscriptDisplay.displayName(for: key)
                    ? .unresolved
                    : .namedHere
            } else if !owner.isEmpty, key.caseInsensitiveCompare(owner) == .orderedSame {
                origin = .you
            } else if canEnroll {
                // A real name that the finalizer wrote into the transcript, so the
                // roster is where it came from.
                origin = .roster
            } else {
                // A name that exists only in the overlay: a per-segment "New person",
                // or a cluster rename whose voice the diarizer never embedded.
                origin = .namedHere
            }

            switch origin {
            case .roster:      rosterMatched += 1
            case .namedHere:   namedHere += 1
            case .unresolved:  unresolved += 1
            case .you, .unattributed: break
            }

            voices.append(
                Voice(
                    displayName: member.displayName,
                    assignKey: key,
                    origin: origin,
                    canEnroll: canEnroll
                )
            )
        }

        return Outcome(
            voices: voices,
            rosterMatched: rosterMatched,
            namedHere: namedHere,
            unresolved: unresolved,
            rosterIsEmpty: rosterNames.isEmpty
        )
    }
}
