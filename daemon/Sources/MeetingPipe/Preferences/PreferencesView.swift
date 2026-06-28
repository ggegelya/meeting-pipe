import AppKit
import SwiftUI

/// Shared selection state for the Preferences window. `PreferencesWindow.show(initial:)` mutates `current` to deeplink an external caller (e.g. permission-warning row) to a specific section; SwiftUI re-renders the sidebar whether the window is fresh or already on screen.
final class PreferencesSelectionState: ObservableObject {
    @Published var current: PreferencesItem = .general
}

/// Sidebar items for the Preferences window (TECH-E4). IA per the Claude-Design handoff, refined in DSN1: General (hotkeys, appearance), Recording (output, debounce, allowlist), Prompt (timeout, stop conditions), Pipeline (summarization), Integrations (Anthropic, Notion), Permissions (TCC, regulated mode), Advanced (config/logs).
enum PreferencesItem: String, CaseIterable, Identifiable, Hashable {
    case general
    case recording
    case prompt
    case pipeline
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
    @ObservedObject var selectionState: PreferencesSelectionState
    @StateObject private var doctor = DoctorRunner()

    @State private var doctorSheetOpen: Bool = false

    var body: some View {
        NavigationSplitView {
            PreferencesSidebar(selection: $selectionState.current)
        } detail: {
            ScrollView {
                detailContent
                    .padding(.horizontal, 32)
                    .padding(.vertical, 28)
                    .frame(maxWidth: 620, alignment: .topLeading)
                    .frame(maxWidth: .infinity, alignment: .top)
            }
            .background(Color(MPColors.bg))
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
            PipelineSectionView(store: store)
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
            PermissionsSectionView(store: store)
        case .advanced:
            AdvancedSectionView()
        }
    }

    // MARK: Doctor sheet

    private var doctorSheet: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Image(systemName: "stethoscope")
                Text("mp doctor").font(.headline)
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
