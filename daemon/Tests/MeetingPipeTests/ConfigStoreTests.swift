import Combine
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
        let store = ConfigStore(configURL: url)
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

        let store = ConfigStore(configURL: url)
        XCTAssertTrue(store.voiceProcessing)
        XCTAssertFalse(store.honorAppMute)

        store.voiceProcessing = false
        store.honorAppMute = true
        try store.saveNow()

        let reloaded = ConfigStore(configURL: url)
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

        let store = ConfigStore(configURL: url)
        XCTAssertEqual(store.debounceEndSec, 7)
        XCTAssertEqual(store.promptTimeoutSec, 45)
        XCTAssertEqual(store.repromptCooldownSec, 120)
        XCTAssertEqual(store.micOnlySilenceSec, 600)

        // An unrelated save must not clobber the values it just read.
        store.regulatedMode = true
        try store.saveNow()
        let reloaded = ConfigStore(configURL: url)
        XCTAssertEqual(reloaded.debounceEndSec, 7)
        XCTAssertEqual(reloaded.micOnlySilenceSec, 600)
    }

    func test_transcription_language_round_trip() throws {
        let url = try makeTempConfigURL()
        try """
        [transcription]
        language = "uk"
        """.write(to: url, atomically: true, encoding: .utf8)

        let store = ConfigStore(configURL: url)
        XCTAssertEqual(store.transcriptionLanguage, "uk")

        store.transcriptionLanguage = "auto"
        try store.saveNow()

        let reloaded = ConfigStore(configURL: url)
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

        let store = ConfigStore(configURL: url)
        store.regulatedMode = true
        store.debounceEndSec = 7
        store.autoConsentApps = ["us.zoom.xos"]
        try store.saveNow()

        // Re-read from disk via a fresh ConfigStore — that proves the
        // file actually changed, not just the in-memory model.
        let reloaded = ConfigStore(configURL: url)
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

        let store = ConfigStore(configURL: url)
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

    // MARK: - Speaker-accuracy keys (DIAR3)

    func test_speaker_accuracy_keys_default_when_absent() throws {
        let url = try makeTempConfigURL()
        let store = ConfigStore(configURL: url)
        XCTAssertEqual(store.diarizationClusteringThreshold,
                       ConfigDefaults.diarizationClusteringThreshold)
        XCTAssertFalse(store.summarizationDiarizeCleanup,
                       "diarize_cleanup is opt-in: it costs an extra model call per meeting")
    }

    func test_speaker_accuracy_keys_round_trip() throws {
        let url = try makeTempConfigURL()
        try """
        [transcription]
        diarization_clustering_threshold = 0.75

        [summarization]
        diarize_cleanup = true
        """.write(to: url, atomically: true, encoding: .utf8)

        let store = ConfigStore(configURL: url)
        XCTAssertEqual(store.diarizationClusteringThreshold, 0.75)
        XCTAssertTrue(store.summarizationDiarizeCleanup)

        // What the Preferences controls do: the segmented control writes a pinned
        // value, the toggle writes a bool.
        store.diarizationClusteringThreshold = 0.55
        store.summarizationDiarizeCleanup = false
        try store.saveNow()

        let reloaded = ConfigStore(configURL: url)
        XCTAssertEqual(reloaded.diarizationClusteringThreshold, 0.55)
        XCTAssertFalse(reloaded.summarizationDiarizeCleanup)
        let raw = try String(contentsOf: url, encoding: .utf8)
        XCTAssertTrue(raw.contains("diarization_clustering_threshold = 0.55"))
        XCTAssertTrue(raw.contains("diarize_cleanup = false"))
    }

    func test_out_of_range_threshold_is_clamped_to_what_the_daemon_would_use() throws {
        // A hand-edited 0.2 is clamped to 0.5 on read, so a store that showed
        // 0.2 would have Preferences reporting a value the runner never sees.
        let url = try makeTempConfigURL()
        try """
        [transcription]
        diarization_clustering_threshold = 0.2
        """.write(to: url, atomically: true, encoding: .utf8)

        let store = ConfigStore(configURL: url)
        XCTAssertEqual(store.diarizationClusteringThreshold, 0.5)
        XCTAssertEqual(store.diarizationClusteringThreshold,
                       ConfigStore(configURL: url).config.transcription.diarizationClusteringThreshold)
    }

    func test_integer_threshold_literal_survives_a_load_and_save() throws {
        // TOMLKit will not coerce int to double, so a `= 1` read `.double`-only would
        // be dropped and then overwritten with the default on the next save.
        let url = try makeTempConfigURL()
        try """
        [transcription]
        diarization_clustering_threshold = 1
        """.write(to: url, atomically: true, encoding: .utf8)

        let store = ConfigStore(configURL: url)
        XCTAssertEqual(store.diarizationClusteringThreshold, 0.9, "1 clamps to the range ceiling")
    }

    func test_speaker_accuracy_writes_preserve_unmodelled_siblings() throws {
        // The FEAT11 lesson in miniature: the two sections these keys live in carry
        // live pipeline knobs with no UI, and a write that dropped them would change
        // pipeline behaviour behind the user's back.
        let url = try makeTempConfigURL()
        try """
        [transcription]
        language = "uk"

        [summarization]
        backend = "local"
        team_context = "Custom team context"
        local_adapter_path = "~/adapters/meetings"
        max_tokens = 4000

        [output]
        sinks = ["obsidian", "filesystem"]
        """.write(to: url, atomically: true, encoding: .utf8)

        let store = ConfigStore(configURL: url)
        store.diarizationClusteringThreshold = 0.55
        store.summarizationDiarizeCleanup = true
        try store.saveNow()

        let raw = try String(contentsOf: url, encoding: .utf8)
        XCTAssertTrue(raw.contains("language = \"uk\""))
        XCTAssertTrue(raw.contains("Custom team context"))
        XCTAssertTrue(raw.contains("~/adapters/meetings"))
        XCTAssertTrue(raw.contains("max_tokens = 4000"))
        XCTAssertTrue(raw.contains("obsidian"), "an unmodelled top-level table survives too")
        XCTAssertTrue(raw.contains("diarization_clustering_threshold = 0.55"))
        XCTAssertTrue(raw.contains("diarize_cleanup = true"))
    }

    // MARK: - Publish targets (UX45)

    func test_publish_target_defaults_match_the_pipeline_on_a_fresh_file() throws {
        // These are the values `ObsidianCfg` / `FilesystemCfg` / `LanCfg` /
        // `NotionCfg` carry in config.py. A drift here would show the owner a
        // destination the publisher does not use, which is worse than no UI.
        let url = try makeTempConfigURL()
        let store = ConfigStore(configURL: url)
        XCTAssertEqual(store.obsidianVaultPath, "", "no vault until the owner picks one")
        XCTAssertEqual(store.obsidianFolder, "Meetings")
        XCTAssertTrue(store.obsidianAttachAudio)
        XCTAssertEqual(store.obsidianAttachmentsSubfolder, "_attachments")
        XCTAssertEqual(store.filesystemOutputDir, "~/Documents/Meetings/published")
        XCTAssertEqual(store.lanMountPath, "/Volumes/meetings")
        XCTAssertEqual(store.lanHost, "")
        XCTAssertTrue(store.notionIncludeFullTranscript, "on, matching the pipeline default")
        XCTAssertEqual(store.summarizationOpenAIModel, "gpt-4o")
    }

    func test_publish_targets_round_trip() throws {
        let url = try makeTempConfigURL()
        try """
        [obsidian]
        vault_path = "~/Vaults/Work"
        folder = "Calls"
        attach_audio = false
        attachments_subfolder = "media"

        [filesystem]
        output_dir = "~/Published"

        [lan]
        mount_path = "/Volumes/team"
        host = "files.example.lan"

        [notion]
        include_full_transcript = false
        """.write(to: url, atomically: true, encoding: .utf8)

        let store = ConfigStore(configURL: url)
        XCTAssertEqual(store.obsidianVaultPath, "~/Vaults/Work")
        XCTAssertEqual(store.obsidianFolder, "Calls")
        XCTAssertFalse(store.obsidianAttachAudio)
        XCTAssertEqual(store.obsidianAttachmentsSubfolder, "media")
        XCTAssertEqual(store.filesystemOutputDir, "~/Published")
        XCTAssertEqual(store.lanMountPath, "/Volumes/team")
        XCTAssertEqual(store.lanHost, "files.example.lan")
        XCTAssertFalse(store.notionIncludeFullTranscript)

        store.obsidianVaultPath = "~/Vaults/Personal"
        store.obsidianAttachAudio = true
        store.filesystemOutputDir = "~/Elsewhere"
        store.lanMountPath = "/Volumes/other"
        store.lanHost = ""
        store.notionIncludeFullTranscript = true
        store.summarizationOpenAIModel = "gpt-4o-mini"
        try store.saveNow()

        let reloaded = ConfigStore(configURL: url)
        XCTAssertEqual(reloaded.obsidianVaultPath, "~/Vaults/Personal")
        XCTAssertTrue(reloaded.obsidianAttachAudio)
        XCTAssertEqual(reloaded.filesystemOutputDir, "~/Elsewhere")
        XCTAssertEqual(reloaded.lanMountPath, "/Volumes/other")
        XCTAssertEqual(reloaded.lanHost, "")
        XCTAssertTrue(reloaded.notionIncludeFullTranscript)
        XCTAssertEqual(reloaded.summarizationOpenAIModel, "gpt-4o-mini")
    }

    /// The Anthropic model row writes `summarization.model`, which the pipeline reads
    /// on every Anthropic path. A fresh config must open on the pipeline's own default:
    /// the store writes this key back on any save, so a drifted fallback would pin a
    /// config that never named a model to a model nobody chose.
    func test_anthropic_model_defaults_to_the_pipelines_and_round_trips() throws {
        let fresh = ConfigStore(configURL: try makeTempConfigURL())
        XCTAssertEqual(fresh.summarizationModel, try pipelineDefaultAnthropicModel())

        let url = try makeTempConfigURL()
        try """
        [summarization]
        model = "claude-sonnet-4-6"
        team_context = "Custom team context"
        """.write(to: url, atomically: true, encoding: .utf8)

        let store = ConfigStore(configURL: url)
        XCTAssertEqual(store.summarizationModel, "claude-sonnet-4-6")
        store.summarizationModel = "claude-opus-5-5"
        try store.saveNow()

        let reloaded = ConfigStore(configURL: url)
        XCTAssertEqual(reloaded.summarizationModel, "claude-opus-5-5")
        let raw = try String(contentsOf: url, encoding: .utf8)
        XCTAssertFalse(raw.contains("claude-sonnet-4-6"), "the old id was replaced, not duplicated")
        XCTAssertTrue(raw.contains("Custom team context"), "an unmodelled sibling survives the write")
    }

    /// `Summarization.model`'s default in `pipeline/src/mp/config.py`, read from source so
    /// the two trees cannot part company silently.
    private func pipelineDefaultAnthropicModel() throws -> String {
        let repo = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()   // MeetingPipeTests
            .deletingLastPathComponent()   // Tests
            .deletingLastPathComponent()   // daemon
            .deletingLastPathComponent()   // repo root
        let source = try String(
            contentsOf: repo.appendingPathComponent("pipeline/src/mp/config.py"), encoding: .utf8
        )
        let re = try NSRegularExpression(
            pattern: #"class Summarization\(BaseModel\):\s*\n\s*model: str = "([^"]+)""#
        )
        guard let m = re.firstMatch(in: source, range: NSRange(source.startIndex..., in: source)),
              let range = Range(m.range(at: 1), in: source) else {
            XCTFail("config.py's Summarization.model default no longer has the shape this fence reads")
            return ""
        }
        return String(source[range])
    }

    func test_publish_target_writes_preserve_unmodelled_siblings() throws {
        // The two Obsidian keys UX45 deliberately left TOML-only live in the same
        // table as the four it models, so a write that dropped them would silently
        // switch the owner back to the built-in template.
        let url = try makeTempConfigURL()
        try """
        [obsidian]
        vault_path = "~/Vaults/Work"
        template_path = "~/Vaults/Work/_templates/meeting.md"
        daily_note_backlink = true

        [notion]
        database_id = "deadbeef"
        default_status = "Captured"

        [lan]
        mount_path = "/Volumes/team"
        """.write(to: url, atomically: true, encoding: .utf8)

        let store = ConfigStore(configURL: url)
        store.obsidianFolder = "Calls"
        store.notionIncludeFullTranscript = false
        try store.saveNow()

        let raw = try String(contentsOf: url, encoding: .utf8)
        XCTAssertTrue(raw.contains("_templates/meeting.md"), "template_path stays TOML-only, not dropped")
        XCTAssertTrue(raw.contains("daily_note_backlink = true"))
        XCTAssertTrue(raw.contains("default_status = \"Captured\""))
        XCTAssertTrue(raw.contains("folder = \"Calls\""))
        XCTAssertTrue(raw.contains("include_full_transcript = false"))
        XCTAssertTrue(raw.contains("mount_path = \"/Volumes/team\""))
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

        let store = ConfigStore(configURL: url)
        XCTAssertEqual(store.notionDatabaseId, "abc123")
        XCTAssertEqual(store.summaryLanguage, "ru")
        XCTAssertEqual(store.summarizationSkipAboveChars, 50000)
        XCTAssertEqual(store.summarizationUserLabel, "Alex")
    }

    func test_round_trip_persists_pipeline_side_fields() throws {
        let url = try makeTempConfigURL()
        try "".write(to: url, atomically: true, encoding: .utf8)

        let store = ConfigStore(configURL: url)
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

        let store = ConfigStore(configURL: url)
        // Default applies on a fresh file.
        XCTAssertEqual(store.forceStopHotkey, "ctrl+option+shift+m")

        store.forceStopHotkey = "cmd+shift+x"
        try store.saveNow()

        let raw = try String(contentsOf: url, encoding: .utf8)
        XCTAssertTrue(raw.contains("force_stop_hotkey = \"cmd+shift+x\""))

        // Reload from disk and confirm the value sticks.
        let reloaded = ConfigStore(configURL: url)
        XCTAssertEqual(reloaded.forceStopHotkey, "cmd+shift+x")
    }

    func test_default_prompt_action_round_trips() throws {
        // TECH-E5: prompt-timeout no longer auto-suppresses; the default
        // action is configurable. Verify the new field loads, mutates,
        // and survives a round-trip through TOML, and that the default
        // is "skip" on a fresh file (preserves historical behaviour).
        let url = try makeTempConfigURL()
        try "".write(to: url, atomically: true, encoding: .utf8)

        let store = ConfigStore(configURL: url)
        XCTAssertEqual(store.defaultPromptAction, "skip")

        store.defaultPromptAction = "record"
        try store.saveNow()

        let raw = try String(contentsOf: url, encoding: .utf8)
        XCTAssertTrue(raw.contains("default_prompt_action = \"record\""))

        let reloaded = ConfigStore(configURL: url)
        XCTAssertEqual(reloaded.defaultPromptAction, "record")
    }

    func test_writeBack_is_pure() throws {
        let url = try makeTempConfigURL()
        try "".write(to: url, atomically: true, encoding: .utf8)
        let store = ConfigStore(configURL: url)
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
        _ = ConfigStore(configURL: url)
        // Give the run loop a tick so any erroneously-scheduled timer
        // would have fired by now.
        RunLoop.current.run(until: Date().addingTimeInterval(0.05))
        XCTAssertFalse(
            FileManager.default.fileExists(atPath: url.path),
            "ConfigStore.init must not persist anything; the file should still not exist"
        )
    }

    // MARK: - ARCH9: a file that does not parse fails closed

    /// A real syntax error on line 3 (an unclosed table header) under a file that
    /// says regulated and carries keys the store does not model.
    private let malformed = """
    [modes]
    regulated_mode = true
    [summarization
    team_context = "keep me"
    """

    func test_malformed_file_sets_parse_error_with_its_line() throws {
        let url = try makeTempConfigURL()
        try malformed.write(to: url, atomically: true, encoding: .utf8)

        let store = ConfigStore(configURL: url)
        let error = try XCTUnwrap(store.parseError)
        XCTAssertEqual(error.line, 3)
        XCTAssertFalse(error.message.isEmpty)
        XCTAssertEqual(error.preferencesMessage,
                       "config.toml has a syntax error at line 3. Fix it in a text editor, then reopen Preferences.")
    }

    func test_preferences_message_without_a_position() {
        let error = ConfigParseError(message: "not UTF-8", line: nil, column: nil)
        XCTAssertEqual(error.preferencesMessage,
                       "config.toml has a syntax error. Fix it in a text editor, then reopen Preferences.")
    }

    func test_unreadable_file_is_a_parse_error_not_a_fresh_install() throws {
        // A file that exists but is not UTF-8 used to read as "no config yet", which
        // is the same empty document the next save would write over it.
        let url = try makeTempConfigURL()
        try Data([0xFF, 0xFE, 0x00, 0xC3]).write(to: url)
        XCTAssertNotNil(ConfigStore(configURL: url).parseError)
    }

    func test_save_now_throws_and_leaves_the_bytes_alone() throws {
        let url = try makeTempConfigURL()
        try malformed.write(to: url, atomically: true, encoding: .utf8)
        let before = try Data(contentsOf: url)

        let store = ConfigStore(configURL: url)
        store.regulatedMode = false
        XCTAssertThrowsError(try store.saveNow()) { error in
            XCTAssertEqual(error as? ConfigParseError, store.parseError)
        }
        XCTAssertEqual(try Data(contentsOf: url), before)
    }

    func test_debounced_preferences_edit_does_not_write_over_a_malformed_file() throws {
        // The data-loss path itself: a Preferences edit arms the 500 ms debounce,
        // which used to replace the user's file with only the modeled keys, every
        // one at its default, `regulated_mode = false` among them.
        let url = try makeTempConfigURL()
        try malformed.write(to: url, atomically: true, encoding: .utf8)
        let before = try Data(contentsOf: url)

        let store = ConfigStore(configURL: url)
        var persisted = false
        let sub = store.didPersist.sink { persisted = true }
        defer { sub.cancel() }
        store.manualHotkey = "ctrl+option+k"
        store.regulatedMode = false

        RunLoop.main.run(until: Date().addingTimeInterval(0.9))
        XCTAssertFalse(persisted)
        XCTAssertEqual(try Data(contentsOf: url), before)
    }

    func test_malformed_file_reads_regulated_and_takes_the_regulated_gate() throws {
        let url = try makeTempConfigURL()
        // Says NOT regulated, and still reads regulated: the store cannot know what
        // an unparsed file says, so it assumes the stricter answer.
        try "[modes]\nregulated_mode = false\n[detection\n".write(to: url, atomically: true, encoding: .utf8)

        let store = ConfigStore(configURL: url)
        XCTAssertNotNil(store.parseError)
        XCTAssertTrue(store.regulatedMode)
        XCTAssertTrue(store.config.modes.regulatedMode)
        XCTAssertEqual(CaptureMode.resolve(regulated: store.regulatedMode, nda: false, redactMuted: false),
                       .regulatedGate)
    }

    func test_well_formed_file_has_no_parse_error() throws {
        let url = try makeTempConfigURL()
        try "[modes]\nregulated_mode = false\n".write(to: url, atomically: true, encoding: .utf8)
        let store = ConfigStore(configURL: url)
        XCTAssertNil(store.parseError)
        XCTAssertFalse(store.regulatedMode)
    }

    func test_reload_after_the_fix_clears_the_error_and_reads_the_file() throws {
        let url = try makeTempConfigURL()
        try malformed.write(to: url, atomically: true, encoding: .utf8)
        let store = ConfigStore(configURL: url)
        XCTAssertNotNil(store.parseError)

        try """
        [modes]
        regulated_mode = false
        [detection]
        manual_hotkey = "ctrl+option+k"
        """.write(to: url, atomically: true, encoding: .utf8)
        var persisted = false
        let sub = store.didPersist.sink { persisted = true }
        defer { sub.cancel() }
        store.reloadIfUnparsed()

        XCTAssertNil(store.parseError)
        XCTAssertFalse(store.regulatedMode)
        XCTAssertEqual(store.manualHotkey, "ctrl+option+k")
        XCTAssertTrue(persisted, "subscribers re-read on a reload that changed what the store says")
        // And saves work again.
        store.manualHotkey = "ctrl+option+j"
        try store.saveNow()
        XCTAssertTrue(try String(contentsOf: url, encoding: .utf8).contains("ctrl+option+j"))
    }

    func test_reload_is_a_no_op_on_a_store_that_parsed() throws {
        // The store is the file's author once it parsed; a re-read would race its
        // own debounced save, so an unsaved edit must survive a Preferences reopen.
        let url = try makeTempConfigURL()
        try "[detection]\nmanual_hotkey = \"ctrl+option+m\"\n".write(to: url, atomically: true, encoding: .utf8)
        let store = ConfigStore(configURL: url)
        store.manualHotkey = "ctrl+option+k"
        store.reloadIfUnparsed()
        XCTAssertEqual(store.manualHotkey, "ctrl+option+k")
    }
}
