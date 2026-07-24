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

    /// How long ago something happened, in the coarsest unit that still reads
    /// naturally. Distinct from `Bucket` on purpose: that one places a date on the
    /// calendar ("Wed 09:00"), this one measures the gap. A prep card (CAL2) asks
    /// "when did we last talk", and "Wed" does not answer it once more than a week
    /// has passed.
    enum Elapsed: Equatable {
        case today
        case yesterday
        case days(Int)
        case weeks(Int)
        case months(Int)
    }

    static func elapsed(for date: Date, now: Date, calendar: Calendar = .current) -> Elapsed {
        let days = calendar.dateComponents(
            [.day], from: calendar.startOfDay(for: date), to: calendar.startOfDay(for: now)
        ).day ?? 0
        if days <= 0 { return .today }       // future timestamps (clock skew) read as today
        if days == 1 { return .yesterday }
        if days < 14 { return .days(days) }
        if days < 63 { return .weeks(days / 7) }
        return .months(max(2, Int((Double(days) / 30).rounded())))
    }

    /// Localized rendering of `elapsed`: "today", "yesterday", "3 days ago",
    /// "5 weeks ago", "4 months ago". Lower-case throughout, unlike the
    /// capitalized list-row stamp, because it reads as a phrase, not a heading.
    static func elapsedString(from date: Date, now: Date = Date(),
                              calendar: Calendar = .current) -> String {
        switch elapsed(for: date, now: now, calendar: calendar) {
        case .today:            return relative.localizedString(from: DateComponents(day: 0))
        case .yesterday:        return relative.localizedString(from: DateComponents(day: -1))
        case .days(let n):      return relative.localizedString(from: DateComponents(day: -n))
        case .weeks(let n):     return relative.localizedString(from: DateComponents(weekOfMonth: -n))
        case .months(let n):    return relative.localizedString(from: DateComponents(month: -n))
        }
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
