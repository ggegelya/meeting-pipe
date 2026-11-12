import Foundation

/// Why a capture writer stopped being able to write, and what the stop notification says about
/// it (REC19 item 3).
///
/// REC3 force-stops a recording once a channel fails `WriteFailureTracker.defaultThreshold`
/// consecutive writes, and it used to tell the owner "the disk may be full" every time. The
/// failure it was written for, a WAV intermediate hitting the 4 GiB RIFF cap at about 3 h 6 min,
/// does not happen on macOS 27.2: `AVAudioFile` turns the file into BW64 and keeps writing
/// (REC19's reproduction). So a run of failed writes is either a full disk, which the volume's
/// free space can confirm, or something this app cannot name from the recorder, and blaming the
/// disk for the second sends the owner to clear space that was never the problem.
///
/// Pure: the free-space read is `freeSpace(at:)`, kept apart so the decision is testable
/// without a full disk.
enum RecordingWriteFailure {

    /// The `cause` attribute on `recorder` / `recording_error`.
    enum Cause: String, Equatable {
        case diskFull = "disk_full"
        case unknown
    }

    /// Below this much free space a failed write run is read as a full disk.
    ///
    /// `volumeAvailableCapacityForImportantUsage` counts purgeable space macOS frees on demand,
    /// so a volume whose writes are already failing can still report a few hundred MB. 1 GiB is
    /// above that noise and is about 31 minutes of both capture channels at 48 kHz (576,000 B/s),
    /// so a volume under it could not have held the rest of a meeting either way.
    static let diskFullThresholdBytes: Int64 = 1 << 30

    struct Decision: Equatable {
        /// `"mic"` or `"system"`.
        let channel: String
        let cause: Cause
        /// The free space read at the failure, or nil when it could not be read.
        let freeBytes: Int64?
        /// The stop notification's text.
        let message: String
    }

    /// Decide the cause from the free space on the recording's volume. A free space that could
    /// not be read is `unknown`, never `disk_full`: unreadable is not empty, and the message
    /// must not send the owner after space that may be there.
    static func decide(channel: String, freeBytes: Int64?, volumeName: String?) -> Decision {
        if let free = freeBytes, free < diskFullThresholdBytes {
            let disk = volumeName.map { "\u{201C}\($0)\u{201D}" } ?? "the disk the recordings are on"
            let freeText = ByteCountFormatter.string(fromByteCount: max(free, 0), countStyle: .file)
            return Decision(
                channel: channel, cause: .diskFull, freeBytes: freeBytes,
                message: "Recording stopped: \(disk) is full (\(freeText) free), so \(channel) audio couldn't keep being saved. The recording up to that point was kept. Free up space before the next recording."
            )
        }
        return Decision(
            channel: channel, cause: .unknown, freeBytes: freeBytes,
            message: "Recording stopped: \(channel) audio couldn't keep being saved. The recording up to that point was kept. To look for the cause, open Preferences \u{25B8} Integrations \u{25B8} Run doctor\u{2026}"
        )
    }

    /// The free space the decision reads: the smaller of the two the volume reports (owner's
    /// choice, 2026-11-12). `importantUsage` (`volumeAvailableCapacityForImportantUsage`) counts
    /// space macOS can purge on demand, so on a Mac holding a lot of purgeable data a disk whose
    /// writes are failing can still read above the threshold there; `available`
    /// (`volumeAvailableCapacity`) is what is free right now. Either one unreadable means the
    /// other is used, and both unreadable is nil, which `decide` reads as `unknown`.
    static func effectiveFreeBytes(importantUsage: Int64?, available: Int64?) -> Int64? {
        switch (importantUsage, available) {
        case let (a?, b?): return min(a, b)
        case let (a?, nil): return a
        case let (nil, b?): return b
        case (nil, nil): return nil
        }
    }

    /// Free space and display name of the volume holding `directory`, each nil when unreadable.
    /// The key `StorageStats.freeBytes` reads plus `volumeAvailableCapacity`, without its
    /// unreadable-as-zero default.
    static func freeSpace(at directory: URL) -> (freeBytes: Int64?, volumeName: String?) {
        let values = try? directory.resourceValues(forKeys: [
            .volumeAvailableCapacityForImportantUsageKey, .volumeAvailableCapacityKey, .volumeLocalizedNameKey,
        ])
        let free = effectiveFreeBytes(
            importantUsage: values?.volumeAvailableCapacityForImportantUsage,
            available: values?.volumeAvailableCapacity.map(Int64.init)
        )
        return (free, values?.volumeLocalizedName)
    }
}
