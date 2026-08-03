import XCTest
@testable import MeetingPipe

/// UX44: the Vocabulary editor's first-contact story, in the two halves that are values
/// rather than pixels.
///
/// FEAT11 shipped a structurally sound editor that spoke pipeline-ese. The owner opened
/// it a day later and filed "I just realize it exists, but not sure what is the purpose".
/// Two of the four fixes for that are testable without a window: the copy (fenced here,
/// the repo's habit for a rule that regresses by accident) and the empty-state and
/// cross-link derivations, which are pure precisely so they can be.
final class VocabularyEditorTests: XCTestCase {

    // MARK: - Copy

    /// The jargon fence. "ASR" appeared unexpanded twice in an editor whose whole
    /// audience is someone who does not know what ASR stands for, which is the single
    /// most cited line of the task. A literal test, because the failure mode is a later
    /// session reaching for the term that is natural in the code.
    func test_no_user_facing_string_says_ASR() {
        for line in VocabularyCopy.allUserFacing {
            XCTAssertFalse(line.contains("ASR"), "user-facing copy still says ASR: \(line)")
        }
    }

    /// The replacement has to actually be there, or the fence above passes on copy that
    /// simply dropped the subject rather than naming it plainly.
    func test_the_lede_names_the_transcriber_in_one_line() {
        XCTAssertTrue(VocabularyCopy.lede.contains("transcriber"), VocabularyCopy.lede)
        XCTAssertFalse(VocabularyCopy.lede.contains("\n"), "the lede is one line")
        XCTAssertLessThan(VocabularyCopy.lede.count, 80, VocabularyCopy.lede)
    }

    /// The footer kept exactly one of the five rules it used to carry in one paragraph:
    /// the one naming the action that reaches a meeting you already have. Reprocess and
    /// Re-summarize redo the summary over the transcript already on disk, so a user sent
    /// to either would watch the garble survive and conclude the feature is broken.
    func test_the_footer_still_names_re_transcribe() {
        XCTAssertTrue(VocabularyCopy.footer.contains("Re-transcribe"), VocabularyCopy.footer)
    }

    /// The matching semantics moved out of the footer and onto the rows they describe.
    func test_matching_semantics_live_on_the_row_tooltip() {
        XCTAssertTrue(VocabularyCopy.rowHelp.contains("case-insensitive"), VocabularyCopy.rowHelp)
        XCTAssertTrue(VocabularyCopy.rowHelp.contains("whole-word"), VocabularyCopy.rowHelp)
        XCTAssertFalse(VocabularyCopy.footer.contains("case-insensitive"),
                       "the footer kept the detail it was supposed to shed")
    }

    /// The empty state used to offer "ticket prefixes" as its example, which is both
    /// jargon and not an example of a *pair*. The sample row is the example now.
    func test_the_empty_state_dropped_ticket_prefixes() {
        XCTAssertFalse(VocabularyCopy.emptyGlobal.lowercased().contains("ticket prefixes"),
                       VocabularyCopy.emptyGlobal)
    }

    /// The sample is the worked pair from `glossary.example.toml`, the one place the
    /// product already had an example and the one place no UI ever showed it.
    func test_the_sample_pair_is_the_documented_one() {
        XCTAssertEqual(VocabularyCopy.sampleHeard, "cube kernetes")
        XCTAssertEqual(VocabularyCopy.sampleCanonical, "Kubernetes")
        // VoiceOver gets the pair and the fact that it is not a saved row; without the
        // second half the example is indistinguishable from a term the user added.
        XCTAssertTrue(VocabularyCopy.sampleAccessibilityLabel.contains("cube kernetes"))
        XCTAssertTrue(VocabularyCopy.sampleAccessibilityLabel.contains("Kubernetes"))
        XCTAssertTrue(VocabularyCopy.sampleAccessibilityLabel.contains("Not saved"))
    }

    /// The near-miss toggle has to read as what it does, not as `[fuzzy].enabled`.
    func test_the_fuzzy_toggle_reads_plainly() {
        XCTAssertFalse(VocabularyCopy.fuzzyLabel.lowercased().contains("fuzzy"),
                       VocabularyCopy.fuzzyLabel)
        XCTAssertFalse(VocabularyCopy.fuzzyLabel.contains("Levenshtein"), VocabularyCopy.fuzzyLabel)
        XCTAssertTrue(VocabularyCopy.fuzzyLabel.contains("near-miss"), VocabularyCopy.fuzzyLabel)
        // The honest half: it is opt-in because a wrong substitution is worse than a
        // missed one, and the sublabel is the only place that can say so.
        XCTAssertTrue(VocabularyCopy.fuzzySublabel.contains("Off by default"),
                      VocabularyCopy.fuzzySublabel)
    }

    // MARK: - Empty state

    func test_the_sample_row_shows_only_on_a_scope_with_no_terms() {
        XCTAssertTrue(VocabularyCopy.showsSampleRow(termCount: 0))
        // One row is enough to hide it, including the blank row "Add term" appends: from
        // that moment the editable row is the one to type into, and an example beside it
        // that looks like a row but eats keystrokes is the worst of both.
        XCTAssertFalse(VocabularyCopy.showsSampleRow(termCount: 1))
        XCTAssertFalse(VocabularyCopy.showsSampleRow(termCount: 7))
    }

    // MARK: - Cross-link

    func test_the_link_targets_the_pipeline_pane() {
        XCTAssertEqual(VocabularyDeepLink.pane, .pipeline)
    }

    func test_a_known_workflow_preselects_its_own_scope() {
        XCTAssertEqual(
            VocabularyDeepLink.scope(
                forWorkflowNamed: "Client work", availableScopes: ["Client work", "General"]
            ),
            "Client work"
        )
    }

    /// The scope picker only offers workflows the store holds. A name it does not carry
    /// (a rename typed but not saved, or a workflow deleted out from under the sheet)
    /// falls back to the global table rather than selecting a row that is not there,
    /// which would leave the picker blank over a table no meeting resolves.
    func test_an_unknown_workflow_falls_back_to_the_global_scope() {
        XCTAssertNil(VocabularyDeepLink.scope(
            forWorkflowNamed: "Renamed but not saved", availableScopes: ["Client work"]
        ))
        XCTAssertNil(VocabularyDeepLink.scope(forWorkflowNamed: "Client work", availableScopes: []))
    }

    func test_a_blank_or_missing_name_is_the_global_scope() {
        XCTAssertNil(VocabularyDeepLink.scope(forWorkflowNamed: nil, availableScopes: ["A"]))
        XCTAssertNil(VocabularyDeepLink.scope(forWorkflowNamed: "   ", availableScopes: ["A"]))
    }

    /// Matching is on the trimmed name, so a workflow saved with stray whitespace around
    /// its name still lands on its own terms rather than silently on the global table.
    func test_the_name_is_trimmed_before_matching() {
        XCTAssertEqual(
            VocabularyDeepLink.scope(forWorkflowNamed: "  Client work  ",
                                     availableScopes: ["Client work"]),
            "Client work"
        )
    }

    /// The deep-link slot starts empty, so a Preferences window opened by hand never
    /// arrives carrying a scope request left over from something else.
    func test_the_selection_state_starts_with_no_pending_scope() {
        XCTAssertNil(PreferencesSelectionState().pendingVocabularyScope)
    }
}
