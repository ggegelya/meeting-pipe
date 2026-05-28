import Foundation

/// Relative date label for Library list rows (TECH-UI-9). Produces, locale-aware:
/// - `Today HH:mm` for today
/// - `Yesterday HH:mm` for yesterday
/// - `Wed HH:mm` (localized weekday) for 2 to 7 days ago
/// - `14 May HH:mm` for older dates in the current year
/// - `14 May 2025` for dates older than the current year (time omitted)
///
/// The detail pane keeps the absolute `MeetingFormatters.fullDateTime` stamp;
/// this is only for the dense list rows. Seconds are never shown.
enum RelativeMeetingDateFormatter {

    /// Which format a date falls into. Exposed (and pure, with injectable
    /// `now`/`calendar`) so the bucketing is unit-testable without depending on
    /// the locale-specific rendered string.
    enum Bucket: Equatable {
        case today
        case yesterday
        case weekday
        case dayMonth
        case dayMonthYear
    }

    static func bucket(for date: Date, now: Date, calendar: Calendar = .current) -> Bucket {
        let startDate = calendar.startOfDay(for: date)
        let startNow = calendar.startOfDay(for: now)
        let days = calendar.dateComponents([.day], from: startDate, to: startNow).day ?? 0
        if days <= 0 { return .today }       // today (future timestamps read as today)
        if days == 1 { return .yesterday }
        if days <= 7 { return .weekday }     // 2 to 7 days ago
        let sameYear = calendar.component(.year, from: date) == calendar.component(.year, from: now)
        return sameYear ? .dayMonth : .dayMonthYear
    }

    static func string(from date: Date, now: Date = Date(), calendar: Calendar = .current) -> String {
        let time = MeetingFormatters.shortTime.string(from: date)
        switch bucket(for: date, now: now, calendar: calendar) {
        case .today:        return "\(namedDay(0)) \(time)"
        case .yesterday:    return "\(namedDay(-1)) \(time)"
        case .weekday:      return "\(MeetingFormatters.shortWeekday.string(from: date)) \(time)"
        case .dayMonth:     return "\(dayMonth.string(from: date)) \(time)"
        case .dayMonthYear: return dayMonthYear.string(from: date)
        }
    }

    /// Localized "today" / "yesterday" with the first character capitalized.
    private static func namedDay(_ dayOffset: Int) -> String {
        let s = relative.localizedString(from: DateComponents(day: dayOffset))
        guard let first = s.first else { return s }
        return first.uppercased() + s.dropFirst()
    }

    private static let relative: RelativeDateTimeFormatter = {
        let f = RelativeDateTimeFormatter()
        f.dateTimeStyle = .named   // "today" / "yesterday" rather than "1 day ago"
        f.unitsStyle = .full
        return f
    }()

    /// Locale-ordered day + abbreviated month ("14 May" vs "May 14").
    private static let dayMonth: DateFormatter = {
        let f = DateFormatter()
        f.setLocalizedDateFormatFromTemplate("dMMM")
        return f
    }()

    private static let dayMonthYear: DateFormatter = {
        let f = DateFormatter()
        f.setLocalizedDateFormatFromTemplate("dMMMyyyy")
        return f
    }()
}
