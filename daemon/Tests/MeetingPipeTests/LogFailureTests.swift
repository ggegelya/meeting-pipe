import XCTest
@testable import MeetingPipe

/// OBS1: a failure is never os.Logger alone. The unified log stores the reason as `<private>`
/// and keeps about a week, and Diagnostics, `mp logs` and `mp doctor` read only the files, so
/// a failed save that went only there left no trace anyone could read.
final class LogFailureTests: XCTestCase {

    private var logs: URL!

    override func setUpWithError() throws {
        logs = FileManager.default.temporaryDirectory
            .appendingPathComponent("LogFailureTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: logs, withIntermediateDirectories: true)
        setenv("MEETINGPIPE_LOGS_DIR", logs.path, 1)
    }

    override func tearDownWithError() throws {
        unsetenv("MEETINGPIPE_LOGS_DIR")
        try? FileManager.default.removeItem(at: logs)
    }

    // MARK: - The helper

    func test_an_nserror_writes_one_row_with_domain_code_and_attributes_and_one_line() throws {
        let error = NSError(domain: NSCocoaErrorDomain, code: 513, userInfo: [
            NSLocalizedDescriptionKey: "You don't have permission to save the file.",
        ])
        Log.failure(category: "library", action: "obs1_probe_write_failed", error: error,
                    attributes: ["stem": "20260101-120000"], file: "obs1probe")

        let rows = try rows(action: "obs1_probe_write_failed")
        XCTAssertEqual(rows.count, 1)
        let row = try XCTUnwrap(rows.first)
        XCTAssertEqual(row["category"] as? String, "library")
        XCTAssertEqual(row["stem"] as? String, "20260101-120000")
        XCTAssertEqual(row["error"] as? String, "You don't have permission to save the file.")
        XCTAssertEqual(row["error_domain"] as? String, NSCocoaErrorDomain)
        XCTAssertEqual(row["error_code"] as? Int, 513)

        let line = try String(contentsOf: logs.appendingPathComponent("obs1probe.log"), encoding: .utf8)
        XCTAssertEqual(line.split(separator: "\n").count, 1)
        XCTAssertTrue(line.contains("obs1_probe_write_failed: You don't have permission"))
        XCTAssertTrue(line.contains("[\(NSCocoaErrorDomain) 513]"))
    }

    func test_the_default_file_is_daemon_log() throws {
        Log.failure(category: "daemon", action: "obs1_probe_default_file", reason: "nothing")
        let line = try String(contentsOf: logs.appendingPathComponent("daemon.log"), encoding: .utf8)
        XCTAssertTrue(line.contains("obs1_probe_default_file: nothing"))
    }

    func test_a_long_description_is_capped() throws {
        let long = String(repeating: "x", count: 1_000)
        Log.failure(category: "daemon", action: "obs1_probe_long",
                    error: NSError(domain: "D", code: 1, userInfo: [NSLocalizedDescriptionKey: long]))
        let text = try XCTUnwrap(try rows(action: "obs1_probe_long").first?["error"] as? String)
        XCTAssertEqual(text.count, Log.failureDescriptionCap)
        XCTAssertTrue(text.hasPrefix("xxx"))
    }

    func test_the_reason_overload_writes_the_same_shape_with_no_domain() throws {
        Log.failure(category: "daemon", action: "obs1_probe_reason", reason: "mp not found",
                    attributes: ["label": "com.meetingpipe.digest"])
        let row = try XCTUnwrap(try rows(action: "obs1_probe_reason").first)
        XCTAssertEqual(row["error"] as? String, "mp not found")
        XCTAssertEqual(row["label"] as? String, "com.meetingpipe.digest")
        XCTAssertNil(row["error_domain"])
        XCTAssertNil(row["error_code"])
    }

    private enum ProbeError: Error { case first, second }

    func test_a_swift_enum_error_records_its_type_name_and_case_index() throws {
        Log.failure(category: "daemon", action: "obs1_probe_enum", error: ProbeError.second)
        let row = try XCTUnwrap(try rows(action: "obs1_probe_enum").first)
        // The bridged domain is module-qualified, so match the type name inside it.
        XCTAssertTrue((row["error_domain"] as? String)?.contains("ProbeError") == true, "\(row)")
        XCTAssertEqual(row["error_code"] as? Int, 1)
    }

    func test_describe_false_keeps_the_text_out_of_both_files() throws {
        let error = NSError(domain: NSCocoaErrorDomain, code: 640, userInfo: [
            NSLocalizedDescriptionKey: "“Placeholder Title” could not be copied.",
        ])
        Log.failure(category: "library", action: "obs1_probe_withheld", error: error, describe: false)
        let row = try XCTUnwrap(try rows(action: "obs1_probe_withheld").first)
        XCTAssertNil(row["error"])
        XCTAssertEqual(row["error_code"] as? Int, 640)
        let line = try String(contentsOf: logs.appendingPathComponent("daemon.log"), encoding: .utf8)
        XCTAssertFalse(line.contains("Placeholder Title"))
        XCTAssertTrue(line.contains("obs1_probe_withheld"))
    }

    // MARK: - Migrated store families

    func test_pipeline_failure_sidecar_write_failure_is_logged() throws {
        let missing = logs.appendingPathComponent("no-such-dir/nested", isDirectory: true)
        XCTAssertNil(PipelineFailureSidecar.write(stem: "obs1-sidecar", in: missing, stage: .pipeline, reason: "boom"))
        let row = try XCTUnwrap(try rows(action: "failure_sidecar_write_failed").first { $0["stem"] as? String == "obs1-sidecar" })
        XCTAssertEqual(row["category"] as? String, "coordinator")
        XCTAssertNotNil(row["error_domain"])
    }

    func test_saved_search_store_unreadable_file_is_logged() throws {
        let url = logs.appendingPathComponent("saved_searches.json")
        try Data("{ not json".utf8).write(to: url)
        let store = SavedSearchStore(url: url)
        store.load()
        XCTAssertEqual(store.searches, [])
        let row = try XCTUnwrap(try rows(action: "saved_searches_unreadable").first)
        XCTAssertEqual(row["file"] as? String, "saved_searches.json")
    }

    func test_saved_search_store_write_failure_is_logged() throws {
        // A regular file where the parent directory should be: createDirectory fails.
        let blocker = logs.appendingPathComponent("blocker")
        try Data().write(to: blocker)
        let store = SavedSearchStore(url: blocker.appendingPathComponent("saved_searches.json"))
        store.upsert(SavedSearch(name: "Avery", filter: MeetingFilter(query: "a")))
        try waitFor { try !self.rows(action: "saved_searches_write_failed").isEmpty }
    }

    func test_workflow_correction_store_unreadable_file_is_logged() throws {
        let url = logs.appendingPathComponent("workflow_corrections.json")
        try Data("[ broken".utf8).write(to: url)
        WorkflowCorrectionStore(url: url).load()
        let row = try XCTUnwrap(try rows(action: "correction_store_unreadable").first)
        XCTAssertEqual(row["category"] as? String, "workflow")
    }

    // MARK: - The fence

    /// Sites allowed to call os.Logger's `.warning` / `.error` directly, as (file, a fragment of
    /// the call, why). Keyed on text, not line numbers, so an edit elsewhere in the file keeps it.
    static let allowlist: [(file: String, fragment: String, reason: String)] = [
        ("MeetingPipe/Logger.swift", "log append failed", "the logger's own failed append; Log.failure writes through the path that failed"),
        ("MeetingPipe/MeetingRecorder.swift", "mic write:", "per-buffer: fires once per failed buffer, counted by WriteFailureTracker (REC22)"),
        ("MeetingPipe/SystemAudioChannel.swift", "system write:", "per-buffer: fires once per failed buffer, counted by WriteFailureTracker (REC22)"),
        ("MeetingPipe/Coordinator.swift", "Could not parse hotkey", "a note, not a failure: the hotkey string did not parse"),
        ("MeetingPipe/Coordinator.swift", "Could not parse force-stop hotkey", "a note, not a failure"),
        ("MeetingPipe/Coordinator.swift", "Could not parse flag-moment hotkey", "a note, not a failure"),
        ("MeetingPipe/Coordinator.swift", "Could not parse off-the-record hotkey", "a note, not a failure"),
        ("MeetingPipe/Coordinator.swift", "Force-stop hotkey matches manual hotkey", "a note: a collision skipped on purpose"),
        ("MeetingPipe/Coordinator.swift", "Flag-moment hotkey matches another hotkey", "a note: a collision skipped on purpose"),
        ("MeetingPipe/Coordinator.swift", "Off-the-record hotkey matches another hotkey", "a note: a collision skipped on purpose"),
        ("MeetingPipe/PipelineLauncher.swift", "cancelled by user", "the owner's own Cancel, not a failure"),
        ("MeetingPipe/PipelineLauncher.swift", "quitting: stopping", "a quit narrating what it stops, not a failure"),
        ("MeetingPipe/WorkflowStore.swift", "refusing to delete the default workflow", "a refusal by design, not a failure"),
        ("MeetingPipe/Tutorial/TutorialSession.swift", "tutorial: no control found", "already public; the tour's own fences cover it"),
        // Already paired with a Log.event or Log.writeLine in the same block.
        ("MeetingPipe/WorkflowStore.swift", "duplicate workflow names", "paired with workflow/duplicate_names"),
        ("MeetingPipe/SecretsStore.swift", "could not read", "paired with main/keychain_read_failed and a main.log line"),
        ("MeetingPipe/SecretsStore.swift", "SecretsStore: writing", "recorded per account by noteSaveOutcome as daemon/config_save_failed (UX91)"),
        ("MeetingPipe/ConfigStore.swift", "ConfigStore persist failed", "recorded beside it as daemon/config_save_failed (UX91)"),
        ("MeetingPipe/MeetingSessionController.swift", "microphone permission missing", "paired with coordinator/recording_blocked"),
        ("MeetingPipe/MeetingSessionController.swift", "failed to start recorder", "paired with coordinator/recording_error"),
        ("MeetingPipe/Coordinator+Delegates.swift", "Looks good: failed to record correction", "paired with correction/failed"),
        ("MeetingPipe/Coordinator.swift", "MuteLabels.loadDefault failed", "paired with coordinator/mute_labels_load_failed"),
        ("MeetingPipe/Coordinator.swift", "Accessibility: NOT trusted", "paired with the accessibility event and line"),
        ("MeetingPipe/SystemAudioCapture.swift", "SCShareableContent prewarm failed", "paired with a recorder.log WARN line"),
        ("MeetingPipe/SystemAudioCapture.swift", "SCStream stopped with error", "paired with a recorder.log line and onStopWithError"),
        ("MeetingPipe/Coordination/SinkDispatcher.swift", "transcription failed", "paired with transcription/engine_failed"),
    ]

    /// Every os.Logger `.warning(` / `.error(` call in `sources` outside the allowlist, plus every
    /// allowlist entry that matched nothing. Pure, so a scratch string can drive it.
    static func violations(in sources: [(String, String)]) throws -> (bare: [String], stale: [String]) {
        let pattern = try NSRegularExpression(pattern: #"\b(?:Log\.)?(?:main|detector|recorder)\.(?:warning|error)\("#)
        var used = Set<Int>()
        var bare: [String] = []
        for (path, text) in sources {
            let ns = text as NSString
            for match in pattern.matches(in: text, range: NSRange(location: 0, length: ns.length)) {
                // The call's text, through the next two lines, for a message that wraps.
                let tail = ns.substring(from: match.range.location)
                let call = tail.split(separator: "\n", maxSplits: 2, omittingEmptySubsequences: false)
                    .prefix(2).joined(separator: "\n")
                if let index = allowlist.firstIndex(where: { $0.file == path && call.contains($0.fragment) }) {
                    used.insert(index)
                } else {
                    let line = ns.substring(to: match.range.location).filter { $0 == "\n" }.count + 1
                    bare.append("\(path):\(line)")
                }
            }
        }
        let stale = allowlist.indices.filter { !used.contains($0) }
            .map { "\(allowlist[$0].file): \(allowlist[$0].fragment)" }
        return (bare, stale)
    }

    func test_no_failure_goes_only_to_os_logger() throws {
        let sources = try daemonSourceFiles()
        XCTAssertGreaterThan(sources.count, 100)
        let (bare, stale) = try Self.violations(in: sources)
        XCTAssertEqual(bare, [], "a failure is never os.Logger alone (OBS1): use Log.failure, or add an allowlist entry with its reason")
        XCTAssertEqual(stale, [], "these allowlist entries match no call any more; delete them")
    }

    func test_the_fence_catches_a_bare_call_outside_the_allowlist() throws {
        let scratch = [("MeetingPipe/Scratch.swift", "func f() {\n    Log.main.error(\"save failed\")\n}\n")]
        XCTAssertEqual(try Self.violations(in: scratch).bare, ["MeetingPipe/Scratch.swift:2"])
        let wrapped = [("MeetingPipe/Scratch.swift", "Log.recorder.warning(\n    \"x\"\n)\n")]
        XCTAssertEqual(try Self.violations(in: wrapped).bare, ["MeetingPipe/Scratch.swift:1"])
    }

    // MARK: - Helpers

    private func rows(action: String) throws -> [[String: Any]] {
        let events = logs.appendingPathComponent("events.jsonl")
        guard let text = try? String(contentsOf: events, encoding: .utf8) else { return [] }
        return text.split(separator: "\n").compactMap { line in
            guard let object = try? JSONSerialization.jsonObject(with: Data(line.utf8)) as? [String: Any],
                  object["action"] as? String == action else { return nil }
            return object
        }
    }

    private func waitFor(_ condition: @escaping () throws -> Bool, timeout: TimeInterval = 5) throws {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if try condition() { return }
            RunLoop.current.run(until: Date().addingTimeInterval(0.05))
        }
        XCTFail("condition not met within \(timeout) s")
    }

    private func daemonSourceFiles() throws -> [(String, String)] {
        let sources = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()   // MeetingPipeTests
            .deletingLastPathComponent()   // Tests
            .deletingLastPathComponent()   // daemon
            .appendingPathComponent("Sources")
        guard let walker = FileManager.default.enumerator(atPath: sources.path) else { return [] }
        var found: [(String, String)] = []
        for case let relative as String in walker where relative.hasSuffix(".swift") {
            let text = try String(contentsOf: sources.appendingPathComponent(relative), encoding: .utf8)
            found.append((relative, text))
        }
        return found
    }
}
