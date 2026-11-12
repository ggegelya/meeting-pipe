import XCTest
@testable import MeetingPipe

/// PERF22 item 6: `ScopeCounts.build` computes its date cutoffs and workflow lookup once per build,
/// and `MeetingGroup.group` its month headings once per month. Both are pinned against copies of
/// the implementations they replaced, over five months of meetings that straddle a DST change and
/// every cutoff, with the calendar and time zone fixed.
final class ScopeDateHoistTests: XCTestCase {

    private var calendar: Calendar = {
        var cal = Calendar(identifier: .gregorian)
        cal.timeZone = TimeZone(identifier: "Europe/Kyiv")!   // DST began 2026-03-29 03:00
        cal.firstWeekday = 2
        return cal
    }()

    private func date(_ y: Int, _ m: Int, _ d: Int, _ h: Int, _ min: Int = 0) -> Date {
        calendar.date(from: DateComponents(year: y, month: m, day: d, hour: h, minute: min))!
    }

    private let nda = Workflow(name: "Client", flags: WorkflowFlags(ndaMode: true), isDefault: false, order: 0)
    private let plain = Workflow(name: "General", flags: WorkflowFlags(ndaMode: false), isDefault: true, order: 1)
    /// Same name as `nda`: the first one wins, as `first(where:)` did.
    private let shadow = Workflow(name: "Client", flags: WorkflowFlags(ndaMode: false), isDefault: false, order: 2)
    private var workflows: [Workflow] { [nda, plain, shadow] }

    private func fixture(now: Date) -> [Meeting] {
        let names: [String?] = ["Client", "General", "", nil, "Deleted"]
        let statuses: [Meeting.Status] = [.done, .failed, .processing, .empty, .manualPasteReady, .done]
        var meetings: [Meeting] = []
        var t = date(2025, 11, 1, 0, 30)
        var i = 0
        // Every 5h37m, so the times of day walk through midnight and the DST hour.
        while t < now.addingTimeInterval(3600) {
            meetings.append(makeMeeting("m\(i)", at: t, workflow: names[i % names.count], status: statuses[i % statuses.count]))
            t = t.addingTimeInterval(5 * 3600 + 37 * 60)
            i += 1
        }
        // A minute either side of each cutoff.
        let edges = [
            calendar.startOfDay(for: now),
            calendar.date(byAdding: .day, value: -7, to: now)!,
            calendar.date(byAdding: .day, value: -30, to: now)!,
        ]
        for (j, edge) in edges.enumerated() {
            meetings.append(makeMeeting("e\(j)a", at: edge.addingTimeInterval(-60), workflow: "Client"))
            meetings.append(makeMeeting("e\(j)b", at: edge.addingTimeInterval(60), workflow: "General"))
            meetings.append(makeMeeting("e\(j)c", at: edge, workflow: nil))
        }
        return meetings.sorted { $0.startedAt > $1.startedAt }
    }

    /// Three clocks: the morning after the DST change, a few days on, and a week on, so the 7-day
    /// cutoff falls on each side of it and one clock sits just after midnight.
    private var nows: [Date] { [date(2026, 3, 30, 9, 15), date(2026, 4, 2, 0, 20), date(2026, 4, 5, 23, 59)] }

    func test_scope_counts_are_identical_to_the_per_meeting_cutoffs_they_replaced() {
        for now in nows {
            let meetings = fixture(now: now)
            XCTAssertEqual(
                ScopeCounts.build(meetings: meetings, workflows: workflows, now: now, calendar: calendar),
                legacyCounts(meetings: meetings, workflows: workflows, now: now),
                "now = \(now)"
            )
        }
    }

    func test_includes_through_a_context_matches_the_per_meeting_predicate() {
        let scopes: [LibraryScope] = [
            .allMeetings, .today, .last7Days, .last30Days, .needsYou, .ndaOnly, .untagged,
            .workflow(nda.id), .workflow(plain.id), .workflow(shadow.id), .facts,
        ]
        for now in nows {
            let context = LibraryScope.Context(workflows: workflows, now: now, calendar: calendar)
            for m in fixture(now: now) {
                for s in scopes {
                    XCTAssertEqual(
                        s.includes(m, in: context),
                        legacyIncludes(s, m, workflows: workflows, now: now),
                        "\(s.title) \(m.stem) at \(m.startedAt)"
                    )
                }
            }
        }
    }

    func test_month_groups_are_identical_to_the_per_meeting_derivation_they_replaced() {
        for now in nows {
            let meetings = fixture(now: now)
            let new = MeetingGroup.group(meetings, now: now, calendar: calendar)
            let old = legacyGroup(meetings, now: now)
            XCTAssertEqual(new.map(\.title), old.map(\.title), "now = \(now)")
            XCTAssertEqual(new.map(\.order), old.map(\.order))
            XCTAssertEqual(new.map { $0.meetings.map(\.stem) }, old.map { $0.meetings.map(\.stem) })
            XCTAssertGreaterThan(new.count, 7, "the fixture spans the fixed buckets and several months")
        }
    }

    // MARK: The implementations PERF22 replaced, verbatim but for the pinned calendar

    private func legacyIncludes(_ scope: LibraryScope, _ meeting: Meeting, workflows: [Workflow], now: Date) -> Bool {
        func resolve() -> Workflow? {
            guard let name = meeting.workflowName, !name.isEmpty else { return nil }
            return workflows.first { $0.name == name }
        }
        switch scope {
        case .allMeetings:
            return true
        case .today:
            return meeting.startedAt >= calendar.startOfDay(for: now)
        case .last7Days:
            guard let cutoff = calendar.date(byAdding: .day, value: -7, to: now) else { return true }
            return meeting.startedAt >= cutoff
        case .last30Days:
            guard let cutoff = calendar.date(byAdding: .day, value: -30, to: now) else { return true }
            return meeting.startedAt >= cutoff
        case .needsYou:
            switch meeting.status {
            case .failed, .manualPasteReady, .empty: return true
            case .done: return meeting.publishState == "none" || meeting.publishState == "partial"
            default: return false
            }
        case .ndaOnly:
            return resolve()?.flags.ndaMode == true
        case .untagged:
            return (meeting.workflowName?.isEmpty ?? true)
        case .facts, .ask, .digests, .people, .stats, .saved:
            return false
        case .workflow(let id):
            return resolve()?.id == id
        }
    }

    private func legacyCounts(meetings: [Meeting], workflows: [Workflow], now: Date) -> ScopeCounts {
        var today = 0, last7 = 0, last30 = 0, needsYou = 0, nda = 0, untagged = 0
        var perWf: [Workflow.ID: Int] = [:]
        let scopes: [LibraryScope] = [.today, .last7Days, .last30Days, .needsYou, .ndaOnly, .untagged]
        for m in meetings {
            for s in scopes {
                guard legacyIncludes(s, m, workflows: workflows, now: now) else { continue }
                switch s {
                case .today: today += 1
                case .last7Days: last7 += 1
                case .last30Days: last30 += 1
                case .needsYou: needsYou += 1
                case .ndaOnly: nda += 1
                case .untagged: untagged += 1
                default: break
                }
            }
            if let name = m.workflowName, !name.isEmpty,
               let wf = workflows.first(where: { $0.name == name }) {
                perWf[wf.id, default: 0] += 1
            }
        }
        return ScopeCounts(
            total: meetings.count, today: today, last7: last7, last30: last30,
            needsYou: needsYou, nda: nda, untagged: untagged, perWorkflow: perWf, perSaved: [:]
        )
    }

    private func legacyGroup(_ meetings: [Meeting], now: Date) -> [MeetingGroup] {
        let cal = calendar
        let todayStart = cal.startOfDay(for: now)
        let yesterdayStart = cal.date(byAdding: .day, value: -1, to: todayStart) ?? todayStart
        let thisWeekStart = cal.date(
            from: cal.dateComponents([.yearForWeekOfYear, .weekOfYear], from: now)
        ) ?? todayStart
        let lastWeekStart = cal.date(byAdding: .weekOfYear, value: -1, to: thisWeekStart) ?? thisWeekStart
        let thisMonthStart = cal.date(from: cal.dateComponents([.year, .month], from: now)) ?? todayStart
        var buckets: [Int: (title: String, meetings: [Meeting])] = [:]
        for meeting in meetings {
            let ts = meeting.startedAt
            let key: (Int, String)
            if ts >= todayStart {
                key = (0, "Today")
            } else if ts >= yesterdayStart {
                key = (1, "Yesterday")
            } else if ts >= thisWeekStart {
                key = (2, "This week")
            } else if ts >= lastWeekStart {
                key = (3, "Last week")
            } else if ts >= thisMonthStart {
                key = (4, "Earlier this month")
            } else {
                let monthAnchor = cal.date(from: cal.dateComponents([.year, .month], from: ts)) ?? ts
                let monthsAgo = max(1, cal.dateComponents([.month], from: monthAnchor, to: thisMonthStart).month ?? 1)
                key = (5 + monthsAgo, MeetingFormatters.monthYear.string(from: ts))
            }
            buckets[key.0, default: (title: key.1, meetings: [])].meetings.append(meeting)
        }
        return buckets
            .sorted { $0.key < $1.key }
            .map { MeetingGroup(title: $0.value.title, meetings: $0.value.meetings, order: $0.key) }
    }

    private func makeMeeting(_ stem: String, at date: Date, workflow: String?, status: Meeting.Status = .done) -> Meeting {
        var m = Meeting(
            stem: stem,
            startedAt: date,
            audioURL: nil,
            recordingsDir: URL(fileURLWithPath: "/tmp"),
            summaryTitle: nil, meetingTitle: nil,
            sourceBundleID: nil, sourceDisplayName: nil, sourceKind: nil,
            workflowName: workflow, workflowColor: nil,
            durationSec: nil, backend: nil, modelId: nil,
            status: status, failureReason: nil, failureStage: nil,
            searchableText: ""
        )
        m.publishState = stem.hasSuffix("3") ? "none" : (stem.hasSuffix("7") ? "partial" : "full")
        return m
    }
}
