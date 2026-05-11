import XCTest
@testable import MeetingPipe

/// ConfigStore exists so the SwiftUI Preferences view can bind to a
/// model that round-trips to disk. The two properties we cover here are
/// the load/mutate/persist cycle and the preserve-unknown-keys behavior
/// — without the latter, editing a daemon-only field in the UI would
/// blow away the pipeline-side fields (transcription, summarization)
/// that we deliberately don't model.
final class ConfigStoreTests: XCTestCase {

    private func makeTempConfigURL() throws -> URL {
        let dir = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("mp-tests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir.appendingPathComponent("config.toml")
    }

    func test_loads_defaults_when_file_missing() throws {
        let url = try makeTempConfigURL()
        // Don't create the file — store should bootstrap empty.
        let store = try ConfigStore(configURL: url)
        XCTAssertEqual(store.sampleRate, 16000)
        XCTAssertEqual(store.debounceEndSec, 5)
        XCTAssertEqual(store.manualHotkey, "ctrl+option+m")
        XCTAssertFalse(store.regulatedMode)
        XCTAssertTrue(store.autoConsentApps.isEmpty)
        // Transcription language default is "en"; auto-detect is opt-in.
        XCTAssertEqual(store.transcriptionLanguage, "en")
    }

    func test_transcription_language_round_trip() throws {
        let url = try makeTempConfigURL()
        try """
        [transcription]
        language = "uk"
        """.write(to: url, atomically: true, encoding: .utf8)

        let store = try ConfigStore(configURL: url)
        XCTAssertEqual(store.transcriptionLanguage, "uk")

        store.transcriptionLanguage = "auto"
        try store.saveNow()

        let reloaded = try ConfigStore(configURL: url)
        XCTAssertEqual(reloaded.transcriptionLanguage, "auto")
    }

    func test_round_trip_persists_changes() throws {
        let url = try makeTempConfigURL()
        try """
        [recording]
        output_dir = "~/Documents/Meetings/raw"
        sample_rate = 16000
        auto_consent_apps = []

        [detection]
        debounce_start_sec = 5
        debounce_end_sec = 5
        manual_hotkey = "ctrl+option+m"
        prompt_timeout_sec = 30

        [modes]
        regulated_mode = false
        """.write(to: url, atomically: true, encoding: .utf8)

        let store = try ConfigStore(configURL: url)
        store.regulatedMode = true
        store.debounceEndSec = 7
        store.autoConsentApps = ["us.zoom.xos"]
        try store.saveNow()

        // Re-read from disk via a fresh ConfigStore — that proves the
        // file actually changed, not just the in-memory model.
        let reloaded = try ConfigStore(configURL: url)
        XCTAssertTrue(reloaded.regulatedMode)
        XCTAssertEqual(reloaded.debounceEndSec, 7)
        XCTAssertEqual(reloaded.autoConsentApps, ["us.zoom.xos"])
    }

    func test_preserves_unknown_pipeline_side_keys() throws {
        let url = try makeTempConfigURL()
        // Most pipeline-side keys (`transcription.model`,
        // `transcription.min_speakers`, `summarization.team_context`,
        // `notion.default_status`, ...) are NOT modeled by ConfigStore.
        // The whole point of the raw-document round-trip is that
        // mutating UI-known fields doesn't strip the unknown ones.
        try """
        [recording]
        output_dir = "~/Documents/Meetings/raw"

        [transcription]
        model = "large-v3"
        language = "auto"
        min_speakers = 1
        max_speakers = 8

        [summarization]
        model = "claude-sonnet-4-6"
        team_context = "Custom team context"

        [notion]
        database_id = "deadbeef"
        default_status = "Captured"

        [modes]
        regulated_mode = false
        """.write(to: url, atomically: true, encoding: .utf8)

        let store = try ConfigStore(configURL: url)
        store.regulatedMode = true  // unrelated UI mutation
        try store.saveNow()

        let raw = try String(contentsOf: url, encoding: .utf8)
        XCTAssertTrue(raw.contains("model"), "transcription/summarization model keys must survive")
        XCTAssertTrue(raw.contains("large-v3"))
        XCTAssertTrue(raw.contains("claude-sonnet-4-6"))
        XCTAssertTrue(raw.contains("Custom team context"))
        XCTAssertTrue(raw.contains("deadbeef"))
        // And the new value made it through:
        XCTAssertTrue(raw.contains("regulated_mode = true"))
    }

    func test_loads_pipeline_side_fields_surfaced_in_ui() throws {
        let url = try makeTempConfigURL()
        try """
        [notion]
        database_id = "abc123"

        [summarization]
        summary_language = "ru"
        skip_above_chars = 50000
        """.write(to: url, atomically: true, encoding: .utf8)

        let store = try ConfigStore(configURL: url)
        XCTAssertEqual(store.notionDatabaseId, "abc123")
        XCTAssertEqual(store.summaryLanguage, "ru")
        XCTAssertEqual(store.summarizationSkipAboveChars, 50000)
    }

    func test_round_trip_persists_pipeline_side_fields() throws {
        let url = try makeTempConfigURL()
        try "".write(to: url, atomically: true, encoding: .utf8)

        let store = try ConfigStore(configURL: url)
        store.notionDatabaseId = "deadbeef"
        store.summaryLanguage = "uk"
        store.summarizationSkipAboveChars = 0
        try store.saveNow()

        let raw = try String(contentsOf: url, encoding: .utf8)
        XCTAssertTrue(raw.contains("database_id = \"deadbeef\""))
        XCTAssertTrue(raw.contains("summary_language = \"uk\""))
        XCTAssertTrue(raw.contains("skip_above_chars = 0"))
    }

    func test_force_stop_hotkey_round_trips() throws {
        // TECH-C5: new field must load and persist through ConfigStore.
        let url = try makeTempConfigURL()
        try "".write(to: url, atomically: true, encoding: .utf8)

        let store = try ConfigStore(configURL: url)
        // Default applies on a fresh file.
        XCTAssertEqual(store.forceStopHotkey, "ctrl+option+shift+m")

        store.forceStopHotkey = "cmd+shift+x"
        try store.saveNow()

        let raw = try String(contentsOf: url, encoding: .utf8)
        XCTAssertTrue(raw.contains("force_stop_hotkey = \"cmd+shift+x\""))

        // Reload from disk and confirm the value sticks.
        let reloaded = try ConfigStore(configURL: url)
        XCTAssertEqual(reloaded.forceStopHotkey, "cmd+shift+x")
    }

    func test_writeBack_is_pure() throws {
        let url = try makeTempConfigURL()
        try "".write(to: url, atomically: true, encoding: .utf8)
        let store = try ConfigStore(configURL: url)
        store.sampleRate = 48000
        store.writeBack()
        // currentTOML reflects the in-memory document — useful for tests
        // that don't want disk I/O.
        XCTAssertTrue(store.currentTOML().contains("sample_rate = 48000"))
        // No file write should have happened yet (writeBack is pure).
        let onDisk = try String(contentsOf: url, encoding: .utf8)
        XCTAssertFalse(onDisk.contains("48000"))
    }

    func test_init_does_not_persist_compile_time_defaults() throws {
        // Regression test: the init's `self.x = ...` assignments fire
        // `didSet` → `scheduleSave`, which (until isInitialized landed)
        // could race in and overwrite the user's file with compile-time
        // defaults if the init ran off the main thread. Instead of
        // simulating that race directly, assert the lighter invariant:
        // a fresh ConfigStore against a non-existent file MUST NOT
        // create the file as a side-effect of construction.
        let url = try makeTempConfigURL()
        XCTAssertFalse(FileManager.default.fileExists(atPath: url.path))
        _ = try ConfigStore(configURL: url)
        // Give the run loop a tick so any erroneously-scheduled timer
        // would have fired by now.
        RunLoop.current.run(until: Date().addingTimeInterval(0.05))
        XCTAssertFalse(
            FileManager.default.fileExists(atPath: url.path),
            "ConfigStore.init must not persist anything; the file should still not exist"
        )
    }
}
