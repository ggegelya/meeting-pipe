import SwiftUI

/// What this step has done to the store so far: which preset is selected, and the id
/// of the workflow it created for that pick (WF9).
///
/// It lives on `OnboardingRootView` rather than in this view's own `@State` because the
/// navigator is a `switch step`, so stepping Back and Continue destroys and rebuilds the
/// step. When the id died with it, the next pick created a *second* workflow with
/// nothing even attempting to remove the first, which is one of the two ways the owner's
/// store came to hold four "Client work" rows.
struct OnboardingWorkflowChoice: Equatable {
    var selected: OnboardingStepWorkflow.Preset?
    var createdID: Workflow.ID?
}

/// Step 3 (TECH-UX1): pick a starting workflow. Choosing a preset creates a
/// default workflow; re-choosing swaps it; "set up later" leaves none.
struct OnboardingStepWorkflow: View {
    @ObservedObject var workflowStore: WorkflowStore
    /// UX21: the "Client work (NDA)" preset creates a local-backend workflow, so
    /// the first NDA meeting needs the MLX model cached. This lets the step offer
    /// the download inline instead of letting that meeting fail after the fact.
    var localModelPreflight: LocalModelPreflight? = nil
    /// WF9: owned by the navigator so a Back/Continue round trip cannot orphan the
    /// workflow this step already created.
    @Binding var choice: OnboardingWorkflowChoice
    /// UX21: the picked preset resolves to the local backend and the model is not
    /// cached. Cached in state (the probe is a filesystem scan) and refreshed when
    /// the selection changes.
    @State private var localModelMissing: Bool = false
    /// UX21: latched once "Download now" is tapped.
    @State private var localModelDownloadStarted: Bool = false

    enum Preset: String, CaseIterable, Identifiable {
        case personal, client, team, later
        var id: String { rawValue }

        var title: String {
            switch self {
            case .personal: return "Personal"
            case .client:   return "Client work (NDA)"
            case .team:     return "Internal team"
            case .later:    return "I'll set up later"
            }
        }

        var subtitle: String {
            switch self {
            case .personal: return "Cloud summary for your own notes."
            case .client:   return "Stays on-device, summarized by the local model, never published."
            case .team:     return "Shared team meetings."
            case .later:    return "Use the defaults for now; add workflows in Preferences."
            }
        }

        var isReal: Bool { self != .later }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Pick a default workflow")
                .font(.mpTextXL.weight(.semibold))
            Text("A workflow decides how a meeting is handled and where its summary goes. You can edit it or add more later.")
                .font(.callout)
                .foregroundStyle(Color(MPColors.fgMuted))
                .fixedSize(horizontal: false, vertical: true)
            VStack(spacing: 8) {
                ForEach(Preset.allCases) { card($0) }
            }
            if localModelMissing {
                localModelDownloadNote
            }
            Spacer(minLength: 0)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .onChange(of: choice.selected) { _, _ in refreshLocalModelMissing() }
        // The step is rebuilt on every Back/Continue, so re-derive the download
        // affordance from the choice the navigator kept rather than from a reset flag.
        .onAppear(perform: refreshLocalModelMissing)
    }

    /// UX21: the inline model-download note under the preset cards. Shown when the
    /// picked preset (Client work / NDA) resolves to the local backend but the MLX
    /// model is not cached. "Download now" routes through the daemon's shared
    /// supervisor, so the pull persists past onboarding and shows in the menu bar.
    @ViewBuilder
    private var localModelDownloadNote: some View {
        HStack(spacing: 10) {
            Image(systemName: "arrow.down.circle")
                .foregroundStyle(.mpWarning)
            if localModelDownloadStarted {
                Text("Downloading the on-device model. Progress shows in the menu bar.")
                    .font(.mpTextXS)
                    .foregroundStyle(Color(MPColors.fgMuted))
                    .fixedSize(horizontal: false, vertical: true)
                Spacer(minLength: 0)
            } else {
                Text("This keeps summaries on-device, which needs a model that is not downloaded yet (\(localModelPreflight?.downloadSizeLabel() ?? "several GB")).")
                    .font(.mpTextXS)
                    .foregroundStyle(Color(MPColors.fgMuted))
                    .fixedSize(horizontal: false, vertical: true)
                Spacer(minLength: 0)
                Button("Download now") {
                    localModelPreflight?.startDownload()
                    localModelDownloadStarted = true
                }
                .controlSize(.small)
            }
        }
        .padding(10)
        .background(RoundedRectangle(cornerRadius: 10).fill(Color(nsColor: .controlBackgroundColor)))
        .overlay(RoundedRectangle(cornerRadius: 10).stroke(Color(MPColors.border)))
    }

    /// UX21: recompute whether the download should be offered for the current
    /// selection. Only the on-device preset (Client work / NDA) resolves to local.
    private func refreshLocalModelMissing() {
        let resolvesLocal = (choice.selected == .client)
        localModelMissing = resolvesLocal && (localModelPreflight?.isModelMissing() ?? false)
    }

    private func card(_ p: Preset) -> some View {
        Button {
            choose(p)
        } label: {
            HStack(spacing: 12) {
                Image(systemName: choice.selected == p ? "largecircle.fill.circle" : "circle")
                    .foregroundStyle(choice.selected == p ? Color(MPColors.signal600) : Color(MPColors.fgMuted))
                VStack(alignment: .leading, spacing: 2) {
                    Text(p.title).font(.mpTextBase.weight(.medium))
                    Text(p.subtitle)
                        .font(.mpTextXS)
                        .foregroundStyle(Color(MPColors.fgMuted))
                        .fixedSize(horizontal: false, vertical: true)
                }
                Spacer()
            }
            .padding(10)
            .background(RoundedRectangle(cornerRadius: 10).fill(Color(nsColor: .controlBackgroundColor)))
            .overlay(
                RoundedRectangle(cornerRadius: 10)
                    .stroke(choice.selected == p ? Color(MPColors.signal600) : Color(MPColors.border))
            )
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }

    /// WF9: re-picking a preset now rewrites the row this step already created instead
    /// of deleting it and making a new one. The old shape leaked a workflow on every
    /// re-pick: each preset is created `isDefault: true`, and `WorkflowStore.delete`
    /// refuses to remove the default, so the delete silently no-opped and the
    /// replacement was appended beside its predecessor. Reusing the id makes the swap
    /// an update, which cannot leak whatever `delete` decides.
    private func choose(_ p: Preset) {
        choice.selected = p
        guard p.isReal else {
            // "I'll set up later": drop what this step made, if the store lets it go.
            // Unchanged behaviour, including the refusal when it is the only default.
            if let id = choice.createdID, (try? workflowStore.delete(id: id)) == true {
                choice.createdID = nil
            }
            return
        }
        let existing = choice.createdID.flatMap { workflowStore.workflow(id: $0) }
        let workflow = Self.presetWorkflow(
            p,
            reusing: existing,
            orderIfNew: workflowStore.workflows.count
        )
        try? workflowStore.upsert(workflow)
        choice.createdID = workflow.id
    }

    /// The workflow a preset stands for. Pure and non-private so the leak that produced
    /// the owner's four "Client work" rows is pinned by a test rather than by clicking
    /// through onboarding. `reusing` is the row an earlier pick in this run created:
    /// its id and its place in the rail are kept so a re-pick swaps rather than adds.
    static func presetWorkflow(_ p: Preset, reusing existing: Workflow?, orderIfNew: Int) -> Workflow {
        var flags = WorkflowFlags()
        flags.ndaMode = (p == .client)
        return Workflow(
            id: existing?.id ?? UUID(),
            name: p == .client ? "Client work" : p.title,
            color: color(p),
            sinks: [.filesystem],
            backend: p == .client ? .local : .anthropic,
            flags: flags,
            isDefault: true,
            order: existing?.order ?? orderIfNew
        )
    }

    private static func color(_ p: Preset) -> String {
        // Curated swatches (TECH-DSN11): Client moves off Pulse-coral (#E5484D,
        // reserved for the recording dot) to amber; the rest map onto the
        // on-brand tonal family instead of the old confetti seeds.
        switch p {
        case .personal: return MPColors.defaultWorkflowHex   // teal
        case .client:   return MPColors.workflowSwatches[5]  // amber
        case .team:     return MPColors.workflowSwatches[4]  // green
        case .later:    return MPColors.workflowSwatches[3]  // mid ink
        }
    }
}
