import SwiftUI

/// Step 3 (TECH-UX1): pick a starting workflow. Choosing a preset creates a
/// default workflow; re-choosing swaps it; "set up later" leaves none.
struct OnboardingStepWorkflow: View {
    @ObservedObject var workflowStore: WorkflowStore
    /// UX21: the "Client work (NDA)" preset creates a local-backend workflow, so
    /// the first NDA meeting needs the MLX model cached. This lets the step offer
    /// the download inline instead of letting that meeting fail after the fact.
    var localModelPreflight: LocalModelPreflight? = nil
    @State private var selected: Preset?
    @State private var createdID: Workflow.ID?
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
        .onChange(of: selected) { _, _ in refreshLocalModelMissing() }
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
        let resolvesLocal = (selected == .client)
        localModelMissing = resolvesLocal && (localModelPreflight?.isModelMissing() ?? false)
    }

    private func card(_ p: Preset) -> some View {
        Button {
            choose(p)
        } label: {
            HStack(spacing: 12) {
                Image(systemName: selected == p ? "largecircle.fill.circle" : "circle")
                    .foregroundStyle(selected == p ? Color(MPColors.signal600) : Color(MPColors.fgMuted))
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
                    .stroke(selected == p ? Color(MPColors.signal600) : Color(MPColors.border))
            )
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }

    private func choose(_ p: Preset) {
        selected = p
        if let id = createdID {
            _ = try? workflowStore.delete(id: id)
            createdID = nil
        }
        guard p.isReal else { return }
        var flags = WorkflowFlags()
        flags.ndaMode = (p == .client)
        let workflow = Workflow(
            name: p == .client ? "Client work" : p.title,
            color: color(p),
            sinks: [.filesystem],
            backend: p == .client ? .local : .anthropic,
            flags: flags,
            isDefault: true,
            order: workflowStore.workflows.count
        )
        try? workflowStore.upsert(workflow)
        createdID = workflow.id
    }

    private func color(_ p: Preset) -> String {
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
