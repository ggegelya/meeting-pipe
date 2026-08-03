import XCTest
@testable import MeetingPipe

/// FEAT11: the in-app Vocabulary editor writes a file the pipeline owns the meaning of,
/// so the store has two jobs it must not get wrong. It has to round-trip everything it
/// does not model (dropping a key would turn a live pipeline setting off behind the
/// user's back; since UX44 the modeled surface includes `[fuzzy].enabled`, so the
/// guarantee now has to hold key by key inside that table, not just table by table), and
/// it has to resolve terms exactly as `mp.glossary` does. That second job is pinned by
/// `Fixtures/glossary-golden.json` in `CI4ContractFixtureTests`; this suite covers the
/// editing behaviour that has no Python counterpart.
final class GlossaryStoreTests: XCTestCase {

    private func makeTempURL() throws -> URL {
        let dir = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("mp-glossary-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: dir) }
        return dir.appendingPathComponent("glossary.toml")
    }

    private func write(_ toml: String, to url: URL) throws {
        try toml.write(to: url, atomically: true, encoding: .utf8)
    }

    // MARK: - Loading

    func test_a_missing_file_loads_empty_and_is_writable() throws {
        let url = try makeTempURL()
        let store = GlossaryStore(fileURL: url)
        XCTAssertTrue(store.globalTerms.isEmpty)

        // The owner's Mac had no glossary.toml at all, which is the state this has to
        // start from: the first term typed creates the file.
        store.globalTerms = [GlossaryTerm(heard: "venusaur", canonical: "Vinicius")]
        try store.saveNow()
        XCTAssertEqual(
            GlossaryStore.resolvedTerms(at: url, workflowName: nil),
            ["venusaur": "Vinicius"]
        )
    }

    func test_a_malformed_file_loads_empty_rather_than_throwing() throws {
        let url = try makeTempURL()
        try write("this is not = = toml", to: url)
        // `load_glossary` logs and returns an empty glossary for the same input, so the
        // editor must not be the one surface that hard-fails on it.
        XCTAssertTrue(GlossaryStore(fileURL: url).globalTerms.isEmpty)
    }

    func test_existing_terms_load_as_rows() throws {
        let url = try makeTempURL()
        try write("""
        [terms]
        "kubernetes" = "Kubernetes"
        "post gres" = "PostgreSQL"
        """, to: url)

        let store = GlossaryStore(fileURL: url)
        XCTAssertEqual(store.globalTerms.count, 2)
        XCTAssertEqual(
            Set(store.globalTerms.map(\.heard)), ["kubernetes", "post gres"]
        )
    }

    // MARK: - Round-trip

    func test_removing_a_row_removes_the_key() throws {
        let url = try makeTempURL()
        try write("""
        [terms]
        "kubernetes" = "Kubernetes"
        "grafana" = "Grafana"
        """, to: url)

        let store = GlossaryStore(fileURL: url)
        store.globalTerms.removeAll { $0.heard == "grafana" }
        try store.saveNow()

        XCTAssertEqual(
            GlossaryStore.resolvedTerms(at: url, workflowName: nil),
            ["kubernetes": "Kubernetes"]
        )
    }

    func test_a_half_typed_row_is_not_written() throws {
        let url = try makeTempURL()
        let store = GlossaryStore(fileURL: url)
        // Exactly the state the editor is in the moment "Add term" is pressed. Writing
        // it would put an empty key in a file the pipeline reads; `_merge_terms` would
        // skip it anyway, but the file should not carry it either.
        store.globalTerms = [
            GlossaryTerm(heard: "  ", canonical: "Kubernetes"),
            GlossaryTerm(heard: "grafana", canonical: ""),
            GlossaryTerm(heard: "acme", canonical: "ACME"),
        ]
        try store.saveNow()

        XCTAssertEqual(
            GlossaryStore.resolvedTerms(at: url, workflowName: nil), ["acme": "ACME"]
        )
    }

    func test_a_key_is_trimmed_but_kept_as_typed_otherwise() throws {
        let url = try makeTempURL()
        let store = GlossaryStore(fileURL: url)
        store.globalTerms = [GlossaryTerm(heard: "  PS for Venusaur  ", canonical: "PS for Vinicius")]
        try store.saveNow()

        // Trimmed on write, lower-cased only at match time (both sides do that), so the
        // resolved key is the folded form and the file keeps the reader's spelling.
        XCTAssertEqual(
            GlossaryStore.resolvedTerms(at: url, workflowName: nil),
            ["ps for venusaur": "PS for Vinicius"]
        )
        let text = try String(contentsOf: url, encoding: .utf8)
        XCTAssertTrue(text.contains("PS for Venusaur"), text)
    }

    func test_two_rows_differing_only_in_case_collapse_to_one_key() throws {
        let url = try makeTempURL()
        let store = GlossaryStore(fileURL: url)
        // Both sides fold the key, so a file carrying both spellings is ambiguous about
        // which wins. The editor refuses to create that: last row wins, one key out.
        store.globalTerms = [
            GlossaryTerm(heard: "Kubernetes", canonical: "wrong"),
            GlossaryTerm(heard: "kubernetes", canonical: "Kubernetes"),
        ]
        try store.saveNow()

        XCTAssertEqual(
            GlossaryStore.resolvedTerms(at: url, workflowName: nil),
            ["kubernetes": "Kubernetes"]
        )
        let text = try String(contentsOf: url, encoding: .utf8)
        XCTAssertFalse(text.contains("wrong"), text)
    }

    // MARK: - Scopes

    func test_workflow_scope_writes_only_that_workflows_table() throws {
        let url = try makeTempURL()
        try write("""
        [terms]
        "acme" = "ACME"

        [workflow."Other".terms]
        "ps" = "Other PS"
        """, to: url)

        let store = GlossaryStore(fileURL: url)
        store.selectWorkflow("Client work")
        XCTAssertTrue(store.workflowTerms.isEmpty, "a fresh workflow starts with no terms of its own")
        store.workflowTerms = [GlossaryTerm(heard: "ps", canonical: "PS Corp")]
        try store.saveNow()

        XCTAssertEqual(
            GlossaryStore.resolvedTerms(at: url, workflowName: "Client work"),
            ["acme": "ACME", "ps": "PS Corp"]
        )
        // The workflow the editor was not showing is untouched.
        XCTAssertEqual(
            GlossaryStore.resolvedTerms(at: url, workflowName: "Other"),
            ["acme": "ACME", "ps": "Other PS"]
        )
        XCTAssertEqual(
            GlossaryStore.resolvedTerms(at: url, workflowName: nil), ["acme": "ACME"]
        )
    }

    func test_switching_scope_keeps_the_edit_that_had_not_been_saved_yet() throws {
        let url = try makeTempURL()
        let store = GlossaryStore(fileURL: url)
        store.selectWorkflow("Client work")
        store.workflowTerms = [GlossaryTerm(heard: "ps", canonical: "PS Corp")]
        // The 500 ms debounce has not fired; switching scopes must fold the edit into
        // the document rather than reload over the top of it.
        store.selectWorkflow(nil)
        try store.saveNow()

        XCTAssertEqual(
            GlossaryStore.resolvedTerms(at: url, workflowName: "Client work"),
            ["ps": "PS Corp"]
        )
    }

    func test_selecting_a_workflow_loads_its_existing_terms() throws {
        let url = try makeTempURL()
        try write("""
        [workflow."Client work".terms]
        "ps" = "PS Corp"
        """, to: url)

        let store = GlossaryStore(fileURL: url)
        store.selectWorkflow("Client work")
        XCTAssertEqual(store.workflowTerms.map(\.heard), ["ps"])
        XCTAssertEqual(store.workflowTerms.map(\.canonical), ["PS Corp"])
    }

    // MARK: - Fuzzy (UX44)

    func test_fuzzy_enabled_loads_from_the_file() throws {
        let url = try makeTempURL()
        try write("""
        [fuzzy]
        enabled = true
        max_distance = 2
        """, to: url)

        XCTAssertTrue(GlossaryStore(fileURL: url).fuzzyEnabled)
    }

    func test_fuzzy_defaults_off_when_the_table_is_absent() throws {
        let url = try makeTempURL()
        try write("""
        [terms]
        "acme" = "ACME"
        """, to: url)

        // Same default as `load_glossary`: `bool(fuzzy.get("enabled", False))`. A knob
        // that turned itself on because nobody wrote it down would be the wrong side of
        // "a wrong substitution is worse than a missed one".
        XCTAssertFalse(GlossaryStore(fileURL: url).fuzzyEnabled)
    }

    /// The one that matters. UX44 modeled exactly one key inside `[fuzzy]`, so the
    /// blind-preservation guarantee had to survive at the key level rather than the
    /// table level: turning the toggle on must not be the write that eats a
    /// `max_distance` the owner hand-tuned, or a key a later pipeline version adds.
    func test_toggling_fuzzy_preserves_max_distance_and_unknown_keys() throws {
        let url = try makeTempURL()
        try write("""
        [terms]
        "acme" = "ACME"

        [fuzzy]
        enabled = false
        max_distance = 3
        future_knob = "keep me"
        """, to: url)

        let store = GlossaryStore(fileURL: url)
        XCTAssertFalse(store.fuzzyEnabled)
        store.fuzzyEnabled = true
        try store.saveNow()

        let rewritten = try String(contentsOf: url, encoding: .utf8)
        XCTAssertTrue(rewritten.contains("enabled = true"), rewritten)
        XCTAssertTrue(rewritten.contains("max_distance = 3"), rewritten)
        XCTAssertTrue(rewritten.contains("keep me"), rewritten)
        // And the terms table is untouched by a fuzzy-only edit.
        XCTAssertEqual(
            GlossaryStore.resolvedTerms(at: url, workflowName: nil), ["acme": "ACME"]
        )
    }

    func test_fuzzy_round_trips_back_off_again() throws {
        let url = try makeTempURL()
        try write("""
        [fuzzy]
        enabled = true
        max_distance = 2
        """, to: url)

        let store = GlossaryStore(fileURL: url)
        store.fuzzyEnabled = false
        try store.saveNow()

        XCTAssertFalse(GlossaryStore(fileURL: url).fuzzyEnabled)
        XCTAssertTrue(try String(contentsOf: url, encoding: .utf8).contains("max_distance = 2"))
    }

    /// A term edit alone writes the toggle's current value rather than leaving the key
    /// absent, so the file states the knob it is subject to. On a file that never had a
    /// `[fuzzy]` table this creates one holding `enabled = false`, which changes nothing
    /// the pipeline does (that is already the default) and makes the knob findable by
    /// hand, the way `[terms]` has always been created here.
    func test_a_term_edit_writes_the_fuzzy_key_on_a_file_that_had_none() throws {
        let url = try makeTempURL()
        let store = GlossaryStore(fileURL: url)
        store.globalTerms = [GlossaryTerm(heard: "acme", canonical: "ACME")]
        try store.saveNow()

        let text = try String(contentsOf: url, encoding: .utf8)
        XCTAssertTrue(text.contains("[fuzzy]"), text)
        XCTAssertTrue(text.contains("enabled = false"), text)
        XCTAssertFalse(GlossaryStore(fileURL: url).fuzzyEnabled)
    }

    // MARK: - Live rows

    func test_live_terms_drops_blanks_and_dedupes_last_wins() {
        let rows = [
            GlossaryTerm(heard: "a", canonical: "A"),
            GlossaryTerm(heard: "", canonical: "nothing"),
            GlossaryTerm(heard: "b", canonical: ""),
            GlossaryTerm(heard: "A", canonical: "A prime"),
        ]
        let live = GlossaryStore.liveTerms(rows)
        // One entry out, holding the LAST row's spelling and value: the fold decides
        // identity, the surviving row decides how it is written.
        XCTAssertEqual(live.map(\.key), ["A"])
        XCTAssertEqual(live.map(\.value), ["A prime"])
    }
}
