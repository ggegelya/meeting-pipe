import XCTest
@testable import MeetingPipe

/// UX93: failure notices name what failed, a stem-less notice keeps its message across a relaunch, a
/// done banner routes with no in-memory map, and an `mp` timeout names its own job.
final class NotificationPayloadUX93Tests: XCTestCase {

    // MARK: - Operations and explanations

    func test_new_operations_have_their_titles() {
        XCTAssertEqual(FailureMetadata.Operation.recording.failureTitle, "Couldn't record the meeting")
        XCTAssertEqual(FailureMetadata.Operation.people.failureTitle, "Couldn't save the name")
    }

    func test_unknown_cause_on_recording_explains_with_the_message_and_offers_no_retry() {
        let message = "Microphone permission is required. Grant it in Preferences → Permissions, then try again."
        let failure = FailurePresentation(diagnostics: message, operation: .recording)
        XCTAssertEqual(failure.title, "Couldn't record the meeting")
        XCTAssertEqual(failure.explanation, message)
        XCTAssertFalse(failure.explanation.contains("Retry when you are ready"))
    }

    func test_unknown_cause_on_summary_still_offers_the_retry_sentence() {
        let failure = FailurePresentation(diagnostics: "something odd", operation: .summary)
        XCTAssertTrue(failure.explanation.contains("Retry when you are ready"), failure.explanation)
    }

    func test_a_multi_line_storage_diagnostic_stays_behind_details() {
        let traceback = "Traceback (most recent call last):\n  File \"x.py\", line 1\nOSError: boom"
        let failure = FailurePresentation(diagnostics: traceback, operation: .storage)
        XCTAssertFalse(failure.explanation.contains("Traceback"), failure.explanation)
    }

    func test_notification_only_operations_never_decode_from_a_sidecar() {
        for op in ["recording", "people"] {
            let json = #"{"schema_version":1,"cause":"unknown","operation":"\#(op)"}"#
            XCTAssertNil(FailureMetadata.decode(Data(json.utf8)), op)
        }
        XCTAssertNotNil(FailureMetadata.decode(Data(#"{"schema_version":1,"cause":"unknown","operation":"summary"}"#.utf8)))
    }

    // MARK: - One stage mapping for the row and the banner

    func test_stage_mapping_is_shared_by_the_row_and_the_banner() {
        XCTAssertEqual(FailurePresentation.operation(forStage: "transcribe"), .transcribe)
        XCTAssertEqual(FailurePresentation.operation(forStage: "publish"), .publish)
        XCTAssertEqual(FailurePresentation.operation(forStage: "pipeline"), .summary)
        XCTAssertEqual(FailurePresentation.operation(forStage: nil), .summary)
        let banner = FailurePresentation(
            error: PipelineLauncher.LaunchError.nonZeroExit(1, "boom"),
            operation: FailurePresentation.operation(forStage: "transcribe")
        )
        XCTAssertEqual(banner.title, "Couldn't transcribe the recording")
    }

    func test_the_detail_view_reads_the_shared_mapping() throws {
        let source = try String(contentsOf: Self.sources.appendingPathComponent("MeetingDetailView.swift"), encoding: .utf8)
        XCTAssertTrue(source.contains("FailurePresentation.operation(forStage: meeting.failureStage)"))
    }

    // MARK: - Stem-less failures survive a relaunch

    func test_a_stem_less_failure_carries_operation_title_and_message_and_no_diagnostics() {
        let message = "Rename failed: disk full"
        let failure = FailurePresentation(diagnostics: message, operation: .people)
        let info = FailureNotificationPayload.userInfo(failure: failure, stem: nil, message: message)
        XCTAssertEqual(Set(info.keys), [FailureNotificationPayload.operationKey,
                                        FailureNotificationPayload.titleKey, FailureNotificationPayload.messageKey])
        XCTAssertEqual(info[FailureNotificationPayload.messageKey], message)
        XCTAssertEqual(FailureNotificationPayload.body(failure: failure, stem: nil, message: message), message)

        let rebuilt = try? XCTUnwrap(FailureNotificationPayload.rebuild(userInfo: info))
        XCTAssertEqual(rebuilt?.title, failure.title)
        XCTAssertEqual(rebuilt?.explanation, failure.explanation)
    }

    func test_a_title_override_survives_the_rebuild() {
        let failure = FailurePresentation(diagnostics: "Still finishing...", operation: .recording,
                                          title: "Still finishing the recording")
        let info = FailureNotificationPayload.userInfo(failure: failure, stem: nil, message: "Still finishing...")
        XCTAssertEqual(FailureNotificationPayload.rebuild(userInfo: info)?.title, "Still finishing the recording")
    }

    func test_a_stem_failure_carries_only_the_stem() {
        let failure = FailurePresentation(diagnostics: "Traceback: secret detail", operation: .summary)
        let info = FailureNotificationPayload.userInfo(failure: failure, stem: "20260511-143110", message: nil)
        XCTAssertEqual(info, [FailureNotificationPayload.stemKey: "20260511-143110"])
        XCTAssertEqual(FailureNotificationPayload.body(failure: failure, stem: "20260511-143110", message: nil),
                       "Review in Library.")
    }

    func test_a_notice_from_an_older_build_rebuilds_nothing() {
        XCTAssertNil(FailureNotificationPayload.rebuild(userInfo: [:]))
    }

    func test_eviction_drops_the_oldest_entry() {
        var store = InsertionOrderedStore<Int>(capacity: 3)
        for (i, key) in ["z", "a", "m", "b"].enumerated() { store.insert(i, for: key) }
        XCTAssertNil(store["z"], "the first inserted is evicted, whatever its key sorts as")
        XCTAssertEqual(store.order, ["a", "m", "b"])
        XCTAssertEqual(store.remove("m"), 2)
        XCTAssertEqual(store.count, 2)
    }

    // MARK: - Done banners route with no in-memory map

    func test_a_done_banner_rebuilds_its_entry_from_userInfo_after_a_relaunch() throws {
        let dir = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("mp-ux93-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let stem = "20260511-143110"
        try #"{"state":"full","page_url":"file:///n.md","sinks":{"filesystem":{"ok":true,"page_url":"file:///n.md"}}}"#
            .write(to: dir.appendingPathComponent("\(stem).publish.json"), atomically: true, encoding: .utf8)

        let info = DoneNotificationPayload.userInfo(stem: stem)
        let resolved = try XCTUnwrap(DoneNotificationPayload.resolve(userInfo: info, recordingsDir: dir))
        XCTAssertEqual(resolved.entry, NotificationRouter.DoneEntry(stem: stem, hasPageURL: true))
        XCTAssertEqual(resolved.pageURL, URL(string: "file:///n.md"))

        // A banner id this process never posted: Looks good, Edit and Open all still route.
        let id = "done-\(UUID().uuidString)"
        let R = NotificationRouter.self
        XCTAssertEqual(R.route(id: id, action: R.actionLooksGood, isDefault: false, doneEntry: resolved.entry).routes,
                       [.markLooksGood(stem: stem)])
        XCTAssertEqual(R.route(id: id, action: R.actionEditSummary, isDefault: false, doneEntry: resolved.entry).routes,
                       [.editSummary(stem: stem)])
        XCTAssertEqual(R.route(id: id, action: R.actionOpen, isDefault: false, doneEntry: resolved.entry).routes,
                       [.openPage])
    }

    func test_a_local_only_done_banner_has_no_page() throws {
        let dir = URL(fileURLWithPath: NSTemporaryDirectory())
        let resolved = try XCTUnwrap(DoneNotificationPayload.resolve(userInfo: [DoneNotificationPayload.stemKey: "nope"],
                                                                     recordingsDir: dir))
        XCTAssertFalse(resolved.entry.hasPageURL)
        XCTAssertNil(DoneNotificationPayload.resolve(userInfo: [:], recordingsDir: dir))
    }

    func test_no_doneEntries_map_is_left_in_the_sources() throws {
        for file in try Self.swiftSources() {
            let text = try String(contentsOf: file, encoding: .utf8)
            XCTAssertFalse(text.contains("doneEntries"), file.lastPathComponent)
        }
    }

    // MARK: - Every stem-less notice names its operation

    /// The parameter is non-defaulted, so the compiler already holds `Notifier`, `SessionNotifying`
    /// and the Library service to it; this catches a default creeping back in.
    func test_every_notifyError_call_names_an_operation() throws {
        var offenders: [String] = []
        for file in try Self.swiftSources() {
            let text = try String(contentsOf: file, encoding: .utf8)
            var search = text.startIndex
            while let hit = text.range(of: "notifyError(", range: search..<text.endIndex) {
                search = hit.upperBound
                let start = text.index(hit.lowerBound, offsetBy: -5, limitedBy: text.startIndex) ?? text.startIndex
                if text[start..<hit.lowerBound].hasSuffix("func ") { continue }
                // The balanced argument list.
                var depth = 1
                var i = hit.upperBound
                while i < text.endIndex, depth > 0 {
                    if text[i] == "(" { depth += 1 } else if text[i] == ")" { depth -= 1 }
                    i = text.index(after: i)
                }
                let args = text[hit.upperBound..<i]
                if !args.contains("operation:") && !args.contains("operation,") {
                    offenders.append("\(file.lastPathComponent): notifyError(\(args.prefix(60))")
                }
            }
        }
        XCTAssertEqual(offenders, [])
    }

    // MARK: - An mp timeout names its job

    func test_a_timeout_names_its_job_and_keeps_run_all_alone_on_the_rerun_sentence() {
        let actions = PipelineLauncher.LaunchError.timeout(120, job: "actions").localizedDescription
        XCTAssertTrue(actions.contains("mp actions"), actions)
        XCTAssertFalse(actions.contains("run-all"), actions)
        XCTAssertTrue(actions.contains("2 min"), actions)

        let runAll = PipelineLauncher.LaunchError.timeout(90 * 60, job: "run-all").localizedDescription
        XCTAssertTrue(runAll.contains("re-run `mp run-all <wav>`"), runAll)

        let roster = PipelineLauncher.LaunchError.timeout(30, job: "roster").localizedDescription
        XCTAssertTrue(roster.contains("30 s"), roster)
        XCTAssertFalse(roster.contains("0 min"), roster)
        XCTAssertEqual(FailurePresentation(diagnostics: roster.lowercased(), operation: .people).metadata.cause, .timeout)
    }

    // MARK: - Helpers

    private static var sources: URL {
        URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("Sources/MeetingPipe")
    }

    private static func swiftSources() throws -> [URL] {
        let walker = FileManager.default.enumerator(at: sources, includingPropertiesForKeys: nil)
        return (walker?.allObjects as? [URL] ?? []).filter { $0.pathExtension == "swift" }
    }
}
