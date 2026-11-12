import Foundation

/// A capture channel, as the write-failure and backlog machinery names it (REC3, REC25). The raw
/// value is the `channel` attribute on `recorder` events and the suffix of the force-stop reason.
enum CaptureWriteChannel: String, CaseIterable {
    case mic
    case system
}

/// REC25: what a capture writer's backlog means, decided once a second on main.
///
/// `SerialBufferWriter` never drops and never blocks the producer (ADR 0009's frame parity), so a
/// disk that hangs instead of failing is invisible to REC3's `WriteFailureTracker`, which only
/// counts thrown errors: buffers pile up at the capture rate (about 576,000 B/s for both channels
/// at 48 kHz, 2.07 GB an hour) while the HUD shows live levels. This reads the writers' pending
/// byte counts on the ticks that already run (`InputDeviceRecovery.checkTapLiveness`,
/// `SystemAudioChannel.checkSystemLiveness`) and answers in two steps:
///
/// - **warn** once per channel per recording when that channel holds more than
///   `softThresholdSeconds` of its own audio. Seconds, not bytes, so a 96 kHz mic warns after the
///   same 30 s as a 48 kHz one.
/// - **stop** once per recording when both channels together hold more than `hardCapBytes`. The
///   host escalates through `onWriteFailure`, so REC3's force-stop keeps the prefix that reached
///   the disk. Buffers are never dropped to stay under it; that would break the parity above.
///
/// Per-recording state, like `WriteFailureTracker`: the host keeps one in a main-only field and
/// replaces it at `start()`.
struct WriterBacklogPolicy {

    /// Seconds of one channel's audio waiting on its writer before `writer_backlog` is logged.
    /// A healthy local write finishes each buffer in well under a tick; 30 s is far past any
    /// hiccup and far short of the memory that would matter.
    static let softThresholdSeconds: Double = 30

    /// Bytes waiting across both writers before the recording is force-stopped. 512 MiB is about
    /// 15.5 minutes of both channels at 48 kHz: high enough that only a disk that has stopped
    /// answering reaches it, low enough to stop before memory pressure on a 16 GB Mac.
    static let hardCapBytes = 512 << 20

    enum Action: Equatable {
        case none
        case warn(pendingSec: Double)
        case stop
    }

    private var warned: Set<CaptureWriteChannel> = []
    private(set) var hasStopped = false

    /// One tick for `channel`. `pendingBytes` is that channel's backlog, `bytesPerSecond` its own
    /// file format's rate (`MeetingRecorder.bytesPerSecond`), `totalPendingBytes` both channels'.
    /// The cap is checked first: a backlog past it stops even if the channel never warned, and
    /// after the stop nothing more is said.
    mutating func evaluate(
        channel: CaptureWriteChannel,
        pendingBytes: Int,
        bytesPerSecond: Double,
        totalPendingBytes: Int
    ) -> Action {
        guard !hasStopped else { return .none }
        if totalPendingBytes > Self.hardCapBytes {
            hasStopped = true
            return .stop
        }
        guard bytesPerSecond > 0, !warned.contains(channel) else { return .none }
        let pendingSec = Double(pendingBytes) / bytesPerSecond
        guard pendingSec > Self.softThresholdSeconds else { return .none }
        warned.insert(channel)
        return .warn(pendingSec: pendingSec)
    }
}
