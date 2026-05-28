import XCTest
@testable import MeetingPipe

/// TECH-UI-9. The bucketing is asserted deterministically (locale-independent);
/// the rendered string is checked only for locale-robust properties (the time
/// is present for recent buckets and absent for the year bucket).
final class RelativeMeetingDateFormatterTests: XCTestCase {

    private let cal = Calendar(identifier: .gregorian)

    private func date(_ y: Int, _ mo: Int, _ d: Int, _ h: Int = 10, _ mi: Int = 54) -> Date {
        var c = DateComponents()
        c.year = y; c.month = mo; c.day = d; c.hour = h; c.minute = mi
        return cal.date(from: c)!
    }

    private func bucket(_ date: Date, _ now: Date) -> RelativeMeetingDateFormatter.Bucket {
        RelativeMeetingDateFormatter.bucket(for: date, now: now, calendar: cal)
    }

    func test_bucket_today() {
        let now = date(2026, 5, 28, 15, 0)
        XCTAssertEqual(bucket(date(2026, 5, 28, 9, 0), now), .today)
    }

    func test_bucket_yesterday() {
        let now = date(2026, 5, 28, 15, 0)
        XCTAssertEqual(bucket(date(2026, 5, 27, 23, 0), now), .yesterday)
    }

    func test_bucket_three_days_ago_is_weekday() {
        let now = date(2026, 5, 28, 15, 0)
        XCTAssertEqual(bucket(date(2026, 5, 25, 9, 0), now), .weekday)
    }

    func test_bucket_fourteen_days_ago_is_day_month() {
        let now = date(2026, 5, 28, 15, 0)
        XCTAssertEqual(bucket(date(2026, 5, 14, 9, 0), now), .dayMonth)
    }

    func test_bucket_eighteen_months_ago_is_day_month_year() {
        let now = date(2026, 5, 28, 15, 0)
        XCTAssertEqual(bucket(date(2024, 11, 2, 9, 0), now), .dayMonthYear)
    }

    /// "2 through 7 days" boundary: 7 days ago is still a weekday, 8 days rolls to day/month.
    func test_bucket_seven_day_boundary() {
        let now = date(2026, 5, 28, 15, 0)
        XCTAssertEqual(bucket(date(2026, 5, 21, 9, 0), now), .weekday)   // 7 days
        XCTAssertEqual(bucket(date(2026, 5, 20, 9, 0), now), .dayMonth)  // 8 days
    }

    func test_string_includes_time_for_today_and_omits_it_for_old_year() {
        let now = date(2026, 5, 28, 15, 0)
        let today = date(2026, 5, 28, 10, 54)
        let old = date(2024, 11, 2, 10, 54)

        let todayStr = RelativeMeetingDateFormatter.string(from: today, now: now, calendar: cal)
        XCTAssertTrue(todayStr.contains(MeetingFormatters.shortTime.string(from: today)))

        let oldStr = RelativeMeetingDateFormatter.string(from: old, now: now, calendar: cal)
        XCTAssertFalse(oldStr.contains(MeetingFormatters.shortTime.string(from: old)))
        XCTAssertTrue(oldStr.contains("2024"))
    }
}
