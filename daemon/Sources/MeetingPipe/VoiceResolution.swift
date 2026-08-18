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
        /// FEAT14: the enrolled person the pipeline's roster match came closest to and
        /// still declined to name, for a voice that is still unresolved. Nil for every
        /// other voice, and nil whenever that person is no longer enrolled.
        ///
        /// A suggestion, and the chip menu is the only thing that may do anything with
        /// it: it is never pre-filled into the naming sheet and never written on its
        /// own. With one or two enrolment samples per person a near miss is often
        /// wrong, and a wrong name applied silently is worse than an unnamed voice,
        /// which is the trade `mp.roster`'s two gates were written to make.
        let suggestedName: String?
        /// This person's slot in the meeting's cast (UX58's `MeetingCast.colorIndex`),
        /// so a chip can carry the same identity dot their transcript rows carry
        /// (UX59). Resolved here rather than in the view because the strip is
        /// presentation-only by construction: every decision it renders lives on this
        /// type, and a second place that answered "which colour is this person" is
        /// exactly how the strip and the rows came to disagree in the first place.
        let colorIndex: Int?

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
        ///
        /// "other" is load-bearing (UX40). The strip renders a chip for every classified
        /// voice, the owner's and the `speaker_unknown` bucket included, and neither is
        /// counted here. Without the word, the owner's own 9-chip meeting read "7 of 7
        /// voices named" and looked like a miscount of what was on screen rather than an
        /// exact count of the people matching could have applied to. The counts are
        /// right; the sentence just had to say what it was counting.
        var headline: String {
            if others == 0 {
                return "No other voices in this meeting."
            }
            if rosterIsEmpty {
                return "No named voices yet, so nothing could be matched. Name a voice below to start."
            }
            let matched = rosterMatched + namedHere
            if matched == others {
                // A 1:1 is the most common shape there is, and "All 1 other voice named"
                // is not a sentence anyone writes.
                return others == 1 ? "The other voice is named." : "All \(others) other voices named."
            }
            return "\(matched) of \(others) other \(others == 1 ? "voice" : "voices") named."
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
    ///     `assignKey` is the underlying label. Its order is also each voice's palette
    ///     slot (UX58), which is what lets a chip and a row draw one person one colour.
    ///   - voiceprintLabels: keys of `<stem>.embeddings.json`, i.e. the labels the
    ///     pipeline itself assigned to a voice it had an embedding for.
    ///   - nearMisses: that sidecar's `near_misses` (FEAT14), keyed the same way: the
    ///     person the roster came closest to on a voice it refused to name.
    ///   - rosterNames: the enrolled people. Only used to tell an empty roster from a
    ///     populated one; whether a given voice was matched is read off the sidecar,
    ///     not off today's roster, so removing somebody does not rewrite history.
    ///   - userLabel: `summarization.user_label`.
    static func derive(
        cast: [CastMember],
        voiceprintLabels: Set<String>,
        nearMisses: [String: String] = [:],
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

            // FEAT14. Two gates on top of the pipeline's own, both of them refusals:
            //
            // - only an unresolved voice with a voiceprint, since a named voice needs
            //   no suggestion and one with no embedding cannot be enrolled at all;
            // - only a person who is still enrolled. The sidecar is a record of what
            //   the pipeline decided, so it outlives a `roster forget`, and offering
            //   somebody the owner deliberately removed would argue with that removal.
            //   It also carries FEAT11's honesty rule for free: with nobody enrolled
            //   no name can be a member, so an empty roster suggests nobody and the
            //   headline's "nothing could be matched" stands alone.
            let suggestion: String? = (origin == .unresolved && canEnroll)
                ? nearMisses[key].flatMap { rosterNames.contains($0) ? $0 : nil }
                : nil

            voices.append(
                Voice(
                    displayName: member.displayName,
                    assignKey: key,
                    origin: origin,
                    canEnroll: canEnroll,
                    suggestedName: suggestion,
                    // Through the shared function rather than off this loop's position,
                    // even though `members` de-duplicates by display name so the two are
                    // the same number today. The point of UX59 is that one rule answers
                    // this for both surfaces; a second derivation that happens to agree
                    // is the shape that drifts.
                    colorIndex: MeetingCast.colorIndex(displayName: member.displayName, in: cast)
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
