import AppKit
import SwiftUI

/// The two ways to change the library root (UX89), offered by both the Recording pane and the
/// Storage pane's **Recordings folder** row. There is no free-text path: a typed path saved
/// mid-keystroke used to re-point new recordings, backups, Ask and digests at a folder that did
/// not exist. Both actions write `output_dir` only after their confirmation, through
/// `StorageStatsStore`, which is the one seam that moves or re-points the library.
struct LibraryRootButtons: View {
    @ObservedObject var stats: StorageStatsStore

    var body: some View {
        HStack(spacing: MPSpace.s2) {
            if stats.isPlanningMove {
                ProgressView().controlSize(.small)
            }
            Button("Move library…") { LibraryRootPanels.chooseMoveDestination(stats: stats) }
                .buttonStyle(.mpGhost)
                .disabled(stats.isPlanningMove)
            Button("Use another folder…") { LibraryRootPanels.chooseOtherFolder(stats: stats) }
                .buttonStyle(.mpGhost)
                .disabled(stats.isPlanningMove)
            Button {
                NSWorkspace.shared.activateFileViewerSelecting([stats.libraryURL])
            } label: {
                Image(systemName: "arrow.up.right.square")
            }
            .buttonStyle(.mpIcon)
            .help("Reveal in Finder")
        }
    }
}

/// The folder pickers behind the two actions. Nothing on disk or in the config changes here.
@MainActor
enum LibraryRootPanels {
    static func chooseMoveDestination(stats: StorageStatsStore) {
        let panel = NSOpenPanel()
        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        panel.canCreateDirectories = true
        panel.allowsMultipleSelection = false
        panel.prompt = "Choose"
        panel.message = "Pick a folder outside every cloud-sync folder. Your recordings folder keeps its name inside it."
        guard panel.runModal() == .OK, let destination = panel.url else { return }
        // PERF13: measured off main; the buttons stay disabled until the plan lands.
        Task { await stats.requestMove(to: destination) }
    }

    static func chooseOtherFolder(stats: StorageStatsStore) {
        let panel = NSOpenPanel()
        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        panel.canCreateDirectories = true
        panel.allowsMultipleSelection = false
        panel.prompt = "Use This Folder"
        panel.message = "New recordings will go here. Nothing is moved."
        guard panel.runModal() == .OK, let folder = panel.url else { return }
        Task { await stats.requestSwitch(to: folder) }
    }
}

/// Both confirmations, attached once per pane that shows `LibraryRootButtons`.
struct LibraryRootDialogs: ViewModifier {
    @ObservedObject var stats: StorageStatsStore

    func body(content: Content) -> some View {
        content
            .confirmationDialog(
                "Move the library?",
                isPresented: Binding(
                    get: { stats.pendingMove != nil }, set: { if !$0 { stats.pendingMove = nil } }
                ),
                titleVisibility: .visible
            ) {
                if let plan = stats.pendingMove {
                    Button("Move \(plan.fileCount) files (\(StorageStatsStore.format(plan.bytes)))") {
                        stats.pendingMove = nil
                        Task { await stats.executeMove(plan) }
                    }
                }
                Button("Cancel", role: .cancel) { stats.pendingMove = nil }
            } message: {
                if let plan = stats.pendingMove {
                    Text("\(plan.source.path)\nmoves to\n\(plan.destination.path)")
                }
            }
            .confirmationDialog(
                "Use another folder?",
                isPresented: Binding(
                    get: { stats.pendingSwitch != nil }, set: { if !$0 { stats.cancelSwitch() } }
                ),
                titleVisibility: .visible
            ) {
                if stats.pendingSwitch != nil {
                    Button("Use This Folder") { Task { await stats.confirmSwitch() } }
                }
                Button("Cancel", role: .cancel) { stats.cancelSwitch() }
            } message: {
                if let folder = stats.pendingSwitch {
                    Text(LibraryRootCopy.switchMessage(current: stats.libraryURL, next: folder))
                }
            }
    }
}

extension View {
    func libraryRootDialogs(_ stats: StorageStatsStore) -> some View {
        modifier(LibraryRootDialogs(stats: stats))
    }
}

enum LibraryRootCopy {
    /// The switch confirmation names both folders and says the current library is not moved.
    static func switchMessage(current: URL, next: URL) -> String {
        "New recordings will go to \(next.path), and the Library will show that folder.\n\n"
            + "Your current library stays where it is, at \(current.path), and stops showing in the app. Nothing is moved or deleted."
    }
}
