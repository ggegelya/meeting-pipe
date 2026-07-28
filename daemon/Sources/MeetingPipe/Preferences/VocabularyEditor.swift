import SwiftUI

/// Preferences ▸ Pipeline ▸ Vocabulary (FEAT11 over ASR1): the in-app editor for
/// `~/.config/meeting-pipe/glossary.toml`.
///
/// ASR1 shipped the whole normalization engine pipeline-side and no way to reach it,
/// so a recurring garble ("Resolve PS for Venusaur ticket") kept reaching both
/// summarize backends because fixing it meant hand-writing a TOML file that did not
/// exist. This is a list of wrong -> right pairs over `GlossaryStore`, with a scope
/// picker for the global table and each workflow's own.
struct VocabularySection: View {
    @ObservedObject var glossary: GlossaryStore
    /// Workflow names offered as per-workflow scopes. Empty in headless hosts.
    let workflowNames: [String]

    /// The scope picker's selection. `nil` is the global `[terms]` table; a name is
    /// that workflow's `[workflow."<name>".terms]`.
    @State private var scope: String? = nil

    var body: some View {
        SettingsGroup("Vocabulary") {
            SettingsRow("Applies to",
                        sublabel: scopeSublabel,
                        alignTop: true,
                        showsDivider: false) {
                SettingsMenuPicker(
                    selection: scopeBinding,
                    options: [(String?.none, "Every meeting")]
                        + workflowNames.map { (String?.some($0), $0) },
                    width: 220
                )
                .disabled(workflowNames.isEmpty)
            }
            if terms.isEmpty {
                SettingsFullRow {
                    Text(emptyLine)
                        .font(.mpTextSM)
                        .foregroundStyle(Color(MPColors.fgMuted))
                        .fixedSize(horizontal: false, vertical: true)
                        .frame(maxWidth: .infinity, alignment: .leading)
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
                        Text(error)
                            .font(.mpTextXS)
                            .foregroundStyle(.mpDanger)
                            .lineLimit(2)
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            }
        } footer: {
            Text(Self.footerText)
        }
        .onAppear { glossary.selectWorkflow(scope) }
        .onDisappear { glossary.flush() }
    }

    /// Terms apply when a transcript is finalized, which is the whole reason this
    /// footer exists: an edit here does nothing to a meeting that already ran until its
    /// transcript is rebuilt, and naming the exact action that does it is cheaper than
    /// a support round-trip with yourself six weeks later. That action is
    /// **Re-transcribe…**, not Reprocess or Re-summarize: the last two re-run the
    /// summary over the transcript already on disk, which still carries the garble.
    static let footerText = """
        Fixes a term ASR keeps mangling: the left side is what it hears, the right side \
        is how it should be spelled. Matching is case-insensitive and whole-word. Applied \
        when a transcript is finalized, before summarize and search ever see it, so a new \
        meeting picks it up on its own. An existing meeting needs Re-transcribe… from its \
        ... menu; Reprocess and Re-summarize only redo the summary over the transcript \
        already on disk. A workflow's terms are added on top of the global ones and win \
        on a clash.
        """

    private var terms: [GlossaryTerm] {
        scope == nil ? glossary.globalTerms : glossary.workflowTerms
    }

    private var scopeSublabel: String {
        if workflowNames.isEmpty {
            return "Every meeting. Add a workflow to keep a term to one kind of meeting."
        }
        return scope == nil
            ? "Terms every meeting gets, whichever workflow it matched."
            : "Terms only meetings matching this workflow get, on top of the global ones."
    }

    private var emptyLine: String {
        scope == nil
            ? "No terms yet. Add the spellings ASR keeps getting wrong: names, products, ticket prefixes."
            : "No terms for this workflow yet. It still gets every global term."
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
