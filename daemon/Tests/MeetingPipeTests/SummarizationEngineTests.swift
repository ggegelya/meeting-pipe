import XCTest
@testable import MeetingPipe

/// UX31 coverage fence: every summarization backend the product ships is named,
/// once, in every register a surface renders.
///
/// The defect these exist to prevent is not a typo, it is a forgotten edit.
/// `claude_cli` and `openai` shipped end to end in the pipeline and were
/// selectable in Preferences, but the six other label sites were six independent
/// switch tables nobody was prompted to update, so an OpenAI meeting showed no
/// engine at all and Ask printed the raw config id. A seventh backend now fails
/// here instead of in the field.
final class SummarizationEngineTests: XCTestCase {

    // MARK: - Every engine, every register

    func test_every_engine_is_named_in_every_register() {
        for engine in SummarizationEngine.all {
            XCTAssertFalse(engine.id.isEmpty, "an engine with no id")
            XCTAssertFalse(engine.name.isEmpty, "\(engine.id) has no name")
            XCTAssertFalse(engine.whereItRuns.isEmpty, "\(engine.id) does not say where it runs")
            XCTAssertFalse(engine.qualified.isEmpty, "\(engine.id) has no qualified label")
            XCTAssertFalse(engine.pickerLabel.isEmpty, "\(engine.id) has no picker label")
            XCTAssertFalse(engine.runPhrase.isEmpty, "\(engine.id) has no present-tense phrase")
        }
    }

    /// The `openai` meeting bug in miniature: a register that falls through to
    /// the id renders "Answered via claude_cli" at the user. No register may
    /// contain the id, and no id-shaped token (snake_case) may appear at all.
    func test_no_register_renders_a_raw_config_id() {
        for engine in SummarizationEngine.all {
            for (register, value) in [
                ("name", engine.name),
                ("whereItRuns", engine.whereItRuns),
                ("qualified", engine.qualified),
                ("pickerLabel", engine.pickerLabel),
                ("runPhrase", engine.runPhrase),
            ] {
                XCTAssertFalse(
                    value.contains(engine.id),
                    "\(engine.id).\(register) renders the raw config id: \(value)"
                )
                XCTAssertFalse(
                    value.contains("_"),
                    "\(engine.id).\(register) looks like a config id, not a name: \(value)"
                )
            }
        }
    }

    func test_ids_are_unique_and_resolve_round_trips() {
        let ids = SummarizationEngine.all.map(\.id)
        XCTAssertEqual(Set(ids).count, ids.count, "two engines share an id")
        for engine in SummarizationEngine.all {
            XCTAssertEqual(SummarizationEngine.resolve(engine.id), engine)
        }
    }

    /// Nil is the deliberate behaviour, not a gap: a legacy / paste / skipped
    /// meeting records no backend, and `mp summarize` writes `"unknown"` when it
    /// cannot attribute a run. Both hide the provenance row rather than inventing
    /// a name for it.
    func test_resolve_is_nil_for_an_absent_or_unknown_id() {
        XCTAssertNil(SummarizationEngine.resolve(nil))
        XCTAssertNil(SummarizationEngine.resolve(""))
        XCTAssertNil(SummarizationEngine.resolve("unknown"))
        XCTAssertNil(SummarizationEngine.resolve("something_new"))
        XCTAssertNil(SummarizationEngine.resolve("Anthropic"), "resolution is by id, not by name")
    }

    // MARK: - The vocabulary the owner settled, 2026-07-28

    func test_the_settled_names() {
        XCTAssertEqual(SummarizationEngine.anthropic.name, "Anthropic")
        XCTAssertEqual(SummarizationEngine.openai.name, "OpenAI")
        // The one exception to the vendor rule: the binary it shells, not an API.
        XCTAssertEqual(SummarizationEngine.claudeCLI.name, "Claude CLI")
        XCTAssertEqual(SummarizationEngine.appleIntelligence.name, "Apple Intelligence")
        XCTAssertEqual(SummarizationEngine.local.name, "Local MLX")
        XCTAssertEqual(SummarizationEngine.auto.name, "Auto")
    }

    func test_the_qualifier_says_where_the_transcript_goes() {
        XCTAssertEqual(SummarizationEngine.anthropic.qualified, "Anthropic (cloud)")
        XCTAssertEqual(SummarizationEngine.openai.qualified, "OpenAI (cloud)")
        // A cloud backend despite the local binary: it egresses through a child
        // process, which is why `effective_backend` forces local for it under a
        // regulated or NDA run.
        XCTAssertEqual(SummarizationEngine.claudeCLI.qualified, "Claude CLI (cloud)")
        XCTAssertEqual(SummarizationEngine.local.qualified, "Local MLX (on-device)")
        XCTAssertEqual(
            SummarizationEngine.appleIntelligence.qualified, "Apple Intelligence (on-device)"
        )
    }

    /// A picker row is an identity, so it carries the bare name. `auto` is the
    /// exception, because "cloud, fall back to local" is behaviour and a picker
    /// is the register with room to explain it.
    func test_a_picker_shows_the_bare_name_except_for_auto() {
        XCTAssertEqual(SummarizationEngine.anthropic.pickerLabel, "Anthropic")
        XCTAssertEqual(SummarizationEngine.local.pickerLabel, "Local MLX")
        XCTAssertEqual(SummarizationEngine.appleIntelligence.pickerLabel, "Apple Intelligence")
        XCTAssertEqual(SummarizationEngine.claudeCLI.pickerLabel, "Claude CLI")
        XCTAssertEqual(SummarizationEngine.openai.pickerLabel, "OpenAI")
        XCTAssertEqual(SummarizationEngine.auto.pickerLabel, "Auto (cloud, fall back to local)")
    }

    /// One phrase serves both present-tense lines, so the busy chip and the Ask
    /// footer cannot describe the same run differently.
    func test_the_present_tense_phrase_says_where_for_on_device_and_which_for_cloud() {
        XCTAssertEqual("Summarizing \(SummarizationEngine.anthropic.runPhrase)", "Summarizing with Anthropic")
        XCTAssertEqual("Summarizing \(SummarizationEngine.local.runPhrase)", "Summarizing on-device")
        XCTAssertEqual(
            "Summarizing \(SummarizationEngine.appleIntelligence.runPhrase)", "Summarizing on-device"
        )
        XCTAssertEqual("Answered \(SummarizationEngine.claudeCLI.runPhrase)", "Answered with Claude CLI")
        XCTAssertEqual("Answered \(SummarizationEngine.openai.runPhrase)", "Answered with OpenAI")
    }

    // MARK: - The pickers read the vocabulary, they do not restate it

    /// The acceptance fence: every id the global backend picker offers resolves,
    /// and resolves to a non-empty label in every register. This is the exact
    /// hole `claude_cli` and `openai` fell through, offered here and named
    /// nowhere else.
    func test_every_id_the_preferences_picker_offers_is_fully_named() {
        XCTAssertFalse(PipelineSectionView.backendOptions.isEmpty)
        for option in PipelineSectionView.backendOptions {
            guard let engine = SummarizationEngine.resolve(option.value) else {
                return XCTFail("Preferences offers backend '\(option.value)' with no entry in SummarizationEngine.all")
            }
            XCTAssertEqual(option.label, engine.pickerLabel)
            XCTAssertFalse(engine.qualified.isEmpty)
            XCTAssertFalse(engine.runPhrase.isEmpty)
        }
    }

    /// The two vocabularies stay in lockstep. Before UX31 the enum modelled four
    /// of the six ids, so a workflow could not pin two backends the global
    /// setting offered, and `WorkflowInspector` had no name for them either.
    func test_every_shipped_engine_is_pinnable_by_a_workflow() {
        XCTAssertEqual(
            Set(WorkflowBackend.allCases.map(\.rawValue)),
            Set(SummarizationEngine.all.map(\.id)),
            "a backend named in one vocabulary and absent from the other"
        )
    }

    func test_the_workflow_picker_offers_the_inherit_row_plus_every_pinnable_backend() {
        let options = WorkflowEditor.backendOptions
        XCTAssertNil(options.first?.value, "the inherit row leads")
        XCTAssertEqual(options.first?.label, "Use global default")
        XCTAssertEqual(
            options.dropFirst().compactMap { $0.value?.rawValue },
            WorkflowBackend.allCases.map(\.rawValue)
        )
        for option in options.dropFirst() {
            guard let backend = option.value else { return XCTFail("a nil pin past the inherit row") }
            XCTAssertEqual(option.label, backend.engine.pickerLabel)
        }
    }

    func test_a_pinned_backend_maps_to_its_engine() {
        for backend in WorkflowBackend.allCases {
            XCTAssertEqual(backend.engine.id, backend.rawValue)
        }
    }

    // MARK: - The surfaces

    /// The reported defect: the detail header and the `...` menu over it are on
    /// screen together and named the same backend differently.
    func test_the_provenance_line_and_the_re_summarize_menu_agree_on_anthropic() {
        XCTAssertEqual(
            SummarizationEngine.anthropic.qualified,
            SummarizationEngine.resolve("anthropic")?.qualified
        )
        XCTAssertEqual(SummarizationEngine.anthropic.qualified, "Anthropic (cloud)")
    }

    func test_the_workflow_inspector_reads_the_shared_vocabulary() {
        XCTAssertEqual(inspector(pinning: .anthropic).backendLine, "Anthropic (cloud)")
        XCTAssertEqual(inspector(pinning: .openai).backendLine, "OpenAI (cloud)")
        XCTAssertEqual(inspector(pinning: .claudeCLI).backendLine, "Claude CLI (cloud)")
        XCTAssertEqual(inspector(pinning: .local).backendLine, "Local MLX (on-device)")
        XCTAssertEqual(inspector(pinning: nil).backendLine, "Global default")
        // NDA forces local whatever the pin says, and the row has to report the
        // engine that will actually run.
        XCTAssertEqual(inspector(pinning: .anthropic, nda: true).backendLine, "Local MLX (on-device)")
    }

    func test_the_busy_line_names_every_engine_a_re_run_can_request() {
        XCTAssertEqual(
            LibraryRun(verb: .regenerate, stem: "m", backend: "claude_cli").progressLabel,
            "Summarizing with Claude CLI"
        )
        XCTAssertEqual(
            LibraryRun(verb: .regenerate, stem: "m", backend: "openai").progressLabel,
            "Summarizing with OpenAI"
        )
        // An id this build cannot name is not guessed at.
        XCTAssertEqual(
            LibraryRun(verb: .regenerate, stem: "m", backend: "something_new").progressLabel,
            "Summarizing"
        )
    }

    /// Ask used to interpolate the raw id, so a Claude Code answer read
    /// "Answered via claude_cli". It now names the engine, or says nothing.
    func test_the_ask_footer_names_the_engine_and_never_the_config_id() {
        XCTAssertEqual(AskView.backendFooter("anthropic"), "Answered with Anthropic")
        XCTAssertEqual(AskView.backendFooter("claude_cli"), "Answered with Claude CLI")
        XCTAssertEqual(AskView.backendFooter("openai"), "Answered with OpenAI")
        XCTAssertEqual(AskView.backendFooter("local"), "Answered on-device")
        XCTAssertEqual(AskView.backendFooter("apple_intelligence"), "Answered on-device")
        XCTAssertNil(AskView.backendFooter(nil))
        XCTAssertNil(AskView.backendFooter("something_new"))
    }

    // MARK: - helpers

    private func inspector(pinning backend: WorkflowBackend?, nda: Bool = false) -> WorkflowInspector {
        WorkflowInspector(
            workflow: Workflow(
                name: "Client work",
                backend: backend,
                flags: WorkflowFlags(ndaMode: nda)
            ),
            recentMeetings: [],
            onEdit: {}
        )
    }
}
