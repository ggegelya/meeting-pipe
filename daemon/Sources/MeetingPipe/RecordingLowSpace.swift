import Foundation

/// The byte rates a recording costs on disk, in one place (REC20). The preflight, the live watch,
/// the Preferences ▸ Storage caption and the workflow editor's retention copy all read these, so
/// the figure the owner sees and the figure the recorder budgets with cannot drift apart again:
/// `Workflow.swift` said "~0.7 GB per recorded hour" for months, about three times the real rate.
enum RecordingSpaceBudget {

    /// The system channel's intermediate: `SystemAudioCapture.captureFormat`, 48 kHz stereo
    /// Float32, 2 x 4 x 48,000. A test pins it to `MeetingRecorder.bytesPerSecond` of that format.
    static let systemCaptureBytesPerSecond: Double = 384_000

    /// The mic intermediate at a 48 kHz device: mono Float32, 4 x 48,000. Nominal, because the
    /// preflight runs before the device is bound; the live watch uses the file's real rate.
    static let nominalMicCaptureBytesPerSecond: Double = 192_000

    /// Both intermediates together while recording: 576,000 B/s, about 2.07 GB an hour.
    static let nominalCaptureBytesPerSecond = systemCaptureBytesPerSecond + nominalMicCaptureBytesPerSecond

    /// The kept final: 16 kHz stereo `pcm_s16le`, 2 x 2 x 16,000 (`RecordingPostProcessor`'s
    /// ffmpeg arguments). Measured on the owner's library on 2026-10-25: 71,669,838 bytes for
    /// 1,119.84 s. About 230 MB per kept hour, and the size of the merge the stop writes while
    /// both intermediates still exist.
    static let finalBytesPerSecond: Double = 64_000

    /// Bytes a final of `seconds` takes: 3,600 s is 230,400,000 bytes.
    static func finalBytes(seconds: Double) -> Int64 {
        Int64((max(0, seconds) * finalBytesPerSecond).rounded())
    }

    /// The final's size for one hour, as the copy says it ("230 MB").
    static var finalPerHourText: String {
        ByteCountFormatter.string(fromByteCount: finalBytes(seconds: 3_600), countStyle: .file)
    }
}

/// REC20 items 1 and 2: how much more recording the free space on the library's volume covers,
/// and what to do about it. Pure: the free space is an input (`RecordingWriteFailure.freeSpace`
/// is the one reader), so every band is testable without a full disk.
///
/// "Covered" means seconds of further recording that fit while still leaving room for the stop's
/// merge, which writes the final while both intermediates still exist: every recorded second
/// costs its capture bytes now and `finalBytesPerSecond` more at stop.
enum RecordingLowSpace {

    /// Below this much covered recording at start, the recording still starts (a meeting is never
    /// refused) but the HUD and a notification say so.
    static let preflightCoveredSeconds: Double = 2 * 3_600

    /// Below this much covered recording mid-meeting, warn once.
    static let warnCoveredSeconds: Double = 15 * 60

    /// How often the live watch re-reads free space.
    static let checkIntervalSeconds: Double = 60

    /// Bytes held back from "covered" on top of the merge: one check interval of growth, capture
    /// plus final (60 s x 640,000 B/s, about 38 MB at 48 kHz). The watch reads once a minute, so
    /// a stop decided at the reading must still leave the merge its room after the minute of
    /// capture that lands before the next reading could have caught it.
    static func marginBytes(captureBytesPerSecond: Double) -> Int64 {
        Int64((checkIntervalSeconds * (captureBytesPerSecond + RecordingSpaceBudget.finalBytesPerSecond)).rounded())
    }

    /// Seconds of further recording `freeBytes` covers after `elapsedSeconds` already recorded.
    /// Zero when the free space no longer covers the merge plus the margin, which is the stop band.
    static func coveredSeconds(
        freeBytes: Int64,
        elapsedSeconds: Double,
        captureBytesPerSecond: Double = RecordingSpaceBudget.nominalCaptureBytesPerSecond
    ) -> Double {
        let reserved = RecordingSpaceBudget.finalBytes(seconds: elapsedSeconds)
            + marginBytes(captureBytesPerSecond: captureBytesPerSecond)
        let spare = Double(freeBytes - reserved)
        guard spare > 0 else { return 0 }
        return spare / (captureBytesPerSecond + RecordingSpaceBudget.finalBytesPerSecond)
    }

    /// What the start found, when it found the space short. Nil means nothing to say: enough
    /// space, or a free space that could not be read (unreadable is not empty, REC19).
    struct StartNotice: Equatable {
        let freeBytes: Int64
        let coveredSeconds: Double
        var hoursCovered: Double { coveredSeconds / 3_600 }
    }

    static func preflight(freeBytes: Int64?) -> StartNotice? {
        guard let free = freeBytes else { return nil }
        let covered = coveredSeconds(freeBytes: free, elapsedSeconds: 0)
        guard covered < preflightCoveredSeconds else { return nil }
        return StartNotice(freeBytes: free, coveredSeconds: covered)
    }

    // MARK: - Copy

    /// The HUD's state label while covered recording is under the preflight bound. Short enough
    /// for the pill (`HUDPanelGeometryTests` measures the longest form), and minutes rather than
    /// a byte count because "how long can this meeting run" is the question it answers.
    static func hudText(coveredSeconds: Double) -> String {
        let minutes = Int(max(0, coveredSeconds) / 60)
        if minutes >= 60 {
            return "Disk: \(minutes / 60)h \(minutes % 60)m left"
        }
        return "Disk: \(minutes)m left"
    }

    /// "1 hour 25 minutes" for the notification body.
    static func durationText(seconds: Double) -> String {
        let formatter = DateComponentsFormatter()
        formatter.allowedUnits = seconds >= 3_600 ? [.hour, .minute] : [.minute]
        formatter.unitsStyle = .full
        formatter.maximumUnitCount = 2
        return formatter.string(from: max(60, seconds)) ?? "\(Int(seconds / 60)) minutes"
    }

    static func freeText(_ bytes: Int64) -> String {
        ByteCountFormatter.string(fromByteCount: max(bytes, 0), countStyle: .file)
    }

    static func startMessage(_ notice: StartNotice) -> (title: String, body: String) {
        (
            "Low disk space",
            "\(freeText(notice.freeBytes)) free covers about \(durationText(seconds: notice.coveredSeconds)) of recording. MeetingPipe is recording anyway; free up space so a long meeting is not cut short."
        )
    }

    static func warnMessage(freeBytes: Int64, coveredSeconds: Double) -> (title: String, body: String) {
        (
            "Disk almost full",
            "\(freeText(freeBytes)) free covers about \(durationText(seconds: coveredSeconds)) more of this recording. Free up space now, or the recording stops on its own before the disk fills."
        )
    }

    static func stopMessage(freeBytes: Int64) -> String {
        "Recording stopped: the disk was almost full (\(freeText(freeBytes)) free), so MeetingPipe stopped while there was still room to save it. The recording up to that point was kept. Free up space before the next recording."
    }

    // MARK: - Live bands

    /// What one live reading means. `hudText` is non-nil while covered recording is under the
    /// preflight bound, so the label counts down for as long as space is short.
    enum Action: Equatable {
        case fine
        case warn
        case stop
    }

    struct Assessment: Equatable {
        let action: Action
        let coveredSeconds: Double
        let hudText: String?
    }

    /// The three-band decision over a sequence of readings, one recording's worth. The warning
    /// fires once, the stop fires once, and after the stop nothing more is said. A reading that
    /// could not be taken decides nothing and leaves the label as it was.
    struct Policy: Equatable {
        let captureBytesPerSecond: Double
        private(set) var warned: Bool
        private(set) var stopped = false

        /// `startCovered` is the preflight's reading: a start already under the warning band has
        /// been told, so the first live reading does not tell it again a minute later.
        init(captureBytesPerSecond: Double, startCovered: Double? = nil) {
            self.captureBytesPerSecond = captureBytesPerSecond
            self.warned = startCovered.map { $0 < RecordingLowSpace.warnCoveredSeconds } ?? false
        }

        mutating func evaluate(freeBytes: Int64?, elapsedSeconds: Double) -> Assessment? {
            guard let free = freeBytes, !stopped else { return nil }
            let covered = RecordingLowSpace.coveredSeconds(
                freeBytes: free, elapsedSeconds: elapsedSeconds, captureBytesPerSecond: captureBytesPerSecond
            )
            let label = covered < RecordingLowSpace.preflightCoveredSeconds
                ? RecordingLowSpace.hudText(coveredSeconds: covered) : nil
            if covered <= 0 {
                stopped = true
                return Assessment(action: .stop, coveredSeconds: 0, hudText: label)
            }
            if covered < RecordingLowSpace.warnCoveredSeconds, !warned {
                warned = true
                return Assessment(action: .warn, coveredSeconds: covered, hudText: label)
            }
            return Assessment(action: .fine, coveredSeconds: covered, hudText: label)
        }
    }

    /// What the watch hands the session on main.
    enum Update: Equatable {
        /// Refresh the HUD's low-space label (nil clears it).
        case label(String?)
        /// Covered recording fell under the warning band: label plus a one-time notification.
        case warn(hudText: String?, title: String, body: String)
        /// Covered recording no longer covers the merge: stop through the normal path.
        case stop(message: String)
    }
}
