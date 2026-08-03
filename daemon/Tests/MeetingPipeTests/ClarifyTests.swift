import XCTest
@testable import MeetingPipe

/// FEAT13: clarifying a misheard word from the transcript rather than from Preferences.
///
/// The suite is organised around the one thing the task exists to protect: **a
/// per-meeting text fix and a global vocabulary rule are different in kind, and Clarify
/// must never blur them.** So the plan is a value with one case per destination, and most
/// of what follows is about which file a given confirm may touch and which it may not.
///
/// The other invariant, carried from FEAT11 through FEAT12: **nothing is written until
/// the user confirms.** `test_opening_and_dismissing_writes_neither_file` states that as
/// a fact about the code by pinning both files byte-for-byte across the whole sheet
/// lifecycle. The reason it is worth a test rather than a comment is on the record:
/// FEAT11's walkthrough meeting contained "Venusaur", an invented word neither the owner
/// nor the session could decode, and an affordance that wrote on selection would have
/// turned it into a permanent rule rewriting every future transcript on a guess.
final class ClarifyTests: XCTestCase {

    private let line = "we deployed to the sitting environment on Friday"

    // MARK: - The two destinations stay distinct

    func test_fixing_this_line_writes_a_correction_and_never_a_term() {
        let plan = Clarify.plan(
            segmentIndex: 7,
            line: line,
            heard: "sitting environment",
            intended: "staging environment",
            destination: .thisLine,
            scope: "Client work",
            retranscribe: true
        )
        // A scope and a re-transcribe were both supplied, and both are ignored: they
        // belong to the other destination. A plan that carried them would be one
        // refactor away from writing a term nobody asked for.
        XCTAssertEqual(
            plan,
            .correctLine(segmentIndex: 7, newText: "we deployed to the staging environment on Friday")
        )
    }

    func test_the_rule_writes_a_term_and_never_a_correction() {
        XCTAssertEqual(
            Clarify.plan(
                segmentIndex: 7,
                line: line,
                heard: "sitting environment",
                intended: "staging environment",
                destination: .everyMeeting,
                scope: "Client work",
                retranscribe: false
            ),
            .addTerm(
                heard: "sitting environment",
                canonical: "staging environment",
                workflow: "Client work",
                retranscribe: false
            )
        )
    }

    func test_only_the_rule_path_offers_a_rebuild() {
        // The asymmetry the spec asked for, pinned rather than left to the view: a
        // correction overlay is applied at load time so the line reads correctly the
        // moment it is written, while a new term reaches an existing transcript only
        // through a re-transcribe.
        XCTAssertFalse(Clarify.Destination.thisLine.offersRetranscribe)
        XCTAssertTrue(Clarify.Destination.everyMeeting.offersRetranscribe)
    }

    func test_the_destinations_are_distinguishable_before_the_explanation_is_read() {
        // The picker is the last control read before a confirm, so each title has to
        // carry the blast radius on its own.
        XCTAssertEqual(Clarify.Destination.thisLine.title, "Fix this line only")
        XCTAssertEqual(Clarify.Destination.everyMeeting.title, "Always fix this")
        XCTAssertNotEqual(
            Clarify.Destination.thisLine.confirmTitle,
            Clarify.Destination.everyMeeting.confirmTitle,
            "the confirm button names the consequence, so the two cannot share a label"
        )
        XCTAssertTrue(Clarify.Destination.thisLine.explanation.contains("this one line"))
        XCTAssertTrue(Clarify.Destination.everyMeeting.explanation.contains("Every transcript"))
    }

    func test_no_user_facing_string_reaches_for_the_code_words() {
        // The same fence `VocabularyEditorTests` puts on the Preferences editor, for the
        // same audience and the same failure mode: a later session reaching for the term
        // that is natural in the code. This copy is the only thing standing between a
        // one-line fix and a permanent rule, so it has to read plainly.
        let strings = Clarify.Destination.allCases.flatMap {
            [$0.title, $0.explanation, $0.confirmTitle]
        }
        for line in strings {
            for word in ["ASR", "glossary", "overlay", "segment", "sidecar"] {
                XCTAssertFalse(
                    line.lowercased().contains(word.lowercased()),
                    "user-facing copy says \"\(word)\": \(line)"
                )
            }
        }
        XCTAssertTrue(
            Clarify.Destination.everyMeeting.explanation.contains("Vocabulary"),
            "the rule path must name the list the user will find the term in"
        )
    }

    func test_the_rebuild_choice_rides_the_rule_plan() {
        guard case .addTerm(_, _, _, let retranscribe) = Clarify.plan(
            segmentIndex: 0, line: line, heard: "sitting", intended: "staging",
            destination: .everyMeeting, scope: nil, retranscribe: true
        ) else { return XCTFail("expected a term") }
        XCTAssertTrue(retranscribe)
    }

    // MARK: - What it refuses

    func test_an_empty_side_is_no_plan() {
        for (heard, intended) in [("", "staging"), ("sitting", ""), ("  ", " ")] {
            for destination in Clarify.Destination.allCases {
                XCTAssertNil(
                    Clarify.plan(
                        segmentIndex: 0, line: line, heard: heard, intended: intended,
                        destination: destination, scope: nil, retranscribe: false
                    ),
                    "\(destination) accepted \(heard.isEmpty ? "an empty heard" : "an empty intended")"
                )
            }
        }
    }

    func test_the_same_word_on_both_sides_is_no_plan() {
        for destination in Clarify.Destination.allCases {
            XCTAssertNil(
                Clarify.plan(
                    segmentIndex: 0, line: line, heard: "sitting", intended: "sitting",
                    destination: destination, scope: nil, retranscribe: false
                )
            )
        }
    }

    func test_a_capitalization_fix_is_still_a_plan() {
        // The FEAT12 rule, restated here because the two surfaces write the same file:
        // keys are folded at match time and values are not, so this substitution really
        // does something to every future transcript.
        XCTAssertEqual(
            Clarify.plan(
                segmentIndex: 3, line: "we run kubernetes here", heard: "kubernetes",
                intended: "Kubernetes", destination: .thisLine, scope: nil, retranscribe: false
            ),
            .correctLine(segmentIndex: 3, newText: "we run Kubernetes here")
        )
    }

    func test_a_line_fix_for_wording_that_is_not_in_the_line_is_no_plan() {
        // Otherwise Clarify writes an overlay entry that changes nothing, which then
        // turns up in a re-transcribe's carry report as work to preserve.
        XCTAssertNil(
            Clarify.plan(
                segmentIndex: 0, line: line, heard: "venusaur", intended: "Vinicius",
                destination: .thisLine, scope: nil, retranscribe: false
            )
        )
    }

    func test_the_rule_does_not_require_the_wording_to_be_in_this_line() {
        // Deliberately permissive where the line path is strict. A glossary term is
        // global, and a user who retyped the heard side into the spelling they know the
        // transcriber produces elsewhere is doing the right thing.
        XCTAssertEqual(
            Clarify.plan(
                segmentIndex: 0, line: line, heard: "venusaur", intended: "Vinicius",
                destination: .everyMeeting, scope: nil, retranscribe: false
            ),
            .addTerm(heard: "venusaur", canonical: "Vinicius", workflow: nil, retranscribe: false)
        )
    }

    // MARK: - Substitution matches the pipeline

    func test_substitution_is_whole_word_and_case_insensitive_like_the_pipeline() {
        // `mp.glossary` compiles `\b(<keys>)\b` case-insensitively, so "Fix this line
        // only" has to be a faithful preview of what the rule would do to this line
        // after a rebuild.
        XCTAssertEqual(
            Clarify.substitute(heard: "sitting", with: "staging", in: "Sitting is sitting"),
            "staging is staging"
        )
        XCTAssertNil(
            Clarify.substitute(heard: "sit", with: "staging", in: "we were sitting there"),
            "a substring inside a longer word is not a whole-word match"
        )
    }

    func test_substitution_replaces_every_occurrence() {
        XCTAssertEqual(
            Clarify.substitute(heard: "acme", with: "ACME", in: "acme and acme again"),
            "ACME and ACME again"
        )
    }

    func test_a_regex_metacharacter_is_matched_literally() {
        // The heard side is typed by a person, not written as a pattern.
        XCTAssertEqual(
            Clarify.substitute(heard: "node.js", with: "Node.js", in: "we ship node.js on Friday"),
            "we ship Node.js on Friday"
        )
        XCTAssertNil(
            Clarify.substitute(heard: "s.tting", with: "staging", in: line),
            "an unescaped dot here would have matched 'sitting'"
        )
    }

    func test_wording_ending_in_punctuation_matches_nothing_here_or_in_the_pipeline() {
        // A limitation inherited on purpose, and pinned so nobody "fixes" it in isolation.
        // `\b` is a word-boundary, so a key ending in `+` can only match where a word
        // character follows, which in real prose it never does. `mp.glossary` compiles
        // the same `\b(<key>)\b` (glossary.py:70), so such a term would sit in
        // `glossary.toml` firing on nothing. Making the line path cleverer than the rule
        // path would be worse than the limitation: "Fix this line only" would then fix a
        // line that "Always fix this" could never fix, which is exactly the confusion
        // between the two blast radii that this task exists to prevent.
        XCTAssertNil(Clarify.substitute(heard: "c++", with: "C plus plus", in: "we wrote it in c++ back then"))
    }

    func test_a_dollar_in_the_replacement_is_not_a_capture_reference() {
        XCTAssertEqual(
            Clarify.substitute(heard: "dollars", with: "$5", in: "it cost dollars"),
            "it cost $5"
        )
    }

    func test_outer_punctuation_is_trimmed_off_the_heard_side() {
        // The same normalisation FEAT12 applies, because both surfaces write keys into
        // the same file and the pipeline matches whole words: a key carrying an outer
        // quote would never fire.
        XCTAssertEqual(
            Clarify.plan(
                segmentIndex: 1, line: "he said \"venusaur\" twice", heard: "\"venusaur\"",
                intended: "Vinicius", destination: .everyMeeting, scope: nil, retranscribe: false
            ),
            .addTerm(heard: "venusaur", canonical: "Vinicius", workflow: nil, retranscribe: false)
        )
    }

    // MARK: - Scope

    func test_the_rule_defaults_to_the_meetings_workflow_and_can_be_widened() {
        XCTAssertEqual(Clarify.defaultScope(workflowName: "Client work"), "Client work")
        XCTAssertNil(Clarify.defaultScope(workflowName: nil))
        XCTAssertNil(
            Clarify.defaultScope(workflowName: "   "),
            "a blank workflow name is no workflow, matching VocabularyOffer.make"
        )
        // Widening is a plain choice the sheet passes through, not a separate rule.
        XCTAssertEqual(
            Clarify.plan(
                segmentIndex: 0, line: line, heard: "sitting", intended: "staging",
                destination: .everyMeeting, scope: nil, retranscribe: false
            ),
            .addTerm(heard: "sitting", canonical: "staging", workflow: nil, retranscribe: false)
        )
    }

    // MARK: - The pre-fill rule, on the bytes

    func test_opening_and_dismissing_writes_neither_file() throws {
        // The step of the owner walkthrough that matters most, as a test. Every plan the
        // sheet could hold is built here, including ones for both destinations, and
        // neither file moves: `Clarify` does no I/O at all, so only a confirm handler can
        // write. This is the Venusaur case, where the right outcome is walking away.
        let dir = try makeTempDir()
        let glossary = dir.appendingPathComponent("glossary.toml")
        let glossaryBefore = """
        [terms]
        "acme" = "ACME"

        [fuzzy]
        enabled = true
        """
        try glossaryBefore.write(to: glossary, atomically: true, encoding: .utf8)

        let stem = "20260723-103118"
        try TranscriptCorrectionStore.upsert(
            segmentIndex: 2, pipelineOriginal: "before", edited: "after", stem: stem, in: dir
        )
        let correctionsURL = TranscriptCorrectionStore.path(stem: stem, in: dir)
        let correctionsBefore = try Data(contentsOf: correctionsURL)

        for destination in Clarify.Destination.allCases {
            _ = Clarify.plan(
                segmentIndex: 7, line: line, heard: "sitting environment",
                intended: "staging environment", destination: destination,
                scope: "Client work", retranscribe: true
            )
        }
        _ = Clarify.substitute(heard: "sitting", with: "staging", in: line)
        _ = Clarify.defaultScope(workflowName: "Client work")

        XCTAssertEqual(try String(contentsOf: glossary, encoding: .utf8), glossaryBefore)
        XCTAssertEqual(try Data(contentsOf: correctionsURL), correctionsBefore)
    }

    // MARK: - Confirming reaches the same writers the other surfaces use

    func test_confirming_a_line_fix_writes_only_the_correction_overlay() throws {
        let dir = try makeTempDir()
        let glossary = dir.appendingPathComponent("glossary.toml")
        let glossaryBefore = """
        [terms]
        "acme" = "ACME"
        """
        try glossaryBefore.write(to: glossary, atomically: true, encoding: .utf8)
        let stem = "20260723-103118"

        guard case .correctLine(let index, let newText)? = Clarify.plan(
            segmentIndex: 7, line: line, heard: "sitting", intended: "staging",
            destination: .thisLine, scope: "Client work", retranscribe: true
        ) else { return XCTFail("expected a line fix") }
        try TranscriptCorrectionStore.upsert(
            segmentIndex: index, pipelineOriginal: line, edited: newText, stem: stem, in: dir
        )

        XCTAssertEqual(
            TranscriptCorrectionStore.read(stem: stem, in: dir)[7]?.editedText,
            "we deployed to the staging environment on Friday"
        )
        XCTAssertEqual(
            try String(contentsOf: glossary, encoding: .utf8), glossaryBefore,
            "the per-meeting path must leave the vocabulary alone"
        )
    }

    func test_confirming_a_rule_writes_only_the_glossary_term() throws {
        let dir = try makeTempDir()
        let glossary = dir.appendingPathComponent("glossary.toml")
        try """
        [terms]
        "acme" = "ACME"

        [fuzzy]
        enabled = true
        """.write(to: glossary, atomically: true, encoding: .utf8)
        let stem = "20260723-103118"

        guard case .addTerm(let heard, let canonical, let workflow, _)? = Clarify.plan(
            segmentIndex: 7, line: line, heard: "sitting environment",
            intended: "staging environment", destination: .everyMeeting,
            scope: "Client work", retranscribe: false
        ) else { return XCTFail("expected a term") }
        // The same one writer FEAT11's editor and FEAT12's offer both ride, which is what
        // keeps `[fuzzy]` and every unmodeled key alive across an add.
        try GlossaryStore(fileURL: glossary).addTerm(
            heard: heard, canonical: canonical, workflow: workflow
        )

        XCTAssertEqual(
            GlossaryStore.resolvedTerms(at: glossary, workflowName: "Client work"),
            ["acme": "ACME", "sitting environment": "staging environment"]
        )
        XCTAssertTrue(try String(contentsOf: glossary, encoding: .utf8).contains("[fuzzy]"))
        XCTAssertFalse(
            FileManager.default.fileExists(
                atPath: TranscriptCorrectionStore.path(stem: stem, in: dir).path
            ),
            "the rule path must not also write the per-meeting overlay: an overlay laid over a term makes a rule that never matched look like it worked"
        )
    }

    func test_a_term_added_here_resolves_like_one_typed_in_preferences() throws {
        // The CI4 parity clause: whichever surface added it, `GlossaryStore.resolvedTerms`
        // (the `mp.glossary` mirror) has to see the same thing.
        let viaClarify = try makeTempDir().appendingPathComponent("glossary.toml")
        let viaPreferences = try makeTempDir().appendingPathComponent("glossary.toml")

        guard case .addTerm(let heard, let canonical, let workflow, _)? = Clarify.plan(
            segmentIndex: 0, line: line, heard: "Sitting Environment ",
            intended: "staging environment", destination: .everyMeeting,
            scope: nil, retranscribe: false
        ) else { return XCTFail("expected a term") }
        try GlossaryStore(fileURL: viaClarify).addTerm(
            heard: heard, canonical: canonical, workflow: workflow
        )

        let editor = GlossaryStore(fileURL: viaPreferences)
        editor.globalTerms = [
            GlossaryTerm(heard: "Sitting Environment", canonical: "staging environment")
        ]
        try editor.saveNow()

        XCTAssertEqual(
            GlossaryStore.resolvedTerms(at: viaClarify, workflowName: nil),
            GlossaryStore.resolvedTerms(at: viaPreferences, workflowName: nil)
        )
    }

    // MARK: - helpers

    private func makeTempDir() throws -> URL {
        let dir = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("mp-feat13-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: dir) }
        return dir
    }
}
