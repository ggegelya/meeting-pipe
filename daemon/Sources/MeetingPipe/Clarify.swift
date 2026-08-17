import Foundation

/// FEAT13: clarifying a misheard word where you find it, instead of in Preferences.
///
/// FEAT11 shipped the Vocabulary editor and FEAT12 shipped the pre-filled offer that
/// follows a line edit. What neither reaches is the moment the garble is actually
/// noticed: reading a transcript. Fixing one then meant leaving the transcript, opening
/// Preferences, retyping a phrase from memory, and coming back.
///
/// Everything here is pure and does no I/O, which is the point. **A per-meeting text fix
/// and a global vocabulary rule are different things with very different blast radii**,
/// and the whole task is about keeping them distinct:
///
/// - `.thisLine` writes the PIPE9 correction overlay: one line, one meeting, reversible.
/// - `.everyMeeting` writes a `glossary.toml` term: every transcript finalized from then
///   on, including meetings not yet recorded.
///
/// **Nothing is written until the user confirms**, and this file is where that is a fact
/// about the code rather than a claim about the UI: building a `ClarifyPlan` cannot touch
/// either file. The argument for that constraint is on the record. FEAT11's walkthrough
/// meeting also contained "Venusaur", a word the transcriber invented that neither the
/// owner nor the session could decode. Under an affordance that wrote on selection, that
/// garble would have become a permanent global rule rewriting every future transcript on
/// a guess; under a pre-fill the owner read it and walked away, which is what happened.
enum Clarify {

    /// The two places a clarification can land, and the copy that tells them apart.
    ///
    /// The titles carry the distinction on their own ("this line only" against "always"),
    /// because the picker is the last thing read before a confirm and an explanation the
    /// user has scrolled past is not a safeguard.
    enum Destination: String, CaseIterable, Identifiable {
        /// PIPE9's per-segment text overlay. The safe default: one meeting, reversible.
        case thisLine
        /// A `glossary.toml` term (FEAT11). Global by nature, and irreversible in the
        /// sense that matters: transcripts finalized under it are written that way.
        case everyMeeting

        var id: String { rawValue }

        var title: String {
            switch self {
            case .thisLine:     return "Fix this line only"
            case .everyMeeting: return "Always fix this"
            }
        }

        /// What confirming actually does, in the register UX44 set for this surface (the
        /// user is told about consequences, not about transcription internals).
        var explanation: String {
            switch self {
            case .thisLine:
                return "Changes this one line, in this meeting. Nothing else is touched, and you can change it back from the same menu."
            case .everyMeeting:
                return "Adds it to your Vocabulary. Every transcript finalized from now on is written the corrected way, including meetings you have not recorded yet. This meeting keeps the words it has until you rebuild it."
            }
        }

        /// The confirm button names the consequence rather than saying "Save", because
        /// the two consequences are the thing being chosen between.
        var confirmTitle: String {
            switch self {
            case .thisLine:     return "Fix Line"
            case .everyMeeting: return "Add Term"
            }
        }

        /// Only the rule path offers Re-transcribe, and that asymmetry is deliberate
        /// rather than incidental: a correction overlay is applied at load time so the
        /// line reads correctly the moment it is written, while a new term reaches an
        /// existing transcript **only** through a re-transcribe. Offering it on both
        /// would teach that a line edit needs a rebuild, which is exactly the confusion
        /// FEAT11's walkthrough had to warn against.
        var offersRetranscribe: Bool { self == .everyMeeting }
    }

    /// What a confirm does. One case per destination, so "which of the two files did
    /// this write" is answerable from the value and pinnable in a test.
    enum Plan: Equatable {
        case correctLine(segmentIndex: Int, newText: String)
        case addTerm(heard: String, canonical: String, workflow: String?, retranscribe: Bool)
    }

    /// The plan a filled-in sheet implies, or nil when there is nothing honest to do.
    ///
    /// Refuses an empty side, a pair that is the same on both sides, and (on the line
    /// path only) a substitution that would not change the line. That last one is what
    /// stops Clarify writing an overlay entry that does nothing, which would then show up
    /// in a re-transcribe's carry report as work to preserve.
    ///
    /// The rule path deliberately does **not** require the term to occur in this line. A
    /// glossary term is global by nature, and a user who has retyped the "as heard" side
    /// into a spelling they know the transcriber produces elsewhere is doing the right
    /// thing, not making a mistake.
    static func plan(
        segmentIndex: Int,
        line: String,
        heard rawHeard: String,
        intended rawIntended: String,
        destination: Destination,
        scope: String?,
        retranscribe: Bool
    ) -> Plan? {
        // The same normalisation FEAT12's diff applies before a pair becomes a key, so a
        // term typed here and a term derived from a line edit land in `glossary.toml`
        // identically. The pipeline matches whole words, so a key carrying an outer comma
        // or quote would simply never fire.
        let heard = VocabularyCandidate.trimPunctuation(rawHeard)
        let intended = rawIntended.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !heard.isEmpty, !intended.isEmpty, heard != intended else { return nil }

        switch destination {
        case .thisLine:
            guard let newText = substitute(heard: heard, with: intended, in: line),
                  newText != line else { return nil }
            return .correctLine(segmentIndex: segmentIndex, newText: newText)
        case .everyMeeting:
            return .addTerm(
                heard: heard,
                canonical: intended,
                workflow: scope,
                retranscribe: retranscribe
            )
        }
    }

    /// Replace every whole-word occurrence of `heard` in `line` with `intended`, or nil
    /// when there is none.
    ///
    /// Deliberately the **same rule the pipeline applies**: `mp.glossary.Glossary`
    /// compiles `\b(<keys>)\b` case-insensitively and substitutes every match
    /// (`glossary.py:70`). Matching it here is what makes "Fix this line only" a faithful
    /// preview of what "Always fix this" would do to this line after a re-transcribe, so
    /// a user who tries the safe option first is not surprised by the other one later.
    static func substitute(heard: String, with intended: String, in line: String) -> String? {
        guard let regex = wordRegex(heard) else { return nil }
        let whole = NSRange(line.startIndex..<line.endIndex, in: line)
        guard regex.firstMatch(in: line, options: [], range: whole) != nil else { return nil }
        return regex.stringByReplacingMatches(
            in: line,
            options: [],
            range: whole,
            withTemplate: NSRegularExpression.escapedTemplate(for: intended)
        )
    }

    /// Whether `word` occurs whole-word in `line`, by the same rule `substitute`
    /// replaces on.
    ///
    /// Exposed for UX66's contradiction test, which has to ask exactly the
    /// question the substitution answers: a conflict detector built on a looser
    /// match than the rule it is checking would report conflicts the rule cannot
    /// actually cause.
    static func containsTerm(_ word: String, in line: String) -> Bool {
        guard let regex = wordRegex(word) else { return false }
        let whole = NSRange(line.startIndex..<line.endIndex, in: line)
        return regex.firstMatch(in: line, options: [], range: whole) != nil
    }

    /// `\b(<word>)\b`, case-insensitive. The single home for the matching rule, so
    /// `substitute` and `containsTerm` cannot drift apart from each other or from
    /// `mp.glossary`.
    private static func wordRegex(_ word: String) -> NSRegularExpression? {
        let escaped = NSRegularExpression.escapedPattern(for: word)
        guard !escaped.isEmpty else { return nil }
        return try? NSRegularExpression(pattern: "\\b\(escaped)\\b", options: [.caseInsensitive])
    }

    /// The scope a rule starts on: the meeting's workflow, so a client's product name
    /// lands beside that client's other terms, or nil (the global `[terms]` table) when
    /// the meeting matched no workflow. Mirrors `VocabularyOffer.make` so the two
    /// vocabulary entry points default the same way.
    static func defaultScope(workflowName: String?) -> String? {
        let trimmed = workflowName?.trimmingCharacters(in: .whitespacesAndNewlines)
        return (trimmed?.isEmpty ?? true) ? nil : trimmed
    }
}

/// The line a Clarify sheet is open for. Identifiable so it drives a `.sheet(item:)`,
/// keyed by the segment index like every other per-segment overlay in this app.
struct ClarifyTarget: Identifiable {
    let segmentIndex: Int
    /// The line as it currently reads, corrections already overlaid. The sheet shows it
    /// and the line path substitutes into it.
    let line: String
    /// Who the line shows and their slot in the meeting's cast, resolved by the row this
    /// sheet was opened from (UX57's `MeetingCast.rowSpeaker`, UX58's `colorIndex`). It
    /// carried the raw diarization label until UX58, which named and tinted a reassigned
    /// line after the person it had been moved away from.
    let speakerName: String
    let speakerColorIndex: Int?
    let start: TimeInterval
    /// The meeting's workflow, for the rule path's default scope.
    let workflowName: String?

    var id: Int { segmentIndex }
}
