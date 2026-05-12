import SwiftUI

/// Custom toolbar strip running across the top of the Library window.
/// Owns the always-visible bits the rail used to hide:
///   • breadcrumb (Library [→ Workflow])
///   • optional "Edit workflow" action when a workflow scope is active
///   • state pill (idle / recording / processing)
///   • Record / Stop button (signal blue / pulse coral)
///   • Preferences gear
///
/// Placed *below* the title bar rather than inside it. SwiftUI's
/// `.toolbar` inside a `NavigationSplitView` content column behaves
/// inconsistently on macOS 14/15 (items get clobbered when the rail
/// collapses), and the design's reference mockup wants a 44pt strip
/// with its own background — neither requirement is friendly to
/// `NSWindow.toolbar`. So we render a plain SwiftUI strip the window
/// hosts itself, matching the prototype's height + hairline.
struct LibraryToolbar: View {
    @ObservedObject var model: LibraryWindowModel
    @ObservedObject var workflowStore: WorkflowStore
    @Binding var selection: LibraryScope
    /// Pull-down menu trigger for editing the currently-scoped workflow.
    /// The root view hosts the editor sheet; the toolbar just signals.
    let onEditWorkflow: (Workflow) -> Void

    var body: some View {
        HStack(spacing: 10) {
            breadcrumb

            if let wf = scopedWorkflow {
                Button {
                    onEditWorkflow(wf)
                } label: {
                    Label("Edit workflow", systemImage: "pencil")
                        .labelStyle(.titleAndIcon)
                        .font(.system(size: 12, weight: .medium))
                }
                .buttonStyle(.borderless)
                .controlSize(.small)
            }

            Spacer(minLength: 8)

            StatePill(
                status: model.status,
                processingCount: model.processingCount,
                workflow: activeWorkflow
            )

            RecordToolbarButton(
                isRecording: model.isRecording,
                isEnabled: model.canToggleRecording,
                action: { model.toggleRecording() }
            )

            Button {
                model.openPreferences()
            } label: {
                Image(systemName: "gearshape")
                    .font(.system(size: 14))
            }
            .buttonStyle(.borderless)
            .help("Preferences…")
        }
        .padding(.horizontal, 12)
        .frame(height: 44)
        .background(
            Color(MPColors.bgSunk)
                .overlay(alignment: .bottom) {
                    Rectangle()
                        .fill(Color(MPColors.border))
                        .frame(height: 0.5)
                }
        )
    }

    // MARK: - Pieces

    private var breadcrumb: some View {
        HStack(spacing: 6) {
            Text("Library")
                .font(.system(size: 12, weight: .medium))
                .foregroundStyle(.secondary)
            if let wf = scopedWorkflow {
                Image(systemName: "chevron.right")
                    .font(.system(size: 9, weight: .semibold))
                    .foregroundStyle(.tertiary)
                HStack(spacing: 5) {
                    Circle()
                        .fill(swiftUIColor(forHex: wf.color))
                        .frame(width: 7, height: 7)
                    Text(wf.name)
                        .font(.system(size: 12, weight: .medium))
                }
            } else {
                Image(systemName: "chevron.right")
                    .font(.system(size: 9, weight: .semibold))
                    .foregroundStyle(.tertiary)
                Text(selection.title)
                    .font(.system(size: 12, weight: .medium))
            }
        }
    }

    /// Workflow associated with the current scope, if any. Used by the
    /// breadcrumb + Edit button. Distinct from `activeWorkflow` (below)
    /// which is what's *currently recording* — those usually differ.
    private var scopedWorkflow: Workflow? {
        guard case .workflow(let id) = selection else { return nil }
        return workflowStore.workflow(id: id)
    }

    /// Workflow currently driving the recording (or, if idle, the
    /// scoped workflow as a fallback so the pill still tints reasonably
    /// when the user is sitting on a workflow scope). Anchor for the
    /// state pill's color treatment during a live recording.
    private var activeWorkflow: Workflow? {
        if case .recording(let appName) = model.status,
           let liveStem = model.liveRecordingStem {
            // Live meeting wins. We don't have the workflow id on the
            // Coordinator side (only the name lands in the sidecar at
            // record time), so look it up by name. Falls back to the
            // scoped workflow if the name doesn't resolve.
            if let m = model.meetingStore.meetings.first(where: { $0.stem == liveStem }),
               let name = m.workflowName,
               let wf = workflowStore.workflows.first(where: { $0.name == name }) {
                return wf
            }
            _ = appName
        }
        return scopedWorkflow ?? workflowStore.defaultWorkflow
    }
}

// MARK: - Subviews

/// The always-visible status pill. Three shapes:
///   • Idle: muted, single dot, "Idle"
///   • Processing: spinner + "Processing N"
///   • Recording: workflow tint, pulse dot, name, elapsed timer (mm:ss)
///
/// Per the design's hybrid header: the recording variant expands inline
/// — same control, larger visual presence. It's not a separate widget.
struct StatePill: View {
    let status: LibraryWindowModel.Status
    let processingCount: Int
    let workflow: Workflow?

    var body: some View {
        switch status {
        case .recording:
            recordingShape
        case .stopping:
            processingShape(label: "Stopping…")
        default:
            if processingCount > 0 {
                processingShape(label: "Processing \(processingCount)")
            } else {
                idleShape
            }
        }
    }

    private var idleShape: some View {
        HStack(spacing: 7) {
            Circle()
                .fill(Color(MPColors.ink400).opacity(0.7))
                .frame(width: 7, height: 7)
            Text("Idle")
                .font(.system(size: 12, weight: .medium))
                .foregroundStyle(.secondary)
        }
        .padding(.horizontal, 10)
        .frame(height: 26)
        .background(
            Capsule(style: .continuous)
                .fill(Color.white.opacity(0.03))
                .overlay(
                    Capsule(style: .continuous)
                        .strokeBorder(Color.white.opacity(0.06), lineWidth: 0.5)
                )
        )
    }

    private func processingShape(label: String) -> some View {
        HStack(spacing: 7) {
            ProgressView()
                .controlSize(.mini)
                .progressViewStyle(.circular)
            Text(label)
                .font(.system(size: 12, weight: .medium))
                .foregroundStyle(.secondary)
        }
        .padding(.horizontal, 10)
        .frame(height: 26)
        .background(
            Capsule(style: .continuous)
                .fill(Color.white.opacity(0.04))
                .overlay(
                    Capsule(style: .continuous)
                        .strokeBorder(Color.white.opacity(0.08), lineWidth: 0.5)
                )
        )
    }

    /// Expanded recording shape — the borrowed piece of Pattern C. Tint
    /// is the workflow color; the dot pulses on a 1.6s opacity loop
    /// (steady, never scale — per the design system motion notes).
    private var recordingShape: some View {
        let wfColor = workflow.flatMap { HexColor.parse($0.color) }
            .map { Color($0) } ?? Color(MPColors.pulse600)
        return HStack(spacing: 8) {
            PulseDot()
            Text("Recording")
                .font(.system(size: 12, weight: .medium))
            if let wf = workflow {
                Text("·").foregroundStyle(.secondary)
                HStack(spacing: 5) {
                    Circle()
                        .fill(wfColor)
                        .frame(width: 6, height: 6)
                    Text(wf.name)
                }
            }
            Text("·").foregroundStyle(.secondary)
            Text(elapsedString)
                .font(.system(size: 12, weight: .medium).monospacedDigit())
        }
        .padding(.horizontal, 10)
        .frame(height: 26)
        .background(
            Capsule(style: .continuous)
                .fill(wfColor.opacity(0.18))
                .overlay(
                    Capsule(style: .continuous)
                        .strokeBorder(wfColor.opacity(0.35), lineWidth: 0.5)
                )
        )
    }

    /// Elapsed time for the live recording. Read off
    /// `LibraryWindowModel.liveRecordingStem` is not enough — the model
    /// doesn't expose a `startedAt` directly — so we infer from the
    /// matching meeting row when one exists. The pill degrades to "—:—"
    /// during the brief window between the recorder writing the wav
    /// and the meeting store picking it up.
    private var elapsedString: String {
        // The current implementation doesn't push a live elapsed counter
        // up through `LibraryWindowModel`. We render a static placeholder
        // here; the recording shape's job in this commit is to be the
        // *visual* expanded pill — a follow-up can wire a tick timer
        // that recomputes once a second. Keeping it static avoids
        // adding a 1Hz Timer.publish that would re-render the entire
        // toolbar (and through it, the rail and list) every second
        // before we measure whether that's acceptable.
        "—:—"
    }
}

/// Soft 1.6s pulse on the recording dot — opacity only, per the design
/// system's motion notes ("scale pulses read as urgent; the dot should
/// feel steady").
private struct PulseDot: View {
    @State private var phase: Double = 1

    var body: some View {
        ZStack {
            Circle()
                .fill(Color(MPColors.pulse600).opacity(0.35))
                .frame(width: 14, height: 14)
                .opacity(2 - phase)   // 0.35 .. 0.0 across the loop
            Circle()
                .fill(Color(MPColors.pulse600))
                .frame(width: 8, height: 8)
        }
        .onAppear {
            withAnimation(.easeInOut(duration: 1.6).repeatForever(autoreverses: true)) {
                phase = 0
            }
        }
    }
}

/// Toolbar's Record button. Signal blue when idle, pulse coral when
/// recording. Square stop glyph during a live recording mirrors the
/// status-bar icon.
/// Hex → SwiftUI Color helper, local to the toolbar so it doesn't pull
/// from the sidebar's file-private one. Falls back to `.secondary` for
/// malformed input (legacy TOML rows).
private func swiftUIColor(forHex hex: String) -> Color {
    if let ns = HexColor.parse(hex) { return Color(ns) }
    return Color.secondary
}

struct RecordToolbarButton: View {
    let isRecording: Bool
    let isEnabled: Bool
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(spacing: 6) {
                if isRecording {
                    Image(systemName: "stop.fill").font(.system(size: 10))
                } else {
                    Circle().fill(Color.white).frame(width: 8, height: 8)
                }
                Text(isRecording ? "Stop" : "Record")
                    .font(.system(size: 12, weight: .medium))
            }
            .padding(.horizontal, 12)
            .frame(height: 26)
            .background(
                RoundedRectangle(cornerRadius: 6, style: .continuous)
                    .fill(isRecording
                          ? Color(MPColors.pulse600)
                          : Color(MPColors.signal600))
            )
            .foregroundStyle(.white)
        }
        .buttonStyle(.plain)
        .disabled(!isEnabled)
        .opacity(isEnabled ? 1 : 0.55)
    }
}
