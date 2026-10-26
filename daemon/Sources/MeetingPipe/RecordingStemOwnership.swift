import Foundation

/// The stems whose capture intermediates the recorder is writing, or may still write (REC23).
///
/// The orphan sweep runs after every finished job, so it can land while a recording is
/// starting, and its only guard used to be `LibraryWindowModel.liveRecordingStem`, a UI mirror
/// set after `start()` returns. By then `<stem>.mic.wav` had existed for the whole engine start
/// (39 to 68 ms on the built-in mic, up to the 8 s budget on a headset), so a sweep in that
/// window could merge the growing files, delete them, and publish a stub in place of the
/// meeting. This set is owned by the one object that knows: claimed before the first file is
/// created, released when the recording's files are finished with.
///
/// A set, not one optional, because a stem whose writer drain was abandoned at stop (REC7) is
/// still being written while the next recording's stem is claimed. Main-confined: claimed and
/// released from `MeetingRecorder`'s `@MainActor` start and stop, and read by the sweep on main.
@MainActor
final class RecordingStemOwnership {

    private(set) var stems: Set<String> = []

    /// Outstanding abandoned drains per stem, released when the count reaches zero.
    private var pendingDrains: [String: Int] = [:]

    nonisolated init() {}

    func contains(_ stem: String) -> Bool { stems.contains(stem) }

    func claim(_ stem: String) {
        stems.insert(stem)
    }

    func release(_ stem: String) {
        stems.remove(stem)
    }

    /// Keep `stem` owned until every writer in `writers` has worked through what was enqueued
    /// on it, then release it. For a stop whose bounded drain timed out: the abandoned drain
    /// keeps writing into the intermediates, and the sweep must not merge and delete a file a
    /// writer still holds. A disk that never comes back keeps the stem owned until the next
    /// launch, whose sweep (nothing owned) recovers it.
    func releaseWhenDrained<Item>(_ stem: String, writers: [SerialBufferWriter<Item>]) {
        guard !writers.isEmpty else {
            release(stem)
            return
        }
        pendingDrains[stem, default: 0] += writers.count
        for writer in writers {
            writer.whenDrained { [weak self] in
                Task { @MainActor in self?.drainFinished(stem) }
            }
        }
    }

    private func drainFinished(_ stem: String) {
        let left = (pendingDrains[stem] ?? 1) - 1
        guard left <= 0 else {
            pendingDrains[stem] = left
            return
        }
        pendingDrains[stem] = nil
        stems.remove(stem)
        Log.writeLine("recorder", "abandoned writer drain for \(stem) finished; its intermediates are released to the orphan sweep")
    }
}
