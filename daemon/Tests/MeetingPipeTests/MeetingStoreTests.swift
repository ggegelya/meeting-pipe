import Combine
import XCTest
@testable import MeetingPipe

/// `MeetingStore` materializes the on-disk sidecar layout into `Meeting`
/// rows. The grouping helper carves the chronological list into the
/// Today / Yesterday / This week / older buckets the list view renders.
final class MeetingStoreTests: XCTestCase {

    private func tempDir() throws -> URL {
        let dir = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("mp-meetingstore-\(UUID().uuidString)",
                                    isDirectory: true)
        try FileManager.default.createDirectory(at: dir,
                                                withIntermediateDirectories: true)
        return dir
    }

    private func writeFile(_ url: URL, _ contents: String = "") throws {
        try contents.data(using: .utf8)!.write(to: url, options: .atomic)
    }

    private func setMtime(_ url: URL, _ date: Date) throws {
        try FileManager.default.setAttributes([.modificationDate: date], ofItemAtPath: url.path)
    }

    // MARK: stem + parse

    func test_stem_strips_first_dot_onward() {
        let url = URL(fileURLWithPath: "/tmp/20260511-143110.summary.json")
        XCTAssertEqual(MeetingStore.stem(of: url), "20260511-143110")
    }

    func test_stem_handles_plain_filename() {
        let url = URL(fileURLWithPath: "/tmp/20260511-143110")
        XCTAssertEqual(MeetingStore.stem(of: url), "20260511-143110")
    }

    func test_parseStem_returns_date_for_canonical_format() {
        XCTAssertNotNil(MeetingStore.parseStem("20260511-143110"))
    }

    func test_parseStem_rejects_garbage() {
        XCTAssertNil(MeetingStore.parseStem("not-a-stem"))
        XCTAssertNil(MeetingStore.parseStem(""))
    }

    // MARK: status inference

    func test_status_done_when_summary_present() throws {
        let dir = try tempDir()
        let stem = "20260511-143110"
        try writeFile(dir.appendingPathComponent("\(stem).wav"))
        try writeFile(dir.appendingPathComponent("\(stem).summary.json"), "{\"title\":\"x\"}")
        let store = MeetingStore(recordingsDir: dir)
        let exp = expectation(description: "scan")
        var captured: [Meeting] = []
        let cancel = store.$meetings.dropFirst().sink { meetings in
            captured = meetings
            exp.fulfill()
        }
        store.start()
        wait(for: [exp], timeout: 2.0)
        cancel.cancel()
        XCTAssertEqual(captured.count, 1)
        XCTAssertEqual(captured.first?.status, .done)
    }

    func test_status_manual_paste_when_ready_marker_present() throws {
        let dir = try tempDir()
        let stem = "20260511-143110"
        try writeFile(dir.appendingPathComponent("\(stem).wav"))
        try writeFile(dir.appendingPathComponent("\(stem).READY_FOR_MANUAL.md"))
        let store = MeetingStore(recordingsDir: dir)
        let exp = expectation(description: "scan")
        var captured: [Meeting] = []
        let cancel = store.$meetings.dropFirst().sink { meetings in
            captured = meetings
            exp.fulfill()
        }
        store.start()
        wait(for: [exp], timeout: 2.0)
        cancel.cancel()
        XCTAssertEqual(captured.first?.status, .manualPasteReady)
    }

    func test_processing_when_only_wav_present() throws {
        let dir = try tempDir()
        // Use a stem within the staleness window so it stays processing.
        let recentStem = MeetingFormatters.stem.string(from: Date().addingTimeInterval(-60))
        try writeFile(dir.appendingPathComponent("\(recentStem).wav"))
        let store = MeetingStore(recordingsDir: dir)
        let exp = expectation(description: "scan")
        var captured: [Meeting] = []
        let cancel = store.$meetings.dropFirst().sink { meetings in
            captured = meetings
            exp.fulfill()
        }
        store.start()
        wait(for: [exp], timeout: 2.0)
        cancel.cancel()
        XCTAssertEqual(captured.first?.status, .processing)
    }

    func test_failed_when_processing_older_than_staleness_threshold() throws {
        let dir = try tempDir()
        // Stem far in the past — exceeds staleProcessingThresholdSec (2 h)
        // with no summary on disk.
        let stem = "20240501-090000"
        try writeFile(dir.appendingPathComponent("\(stem).wav"))
        let store = MeetingStore(recordingsDir: dir)
        let exp = expectation(description: "scan")
        var captured: [Meeting] = []
        let cancel = store.$meetings.dropFirst().sink { meetings in
            captured = meetings
            exp.fulfill()
        }
        store.start()
        wait(for: [exp], timeout: 2.0)
        cancel.cancel()
        XCTAssertEqual(captured.first?.status, .failed)
    }

    func test_done_overrides_staleness() throws {
        // Even an ancient meeting stays `.done` once a summary lands.
        let dir = try tempDir()
        let stem = "20240501-090000"
        try writeFile(dir.appendingPathComponent("\(stem).wav"))
        try writeFile(dir.appendingPathComponent("\(stem).summary.json"), "{}")
        let store = MeetingStore(recordingsDir: dir)
        let exp = expectation(description: "scan")
        var captured: [Meeting] = []
        let cancel = store.$meetings.dropFirst().sink { meetings in
            captured = meetings
            exp.fulfill()
        }
        store.start()
        wait(for: [exp], timeout: 2.0)
        cancel.cancel()
        XCTAssertEqual(captured.first?.status, .done)
    }

    // MARK: failure surfacing

    func test_failed_when_error_sidecar_present() throws {
        let dir = try tempDir()
        // A recent stem: without the error sidecar this would be
        // `.processing`, so the test proves the sidecar is what flips it.
        let stem = MeetingFormatters.stem.string(from: Date().addingTimeInterval(-60))
        try writeFile(dir.appendingPathComponent("\(stem).wav"))
        PipelineFailureSidecar.write(
            stem: stem, in: dir, stage: .pipeline, reason: "pipeline exited 1: boom"
        )
        let store = MeetingStore(recordingsDir: dir)
        let exp = expectation(description: "scan")
        var captured: [Meeting] = []
        let cancel = store.$meetings.dropFirst().sink { meetings in
            captured = meetings
            exp.fulfill()
        }
        store.start()
        wait(for: [exp], timeout: 2.0)
        cancel.cancel()
        let row = try XCTUnwrap(captured.first)
        XCTAssertEqual(row.status, .failed)
        XCTAssertEqual(row.failureReason, "pipeline exited 1: boom")
        XCTAssertEqual(row.failureStage, "pipeline")
    }

    func test_summary_supersedes_a_stale_error_sidecar() throws {
        // A regenerate produced a summary but left the old failure
        // sidecar behind: the row is `.done`, not `.failed`.
        let dir = try tempDir()
        let stem = "20260511-143110"
        try writeFile(dir.appendingPathComponent("\(stem).wav"))
        try writeFile(dir.appendingPathComponent("\(stem).summary.json"), "{}")
        PipelineFailureSidecar.write(
            stem: stem, in: dir, stage: .pipeline, reason: "old failure"
        )
        let store = MeetingStore(recordingsDir: dir)
        let exp = expectation(description: "scan")
        var captured: [Meeting] = []
        let cancel = store.$meetings.dropFirst().sink { meetings in
            captured = meetings
            exp.fulfill()
        }
        store.start()
        wait(for: [exp], timeout: 2.0)
        cancel.cancel()
        let row = try XCTUnwrap(captured.first)
        XCTAssertEqual(row.status, .done)
        XCTAssertNil(row.failureReason)
    }

    func test_unrecoveredFailureStems_finds_error_without_summary() {
        let stems = MeetingStore.unrecoveredFailureStems(fileNames: [
            "a.wav", "a.error.json",
            "b.wav", "b.summary.json",
            "c.wav", "c.error.json", "c.summary.json",
        ])
        XCTAssertEqual(stems, ["a"],
                       "b succeeded; c's summary supersedes its error sidecar")
    }

    func test_unrecoveredFailureStems_empty_when_no_failures() {
        XCTAssertTrue(MeetingStore.unrecoveredFailureStems(fileNames: [
            "a.wav", "a.summary.json", "b.wav",
        ]).isEmpty)
    }

    // MARK: meta + summary parsing

    func test_meta_and_summary_populate_row_fields() throws {
        let dir = try tempDir()
        let stem = "20260511-143110"
        try writeFile(dir.appendingPathComponent("\(stem).wav"))
        let meta: [String: Any] = [
            "source_bundle_id": "us.zoom.xos",
            "source_display_name": "Zoom",
            "source_kind": "native",
            "meeting_title": "Sprint planning",
        ]
        let metaData = try JSONSerialization.data(withJSONObject: meta)
        try metaData.write(to: dir.appendingPathComponent("\(stem).meta.json"))
        let summary: [String: Any] = ["title": "Aligned scope for Q3"]
        let summaryData = try JSONSerialization.data(withJSONObject: summary)
        try summaryData.write(to: dir.appendingPathComponent("\(stem).summary.json"))

        let store = MeetingStore(recordingsDir: dir)
        let exp = expectation(description: "scan")
        var captured: [Meeting] = []
        let cancel = store.$meetings.dropFirst().sink { meetings in
            captured = meetings
            exp.fulfill()
        }
        store.start()
        wait(for: [exp], timeout: 2.0)
        cancel.cancel()
        let row = try XCTUnwrap(captured.first)
        XCTAssertEqual(row.stem, stem)
        XCTAssertEqual(row.summaryTitle, "Aligned scope for Q3")
        XCTAssertEqual(row.meetingTitle, "Sprint planning")
        XCTAssertEqual(row.sourceBundleID, "us.zoom.xos")
        XCTAssertEqual(row.sourceDisplayName, "Zoom")
        XCTAssertEqual(row.sourceKind, .native)
        XCTAssertEqual(row.displayTitle, "Aligned scope for Q3")
    }

    func test_displayTitle_falls_back_to_source_when_summary_missing() throws {
        let dir = try tempDir()
        let stem = "20260511-143110"
        try writeFile(dir.appendingPathComponent("\(stem).wav"))
        let meta: [String: Any] = [
            "source_bundle_id": "us.zoom.xos",
            "source_display_name": "Zoom",
        ]
        let metaData = try JSONSerialization.data(withJSONObject: meta)
        try metaData.write(to: dir.appendingPathComponent("\(stem).meta.json"))
        let store = MeetingStore(recordingsDir: dir)
        let exp = expectation(description: "scan")
        var captured: [Meeting] = []
        let cancel = store.$meetings.dropFirst().sink { meetings in
            captured = meetings
            exp.fulfill()
        }
        store.start()
        wait(for: [exp], timeout: 2.0)
        cancel.cancel()
        let row = try XCTUnwrap(captured.first)
        XCTAssertTrue(row.displayTitle.contains("Zoom at "), "got \(row.displayTitle)")
    }

    // MARK: ordering

    func test_scan_sorts_newest_first() throws {
        let dir = try tempDir()
        try writeFile(dir.appendingPathComponent("20260510-080000.wav"))
        try writeFile(dir.appendingPathComponent("20260511-143110.wav"))
        try writeFile(dir.appendingPathComponent("20260509-101010.wav"))
        let store = MeetingStore(recordingsDir: dir)
        let exp = expectation(description: "scan")
        var captured: [Meeting] = []
        let cancel = store.$meetings.dropFirst().sink { meetings in
            captured = meetings
            exp.fulfill()
        }
        store.start()
        wait(for: [exp], timeout: 2.0)
        cancel.cancel()
        XCTAssertEqual(
            captured.map(\.stem),
            ["20260511-143110", "20260510-080000", "20260509-101010"]
        )
    }

    // MARK: mtime cache (TECH-A12)

    func test_mtime_cache_serves_stale_row_until_mtime_changes() throws {
        // Drives performScan directly (synchronous) so the cache behavior is
        // deterministic without the debounce / watcher timing. Both files are
        // pinned to whole-second mtimes that round-trip losslessly through
        // setAttributes, so "unchanged" really means a bit-identical signature.
        let dir = try tempDir()
        let stem = "20260511-143110"
        let wavURL = dir.appendingPathComponent("\(stem).wav")
        let summaryURL = dir.appendingPathComponent("\(stem).summary.json")
        try writeFile(wavURL)
        try writeFile(summaryURL, "{\"title\":\"Alpha\"}")
        let wavTime = Date(timeIntervalSince1970: 1_700_000_000)
        let summaryTime = Date(timeIntervalSince1970: 1_700_000_100)
        try setMtime(wavURL, wavTime)
        try setMtime(summaryURL, summaryTime)

        let store = MeetingStore(recordingsDir: dir)
        XCTAssertEqual(store.performScan(directory: dir).first?.summaryTitle, "Alpha")

        // Rewrite the content but restore the same mtimes. The signature is
        // unchanged, so a working cache serves the stale row (the JSON parse
        // was skipped) rather than the new content.
        try writeFile(summaryURL, "{\"title\":\"Beta\"}")
        try setMtime(wavURL, wavTime)
        try setMtime(summaryURL, summaryTime)
        XCTAssertEqual(
            store.performScan(directory: dir).first?.summaryTitle, "Alpha",
            "unchanged mtime should reuse the cached row (no re-parse)"
        )

        // Bump the summary mtime: signature changes, the row re-parses.
        try setMtime(summaryURL, summaryTime.addingTimeInterval(5))
        XCTAssertEqual(
            store.performScan(directory: dir).first?.summaryTitle, "Beta",
            "a changed mtime should trigger a re-parse"
        )
    }

    func test_new_meeting_appears_on_next_scan() throws {
        let dir = try tempDir()
        try writeFile(dir.appendingPathComponent("20260511-143110.wav"))
        try writeFile(dir.appendingPathComponent("20260511-143110.summary.json"), "{\"title\":\"A\"}")
        let store = MeetingStore(recordingsDir: dir)
        XCTAssertEqual(store.performScan(directory: dir).count, 1)

        try writeFile(dir.appendingPathComponent("20260512-090000.wav"))
        try writeFile(dir.appendingPathComponent("20260512-090000.summary.json"), "{\"title\":\"B\"}")
        let rows = store.performScan(directory: dir)
        XCTAssertEqual(rows.count, 2, "a new stem must appear even though older rows are cached")
        XCTAssertEqual(rows.map(\.stem), ["20260512-090000", "20260511-143110"])
    }

    func test_processing_row_is_not_cached_and_picks_up_a_late_summary() throws {
        // A `.processing` row is age-derived, so it must re-evaluate each scan
        // rather than be pinned in the cache.
        let dir = try tempDir()
        let stem = MeetingFormatters.stem.string(from: Date().addingTimeInterval(-60))
        try writeFile(dir.appendingPathComponent("\(stem).wav"))
        let store = MeetingStore(recordingsDir: dir)
        XCTAssertEqual(store.performScan(directory: dir).first?.status, .processing)

        try writeFile(dir.appendingPathComponent("\(stem).summary.json"), "{\"title\":\"done now\"}")
        let rows = store.performScan(directory: dir)
        XCTAssertEqual(rows.first?.status, .done)
        XCTAssertEqual(rows.first?.summaryTitle, "done now")
    }

    // MARK: republish staleness (TECH-UX2)

    func test_needsRepublish_true_when_summary_newer_than_publish_sidecar() throws {
        let dir = try tempDir()
        let stem = "20260511-143110"
        try writeFile(dir.appendingPathComponent("\(stem).wav"))
        let summaryURL = dir.appendingPathComponent("\(stem).summary.json")
        let notionURL = dir.appendingPathComponent("\(stem).notion.json")
        try writeFile(summaryURL, "{\"title\":\"x\"}")
        try writeFile(notionURL, "{\"page_url\":\"https://n\"}")
        try setMtime(notionURL, Date(timeIntervalSince1970: 1_700_000_000))
        try setMtime(summaryURL, Date(timeIntervalSince1970: 1_700_000_500))
        let store = MeetingStore(recordingsDir: dir)
        XCTAssertEqual(store.performScan(directory: dir).first?.needsRepublish, true)
    }

    func test_needsRepublish_false_when_publish_is_current() throws {
        let dir = try tempDir()
        let stem = "20260511-143110"
        try writeFile(dir.appendingPathComponent("\(stem).wav"))
        let summaryURL = dir.appendingPathComponent("\(stem).summary.json")
        let obsidianURL = dir.appendingPathComponent("\(stem).obsidian.json")
        try writeFile(summaryURL, "{\"title\":\"x\"}")
        try writeFile(obsidianURL, "{}")
        try setMtime(summaryURL, Date(timeIntervalSince1970: 1_700_000_000))
        try setMtime(obsidianURL, Date(timeIntervalSince1970: 1_700_000_500))
        let store = MeetingStore(recordingsDir: dir)
        XCTAssertEqual(store.performScan(directory: dir).first?.needsRepublish, false)
    }

    func test_needsRepublish_false_when_never_published() throws {
        let dir = try tempDir()
        let stem = "20260511-143110"
        try writeFile(dir.appendingPathComponent("\(stem).wav"))
        try writeFile(dir.appendingPathComponent("\(stem).summary.json"), "{\"title\":\"x\"}")
        let store = MeetingStore(recordingsDir: dir)
        XCTAssertEqual(store.performScan(directory: dir).first?.needsRepublish, false)
    }

    // MARK: detected language lift (TECH-UI-4)

    func test_detectedLanguage_lifted_from_summary() throws {
        let dir = try tempDir()
        let stem = "20260511-143110"
        try writeFile(dir.appendingPathComponent("\(stem).wav"))
        try writeFile(dir.appendingPathComponent("\(stem).summary.json"),
                      "{\"title\":\"x\",\"detected_language\":\"uk\"}")
        let store = MeetingStore(recordingsDir: dir)
        XCTAssertEqual(store.performScan(directory: dir).first?.detectedLanguage, "uk")
    }

    func test_detectedLanguage_nil_when_absent() throws {
        let dir = try tempDir()
        let stem = "20260511-143110"
        try writeFile(dir.appendingPathComponent("\(stem).wav"))
        try writeFile(dir.appendingPathComponent("\(stem).summary.json"), "{\"title\":\"x\"}")
        let store = MeetingStore(recordingsDir: dir)
        XCTAssertNil(store.performScan(directory: dir).first?.detectedLanguage)
    }

    // MARK: grouping

    func test_group_buckets_today_yesterday_and_older() {
        // "now" must be late enough in the week that "-3 days" lands in
        // the same calendar week regardless of the locale's
        // `firstWeekday` setting (Sunday in en_US, Monday in many EU
        // locales). Friday 2026-05-15 → -3 days = Tuesday 2026-05-12,
        // which is in the same week under any common convention.
        let now = makeDate(year: 2026, month: 5, day: 15, hour: 12, minute: 0)
        let cal = Calendar.current
        let today = cal.date(byAdding: .hour, value: -2, to: now)!
        let yesterday = cal.date(byAdding: .day, value: -1, to: now)!
        let thisWeek = cal.date(byAdding: .day, value: -3, to: now)!
        let lastMonth = cal.date(byAdding: .month, value: -2, to: now)!

        let meetings = [
            makeMeeting("a", at: today),
            makeMeeting("b", at: yesterday),
            makeMeeting("c", at: thisWeek),
            makeMeeting("d", at: lastMonth),
        ]
        let groups = MeetingGroup.group(meetings, now: now)
        let titles = groups.map(\.title)
        XCTAssertEqual(titles.prefix(3), ["Today", "Yesterday", "This week"])
        // Last group's title is a "Month YYYY" string.
        XCTAssertTrue(titles.last?.contains("2026") ?? false)
    }

    func test_group_orders_older_months_after_fixed_buckets_newest_first() {
        let now = makeDate(year: 2026, month: 5, day: 12, hour: 12, minute: 0)
        let cal = Calendar.current
        let today = cal.date(byAdding: .hour, value: -2, to: now)!
        let april = makeDate(year: 2026, month: 4, day: 15, hour: 10, minute: 0)
        let march = makeDate(year: 2026, month: 3, day: 20, hour: 10, minute: 0)
        let february = makeDate(year: 2026, month: 2, day: 5, hour: 10, minute: 0)

        let meetings = [
            makeMeeting("d", at: today),
            makeMeeting("c", at: april),
            makeMeeting("b", at: march),
            makeMeeting("a", at: february),
        ]
        let groups = MeetingGroup.group(meetings, now: now)
        let titles = groups.map(\.title)
        // Today must be first; older months follow in reverse-chrono order.
        XCTAssertEqual(titles.first, "Today")
        let monthTitles = titles.dropFirst()
        XCTAssertTrue(
            monthTitles.contains(where: { $0.contains("April") }),
            "got \(titles)"
        )
        // April should come BEFORE March, March before February.
        let aprilIdx = titles.firstIndex(where: { $0.contains("April") })!
        let marchIdx = titles.firstIndex(where: { $0.contains("March") })!
        let febIdx = titles.firstIndex(where: { $0.contains("February") })!
        XCTAssertLessThan(aprilIdx, marchIdx)
        XCTAssertLessThan(marchIdx, febIdx)
    }

    func test_group_drops_empty_buckets() {
        let now = makeDate(year: 2026, month: 5, day: 12, hour: 12, minute: 0)
        let cal = Calendar.current
        let today = cal.date(byAdding: .hour, value: -2, to: now)!
        let meetings = [makeMeeting("a", at: today)]
        let groups = MeetingGroup.group(meetings, now: now)
        XCTAssertEqual(groups.count, 1)
        XCTAssertEqual(groups.first?.title, "Today")
    }

    // MARK: Helpers

    private func makeDate(year: Int, month: Int, day: Int, hour: Int, minute: Int) -> Date {
        var c = DateComponents()
        c.year = year; c.month = month; c.day = day
        c.hour = hour; c.minute = minute
        return Calendar.current.date(from: c)!
    }

    private func makeMeeting(_ stem: String, at date: Date) -> Meeting {
        Meeting(
            stem: stem,
            startedAt: date,
            wavURL: URL(fileURLWithPath: "/tmp/\(stem).wav"),
            recordingsDir: URL(fileURLWithPath: "/tmp"),
            summaryTitle: nil,
            meetingTitle: nil,
            sourceBundleID: nil,
            sourceDisplayName: nil,
            sourceKind: nil,
            workflowName: nil,
            workflowColor: nil,
            durationSec: nil,
            backend: nil,
            modelId: nil,
            status: .done,
            failureReason: nil,
            failureStage: nil,
            searchableText: ""
        )
    }
}

