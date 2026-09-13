import SwiftUI

/// Preferences ▸ Pipeline ▸ Vocabulary (FEAT11 over ASR1): the in-app editor for
/// `~/.config/meeting-pipe/glossary.toml`.
///
/// ASR1 shipped the whole normalization engine pipeline-side and no way to reach it,
/// so a recurring garble ("Resolve PS for Venusaur ticket") kept reaching both
/// summarize backends because fixing it meant hand-writing a TOML file that did not
/// exist. This is a list of wrong -> right pairs over `GlossaryStore`, with a scope
/// picker for the global table and each workflow's own.
///
/// UX44 gave it a first-contact story. FEAT11's version was correct and unreadable:
/// the owner opened it a day after it shipped and could not tell what it was for. It
/// now leads with one line saying what it does, shows a greyed example of a term
/// instead of asking the user to invent both halves of one, and surfaces the near-miss
/// pass that was a live pipeline knob reachable only by hand-editing the file.
struct VocabularySection: View {
    @ObservedObject var glossary: GlossaryStore
    /// Workflow names offered as per-workflow scopes. Empty in headless hosts.
    let workflowNames: [String]
    /// UX44: a scope the workflow editor's "Vocabulary…" link asked for, consumed on
    /// arrival. `.constant(nil)` in hosts with no deep link to serve.
    var pendingScope: Binding<String?> = .constant(nil)

    /// The scope picker's selection. `nil` is the global `[terms]` table; a name is
    /// that workflow's `[workflow."<name>".terms]`.
    @State private var scope: String? = nil

    var body: some View {
        SettingsGroup("Vocabulary") {
            SettingsFullRow(showsDivider: false) {
                Text(VocabularyCopy.lede)
                    .font(.mpTextSM)
                    .foregroundStyle(Color(MPColors.fgMuted))
                    .fixedSize(horizontal: false, vertical: true)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
            SettingsRow("Applies to",
                        sublabel: scopeSublabel,
                        alignTop: true) {
                SettingsMenuPicker(
                    selection: scopeBinding,
                    options: [(String?.none, "Every meeting")]
                        + workflowNames.map { (String?.some($0), $0) },
                    width: 220
                )
                .disabled(workflowNames.isEmpty)
            }
            if VocabularyCopy.showsSampleRow(termCount: terms.count) {
                SettingsFullRow {
                    VStack(alignment: .leading, spacing: 6) {
                        Text(emptyLine)
                            .font(.mpTextSM)
                            .foregroundStyle(Color(MPColors.fgMuted))
                            .fixedSize(horizontal: false, vertical: true)
                            .frame(maxWidth: .infinity, alignment: .leading)
                        sampleRow
                    }
                }
            } else {
                ForEach(terms) { term in
                    SettingsFullRow {
                        termRow(id: term.id)
                    }
                }
            }
            SettingsFullRow {
                HStack(spacing: 8) {
                    Button {
                        append(GlossaryTerm())
                    } label: {
                        Label("Add term", systemImage: "plus")
                    }
                    .buttonStyle(.mpGhost)
                    Spacer(minLength: 0)
                    if let error = glossary.saveError {
                        FailureNotice(failure: FailurePresentation(diagnostics: error, operation: .processing, title: "Couldn't save the vocabulary"))
                            .font(.mpTextXS)
                            .foregroundStyle(.mpDanger)
                            .lineLimit(2)
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            SettingsToggleRow(VocabularyCopy.fuzzyLabel,
                              sublabel: VocabularyCopy.fuzzySublabel,
                              isOn: $glossary.fuzzyEnabled,
                              showsDivider: true)
        } footer: {
            Text(VocabularyCopy.footer)
        }
        .onAppear {
            glossary.selectWorkflow(scope)
            applyPendingScope()
        }
        .onChange(of: pendingScope.wrappedValue) { _, _ in applyPendingScope() }
        .onDisappear { glossary.flush() }
        .tutorialAnchor(.vocabulary)
    }

    private var terms: [GlossaryTerm] {
        scope == nil ? glossary.globalTerms : glossary.workflowTerms
    }

    private var scopeSublabel: String {
        if workflowNames.isEmpty { return VocabularyCopy.scopeNoWorkflows }
        return scope == nil ? VocabularyCopy.scopeGlobal : VocabularyCopy.scopeWorkflow
    }

    private var emptyLine: String {
        scope == nil ? VocabularyCopy.emptyGlobal : VocabularyCopy.emptyWorkflow
    }

    private var scopeBinding: Binding<String?> {
        Binding(
            get: { scope },
            set: { newValue in
                scope = newValue
                glossary.selectWorkflow(newValue)
            }
        )
    }

    /// Take a deep-linked scope, if one is waiting, and clear it (UX44). Clearing is
    /// what stops a Preferences window opened by hand next week from silently re-routing
    /// the picker to the workflow a cross-link visited once; it is the
    /// `LibraryWindowModel.pendingScope` idiom, one-shot rather than sticky.
    private func applyPendingScope() {
        guard let requested = pendingScope.wrappedValue else { return }
        pendingScope.wrappedValue = nil
        let resolved = VocabularyDeepLink.scope(
            forWorkflowNamed: requested, availableScopes: workflowNames
        )
        scope = resolved
        glossary.selectWorkflow(resolved)
    }

    /// The greyed, non-persisted example (UX44). "Add term" used to append a fully blank
    /// row, so a first-time user had to invent both halves of a pair from two
    /// placeholders; the only worked examples in the product lived in
    /// `glossary.example.toml`, which no surface shows. This borrows one of them.
    ///
    /// Plain text, not disabled text fields: a row that looks editable and is not is a
    /// worse lie than a row that plainly is not editable, and nothing here is written
    /// until the user adds a term of their own (FEAT11's keep-it-a-pre-fill honesty rule).
    private var sampleRow: some View {
        HStack(alignment: .center, spacing: 8) {
            Text(VocabularyCopy.sampleHeard)
                .font(.mpTextBase.monospaced())
            Image(systemName: "arrow.right")
                .font(.mpTextXS)
            Text(VocabularyCopy.sampleCanonical)
                .font(.mpTextBase)
            Spacer(minLength: 0)
            Text(VocabularyCopy.sampleTag)
                .font(.mpTextXS)
        }
        // fgSubtle, not fgFaint: this reads as an example rather than a row, and it
        // still has to clear the 4.5:1 contrast floor (DSN3), which fgFaint does not.
        .foregroundStyle(Color(MPColors.fgSubtle))
        .frame(maxWidth: .infinity, alignment: .leading)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(VocabularyCopy.sampleAccessibilityLabel)
    }

    private func termRow(id: UUID) -> some View {
        HStack(alignment: .center, spacing: 8) {
            TextField("as heard", text: binding(id, \.heard))
                .textFieldStyle(.roundedBorder)
                .font(.mpTextBase.monospaced())
                .accessibilityLabel("Term as heard")
            Image(systemName: "arrow.right")
                .font(.mpTextXS)
                .foregroundStyle(Color(MPColors.fgMuted))
                .accessibilityHidden(true)
            TextField("correct spelling", text: binding(id, \.canonical))
                .textFieldStyle(.roundedBorder)
                .accessibilityLabel("Correct spelling")
            Button(role: .destructive) {
                remove(id: id)
            } label: {
                Image(systemName: "minus.circle")
            }
            .buttonStyle(.borderless)
            .help("Remove this term")
            .accessibilityLabel("Remove term")
        }
        // UX44: the matching semantics used to be two clauses inside a six-line footer
        // that nobody read to the end of. They belong on the thing they describe.
        .help(VocabularyCopy.rowHelp)
    }

    /// Id-keyed binding into the active scope's rows, the `WorkflowEditor.ruleBinding`
    /// idiom: a positional binding goes stale the moment a different row is removed.
    private func binding(_ id: UUID, _ keyPath: WritableKeyPath<GlossaryTerm, String>) -> Binding<String> {
        Binding(
            get: { terms.first(where: { $0.id == id })?[keyPath: keyPath] ?? "" },
            set: { newValue in
                mutate { rows in
                    if let i = rows.firstIndex(where: { $0.id == id }) {
                        rows[i][keyPath: keyPath] = newValue
                    }
                }
            }
        )
    }

    private func append(_ term: GlossaryTerm) {
        mutate { $0.append(term) }
    }

    private func remove(id: UUID) {
        mutate { rows in rows.removeAll { $0.id == id } }
    }

    /// One write path into whichever scope is showing, so adding a row can never
    /// land in the global table while the workflow scope is selected.
    private func mutate(_ change: (inout [GlossaryTerm]) -> Void) {
        if scope == nil {
            change(&glossary.globalTerms)
        } else {
            change(&glossary.workflowTerms)
        }
    }
}

// MARK: - Copy (UX44)

/// Every user-facing string the Vocabulary editor renders, in one place.
///
/// FEAT11's copy was accurate and expert-facing: "ASR" appeared unexpanded twice, the
/// footer carried five rules in one six-line paragraph, and "ticket prefixes" stood in
/// for an example the app never actually showed. The owner discovered the editor a day
/// after it shipped and filed "I just realize it exists, but not sure what is the
/// purpose" (UX44). Holding the strings here rather than inline is what lets
/// `VocabularyEditorTests` fence the jargon back out; the register is the repo's
/// standing one (second person, sentence case, no exclamation marks, PRODUCT.md).
enum VocabularyCopy {

    /// The one-line answer to "what is this?", above the rows. This is the sentence
    /// FEAT11 did not have anywhere.
    static let lede = "Teach the transcriber the words it keeps getting wrong."

    /// When it applies, and the one action that reaches a meeting you already have.
    /// **Re-transcribe…**, not Reprocess or Re-summarize: the last two re-run the summary
    /// over the transcript already on disk, which still carries the garble. Naming the
    /// exact action is cheaper than a support round-trip with yourself six weeks later.
    static let footer = """
        Applied when a transcript is finalized, before summarize and search ever see it, \
        so a new meeting picks it up on its own. A meeting you already have needs \
        Re-transcribe… from its ... menu; Reprocess and Re-summarize only redo the \
        summary over the transcript already on disk.
        """

    /// The matching semantics, on a tooltip over the row they describe.
    static let rowHelp = """
        Left is what the transcriber hears, right is how it should be spelled. \
        Matching is case-insensitive and whole-word.
        """

    // The worked pair borrowed from `glossary.example.toml`, so the app finally shows
    // one of the examples that until now only existed in a file nothing surfaces.
    static let sampleHeard = "cube kernetes"
    static let sampleCanonical = "Kubernetes"
    static let sampleTag = "Example"
    static let sampleAccessibilityLabel =
        "Example term: \"cube kernetes\" is written as \"Kubernetes\". Not saved."

    static let emptyGlobal = "No terms yet. Add the names and words the transcriber keeps getting wrong."
    static let emptyWorkflow =
        "No terms for this workflow yet. It still gets the ones that apply to every meeting."

    static let scopeNoWorkflows = "Every meeting. Add a workflow to keep a term to one kind of meeting."
    static let scopeGlobal = "Terms every meeting gets, whichever workflow it matched."
    static let scopeWorkflow =
        "Terms only meetings matching this workflow get, on top of the ones every meeting gets."

    static let fuzzyLabel = "Also catch near-misses (one letter off)"
    static let fuzzySublabel = """
        Off by default. On, a word within one letter of a term above is corrected too, \
        which catches spellings you did not think to list and can occasionally change a \
        different word that happens to look similar.
        """

    /// Whether the greyed example stands in for the term list.
    ///
    /// Only on a scope with zero rows. The moment "Add term" appends even a blank row,
    /// that row is the one the user should be typing into, and showing an example that
    /// looks like a row beside a row that takes keystrokes is the worst of both.
    static func showsSampleRow(termCount: Int) -> Bool { termCount == 0 }

    /// Every string above, for the jargon fence. A new string that skips this list is
    /// invisible to the test, so add to it when you add copy.
    static let allUserFacing: [String] = [
        lede, footer, rowHelp,
        sampleHeard, sampleCanonical, sampleTag, sampleAccessibilityLabel,
        emptyGlobal, emptyWorkflow,
        scopeNoWorkflows, scopeGlobal, scopeWorkflow,
        fuzzyLabel, fuzzySublabel,
        WorkflowVocabularyLink.caption, WorkflowVocabularyLink.buttonLabel,
    ]
}

// MARK: - Cross-link (UX44)

/// The workflow editor sheet's "Vocabulary…" link: where it goes, and with which scope.
///
/// The editor had exactly one entry point (the Pipeline pane), and the workflow sheet
/// never mentioned that a workflow has terms of its own, so reaching them meant leaving
/// the workflow, opening Preferences, and re-selecting the same workflow in a picker.
/// Pure so the route is a value a test can assert, rather than a window it has to open;
/// `SetupChecklist.Fix` is the same shape for the same reason.
enum VocabularyDeepLink {

    /// The Preferences pane the Vocabulary editor lives in.
    static let pane: PreferencesItem = .pipeline

    /// The scope picker value for `workflowName`, given the scopes the picker actually
    /// offers.
    ///
    /// `nil` is the global table, and it is also the honest answer for a name the picker
    /// does not carry: a workflow renamed but not yet saved, or deleted out from under
    /// the sheet. Selecting a row that is not in the list would leave the picker showing
    /// nothing and the editor writing to a table no meeting resolves.
    static func scope(forWorkflowNamed workflowName: String?, availableScopes: [String]) -> String? {
        guard let raw = workflowName else { return nil }
        let name = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !name.isEmpty, availableScopes.contains(name) else { return nil }
        return name
    }
}

/// The workflow sheet's half of that link: its copy, held beside the editor's so the two
/// surfaces cannot drift into describing the same feature two ways.
enum WorkflowVocabularyLink {
    static let caption = "Fix the words the transcriber keeps getting wrong in this workflow's meetings."
    static let buttonLabel = "Vocabulary…"
}
