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
        return Info(takenAt: taken, audioIncluded: obj["audio_included"] as? Bool ?? true)
    }

    /// A human age line ("Last backup today", "Last backup 3 days ago"), matching
    /// `doctor.py`'s day-granularity wording, or nil when no backup has run.
    static func ageDescription(now: Date = Date(), at url: URL = fileURL) -> String? {
        guard let info = read(at: url) else { return nil }
        let days = max(0, Calendar.current.dateComponents([.day], from: info.takenAt, to: now).day ?? 0)
        let when = days == 0 ? "today" : "\(days) day\(days == 1 ? "" : "s") ago"
        let suffix = info.audioIncluded ? "" : ", without recordings"
        return "Last backup \(when)\(suffix)"
    }

    /// Python writes `datetime.now(timezone.utc).isoformat()`, e.g.
    /// "2026-07-11T14:32:05.123456+00:00" (microsecond fraction + colon offset).
    /// `ISO8601DateFormatter`'s fractional-seconds mode expects milliseconds, so on a
    /// miss we strip the fraction and reparse at whole-second precision, which is all
    /// the day-granularity age line needs.
    private static func parseISO8601(_ s: String) -> Date? {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        if let date = formatter.date(from: s) { return date }
        let stripped = s.replacingOccurrences(of: #"\.\d+"#, with: "", options: .regularExpression)
        formatter.formatOptions = [.withInternetDateTime]
        return formatter.date(from: stripped)
    }
}
