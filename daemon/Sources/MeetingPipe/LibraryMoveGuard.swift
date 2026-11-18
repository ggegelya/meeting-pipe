import Foundation

/// The execute-time half of the library move's two refusals (STOR16). `LibraryMover.plan` checks
/// for in-flight work when the plan is measured, and the confirmation that follows has no time
/// limit, so a recording or a job could start in between. This asks the components that own the
/// work (REC23's rule: ownership comes from the owner, not from files) and, in the same main-queue
/// turn, marks the move as running, which the recording start path reads and defers on.
///
/// Main-queue only, like every reader of the recorder's owned stems.
final class LibraryMoveGuard {
    /// Why the library is busy right now, or nil. The Coordinator answers from
    /// `MeetingRecorder.ownedStems` and the pipeline lane's queue depth; a headless guard is never busy.
    var busyReason: () -> String?
    /// Called on main when a move finishes, success or failure, so a held start can go ahead.
    var onMoveFinished: () -> Void = {}
    private(set) var moveInProgress = false
    /// Backups and restores this app started (`mp backup`, `mp restore`), registered here rather
    /// than on the Storage pane, whose state dies with the pane while the job keeps running. A
    /// scheduled backup run by launchd is invisible to the app and stays out of scope.
    private(set) var storageJobs = 0

    func storageJobStarted() { storageJobs += 1 }
    func storageJobFinished() { storageJobs = max(0, storageJobs - 1) }

    init(busyReason: @escaping () -> String? = { nil }) {
        self.busyReason = busyReason
    }

    /// Check and claim in one step: nil when the move may run (and is now marked running), else
    /// the reason it may not.
    func begin() -> String? {
        if moveInProgress { return "a library move is already running" }
        if let reason = currentBusyReason { return reason }
        moveInProgress = true
        return nil
    }

    /// Why a move or a switch may not start now: a storage job, or whatever the owners report.
    var currentBusyReason: String? {
        if storageJobs > 0 { return "a backup or restore is running" }
        return busyReason()
    }

    func end() {
        guard moveInProgress else { return }
        moveInProgress = false
        onMoveFinished()
    }
}
