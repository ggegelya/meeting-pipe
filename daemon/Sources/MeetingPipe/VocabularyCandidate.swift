import Foundation

/// FEAT12: the pure word-diff that turns "I just fixed this line" into at most one
/// vocabulary pair, plus the offer the transcript's edit flow presents from it.
///
/// The moment a user retypes a garbled term in the transcript is the only moment both
/// sides of the pair are known, and until now that knowledge was thrown away: the
/// Vocabulary editor (FEAT11) could only be filled by remembering a garble later and
/// typing both sides from memory in Preferences.
///
/// Two constraints carried over from FEAT11 and restated by this task shape everything
/// below, and neither is a detail:
///
/// 1. **This is a pre-fill, never an auto-write.** Nothing here touches `GlossaryStore`.
///    `derive` is pure and `make` does no I/O, so the only way a pair reaches
///    `glossary.toml` is an explicit confirm in the sheet.
/// 2. **The diff is deliberately dumb.** It describes a single-token or two-token
///    contiguous replacement and refuses everything else: different token counts
///    (insertions, deletions), a change split across two places, a same-words reorder,
///    or a span longer than `maxSpan`. Bailing is the feature. A wrong pair is not a
///    wrong suggestion, it is a permanent rule that silently rewrites every transcript
///    finalized from then on, and the user has no reason to distrust a pair the app
///    filled in for them.
enum VocabularyCandidate {

    /// One "as heard" -> canonical pair, ready to pre-fill the confirm sheet. The same
    /// two sides as a `[terms]` row: `heard` becomes the key (folded at match time by
    /// both `mp.glossary` and `GlossaryStore`), `canonical` the spelling written instead.
    struct Pair: Equatable {
        let heard: String
        let canonical: String
    }

    /// The longest replacement this will describe as one pair. Two, not more: a
    /// two-token contiguous span is still recognisably "that word, spelled wrong", and
    /// three or more is a rewritten phrase, which is what "no multi-word rewrites" means.
    static let maxSpan = 2

    /// The pair a `(original, edited)` line pair implies, or nil when the edit is
    /// anything this refuses to describe.
    ///
    /// Token comparison is exact, and edge tokens that differ only in case are then
    /// trimmed off the changed span. That two-step is what keeps a stray
    /// re-capitalization next door ("the" -> "The") from widening a one-word fix into a
    /// two-word pair, while still letting a pure capitalization fix stand on its own
    /// when it is the whole edit ("kubernetes" -> "Kubernetes" is a real substitution,
    /// since the key is folded and the value is not).
    static func derive(original: String, edited: String) -> Pair? {
        let before = tokens(original)
        let after = tokens(edited)
        // A different token count is an insertion, a deletion, or a rewrite. There is no
        // honest single pair in any of those, so there is no alignment step: refuse.
        guard before.count == after.count else { return nil }

        let changed = before.indices.filter { before[$0] != after[$0] }
        guard var lo = changed.first, var hi = changed.last else { return nil }

        while lo < hi, foldEqual(before[lo], after[lo]) { lo += 1 }
        while hi > lo, foldEqual(before[hi], after[hi]) { hi -= 1 }

        // The span is the smallest contiguous run covering every difference, so a change
        // split across two places is necessarily longer than the run it would need to be.
        guard hi - lo + 1 <= maxSpan else { return nil }

        let heardSpan = Array(before[lo...hi])
        let canonicalSpan = Array(after[lo...hi])

        // Same words, different order. Contiguous and short, so every other gate lets it
        // through, and it would produce a pair that rewrites one phrase into a permutation
        // of itself for every future meeting.
        if heardSpan.count > 1,
           heardSpan.map({ $0.lowercased() }).sorted() == canonicalSpan.map({ $0.lowercased() }).sorted() {
            return nil
        }

        // Punctuation-tolerant: a comma the token happened to carry is not part of the
        // term, and a key ending in one would never match, since the pipeline matches
        // whole words.
        let heard = trimPunctuation(heardSpan.joined(separator: " "))
        let canonical = trimPunctuation(canonicalSpan.joined(separator: " "))
        guard !heard.isEmpty, !canonical.isEmpty, heard != canonical else { return nil }
        return Pair(heard: heard, canonical: canonical)
    }

    private static func tokens(_ text: String) -> [String] {
        text.split(whereSeparator: { $0.isWhitespace }).map(String.init)
    }

    /// The same fold `GlossaryStore.liveTerms` and `mp.glossary` apply to a key.
    private static func foldEqual(_ a: String, _ b: String) -> Bool {
        a.lowercased() == b.lowercased()
    }

    /// Leading and trailing punctuation only. An apostrophe or hyphen inside a word
    /// ("let's", "e-mail") is part of the term and survives.
    private static func trimPunctuation(_ text: String) -> String {
        text.trimmingCharacters(in: CharacterSet.punctuationCharacters.union(.whitespaces))
    }
}

/// FEAT12: what the transcript's edit flow offers after a line is saved, or nil when the
/// diff refused to name a pair.
///
/// Pure and I/O-free on purpose, so "the offer appeared" and "something was written" stay
/// separable facts: constructing one of these can never change `glossary.toml`, and the
/// sheet's Add button is the only thing that can.
struct VocabularyOffer: Identifiable {
    let pair: VocabularyCandidate.Pair
    /// The scope the sheet starts on: the meeting's workflow, so a client's product name
    /// lands beside that client's other terms, or nil (the global `[terms]` table) when
    /// the meeting matched no workflow. The user can still switch it before confirming.
    let defaultScope: String?

    var id: String { "\(pair.heard)\u{1F}\(pair.canonical)\u{1F}\(defaultScope ?? "")" }

    static func make(original: String, edited: String, workflowName: String?) -> VocabularyOffer? {
        guard let pair = VocabularyCandidate.derive(original: original, edited: edited) else {
            return nil
        }
        let trimmed = workflowName?.trimmingCharacters(in: .whitespacesAndNewlines)
        let scope = (trimmed?.isEmpty ?? true) ? nil : trimmed
        return VocabularyOffer(pair: pair, defaultScope: scope)
    }
}
