import SwiftUI

/// Top-level sections of the Library window's left rail.
enum LibrarySidebarItem: Hashable, Identifiable, CaseIterable {
    case library
    case workflows
    case preferences

    var id: Self { self }

    var title: String {
        switch self {
        case .library: return "Library"
        case .workflows: return "Workflows"
        case .preferences: return "Preferences"
        }
    }

    var systemImage: String {
        switch self {
        case .library: return "tray.full"
        case .workflows: return "square.stack.3d.up"
        case .preferences: return "gearshape"
        }
    }
}

/// Left rail: nav list on top, daemon-state footer on the bottom. The
/// footer is the only surface (besides the menu bar) where the user can
/// always see whether the daemon is recording right now, so it doubles
/// as a manual record button.
struct LibrarySidebar: View {
    @Binding var selection: LibrarySidebarItem
    @ObservedObject var model: LibraryWindowModel

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            List(selection: $selection) {
                ForEach(LibrarySidebarItem.allCases) { item in
                    Label(item.title, systemImage: item.systemImage)
                        .tag(item)
                }
            }
            .listStyle(.sidebar)

            Divider()

            footer
                .padding(12)
        }
        .frame(minWidth: 180, idealWidth: 200, maxWidth: 240)
        .navigationSplitViewColumnWidth(min: 180, ideal: 200, max: 240)
    }

    private var footer: some View {
        VStack(alignment: .leading, spacing: 10) {
            statusRow
            recordButton
            modelDownloadRow
        }
    }

    // MARK: Status row

    private var statusRow: some View {
        HStack(spacing: 8) {
            Circle()
                .fill(badgeColor)
                .frame(width: 8, height: 8)
            VStack(alignment: .leading, spacing: 1) {
                Text(statusText)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                if model.processingCount > 0 {
                    Text("Processing \(model.processingCount)")
                        .font(.caption2)
                        .foregroundStyle(.tertiary)
                        .lineLimit(1)
                }
            }
            Spacer(minLength: 0)
        }
    }

    private var statusText: String {
        switch model.status {
        case .idle: return "Idle"
        case .prompting(let name): return "Detected \(name)"
        case .recording(let name?): return "Recording — \(name)"
        case .recording(nil): return "Recording"
        case .stopping: return "Stopping…"
        }
    }

    private var badgeColor: Color {
        switch model.status {
        case .idle: return Color.secondary.opacity(0.6)
        case .prompting: return Color.yellow
        case .recording: return Color(MPColors.pulse600)
        case .stopping: return Color.secondary
        }
    }

    // MARK: Record button

    private var recordButton: some View {
        Button {
            model.toggleRecording()
        } label: {
            HStack(spacing: 6) {
                Image(systemName: model.isRecording ? "stop.circle.fill" : "record.circle")
                Text(model.isRecording ? "Stop recording" : "Start recording")
                Spacer(minLength: 0)
            }
            .frame(maxWidth: .infinity)
        }
        .buttonStyle(.borderedProminent)
        .controlSize(.regular)
        .disabled(!model.canToggleRecording)
    }

    // MARK: Model download

    @ViewBuilder
    private var modelDownloadRow: some View {
        switch model.modelDownload {
        case .idle:
            EmptyView()
        case .downloading(let modelId, let progress, let downloaded, let total):
            VStack(alignment: .leading, spacing: 4) {
                HStack(spacing: 4) {
                    Image(systemName: "arrow.down.circle")
                        .font(.caption)
                    Text(Self.shortModelId(modelId))
                        .font(.caption)
                        .lineLimit(1)
                        .truncationMode(.middle)
                }
                if let p = progress {
                    ProgressView(value: p)
                        .progressViewStyle(.linear)
                        .controlSize(.small)
                } else {
                    ProgressView()
                        .progressViewStyle(.linear)
                        .controlSize(.small)
                }
                if total > 0 {
                    Text("\(Self.formatBytes(downloaded)) / \(Self.formatBytes(total))")
                        .font(.caption2)
                        .foregroundStyle(.tertiary)
                        .lineLimit(1)
                }
            }
        case .completed(let modelId):
            HStack(spacing: 4) {
                Image(systemName: "checkmark.circle.fill")
                    .foregroundStyle(.green)
                    .font(.caption)
                Text("Downloaded \(Self.shortModelId(modelId))")
                    .font(.caption)
                    .lineLimit(1)
                    .truncationMode(.middle)
            }
        case .failed(let modelId, let err):
            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 4) {
                    Image(systemName: "exclamationmark.triangle.fill")
                        .foregroundStyle(.orange)
                        .font(.caption)
                    Text("Model failed: \(Self.shortModelId(modelId))")
                        .font(.caption)
                        .lineLimit(1)
                }
                Text(err)
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
                    .lineLimit(2)
            }
        }
    }

    private static func shortModelId(_ id: String) -> String {
        if let slash = id.lastIndex(of: "/") {
            return String(id[id.index(after: slash)...])
        }
        return id
    }

    private static func formatBytes(_ bytes: Int64) -> String {
        let kb = Double(bytes) / 1024.0
        let mb = kb / 1024.0
        let gb = mb / 1024.0
        if gb >= 1 { return String(format: "%.1f GB", gb) }
        if mb >= 1 { return String(format: "%.0f MB", mb) }
        if kb >= 1 { return String(format: "%.0f KB", kb) }
        return "\(bytes) B"
    }
}
