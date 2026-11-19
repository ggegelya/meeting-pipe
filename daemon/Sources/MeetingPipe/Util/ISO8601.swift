import Foundation

/// The one owner of ISO-8601 timestamps in the daemon (ARCH17).
///
/// Every `ts` the app reads or writes goes through here: the events log (Swift `Logger` and
/// Python `events.py`), `run.json`, the correction record, the failure sidecar, backup and
/// digest attempt records, the restore manifest. Before ARCH17 four hand-rolled parsers held
/// three beliefs about the same format; a new timestamp field now has one copy to pick.
///
/// Writers always emit UTC with a `Z`. Readers accept whole seconds or any fraction length,
/// with `Z` or a numeric offset. A naive timestamp (no offset) is refused: guessing its zone
/// would be a silent wrong date, and nil lets each caller fall back to the raw string.
enum ISO8601 {
    private static let plain: ISO8601DateFormatter = {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime]
        f.timeZone = TimeZone(identifier: "UTC")
        return f
    }()

    private static let fractional: ISO8601DateFormatter = {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        f.timeZone = TimeZone(identifier: "UTC")
        return f
    }()

    /// Parse `2026-07-11T14:32:05Z`, `...05+00:00`, `...05.123Z`, `...05.123456+00:00` and the like.
    ///
    /// Fractional first, then plain, then the fraction stripped and plain again. Measured on
    /// 2026-10-25 (macOS 26.5.1): the fractional formatter takes any fraction length, Python's
    /// microseconds included (truncated to milliseconds), and the plain one takes whole seconds,
    /// so the third attempt never fires on this OS. It stays as a belt for an older macOS,
    /// where the microsecond case was reported to fail but was never measured.
    static func parse(_ s: String) -> Date? {
        if let date = fractional.date(from: s) { return date }
        if let date = plain.date(from: s) { return date }
        let stripped = s.replacingOccurrences(of: #"\.\d+"#, with: "", options: .regularExpression)
        guard stripped != s else { return nil }
        return plain.date(from: stripped)
    }

    /// `2026-07-11T14:32:05Z`, or with `fractional` `2026-07-11T14:32:05.123Z`: byte-identical to
    /// what `ISO8601DateFormatter()` (plain) and the logger's fractional formatter wrote before.
    static func format(_ date: Date, fractional: Bool = false) -> String {
        (fractional ? Self.fractional : plain).string(from: date)
    }
}
