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
    private let writeQueue = DebouncedSaver.makeQueue(label: "com.meetingpipe.glossarystore.write")

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

    /// STOR9 item 4, ARCH9's rule for a hand-edited file: `glossary.toml` is there and will not
    /// read or parse. Held until a re-read succeeds (`reload()`); while it is set nothing is
    /// written, so the owner's file is never replaced by the empty table this store fell back to.
    @Published private(set) var readError: String?
    /// One `store_unreadable` row per held error, not one per pane switch.
    private var readErrorReported = false
    /// The event's `reason` for the held error: `unparseable`, or the errno's name.
    private var readErrorReason = "unparseable"

    /// What the rows were last loaded from or saved as (STOR9 item 9, G012). A save applies only
    /// the difference between the rows and these onto a fresh read of the file, so a term another
    /// instance wrote (the transcript's Add to Vocabulary) survives this one's save.
    private var baseGlobal: [String: TermPair] = [:]
    private var baseWorkflow: [String: TermPair] = [:]
    private var baseFuzzy = false
    /// A workflow scope left with unsaved edits: its delta, kept until a save lands.
    private var stashedWorkflowDeltas: [String: TermDelta] = [:]
    /// Snapshots of what each in-flight debounced save wrote, committed as the new base only once
    /// that write lands (the `ConfigStore.commit` rule): a failed write keeps its delta.
    private var pendingCommits: [SaveSnapshot] = []

    /// The debounced save (CONC8): snapshots on main, writes on `writeQueue`.
    private lazy var saver = DebouncedSaver(
        queue: writeQueue,
        prepare: { [weak self] in self?.prepareSave() },
        completion: { [weak self] result in
            let snapshot = self?.pendingCommits.isEmpty == false ? self?.pendingCommits.removeFirst() : nil
            switch result {
            case .success:
                self?.saveError = nil
                if let snapshot { self?.commit(snapshot) }
            case .failure(let error):
                Log.failure(category: "daemon", action: "glossary_save_failed", error: error)
                self?.saveError = error.localizedDescription
            }
        }
    )

    /// Gates `scheduleSave` until init finishes, so the `didSet` storm from assigning
    /// the loaded values does not immediately rewrite the file (the `ConfigStore` idiom).
    private var isInitialized: Bool = false

    init(fileURL: URL = GlossaryStore.defaultURL) {
        self.fileURL = fileURL
        // A malformed or unreadable file loads as an empty document rather than throwing, matching
        // `load_glossary`, which logs and returns an empty glossary. Since STOR9 that empty document
        // is never saved over the file: the error is held and every write refuses until a re-read.
        let doc: TOMLTable
        switch GlossaryStore.readDocument(at: fileURL) {
        case .loaded(let loaded): doc = loaded
        case .missing: doc = TOMLTable()
        case .unparseable(let error):
            doc = TOMLTable()
            self.readError = GlossaryStore.readErrorText(fileURL, error)
        case .unreadable(let error):
            doc = TOMLTable()
            self.readError = GlossaryStore.readErrorText(fileURL, error)
            self.readErrorReason = StoreGuard.errnoName(of: error)
        }
        self.rawDocument = doc
        self.globalTerms = GlossaryStore.terms(in: doc["terms"]?.table)
        self.selectedWorkflow = nil
        self.workflowTerms = []
        // Missing key and non-bool value both read as off, matching the default in
        // `load_glossary`. The two readers only part on a hand-written non-bool
        // (Python's `bool("yes")` is true), which no UI can produce and which off is
        // the safe answer to anyway: a wrong substitution is worse than a missed one.
        self.fuzzyEnabled = doc["fuzzy"]?.table?["enabled"]?.bool ?? false
        self.baseGlobal = GlossaryStore.folded(globalTerms)
        self.baseFuzzy = fuzzyEnabled
        self.isInitialized = true
    }

    /// Re-read the file and start over from it (STOR9): what clears a held `readError` once the owner
    /// fixed the file, and what the Vocabulary pane runs when it appears. Unsaved edits are kept: a
    /// reload over them is skipped unless the store is holding an error, which has nothing to keep.
    func reload() {
        guard readError != nil || !hasUnsavedChanges else { return }
        let doc: TOMLTable
        switch GlossaryStore.readDocument(at: fileURL) {
        case .loaded(let loaded): doc = loaded
        case .missing: doc = TOMLTable()
        case .unparseable(let error), .unreadable(let error):
            readError = GlossaryStore.readErrorText(fileURL, error)
            readErrorReason = GlossaryStore.eventReason(error)
            return
        }
        isInitialized = false
        rawDocument = doc
        readError = nil
        readErrorReported = false
        stashedWorkflowDeltas = [:]
        globalTerms = GlossaryStore.terms(in: doc["terms"]?.table)
        let table = selectedWorkflow.flatMap { GlossaryStore.workflowTable(named: $0, in: doc) }
        workflowTerms = GlossaryStore.terms(in: table?["terms"]?.table)
        fuzzyEnabled = doc["fuzzy"]?.table?["enabled"]?.bool ?? false
        baseGlobal = GlossaryStore.folded(globalTerms)
        baseWorkflow = GlossaryStore.folded(workflowTerms)
        baseFuzzy = fuzzyEnabled
        isInitialized = true
    }

    /// True when the rows, a stashed workflow scope or the near-miss switch differ from what was
    /// last loaded or saved. `flush()` writes nothing otherwise (G012: opening and leaving the pane
    /// used to rewrite the file every time).
    var hasUnsavedChanges: Bool {
        !GlossaryStore.delta(base: baseGlobal, rows: globalTerms).isEmpty
            || (selectedWorkflow != nil && !GlossaryStore.delta(base: baseWorkflow, rows: workflowTerms).isEmpty)
            || stashedWorkflowDeltas.values.contains { !$0.isEmpty }
            || fuzzyEnabled != baseFuzzy
    }

    // MARK: - Scope

    /// Point the editor at a workflow's own table (or back at the global one with nil).
    /// Flushes the current scope into the document first, so switching scopes never
    /// drops an edit that has not hit the debounce yet.
    func selectWorkflow(_ name: String?) {
        guard name != selectedWorkflow else { return }
        writeBack()
        // STOR9: the outgoing scope's unsaved edits ride along to the next save as a delta.
        if let outgoing = selectedWorkflow {
            let delta = GlossaryStore.delta(base: baseWorkflow, rows: workflowTerms)
            if !delta.isEmpty { stashedWorkflowDeltas[outgoing] = (stashedWorkflowDeltas[outgoing] ?? TermDelta()).then(delta) }
        }
        selectedWorkflow = name
        let table = name.flatMap { GlossaryStore.workflowTable(named: $0, in: rawDocument) }
        let loaded = GlossaryStore.terms(in: table?["terms"]?.table)
        // The base is what this scope holds before this pane touches it, minus a stash of its own:
        // a stashed scope re-entered shows its edits (they are in `rawDocument`) and keeps them owed.
        baseWorkflow = GlossaryStore.folded(loaded)
        if let name, let stash = stashedWorkflowDeltas.removeValue(forKey: name) {
            baseWorkflow = stash.undo(on: baseWorkflow)
        }
        // Assign through the stored property: its `didSet` schedules a save, which is
        // harmless (the document already matches) and keeps one write path.
        workflowTerms = loaded
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
        if let readError { throw GlossaryReadRefusal(message: readError) }
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

    // MARK: - Workflow rename (WF11)

    /// Move `[workflow."<old>"]` to `[workflow."<new>"]` after a workflow is renamed.
    ///
    /// `glossary.toml` keys a workflow's table by name (UX44 keeps it hand-editable that way),
    /// and every reader resolves a meeting to a name, so without this a rename stranded the
    /// table: the Vocabulary editor lists only current names, and no meeting resolved to the
    /// old one again. A destination table that already exists is merged into, its own keys
    /// winning (compared folded, the pipeline's identity). `[terms]` and every other table are
    /// untouched. Returns how many terms moved and how many the destination kept, or nil when
    /// there was no source table (nothing to do, nothing written).
    ///
    /// Written straight to the file rather than through the debounced row editor, which models
    /// one scope's rows and has no notion of a table changing its name. An editor instance open
    /// on the old scope with unsaved rows can still re-create the old table on its next save;
    /// that is the same narrow race `addVocabularyTerm` documents.
    @discardableResult
    func renameWorkflowTable(from old: String, to new: String) throws -> (moved: Int, kept: Int)? {
        guard !old.isEmpty, !new.isEmpty, old != new else { return nil }
        if let readError { throw GlossaryReadRefusal(message: readError) }
        let disk: TOMLTable
        switch GlossaryStore.readDocument(at: fileURL) {
        case .loaded(let doc): disk = doc
        case .missing: return nil
        case .unparseable(let error), .unreadable(let error):
            throw GlossaryReadRefusal(message: GlossaryStore.readErrorText(fileURL, error))
        }
        guard let workflows = disk["workflow"]?.table, let source = workflows[old]?.table else { return nil }
        let destination = ensureTable(new, in: workflows)
        var moved = 0
        var kept = 0
        if let sourceTerms = source["terms"]?.table {
            let destinationTerms = ensureTable("terms", in: destination)
            let present = Set(destinationTerms.keys.map { $0.lowercased() })
            for key in sourceTerms.keys {
                if present.contains(key.lowercased()) {
                    kept += 1
                } else if let value = sourceTerms[key] {
                    destinationTerms[key] = value
                    moved += 1
                }
            }
        }
        for key in source.keys where key != "terms" && destination[key] == nil {
            if let value = source[key] { destination[key] = value }
        }
        workflows.remove(at: old)
        rawDocument = disk
        try writeToDisk(currentTOML())
        // Counts only: the names are workflow names and the terms are meeting vocabulary.
        Log.writeLine("daemon", "glossary: a renamed workflow's table moved, \(moved) terms moved, \(kept) kept from the destination")
        return (moved, kept)
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

    /// Force an immediate save (used by tests and by the editor's explicit actions). Written through the
    /// saver's queue, behind any debounced write already in flight. Throws while a read error is held.
    func saveNow() throws {
        guard let prepared = try prepareMerge(force: true) else { return }
        let (toml, snapshot) = prepared
        try saver.performNow { try self.writeToDisk(toml) }
        saveError = nil
        commit(snapshot)
    }

    /// Write pending edits out now, recording a failure instead of throwing. The editor
    /// calls this when it goes away: the 500 ms debounce is held by a timer that a
    /// closed Preferences window can outlive by less than that, and a dropped last
    /// keystroke here is a term the pipeline silently never applies. Writes nothing
    /// when nothing changed, and nothing while a read error is held (STOR9).
    func flush() {
        saver.flush()
    }

    private func scheduleSave() {
        guard isInitialized else { return }
        saver.schedule()
    }

    /// On main when the debounce fires: merge onto a fresh read and render it here, so the queue only
    /// sees a string. Nil writes nothing (no change, or a held read error).
    private func prepareSave() -> DebouncedSaver.Work? {
        guard isInitialized else { return nil }
        let prepared: (String, SaveSnapshot)?
        do { prepared = try prepareMerge(force: false) } catch { return nil }
        guard let prepared else { return nil }
        let (toml, snapshot) = prepared
        pendingCommits.append(snapshot)
        return { [self] in try writeToDisk(toml) }
    }

    /// STOR9 items 4 and 9: re-read `glossary.toml`, lay this pane's own changes onto it, and render.
    /// A file that will not read holds `readError` and refuses (throws `GlossaryReadRefusal`); no change
    /// writes nothing unless `force` (an explicit save still writes, so the `[fuzzy]` key appears).
    private func prepareMerge(force: Bool) throws -> (String, SaveSnapshot)? {
        if let readError {
            reportRefusal(GlossaryReadRefusal(message: readError))
            throw GlossaryReadRefusal(message: readError)
        }
        writeBack()   // keeps `rawDocument` (the live resolution's view) current
        let global = GlossaryStore.delta(base: baseGlobal, rows: globalTerms)
        let workflow = selectedWorkflow.map { ($0, GlossaryStore.delta(base: baseWorkflow, rows: workflowTerms)) }
        let fuzzyChanged = fuzzyEnabled != baseFuzzy
        let changed = !global.isEmpty || !(workflow?.1.isEmpty ?? true)
            || stashedWorkflowDeltas.values.contains { !$0.isEmpty } || fuzzyChanged
        guard changed || force else { return nil }

        let disk: TOMLTable
        switch GlossaryStore.readDocument(at: fileURL) {
        case .loaded(let doc): disk = doc
        case .missing: disk = TOMLTable()
        case .unparseable(let error), .unreadable(let error):
            let message = GlossaryStore.readErrorText(fileURL, error)
            readError = message
            readErrorReason = GlossaryStore.eventReason(error)
            reportRefusal(GlossaryReadRefusal(message: message))
            throw GlossaryReadRefusal(message: message)
        }
        global.apply(to: ensureTable("terms", in: disk))
        let workflows = { self.ensureTable("workflow", in: disk) }
        for (name, delta) in stashedWorkflowDeltas where !delta.isEmpty {
            delta.apply(to: ensureTable("terms", in: ensureTable(name, in: workflows())))
        }
        if let (name, delta) = workflow, !name.isEmpty, !delta.isEmpty {
            delta.apply(to: ensureTable("terms", in: ensureTable(name, in: workflows())))
        }
        let fuzzy = ensureTable("fuzzy", in: disk)
        if fuzzyChanged || fuzzy["enabled"]?.bool == nil { fuzzy["enabled"] = fuzzyEnabled }
        // The merged document: this pane's rows plus whatever another instance wrote. Not
        // `writeBack()`ed again, which replaces a table with the rows and would drop those keys.
        rawDocument = disk
        let snapshot = SaveSnapshot(
            global: GlossaryStore.folded(globalTerms),
            workflow: selectedWorkflow.map { ($0, GlossaryStore.folded(workflowTerms)) },
            fuzzy: fuzzyEnabled,
            stashedScopes: Set(stashedWorkflowDeltas.keys)
        )
        return (currentTOML(), snapshot)
    }

    /// A write landed: what it wrote is the new base, and the stashes it carried are paid.
    private func commit(_ snapshot: SaveSnapshot) {
        baseGlobal = snapshot.global
        if let (name, rows) = snapshot.workflow, name == selectedWorkflow { baseWorkflow = rows }
        baseFuzzy = snapshot.fuzzy
        for name in snapshot.stashedScopes { stashedWorkflowDeltas.removeValue(forKey: name) }
    }

    private func reportRefusal(_ refusal: GlossaryReadRefusal) {
        guard !readErrorReported else { return }
        readErrorReported = true
        StoreGuard.report(store: "glossary", pathKind: .config, reason: readErrorReason, outcome: "refused", error: refusal)
    }

    /// `glossary.toml` read as a document: missing, parsed, or the reason it is not.
    static func readDocument(at url: URL) -> StoreLoad<TOMLTable> {
        StoreLoad.read(url) { data in
            guard let raw = String(data: data, encoding: .utf8) else {
                throw StoreShapeError(why: "glossary.toml is not UTF-8 text")
            }
            return try TOMLTable(string: raw)
        }
    }

    /// `unparseable` for a parse error, the errno's name for an I/O one (CONVENTIONS' vocabulary).
    static func eventReason(_ error: Error) -> String {
        let code = LibraryRootState.posixCode(of: error)
        return (error is StoreShapeError || code == EIO) && !(error is CocoaError) ? "unparseable" : StoreGuard.errnoName(of: error)
    }

    static func readErrorText(_ url: URL, _ error: Error) -> String {
        let reason = LibraryRootState.posixCode(of: error) == EIO && !(error is StoreShapeError)
            ? (error as? LocalizedError)?.errorDescription ?? String(describing: error)
            : error.localizedDescription
        return "Couldn't read \(url.path): \(reason). Nothing is saved until the file reads; fix it, then reopen this pane."
    }

    // MARK: - Three-way merge (STOR9 item 9)

    /// One row as written: the key as typed, its value.
    struct TermPair: Equatable { let key: String; let value: String }

    /// Live rows keyed by their folded (lower-cased) key, the identity the pipeline matches on.
    static func folded(_ terms: [GlossaryTerm]) -> [String: TermPair] {
        var out: [String: TermPair] = [:]
        for pair in liveTerms(terms) { out[pair.key.lowercased()] = TermPair(key: pair.key, value: pair.value) }
        return out
    }

    static func delta(base: [String: TermPair], rows: [GlossaryTerm]) -> TermDelta {
        let current = folded(rows)
        var delta = TermDelta()
        for (fold, pair) in current where base[fold] != pair { delta.upserts[fold] = pair }
        for fold in base.keys where current[fold] == nil { delta.removals.insert(fold) }
        delta.prior = base.filter { delta.upserts[$0.key] != nil || delta.removals.contains($0.key) }
        return delta
    }

    /// What this pane changed in one table: keys it set (by fold) and keys it removed. Applied onto a
    /// fresh read, it leaves every other key, including one another instance added, alone.
    struct TermDelta: Equatable {
        var upserts: [String: TermPair] = [:]
        var removals: Set<String> = []
        /// The base values the changed keys had, so a stash can be undone into a base on re-entry.
        var prior: [String: TermPair] = [:]

        var isEmpty: Bool { upserts.isEmpty && removals.isEmpty }

        func apply(to table: TOMLTable) {
            for key in table.keys {
                let fold = key.lowercased()
                if removals.contains(fold) { table.remove(at: key); continue }
                if let pair = upserts[fold], pair.key != key { table.remove(at: key) }
            }
            for pair in upserts.values { table[pair.key] = pair.value }
        }

        /// This delta followed by `next`.
        func then(_ next: TermDelta) -> TermDelta {
            var out = self
            for (fold, pair) in next.upserts { out.upserts[fold] = pair; out.removals.remove(fold) }
            for fold in next.removals { out.removals.insert(fold); out.upserts.removeValue(forKey: fold) }
            for (fold, pair) in next.prior where out.prior[fold] == nil { out.prior[fold] = pair }
            return out
        }

        /// The base a scope had before this delta, given the base that already includes it.
        func undo(on base: [String: TermPair]) -> [String: TermPair] {
            var out = base
            for fold in upserts.keys { out.removeValue(forKey: fold) }
            for fold in removals { out.removeValue(forKey: fold) }
            for (fold, pair) in prior { out[fold] = pair }
            return out
        }
    }

    struct SaveSnapshot {
        let global: [String: TermPair]
        let workflow: (String, [String: TermPair])?
        let fuzzy: Bool
        let stashedScopes: Set<String>
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

    /// Replace `fileURL` with `toml` atomically. Runs on `writeQueue`.
    func writeToDisk(_ toml: String) throws {
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

    /// Render the document as TOML; mirrors the disk write so tests see the on-disk
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

/// A glossary write refused because `glossary.toml` will not read (STOR9 item 4).
struct GlossaryReadRefusal: LocalizedError {
    let message: String
    var errorDescription: String? { message }
}
