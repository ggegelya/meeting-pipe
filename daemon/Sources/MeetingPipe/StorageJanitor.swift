import Foundation

/// CONC5: the launch and after-job storage sweep (`Coordinator.reapStorage`) as one serial, coalescing
/// unit, where it used to be a fresh `Task.detached` per call.
///
/// Two defects came with the detached task. It runs on the cooperative pool (`Task.detached` is not
/// off-pool), and its body blocks: `AudioRetentionSweep` runs a synchronous ffmpeg per WAV and
/// `LocalServerReaper` sleeps in a loop. And nothing stopped two of them overlapping, so a job finishing
/// during a long compress backlog started a second sweep over the same WAVs. Both encoded to the one
/// `<stem>.flac.writing`: each unlinked the other's temp, and with three in flight one could delete a
/// verified FLAC after another had removed its WAV.
///
/// So the body runs on one private serial queue (`.utility`, not `.background`: a FLAC encode that
/// I/O throttling stretched past its ceiling would be killed on every sweep), and requests go through the
/// same `OrphanRecoveryLatch` REC24 built for the orphan sweep: any number during a run collapse into one
/// follow-up. The follow-up takes a FRESH snapshot on main when it starts (workflow retention and the
/// recorder's owned stems, REC23), never the one of the request it absorbed, which can be minutes old.
///
/// Order inside the body: `LocalServerReaper` first. It is cheap and frees an orphaned `mlx_lm.server`'s
/// RAM, and behind the whole compress backlog it used to wait for the last WAV.
@MainActor
final class StorageJanitor {

    /// What one sweep needs from main-owned state.
    struct Snapshot: Sendable {
        var directory: URL
        var policies: [UUID: WorkflowRetention]
        var defaultWorkflowID: UUID?
        var liveStems: Set<String>
    }

    /// The three steps of one sweep, injectable so a test sees their order and overlap.
    struct Steps: Sendable {
        var reapServer: @Sendable () -> Void
        var reapOriginals: @Sendable () -> Void
        var retention: @Sendable (Snapshot) -> Void

        /// The local-server reaper first, then the originals reaper (MIC13), then audio retention (STOR1).
        func run(_ snapshot: Snapshot) {
            reapServer()
            reapOriginals()
            retention(snapshot)
        }

        static let production = Steps(
            reapServer: { LocalServerReaper.reapIfOrphaned() },
            reapOriginals: { OriginalsReaper.sweep() },
            retention: { snap in
                AudioRetentionSweep.sweep(
                    in: snap.directory, policies: snap.policies,
                    defaultWorkflowID: snap.defaultWorkflowID, liveStems: snap.liveStems
                )
            }
        )
    }

    private var latch = OrphanRecoveryLatch()
    private nonisolated let snapshot: @Sendable @MainActor () -> Snapshot
    private nonisolated let steps: Steps
    private nonisolated let queue: DispatchQueue

    nonisolated init(
        queue: DispatchQueue = DispatchQueue(label: "com.meetingpipe.reaper", qos: .utility),
        snapshot: @escaping @Sendable @MainActor () -> Snapshot,
        steps: Steps = .production
    ) {
        self.queue = queue
        self.snapshot = snapshot
        self.steps = steps
    }

    var isRunning: Bool { latch.isRunning }

    func request() {
        guard latch.request() == .start else { return }
        start()
    }

    private func start() {
        let snap = snapshot()
        let steps = self.steps
        let done: @Sendable () -> Void = { [weak self] in
            MainActor.assumeIsolated { self?.finished() }
        }
        queue.async {
            steps.run(snap)
            DispatchQueue.main.async(execute: done)
        }
    }

    private func finished() {
        if latch.finish() == .rerun { start() }
    }
}
