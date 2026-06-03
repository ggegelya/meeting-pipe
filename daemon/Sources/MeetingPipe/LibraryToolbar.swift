import SwiftUI

/// Custom 44pt toolbar strip below the title bar: breadcrumb, optional "Edit workflow" button, state pill, Record/Stop button, and Preferences gear. Placed below the title bar rather than inside it because SwiftUI `.toolbar` inside `NavigationSplitView` is unreliable on macOS 14/15 (items get clobbered when the rail collapses), and the design needs a dedicated background strip.
struct LibraryToolbar: View {
    @ObservedObject var model: LibraryWindowModel
    /// Observed separately from the model so processing ticks don't re-render the rail, list, or detail. Wired from `model.processing`.
    @ObservedObject var processing: ProcessingTracker
    @ObservedObject var workflowStore: WorkflowStore
    @Binding var selection: LibraryScope
    /// Signals the root to open the editor sheet for the scoped workflow.
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
                processingCount: processing.count,
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

    /// Workflow for the current scope, if any. Used by the breadcrumb and Edit button. Distinct from `activeWorkflow` (the one currently recording).
    private var scopedWorkflow: Workflow? {
        guard case .workflow(let id) = selection else { return nil }
        return workflowStore.workflow(id: id)
    }

    /// Workflow driving the live recording; falls back to the scoped workflow when idle so the pill still tints on a workflow scope.
    private var activeWorkflow: Workflow? {
        if case .recording(let appName) = model.status,
           let liveStem = model.liveRecordingStem {
            // Only the workflow name lands in the sidecar at record time, so look up by name. Falls back to the scoped workflow if unresolvable.
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

/// Always-visible status pill: idle (dot + "Idle"), processing (spinner + count), recording (tinted expanded pill + elapsed). The recording variant expands inline; it is not a separate widget.
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

    /// Expanded recording shape, tinted by the workflow color. The dot pulses on a 1.6s opacity loop (no scale pulse, per the design system motion notes).
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

}

/// 1.6s opacity-only pulse for the recording dot ("scale pulses read as urgent; the dot should feel steady"). Uses `TimelineView(.animation)` rather than `withAnimation.repeatForever`: the old pattern restarted on every parent re-render, causing a ~1s stutter. TimelineView reads a free-running clock and invalidates only this subtree.
private struct PulseDot: View {
    /// One full opacity cycle, matching the legacy `easeInOut(duration: 1.6).autoreverses` envelope.
    private static let periodSec: Double = 1.6

    var body: some View {
        TimelineView(.animation) { context in
            // Cosine maps phase [0,1) to a 0..1..0 envelope without `withAnimation`.
            let t = context.date.timeIntervalSinceReferenceDate
            let phase = (t.truncatingRemainder(dividingBy: Self.periodSec)) / Self.periodSec
            let envelope = 0.5 + 0.5 * cos(phase * 2 * .pi)   // 0..1..0
            ZStack {
                Circle()
                    .fill(Color(MPColors.pulse600).opacity(0.35 * envelope))
                    .frame(width: 14, height: 14)
                Circle()
                    .fill(Color(MPColors.pulse600))
                    .frame(width: 8, height: 8)
            }
        }
        // Pin frame to the 14pt aura so adjacent layout doesn't shimmy.
        .frame(width: 14, height: 14)
    }
}

/// Hex → SwiftUI Color helper. Local to the toolbar; falls back to `.secondary` for malformed input (legacy TOML rows).
/// Record button: signal blue when idle, pulse coral when recording.
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
