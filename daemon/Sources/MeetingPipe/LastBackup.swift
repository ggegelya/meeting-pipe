import Foundation

/// Read-only view of the pipeline-owned last-backup marker
/// (`~/.config/meeting-pipe/.last-backup.json`, written by `mp backup`), surfaced in
/// Preferences ▸ Storage as a "last backup N days ago" line (STOR3). The daemon only
/// reads it; the Python pipeline owns writing it. Not part of the `<stem>.meta.json`
/// Swift-to-Python contract, this is a display-only surface over shared per-user state
/// (like `VoiceprintProfile`). Mirrors `doctor.py`'s `check_last_backup`.
enum LastBackup {

    static var fileURL: URL {
        FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(Endpoints.Paths.lastBackupRelative)
    }

    struct Info: Equatable {
        let takenAt: Date
        let audioIncluded: Bool
        /// STOR8: whether the destination volume was encrypted; nil when `mp backup`
        /// could not tell (`null`) or the marker predates STOR8 (absent).
        var destinationEncrypted: Bool? = nil
        /// Whether the marker carries the field at all, so a `null` (a share, a drive
        /// `diskutil` could not read) is told apart from a marker older than STOR8.
        var encryptionRecorded = false
    }

    /// The parsed marker, or nil when no `mp backup` has run (absent / malformed /
    /// missing or unparseable `at`). Pure over the URL for testability.
    static func read(at url: URL = fileURL) -> Info? {
        guard
            let data = try? Data(contentsOf: url),
            let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
            let at = obj["at"] as? String,
            let taken = parseISO8601(at)
        else { return nil }
        return Info(
            takenAt: taken,
            audioIncluded: obj["audio_included"] as? Bool ?? true,
            destinationEncrypted: obj["destination_encrypted"] as? Bool,
            encryptionRecorded: obj["destination_encrypted"] != nil
        )
    }

    /// A human age line ("Last backup today", "Last backup 3 days ago"), matching
    /// `doctor.py`'s day-granularity wording, or nil when no backup has run.
    static func ageDescription(now: Date = Date(), at url: URL = fileURL) -> String? {
        guard let info = read(at: url) else { return nil }
        let days = max(0, Calendar.current.dateComponents([.day], from: info.takenAt, to: now).day ?? 0)
        let when = days == 0 ? "today" : "\(days) day\(days == 1 ? "" : "s") ago"
        let suffix = info.audioIncluded ? "" : ", without recordings"
        // STOR8: the archive holds every transcript and voiceprint; an unencrypted
        // destination is said here because a scheduled run's warning goes to a log.
        let volume: String
        switch (info.encryptionRecorded, info.destinationEncrypted) {
        case (true, false?): volume = ", to a drive that is not encrypted"
        case (true, nil): volume = ", to a drive that may not be encrypted"
        default: volume = ""
        }
        return "Last backup \(when)\(suffix)\(volume)"
    }

    // MARK: - STOR10: the last attempt, and what a scheduled run's state says

    /// One `mp backup` / `mp digest` run, success or not, from `.last-<job>-attempt.json`
    /// (`mp.run_attempt`). `trigger` is `scheduled` for a LaunchAgent run, else `manual`.
    struct Attempt: Equatable {
        let at: Date
        let failed: Bool
        let reason: String?
        let scheduled: Bool
    }

    static var backupAttemptURL: URL {
        fileURL.deletingLastPathComponent().appendingPathComponent(".last-backup-attempt.json")
    }

    static var digestAttemptURL: URL {
        fileURL.deletingLastPathComponent().appendingPathComponent(".last-digest-attempt.json")
    }

    static func readAttempt(at url: URL) -> Attempt? {
        guard
            let data = try? Data(contentsOf: url),
            let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
            let raw = obj["at"] as? String,
            let at = parseISO8601(raw)
        else { return nil }
        return Attempt(
            at: at,
            failed: (obj["outcome"] as? String) == "failed",
            reason: obj["reason"] as? String,
            scheduled: (obj["trigger"] as? String) == "scheduled"
        )
    }

    /// What the scheduled job's own surfaces should say, beyond the plain age line.
    enum ScheduledState: Equatable {
        case fine
        /// The newest attempt was a scheduled run that failed, after the last success.
        case failed(at: Date, reason: String?)
        /// The schedule is on and the last success is older than two of its intervals.
        case overdue(lastSuccess: Date)
    }

    /// Pure. A manual failure is not reported here: Back up now shows its own error inline. A
    /// schedule with no success and no attempt yet is `fine`: it was just turned on and has not
    /// had its first chance to run.
    static func scheduledState(
        lastSuccess: Date?, attempt: Attempt?, scheduleOn: Bool, intervalDays: Int, now: Date
    ) -> ScheduledState {
        if let attempt, attempt.failed, attempt.scheduled, lastSuccess.map({ attempt.at > $0 }) ?? true {
            return .failed(at: attempt.at, reason: attempt.reason)
        }
        if scheduleOn, let lastSuccess,
           now.timeIntervalSince(lastSuccess) > Double(2 * intervalDays) * 86_400 {
            return .overdue(lastSuccess: lastSuccess)
        }
        return .fine
    }

    /// The line a non-fine state reads as, on the Storage pane and the Weekly digest group;
    /// `job` is "backup" or "digest".
    static func scheduledLine(_ state: ScheduledState, job: String, now: Date = Date()) -> String? {
        switch state {
        case .fine:
            return nil
        case .failed(let at, let reason):
            let because = reason.map { ": \($0)" } ?? ""
            return "Last automatic \(job) failed \(dayPhrase(from: at, to: now))\(because)"
        case .overdue(let lastSuccess):
            return "Automatic \(job) overdue: last success \(dayPhrase(from: lastSuccess, to: now))"
        }
    }

    /// The menu row's title for a scheduled run that failed or fell behind.
    static func menuTitle(_ state: ScheduledState, job: String) -> String? {
        switch state {
        case .fine: return nil
        case .failed: return "Automatic \(job) failed"
        case .overdue: return "Automatic \(job) overdue"
        }
    }

    private static func dayPhrase(from date: Date, to now: Date) -> String {
        let days = max(0, Calendar.current.dateComponents([.day], from: date, to: now).day ?? 0)
        return days == 0 ? "today" : "\(days) day\(days == 1 ? "" : "s") ago"
    }

    /// The backup's state from the markers on disk and the remembered schedule. Reads two small
    /// files, so off main for the menu (PERF24).
    static func backupState(scheduleOn: Bool, weekly: Bool, now: Date = Date()) -> ScheduledState {
        scheduledState(
            lastSuccess: read()?.takenAt, attempt: readAttempt(at: backupAttemptURL),
            scheduleOn: scheduleOn, intervalDays: weekly ? 7 : 1, now: now
        )
    }

    /// The digest has no success marker of its own; its last `ok` attempt is the success.
    static func digestState(scheduleOn: Bool, now: Date = Date()) -> ScheduledState {
        let attempt = readAttempt(at: digestAttemptURL)
        let success = attempt.flatMap { $0.failed ? nil : $0.at }
        return scheduledState(lastSuccess: success, attempt: attempt, scheduleOn: scheduleOn, intervalDays: 7, now: now)
    }

    /// Python writes `datetime.now(timezone.utc).isoformat()`, e.g.
    /// "2026-07-11T14:32:05.123456+00:00" (microsecond fraction + colon offset).
    /// `ISO8601.parse` reads it (ARCH17). An earlier comment here said the fractional
    /// formatter "expects milliseconds" and fails on that shape; measured on 2026-10-25
    /// (macOS 26.5.1) it parses it, truncating to milliseconds. The restore preview's
    /// manifest `created_at` goes through the same parser.
    static func parseISO8601(_ s: String) -> Date? { ISO8601.parse(s) }
}
