import Combine
import Foundation
import TOMLKit

/// One "as heard" -> canonical substitution row in the vocabulary editor (FEAT11).
///
/// Identity is a `UUID`, not the key text, for the `ruleBinding` reason the workflow
/// editor already learned: a row keyed by its own text jumps position (or collapses
/// into a sibling) while the user is still typing the key.
struct GlossaryTerm: Identifiable, Equatable {
    let id: UUID
    /// The mangled form ASR produces, the left side of the TOML pair.
    var heard: String
    /// The canonical spelling to write instead, the right side.
    var canonical: String

    init(id: UUID = UUID(), heard: String = "", canonical: String = "") {
        self.id = id
        self.heard = heard
        self.canonical = canonical
    }

    /// Whether the pipeline would actually read this row. Mirrors
    /// `mp.glossary._merge_terms`: a blank key is skipped (`key.strip()`), and so is
    /// an empty value. Note the asymmetry, which is the Python reader's, not a typo:
    /// the key is trimmed before the test, the value only has to be non-empty.
    var isLive: Bool {
        !heard.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty && !canonical.isEmpty
    }
}

/// Observable reader/writer for `~/.config/meeting-pipe/glossary.toml` (FEAT11 over ASR1).
///
/// The glossary was fully built pipeline-side (`mp.glossary`, applied deterministically
/// at finalize) and had no in-app surface at all, so the only way to fix a recurring ASR
/// garble was to hand-write a TOML file that did not exist on disk. This store is the
/// Preferences half: same `ConfigStore` shape (read into a `TOMLTable`, mutate only the
/// tables the UI models, debounce the write), so an unknown key survives an edit
/// untouched. UX44 extended the modeled surface by exactly one boolean,
/// `[fuzzy].enabled`; the rest of that table (`max_distance`, anything later) is still
/// round-tripped blind.
///
/// Two layers, exactly as the pipeline resolves them: a global `[terms]` table and an
/// optional `[workflow."<name>".terms]` that wins on a key clash. The editor holds one
/// scope at a time (`selectWorkflow`), so only that workflow's table is ever rewritten.
final class GlossaryStore: ObservableObject {

    static var defaultURL: URL {
        FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(Endpoints.Paths.glossaryRelative)
    }

    private let fileURL: URL
    private let writeQueue = DispatchQueue(label: "com.meetingpipe.glossarystore.write", qos: .utility)

    /// Read once at load, mutated in place and re-serialized on persist; that is how
    /// `[fuzzy].max_distance`, a per-workflow table for a workflow the editor is not
    /// showing, and any key a later pipeline version adds all survive.
    private var rawDocument: TOMLTable

    /// The global `[terms]` table, in editing order.
    @Published var globalTerms: [GlossaryTerm] { didSet { scheduleSave() } }

    /// The workflow whose `[workflow."<name>".terms]` table `workflowTerms` holds, or
    /// nil when the editor is on the global scope.
    @Published private(set) var selectedWorkflow: String?

    /// The selected workflow's own terms. Empty (and never written) on the global scope.
    @Published var workflowTerms: [GlossaryTerm] { didSet { scheduleSave() } }

    /// `[fuzzy].enabled`, the near-miss second pass (UX44).
    ///
    /// The one key this store models outside the term tables. It stayed UI-less through
    /// FEAT11 and the only way to turn it on was to hand-edit a file the app otherwise
    /// owns, which for a knob whose whole job is "catch the spelling I did not think to
    /// list" is the wrong side of the trade. `max_distance` deliberately stays
    /// config-only: its default of 1 is the sane setting, and a second control would ask
    /// the user to reason about edit distance to change nothing worth changing.
    @Published var fuzzyEnabled: Bool { didSet { scheduleSave() } }

    /// Last write failure, surfaced in the editor rather than swallowed: a vocabulary
    /// the user typed and the pipeline never sees is the whole bug this task fixes.
    @Published private(set) var saveError: String?

    private var saveTimer: Timer?

    /// Gates `scheduleSave` until init finishes, so the `didSet` storm from assigning
    /// the loaded values does not immediately rewrite the file (the `ConfigStore` idiom).
    private var isInitialized: Bool = false

    init(fileURL: URL = GlossaryStore.defaultURL) {
        self.fileURL = fileURL
        let raw = (try? String(contentsOf: fileURL, encoding: .utf8)) ?? ""
        // A malformed file loads as an empty document rather than throwing, matching
        // `load_glossary`, which logs and returns an empty glossary. Saving from here
        // would replace the broken file, which is the only way out of it in-app.
        let doc = (try? TOMLTable(string: raw)) ?? TOMLTable()
        self.rawDocument = doc
        self.globalTerms = GlossaryStore.terms(in: doc["terms"]?.table)
        self.selectedWorkflow = nil
        self.workflowTerms = []
        // Missing key and non-bool value both read as off, matching the default in
        // `load_glossary`. The two readers only part on a hand-written non-bool
        // (Python's `bool("yes")` is true), which no UI can produce and which off is
        // the safe answer to anyway: a wrong substitution is worse than a missed one.
        self.fuzzyEnabled = doc["fuzzy"]?.table?["enabled"]?.bool ?? false
        self.isInitialized = true
    }

    // MARK: - Scope

    /// Point the editor at a workflow's own table (or back at the global one with nil).
    /// Flushes the current scope into the document first, so switching scopes never
    /// drops an edit that has not hit the debounce yet.
    func selectWorkflow(_ name: String?) {
        guard name != selectedWorkflow else { return }
        writeBack()
        selectedWorkflow = name
        let table = name.flatMap { GlossaryStore.workflowTable(named: $0, in: rawDocument) }
        // Assign through the stored property: its `didSet` schedules a save, which is
        // harmless (the document already matches) and keeps one write path.
        workflowTerms = GlossaryStore.terms(in: table?["terms"]?.table)
    }

    // MARK: - Confirmed append (FEAT12)

    /// Add one confirmed pair to a scope's table and write it out now.
    ///
    /// The transcript's "Add to Vocabulary" has no editor on screen, so it cannot ride
    /// the `globalTerms` / `workflowTerms` bindings the rows use. This is those same two
    /// steps, point the store at a scope and mutate that scope's rows, collapsed into one
    /// call, so `glossary.toml` still has exactly one writer rather than a second one that
    /// could learn a different idea of what a live row is.
    ///
    /// A row already holding the same folded key is updated in place instead of
    /// duplicated. `liveTerms` would collapse a duplicate on the way to disk anyway
    /// (last wins), but leaving two rows in memory would show the editor a phantom row
    /// that disappears on its next open.
    ///
    /// Callers must have an explicit user confirm behind them (FEAT11's honesty rule,
    /// FEAT12's hard constraint): nothing in the correction flow may reach this without
    /// one.
    func addTerm(heard: String, canonical: String, workflow: String?) throws {
        selectWorkflow(workflow)
        let fold = heard.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        func apply(_ rows: inout [GlossaryTerm]) {
            let match = rows.firstIndex {
                $0.heard.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() == fold
            }
            if let i = match {
                rows[i].canonical = canonical
            } else {
                rows.append(GlossaryTerm(heard: heard, canonical: canonical))
            }
        }
        if workflow == nil {
            apply(&globalTerms)
        } else {
            apply(&workflowTerms)
        }
        try saveNow()
    }

    // MARK: - Resolution (the `mp.glossary` mirror)

    /// The substitutions the pipeline would apply to a meeting in `workflowName`,
    /// keyed by the lower-cased "as heard" form.
    ///
    /// A mirror of `mp.glossary.load_glossary`'s merge, and pinned against the real
    /// Python reader by `Fixtures/glossary-golden.json`: global first, then the
    /// per-workflow table on top (so per-workflow wins a clash), keys lower-cased,
    /// blank keys and empty values skipped, non-string values ignored.
    ///
    /// One hand-edit hazard this cannot pin: two keys that differ only in case are
    /// collapsed by both sides, but "last wins" means document order in Python and
    /// toml++'s key order here, so a hand-written file carrying both spellings is
    /// ambiguous. The editor never writes one (`liveTerms` dedupes by lower-cased key).
    static func resolvedTerms(in document: TOMLTable, workflowName: String?) -> [String: String] {
        var out: [String: String] = [:]
        merge(&out, document["terms"]?.table)
        if let name = workflowName, !name.isEmpty,
           let workflow = workflowTable(named: name, in: document) {
            merge(&out, workflow["terms"]?.table)
        }
        return out
    }

    /// `resolvedTerms` over this store's live document, including edits that have not
    /// been written to disk yet.
    func resolvedTerms(workflowName: String?) -> [String: String] {
        writeBack()
        return GlossaryStore.resolvedTerms(in: rawDocument, workflowName: workflowName)
    }

    /// `resolvedTerms` over a glossary file on disk. The URL-shaped entry point so a
    /// caller (and the CI4 fixture test) never has to hold a `TOMLTable` itself. A
    /// missing or malformed file yields no terms, exactly as `load_glossary` does.
    static func resolvedTerms(at url: URL, workflowName: String?) -> [String: String] {
        let raw = (try? String(contentsOf: url, encoding: .utf8)) ?? ""
        let doc = (try? TOMLTable(string: raw)) ?? TOMLTable()
        return resolvedTerms(in: doc, workflowName: workflowName)
    }

    private static func merge(_ dst: inout [String: String], _ table: TOMLTable?) {
        guard let table else { return }
        for key in table.keys {
            guard let value = table[key]?.string, !value.isEmpty else { continue }
            guard !key.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { continue }
            dst[key.lowercased()] = value
        }
    }

    /// `[workflow."<name>"]`, read-only (no table is created for a lookup miss).
    private static func workflowTable(named name: String, in document: TOMLTable) -> TOMLTable? {
        document["workflow"]?.table?[name]?.table
    }

    private static func terms(in table: TOMLTable?) -> [GlossaryTerm] {
        guard let table else { return [] }
        return table.keys.compactMap { key in
            guard let value = table[key]?.string else { return nil }
            return GlossaryTerm(heard: key, canonical: value)
        }
    }

    // MARK: - Persistence

    /// Force an immediate save (used by tests and by the editor's explicit actions).
    func saveNow() throws {
        writeBack()
        try persistToDisk()
    }

    /// Write pending edits out now, recording a failure instead of throwing. The editor
    /// calls this when it goes away: the 500 ms debounce is held by a timer that a
    /// closed Preferences window can outlive by less than that, and a dropped last
    /// keystroke here is a term the pipeline silently never applies.
    func flush() {
        saveTimer?.invalidate()
        saveTimer = nil
        do {
            try saveNow()
            saveError = nil
        } catch {
            Log.main.error("GlossaryStore flush failed: \(String(describing: error))")
            saveError = error.localizedDescription
        }
    }

    private func scheduleSave() {
        guard isInitialized else { return }
        guard Thread.current.isMainThread else {
            DispatchQueue.main.async { [weak self] in self?.scheduleSave() }
            return
        }
        saveTimer?.invalidate()
        saveTimer = Timer.scheduledTimer(withTimeInterval: 0.5, repeats: false) { [weak self] _ in
            guard let self = self else { return }
            self.writeBack()
            self.writeQueue.async {
                do {
                    try self.persistToDisk()
                    DispatchQueue.main.async { self.saveError = nil }
                } catch {
                    Log.main.error("GlossaryStore persist failed: \(String(describing: error))")
                    let message = error.localizedDescription
                    DispatchQueue.main.async { self.saveError = message }
                }
            }
        }
    }

    /// Mutate `rawDocument` to reflect the current rows. Visible to tests so they can
    /// assert the round-trip without disk I/O.
    func writeBack() {
        write(globalTerms, into: ensureTable("terms", in: rawDocument))
        if let name = selectedWorkflow, !name.isEmpty {
            let workflows = ensureTable("workflow", in: rawDocument)
            let workflow = ensureTable(name, in: workflows)
            write(workflowTerms, into: ensureTable("terms", in: workflow))
        }
        // One key, set in place. `[fuzzy]` is now modeled to the depth of that single
        // boolean and no further, so `max_distance` and anything a later pipeline adds
        // beside it round-trip exactly as they did while the whole table was blind
        // (UX44). The table is created unconditionally, like `[terms]` above: this file
        // is already written the moment the pane is opened, and a knob spelled out as
        // `enabled = false` is easier to find by hand than one that exists only in the
        // example file.
        ensureTable("fuzzy", in: rawDocument)["enabled"] = fuzzyEnabled
    }

    /// Replace a `[terms]` table's contents with `terms`, dropping keys the user
    /// removed. Only this one table is touched, so anything else in the document
    /// (`[fuzzy]`, another workflow, a key a later pipeline adds) is left alone; the one
    /// key outside a term table this store writes at all is `[fuzzy].enabled`, and
    /// `writeBack` sets that one in place rather than through here.
    private func write(_ terms: [GlossaryTerm], into table: TOMLTable) {
        let live = GlossaryStore.liveTerms(terms)
        let keep = Set(live.map(\.key))
        for key in table.keys where !keep.contains(key) {
            table.remove(at: key)
        }
        for pair in live {
            table[pair.key] = pair.value
        }
    }

    /// The rows worth writing, in order, deduped by lower-cased key with the last row
    /// winning. Deduping here is what keeps the file free of the case-clash ambiguity
    /// described on `resolvedTerms`; the key text itself is preserved as typed, since
    /// the pipeline lower-cases at match time anyway.
    static func liveTerms(_ terms: [GlossaryTerm]) -> [(key: String, value: String)] {
        var order: [String] = []
        var byFold: [String: (key: String, value: String)] = [:]
        for term in terms where term.isLive {
            let key = term.heard.trimmingCharacters(in: .whitespacesAndNewlines)
            let fold = key.lowercased()
            if byFold[fold] == nil { order.append(fold) }
            byFold[fold] = (key: key, value: term.canonical)
        }
        return order.compactMap { byFold[$0] }
    }

    private func persistToDisk() throws {
        let toml = rawDocument.convert(to: .toml, options: GlossaryStore.renderOptions)
        try FileManager.default.createDirectory(
            at: fileURL.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        let tmp = fileURL.appendingPathExtension("writing")
        try toml.data(using: .utf8)?.write(to: tmp, options: .atomic)
        if FileManager.default.fileExists(atPath: fileURL.path) {
            _ = try FileManager.default.replaceItemAt(fileURL, withItemAt: tmp)
        } else {
            try FileManager.default.moveItem(at: tmp, to: fileURL)
        }
    }

    /// Mirrors `ConfigStore`: no `.allowLiteralStrings`, so strings serialize as
    /// canonical double-quoted basic strings rather than TOMLKit's single-quote form.
    private static let renderOptions: FormatOptions = [
        .allowMultilineStrings,
        .allowUnicodeStrings,
        .allowBinaryIntegers,
        .allowOctalIntegers,
        .allowHexadecimalIntegers,
        .indentations,
    ]

    /// Render the document as TOML; mirrors `persistToDisk` so tests see the on-disk
    /// output. Visible to tests.
    func currentTOML() -> String {
        rawDocument.convert(to: .toml, options: GlossaryStore.renderOptions)
    }

    /// Get-or-create a child table, re-fetching after insertion. See `ConfigStore.ensureTable`:
    /// TOMLKit's subscript SET copies the source node into the parent, so the local value
    /// is detached afterwards and the first assignment per fresh table is silently dropped.
    private func ensureTable(_ key: String, in parent: TOMLTable) -> TOMLTable {
        if let existing = parent[key]?.table { return existing }
        parent[key] = TOMLTable()
        if let live = parent[key]?.table { return live }
        let new = TOMLTable()
        parent[key] = new
        return new
    }
}
