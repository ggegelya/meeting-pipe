import AppKit
import Combine
import Foundation

extension Coordinator {
    /// UX89: the Library follows `[recording] output_dir`. A confirmed move, a confirmed "Use
    /// another folder", the missing-root state's Choose folder and a hand edit UX96 reloads all
    /// change the one `ConfigStore` value, and this one subscription re-roots the same store in
    /// place, so the search indexer and every view observing the store carry over unchanged.
    /// STOR9: a store that refused a write or quarantined a file tells the owner, and so does `mp`.
    func wireStoreNotices() {
        MainActor.assumeIsolated {
            StoreNotice.install { [weak self] message in self?.notifier.notifyStoreNotice(message) }
        }
    }

    func wireLibraryRoot() {
        // STOR16: the move asks the owners of the work, and a held recording start goes ahead when it ends.
        libraryMoveGuard.busyReason = { [weak self] in self?.libraryBusyReason }
        libraryMoveGuard.onMoveFinished = { [weak self] in self?.session.releaseHeldStart() }
        preferencesWindow?.libraryMoveGuard = libraryMoveGuard
        guard let configStore else { return }
        libraryRootCancellable = libraryModel.meetingStore.follow(configStore)
    }

    /// STOR16: why the library cannot be moved or re-pointed right now, from the components that
    /// own the work rather than from its files (REC23's rule). The recorder's owned stems cover a
    /// capture from before its engine starts; the lane's depth covers run-all and every Library
    /// re-run (re-summarize, re-transcribe, merge), which PIPE11 routes through it. The storage
    /// janitor and the orphan sweep start right after every settled job, so they are asked too.
    var libraryBusyReason: String? {
        if !MainActor.assumeIsolated({ recorder.ownedStems }).isEmpty { return "a recording is in progress" }
        if jobDispatcher.queueDepth > 0 { return "a meeting is still being processed" }
        // Merge, publish-from-paste and the summary preview spawn outside the lane (STOR16 follow-up).
        if launcher.meetingSpawnsInFlight > 0 { return "a meeting is still being processed" }
        if let reason = storageSweepBusyReason { return reason }
        return nil
    }

    var libraryMoveInProgress: Bool { libraryMoveGuard.moveInProgress }

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
