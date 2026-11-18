import AppKit
import Combine
import Foundation

extension Coordinator {
    /// UX89: the Library follows `[recording] output_dir`. A confirmed move, a confirmed "Use
    /// another folder", the missing-root state's Choose folder and a hand edit UX96 reloads all
    /// change the one `ConfigStore` value, and this one subscription re-roots the same store in
    /// place, so the search indexer and every view observing the store carry over unchanged.
    func wireLibraryRoot() {
        guard let configStore else { return }
        libraryRootCancellable = configStore.$outputDirPath
            .removeDuplicates()
            .dropFirst()
            .receive(on: DispatchQueue.main)
            .sink { [weak self] raw in
                guard let self else { return }
                let root = URL(fileURLWithPath: (raw as NSString).expandingTildeInPath)
                self.libraryModel.meetingStore.reroot(to: root)
            }
    }

    /// The missing-root state's **Choose folder…** (UX89). Points the library at an existing
    /// folder without moving anything: the configured root is not there, so nothing stays behind.
    func chooseLibraryFolder() {
        guard let configStore else { return }
        let panel = NSOpenPanel()
        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        panel.allowsMultipleSelection = false
        panel.canCreateDirectories = false
        panel.prompt = "Use This Folder"
        panel.message = "Choose the folder that holds your recordings."
        guard panel.runModal() == .OK, let url = panel.url else { return }
        MainActor.assumeIsolated { LibraryRootChange.pointAt(url, configStore: configStore) }
    }
}
