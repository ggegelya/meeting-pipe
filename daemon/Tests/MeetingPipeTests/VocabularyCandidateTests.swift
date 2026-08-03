import XCTest
@testable import MeetingPipe

/// FEAT12: "Add to Vocabulary" from a transcript correction.
///
/// Two hard constraints carried over from FEAT11, and both are pinned here rather than
/// left to a code comment, because both are the kind of thing a later change softens
/// without noticing:
///
/// 1. It stays a **pre-fill**. `VocabularyCandidate.derive` and `VocabularyOffer.make`
///    are pure, so the offer appearing can never be the thing that wrote a term; only an
///    explicit confirm calls `GlossaryStore.addTerm`. `test_making_an_offer_writes_nothing`
///    is the cancel case: it pins the file byte-for-byte.
/// 2. The diff stays **deliberately dumb**. Bailing is the feature, so most of this suite
///    is refusals. A wrong pair is not a bad suggestion, it is a permanent rule rewriting
///    every transcript finalized after it, filled in by the app so the user has no reason
///    to distrust it.
final class VocabularyCandidateTests: XCTestCase {

    // MARK: - The pairs it will name

    func test_a_single_token_replacement_yields_the_pair() {
        let pair = VocabularyCandidate.derive(
            original: "resolve PS for venusaur this week",
            edited: "resolve PS for Vinicius this week"
        )
        // The canonical side keeps the casing the user typed; the key is folded only at
        // match time, by `mp.glossary` and `GlossaryStore` alike.
        XCTAssertEqual(pair, .init(heard: "venusaur", canonical: "Vinicius"))
    }

    func test_a_pure_capitalization_fix_is_a_real_pair() {
        // Keys are folded and values are not, so this substitution does something: every
        // future "kubernetes" is written "Kubernetes".
        XCTAssertEqual(
            VocabularyCandidate.derive(original: "we run kubernetes here", edited: "we run Kubernetes here"),
            .init(heard: "kubernetes", canonical: "Kubernetes")
        )
    }

    func test_a_cased_variant_beside_the_fix_matches_case_insensitively() {
        // The user re-capitalized "the" in the same pass. Comparing that token case
        // insensitively is what keeps the span on the one word that actually changed,
        // instead of widening the pair to "the venusaur" -> "The Vinicius".
        XCTAssertEqual(
            VocabularyCandidate.derive(original: "the venusaur ticket", edited: "The Vinicius ticket"),
            .init(heard: "venusaur", canonical: "Vinicius")
        )
    }

    func test_punctuation_adjacent_tokens_are_tolerated() {
        // The comma belongs to the sentence, not the term, and the pipeline matches whole
        // words, so a key carrying it would never fire.
        XCTAssertEqual(
            VocabularyCandidate.derive(original: "we shipped venusaur, finally", edited: "we shipped Vinicius, finally"),
            .init(heard: "venusaur", canonical: "Vinicius")
        )
        XCTAssertEqual(
            VocabularyCandidate.derive(original: "he said \"venusaur\".", edited: "he said \"Vinicius\"."),
            .init(heard: "venusaur", canonical: "Vinicius")
        )
    }

    func test_punctuation_inside_a_word_survives() {
        XCTAssertEqual(
            VocabularyCandidate.derive(original: "lets start now", edited: "let's start now"),
            .init(heard: "lets", canonical: "let's")
        )
    }

    func test_a_contiguous_two_token_span_yields_the_pair() {
        XCTAssertEqual(
            VocabularyCandidate.derive(original: "the post gres migration", edited: "the PostgreSQL Server migration"),
            .init(heard: "post gres", canonical: "PostgreSQL Server")
        )
    }

    // MARK: - The refusals (the point of the task)

    func test_a_two_token_change_that_is_not_contiguous_yields_nothing() {
        // Same two changed words, one token further apart. Contiguity is the whole
        // difference between "that word, spelled wrong" and two unrelated fixes.
        XCTAssertNil(VocabularyCandidate.derive(
            original: "the post big gres migration",
            edited: "the PostgreSQL big Server migration"
        ))
    }

    func test_an_insertion_yields_nothing() {
        XCTAssertNil(VocabularyCandidate.derive(
            original: "we shipped venusaur",
            edited: "we shipped the venusaur"
        ))
    }

    func test_a_deletion_yields_nothing() {
        XCTAssertNil(VocabularyCandidate.derive(
            original: "we actually shipped venusaur",
            edited: "we shipped venusaur"
        ))
    }

    func test_a_multi_span_edit_yields_nothing() {
        XCTAssertNil(VocabularyCandidate.derive(
            original: "venusaur ships on friday to pikachu",
            edited: "Vinicius ships on friday to Priya"
        ))
    }

    func test_a_reorder_yields_nothing() {
        // Contiguous, two tokens, equal counts: every other gate passes it. The pair it
        // would produce rewrites a phrase into a permutation of itself, for ever.
        XCTAssertNil(VocabularyCandidate.derive(
            original: "the quick brown fox",
            edited: "the brown quick fox"
        ))
    }

    func test_a_three_token_rewrite_yields_nothing() {
        XCTAssertNil(VocabularyCandidate.derive(
            original: "we should probably ship it",
            edited: "we could maybe hold it"
        ))
    }

    func test_no_change_yields_nothing() {
        XCTAssertNil(VocabularyCandidate.derive(original: "same line", edited: "same line"))
        XCTAssertNil(VocabularyCandidate.derive(original: "same  line", edited: "same line"),
                     "collapsing whitespace is not a vocabulary term")
    }

    func test_a_punctuation_only_change_yields_nothing() {
        // Trimming the edges leaves both sides identical, so the pair would be a no-op
        // rule the pipeline still has to carry.
        XCTAssertNil(VocabularyCandidate.derive(original: "we shipped it", edited: "we shipped it."))
    }

    func test_clearing_the_line_yields_nothing() {
        XCTAssertNil(VocabularyCandidate.derive(original: "we shipped venusaur", edited: ""))
        XCTAssertNil(VocabularyCandidate.derive(original: "", edited: ""))
    }

    // MARK: - The offer

    func test_the_offer_exists_only_when_a_candidate_does() {
        XCTAssertNotNil(VocabularyOffer.make(
            original: "ping venusaur today", edited: "ping Vinicius today", workflowName: "Client work"
        ))
        // The affordance is absent, not disabled: an edit the diff refuses to describe
        // produces no offer at all, so the flow says nothing rather than showing an empty
        // sheet the user has to dismiss.
        XCTAssertNil(VocabularyOffer.make(
            original: "ping venusaur today", edited: "ping venusaur later today", workflowName: "Client work"
        ))
    }

    func test_the_offer_defaults_to_the_meetings_workflow() {
        let offer = VocabularyOffer.make(
            original: "ping venusaur", edited: "ping Vinicius", workflowName: "Client work"
        )
        XCTAssertEqual(offer?.defaultScope, "Client work")
    }

    func test_a_workflowless_meeting_defaults_to_the_global_scope() {
        XCTAssertNil(
            VocabularyOffer.make(original: "ping venusaur", edited: "ping Vinicius", workflowName: nil)?
                .defaultScope
        )
        // A blank name is the same case, not a workflow called "  ": `[workflow."  "]`
        // is a table `resolvedTerms` would never look in.
        XCTAssertNil(
            VocabularyOffer.make(original: "ping venusaur", edited: "ping Vinicius", workflowName: "   ")?
                .defaultScope
        )
    }

    func test_making_an_offer_writes_nothing() throws {
        // The cancel case, and the honesty rule stated as a fact about the code: building
        // an offer is pure, so an offer the user never confirms cannot have changed
        // anything. Pinned on the bytes, not just on the resolved terms.
        let url = try makeTempURL()
        let before = """
        [terms]
        "acme" = "ACME"

        [fuzzy]
        enabled = true
        """
        try before.write(to: url, atomically: true, encoding: .utf8)

        _ = VocabularyOffer.make(original: "ping venusaur", edited: "ping Vinicius", workflowName: "Client work")

        XCTAssertEqual(try String(contentsOf: url, encoding: .utf8), before)
    }

    // MARK: - The confirmed append

    func test_confirming_appends_one_row_to_the_workflow_scope() throws {
        let url = try makeTempURL()
        try """
        [terms]
        "acme" = "ACME"
        """.write(to: url, atomically: true, encoding: .utf8)

        let store = GlossaryStore(fileURL: url)
        try store.addTerm(heard: "venusaur", canonical: "Vinicius", workflow: "Client work")

        // Exactly one row, in the workflow's own table, resolved the way the pipeline
        // resolves it.
        XCTAssertEqual(
            GlossaryStore.resolvedTerms(at: url, workflowName: "Client work"),
            ["acme": "ACME", "venusaur": "Vinicius"]
        )
        XCTAssertEqual(
            GlossaryStore.resolvedTerms(at: url, workflowName: nil), ["acme": "ACME"],
            "a workflow-scoped confirm must not widen itself to every meeting"
        )
    }

    func test_confirming_the_global_scope_writes_the_global_table() throws {
        let url = try makeTempURL()
        let store = GlossaryStore(fileURL: url)
        try store.addTerm(heard: "venusaur", canonical: "Vinicius", workflow: nil)

        XCTAssertEqual(
            GlossaryStore.resolvedTerms(at: url, workflowName: nil), ["venusaur": "Vinicius"]
        )
    }

    func test_confirming_a_key_that_already_exists_updates_it_rather_than_duplicating() throws {
        let url = try makeTempURL()
        try """
        [terms]
        "venusaur" = "Venusaur"
        """.write(to: url, atomically: true, encoding: .utf8)

        let store = GlossaryStore(fileURL: url)
        try store.addTerm(heard: "Venusaur", canonical: "Vinicius", workflow: nil)

        XCTAssertEqual(store.globalTerms.count, 1, "no phantom row for the editor to show")
        XCTAssertEqual(
            GlossaryStore.resolvedTerms(at: url, workflowName: nil), ["venusaur": "Vinicius"]
        )
    }

    func test_confirming_preserves_the_knobs_the_editor_does_not_model() throws {
        // The append rides the editor's own write-back, so `[fuzzy]` survives it for the
        // same reason it survives an edit. Worth pinning at this entry point too: a
        // second writer that dropped it would turn near-miss matching off silently.
        let url = try makeTempURL()
        try """
        [fuzzy]
        enabled = true
        """.write(to: url, atomically: true, encoding: .utf8)

        let store = GlossaryStore(fileURL: url)
        try store.addTerm(heard: "venusaur", canonical: "Vinicius", workflow: nil)

        XCTAssertTrue(try String(contentsOf: url, encoding: .utf8).contains("[fuzzy]"))
    }

    // MARK: - helpers

    private func makeTempURL() throws -> URL {
        let dir = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("mp-feat12-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: dir) }
        return dir.appendingPathComponent("glossary.toml")
    }
}
