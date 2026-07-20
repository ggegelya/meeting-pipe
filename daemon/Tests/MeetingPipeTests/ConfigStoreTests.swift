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
        XCTAssertEqual(store.debounceEndSec, 5)
        XCTAssertEqual(store.manualHotkey, "ctrl+option+m")
        XCTAssertFalse(store.regulatedMode)
        XCTAssertTrue(store.autoConsentApps.isEmpty)
        // HYG2: "auto", not "en". The key now reaches the ASR runner, and before
        // it was wired the runner got `languageHint: nil` (auto-detect); an "en"
        // default would silently pin every existing config to English.
        XCTAssertEqual(store.transcriptionLanguage, "auto")
        // Recording / detection knobs surfaced in Preferences.
        XCTAssertFalse(store.voiceProcessing, "voice_processing defaults off; VPIO drops mic gain system-wide")
        XCTAssertTrue(store.honorAppMute, "honor_app_mute defaults on; MicGate tracks in-app mute for the redaction timeline + idle backstop, not live zeroing (ADR 0016)")
        XCTAssertEqual(store.repromptCooldownSec, 60)
        XCTAssertEqual(store.micOnlySilenceSec, 900)  // TECH-END3: idle auto-stop horizon, 15 min
    }

    func test_voice_processing_and_honor_app_mute_round_trip() throws {
        let url = try makeTempConfigURL()
        try """
        [recording]
        voice_processing = true
        honor_app_mute = false
        """.write(to: url, atomically: true, encoding: .utf8)

        let store = try ConfigStore(configURL: url)
        XCTAssertTrue(store.voiceProcessing)
        XCTAssertFalse(store.honorAppMute)

        store.voiceProcessing = false
        store.honorAppMute = true
        try store.saveNow()

        let reloaded = try ConfigStore(configURL: url)
        XCTAssertFalse(reloaded.voiceProcessing)
        XCTAssertTrue(reloaded.honorAppMute)
    }

    func test_integer_seconds_literals_survive_a_load_and_save() throws {
        // The store used to read these `.double`-only, so an integer literal in a
        // hand-edited config was dropped on load and then overwritten with the
        // default on the next Preferences save.
        let url = try makeTempConfigURL()
        try """
        [detection]
        debounce_end_sec = 7
        prompt_timeout_sec = 45
        reprompt_cooldown_sec = 120
        mic_only_silence_seconds = 600
        """.write(to: url, atomically: true, encoding: .utf8)

        let store = try ConfigStore(configURL: url)
        XCTAssertEqual(store.debounceEndSec, 7)
        XCTAssertEqual(store.promptTimeoutSec, 45)
        XCTAssertEqual(store.repromptCooldownSec, 120)
        XCTAssertEqual(store.micOnlySilenceSec, 600)

        // An unrelated save must not clobber the values it just read.
        store.regulatedMode = true
        try store.saveNow()
        let reloaded = try ConfigStore(configURL: url)
        XCTAssertEqual(reloaded.debounceEndSec, 7)
        XCTAssertEqual(reloaded.micOnlySilenceSec, 600)
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
        auto_consent_apps = []

        [detection]
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
        user_label = "Alex"
        """.write(to: url, atomically: true, encoding: .utf8)

        let store = try ConfigStore(configURL: url)
        XCTAssertEqual(store.notionDatabaseId, "abc123")
        XCTAssertEqual(store.summaryLanguage, "ru")
        XCTAssertEqual(store.summarizationSkipAboveChars, 50000)
        XCTAssertEqual(store.summarizationUserLabel, "Alex")
    }

    func test_round_trip_persists_pipeline_side_fields() throws {
        let url = try makeTempConfigURL()
        try "".write(to: url, atomically: true, encoding: .utf8)

        let store = try ConfigStore(configURL: url)
        store.notionDatabaseId = "deadbeef"
        store.summaryLanguage = "uk"
        store.summarizationSkipAboveChars = 0
        store.summarizationUserLabel = "Alex"
        try store.saveNow()

        let raw = try String(contentsOf: url, encoding: .utf8)
        XCTAssertTrue(raw.contains("database_id = \"deadbeef\""))
        XCTAssertTrue(raw.contains("summary_language = \"uk\""))
        XCTAssertTrue(raw.contains("skip_above_chars = 0"))
        XCTAssertTrue(raw.contains("user_label = \"Alex\""))
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

    func test_default_prompt_action_round_trips() throws {
        // TECH-E5: prompt-timeout no longer auto-suppresses; the default
        // action is configurable. Verify the new field loads, mutates,
        // and survives a round-trip through TOML, and that the default
        // is "skip" on a fresh file (preserves historical behaviour).
        let url = try makeTempConfigURL()
        try "".write(to: url, atomically: true, encoding: .utf8)

        let store = try ConfigStore(configURL: url)
        XCTAssertEqual(store.defaultPromptAction, "skip")

        store.defaultPromptAction = "record"
        try store.saveNow()

        let raw = try String(contentsOf: url, encoding: .utf8)
        XCTAssertTrue(raw.contains("default_prompt_action = \"record\""))

        let reloaded = try ConfigStore(configURL: url)
        XCTAssertEqual(reloaded.defaultPromptAction, "record")
    }

    func test_writeBack_is_pure() throws {
        let url = try makeTempConfigURL()
        try "".write(to: url, atomically: true, encoding: .utf8)
        let store = try ConfigStore(configURL: url)
        // Any round-tripped knob proves the invariant; this used to assert on
        // `sample_rate`, which HYG2 deleted as a dead knob.
        store.manualHotkey = "cmd+shift+z"
        store.writeBack()
        // currentTOML reflects the in-memory document — useful for tests
        // that don't want disk I/O.
        XCTAssertTrue(store.currentTOML().contains("manual_hotkey = \"cmd+shift+z\""))
        // No file write should have happened yet (writeBack is pure).
        let onDisk = try String(contentsOf: url, encoding: .utf8)
        XCTAssertFalse(onDisk.contains("cmd+shift+z"))
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
