import AppKit
import SwiftUI

/// Shared selection state for the Preferences window. `PreferencesWindow.show(initial:)` mutates `current` to deeplink an external caller (e.g. permission-warning row) to a specific section; SwiftUI re-renders the sidebar whether the window is fresh or already on screen.
final class PreferencesSelectionState: ObservableObject {
    @Published var current: PreferencesItem = .general
    /// UX44: a Vocabulary scope the Pipeline pane should preselect, set by the workflow
    /// editor sheet's "Vocabulary…" cross-link and cleared by the editor once consumed.
    /// One-shot rather than sticky, so opening Preferences by hand later does not
    /// silently re-route the picker to a workflow a link visited once.
    @Published var pendingVocabularyScope: String?
}

/// Sidebar items for the Preferences window (TECH-E4). IA per the Claude-Design handoff, refined in DSN1: General (hotkeys, appearance), Recording (output, debounce, allowlist), Prompt (timeout, stop conditions), Pipeline (summarization), Storage (library size, retention, caches), Integrations (Anthropic, Notion), Permissions (TCC, regulated mode), Advanced (config/logs).
enum PreferencesItem: String, CaseIterable, Identifiable, Hashable {
    case general
    case recording
    case prompt
    case pipeline
    case storage
    case integrations
    case permissions
    case advanced

    var id: String { rawValue }

    var title: String {
        switch self {
        case .general:      return "General"
        case .recording:    return "Recording"
        case .prompt:       return "Prompt"
        case .pipeline:     return "Pipeline"
        case .storage:      return "Storage"
        case .integrations: return "Integrations"
        case .permissions:  return "Permissions"
        case .advanced:     return "Advanced"
        }
    }

    /// SF Symbols mapped from the Lucide names in the prototype.
    var systemImage: String {
        switch self {
        case .general:      return "slider.horizontal.3"
        case .recording:    return "mic"
        case .prompt:       return "waveform"
        case .pipeline:     return "cpu"
        case .storage:      return "internaldrive"
        case .integrations: return "powerplug"
        case .permissions:  return "lock.shield"
        case .advanced:     return "command"
        }
    }
}

/// Top-level Preferences view. NavigationSplitView with a 200pt sidebar rail and a raised-paper detail pane.
struct PreferencesView: View {
    @ObservedObject var store: ConfigStore
    @ObservedObject var secrets: SecretsStore
    @ObservedObject var workflows: WorkflowStore
    @ObservedObject var selectionState: PreferencesSelectionState
    /// UX60: the Permissions pane's regulated-mode group offers the on-device
    /// model's download inline, since the clamp it now names lands on a model this
    /// Mac may not have. Nil headless, which suppresses the row.
    var localModelPreflight: LocalModelPreflight? = nil
    @StateObject private var doctor = DoctorRunner()

    @State private var doctorSheetOpen: Bool = false

    /// UX43: what a pane switch scrolls back to. A zero-height anchor driven by a
    /// `ScrollViewReader`, deliberately not `.id(selectionState.current)` on the
    /// content: re-identifying the content would reset the offset too, but it also
    /// tears down every pane's own `@State` (a rename in flight in People, a
    /// disclosure the user just opened), which is a far larger change than "open at
    /// the top". This moves the scroller and nothing else. The id is a constant, so
    /// the anchor itself never re-identifies anything either.
    private static let topAnchor = "preferences-top"

    var body: some View {
        NavigationSplitView {
            PreferencesSidebar(selection: $selectionState.current)
        } detail: {
            ScrollViewReader { proxy in
                ScrollView {
                    VStack(alignment: .leading, spacing: 0) {
                        Color.clear.frame(height: 0).id(Self.topAnchor)
                        detailContent
                    }
                    .padding(.horizontal, 32)
                    .padding(.vertical, 28)
                    .frame(maxWidth: 620, alignment: .topLeading)
                    .frame(maxWidth: .infinity, alignment: .top)
                }
                .background(Color(MPColors.bg))
                // The ScrollView is created outside the pane switch, so its backing
                // NSScrollView and that scroller's offset survive it: scrolled to the
                // bottom of Storage, General used to open at the bottom.
                .onChange(of: selectionState.current) { _, _ in
                    proxy.scrollTo(Self.topAnchor, anchor: .top)
                }
            }
        }
        .frame(minWidth: 780, minHeight: 660)
        .sheet(isPresented: $doctorSheetOpen) { doctorSheet }
    }

    @ViewBuilder
    private var detailContent: some View {
        switch selectionState.current {
        case .general:
            GeneralSectionView(store: store)
        case .recording:
            RecordingSectionView(store: store)
        case .prompt:
            PromptSectionView(store: store)
        case .pipeline:
            PipelineSectionView(
                store: store,
                workflowNames: workflows.workflows.map(\.name).sorted {
                    $0.localizedCaseInsensitiveCompare($1) == .orderedAscending
                },
                pendingVocabularyScope: $selectionState.pendingVocabularyScope
            )
        case .storage:
            StorageSectionView(store: store, workflowStore: workflows)
        case .integrations:
            IntegrationsSectionView(
                store: store,
                secrets: secrets,
                onRunDoctor: {
                    doctorSheetOpen = true
                    doctor.run()
                }
            )
        case .permissions:
            PermissionsSectionView(store: store, localModelPreflight: localModelPreflight)
        case .advanced:
            AdvancedSectionView()
        }
    }

    // MARK: Doctor sheet

    private var doctorSheet: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Image(systemName: "stethoscope")
                Text("Doctor").font(.headline)
                Spacer()
                doctorStatusLabel
            }

            ScrollView {
                Text(doctor.output.isEmpty ? "Running…" : doctor.output)
                    .font(.system(.body, design: .monospaced))
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .textSelection(.enabled)
            }
            .background(Color(NSColor.textBackgroundColor))
            .border(Color.secondary.opacity(0.3))

            HStack {
                Button("Re-run") { doctor.run() }
                    .disabled(doctor.state == .running)
                Spacer()
                Button("Close") {
                    if doctor.state == .running { doctor.cancel() }
                    doctorSheetOpen = false
                }
                .keyboardShortcut(.defaultAction)
            }
        }
        .padding(20)
        .frame(minWidth: 560, minHeight: 420)
    }

    private var doctorStatusLabel: some View {
        switch doctor.state {
        case .idle:
            return AnyView(Text("Idle").foregroundStyle(Color(MPColors.fgMuted)).font(.caption))
        case .running:
            return AnyView(
                HStack(spacing: 6) {
                    ProgressView().controlSize(.small)
                    Text("Running…").font(.caption)
                }
            )
        case .finished(let exit):
            let ok = exit == 0
            return AnyView(
                HStack(spacing: 4) {
                    Image(systemName: ok ? "checkmark.circle.fill" : "xmark.circle.fill")
                        .foregroundStyle(ok ? Color.mpSuccess : Color.mpDanger)
                    Text(ok ? "Done (exit 0)" : "Failed (exit \(exit))").font(.caption)
                }
            )
        }
    }
}

// MARK: - Sidebar

/// Sidebar rail: SwiftUI List with `.sidebar` style, signal-blue active row.
private struct PreferencesSidebar: View {
    @Binding var selection: PreferencesItem

    var body: some View {
        List(selection: $selection) {
            ForEach(PreferencesItem.allCases) { item in
                Label(item.title, systemImage: item.systemImage)
                    .tag(item)
            }
        }
        .listStyle(.sidebar)
        .navigationSplitViewColumnWidth(min: 180, ideal: 200, max: 240)
    }
}

// MARK: - General
