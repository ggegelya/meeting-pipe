import XCTest
@testable import MeetingPipe

final class ConfigTests: XCTestCase {
    private var tempDir: URL!

    override func setUp() {
        super.setUp()
        tempDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("mp-config-\(UUID().uuidString)")
        try? FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
    }

    override func tearDown() {
        try? FileManager.default.removeItem(at: tempDir)
        super.tearDown()
    }

    private func writeTOML(_ contents: String) -> URL {
        let url = tempDir.appendingPathComponent("config.toml")
        try! contents.write(to: url, atomically: true, encoding: .utf8)
        return url
    }

    func testParsesMinimalToml() throws {
        let url = writeTOML("""
        [recording]
        output_dir = "/tmp/recordings"
        auto_consent_apps = ["us.zoom.xos", "com.microsoft.teams2"]
        """)
        let cfg = try Config.load(from: url)
        XCTAssertEqual(cfg.recording.outputDir.path, "/tmp/recordings")
        XCTAssertEqual(cfg.recording.autoConsentApps, ["us.zoom.xos", "com.microsoft.teams2"])
    }

    func testFallsBackToDefaultsWhenSectionsMissing() throws {
        // Empty TOML → defaults.
        let url = writeTOML("")
        let cfg = try Config.load(from: url)
        XCTAssertEqual(cfg.detection.manualHotkey, "ctrl+option+m")
        XCTAssertEqual(cfg.detection.forceStopHotkey, "ctrl+option+shift+m")
        XCTAssertEqual(cfg.detection.debounceEndSec, 5)
        XCTAssertFalse(cfg.modes.regulatedMode)
    }

    func testSecondsKnobsAcceptIntegerTomlLiterals() throws {
        // `config.example.toml` writes every seconds knob as an integer, and
        // TOMLKit does not coerce int to double, so a `.double`-only read made
        // hand-editing the shipped file a silent no-op. Same class as the HYG2
        // dead knobs: the user changes the setting and nothing happens.
        let cfg = try Config.load(from: writeTOML("""
        [detection]
        debounce_end_sec = 7
        prompt_timeout_sec = 45
        reprompt_cooldown_sec = 120
        mic_only_silence_seconds = 600
        """))
        XCTAssertEqual(cfg.detection.debounceEndSec, 7)
        XCTAssertEqual(cfg.detection.promptTimeoutSec, 45)
        XCTAssertEqual(cfg.detection.repromptCooldownSec, 120)
        XCTAssertEqual(cfg.detection.micOnlySilenceSec, 600)
    }

    func testSecondsKnobsStillAcceptFloatTomlLiterals() throws {
        let cfg = try Config.load(from: writeTOML("""
        [detection]
        debounce_end_sec = 7.5
        prompt_timeout_sec = 45.5
        """))
        XCTAssertEqual(cfg.detection.debounceEndSec, 7.5, accuracy: 1e-9)
        XCTAssertEqual(cfg.detection.promptTimeoutSec, 45.5, accuracy: 1e-9)
    }

    func testParsesForceStopHotkeyOverride() throws {
        // TECH-C5: user-provided override flows through Config.load.
        let url = writeTOML("""
        [detection]
        force_stop_hotkey = "cmd+shift+x"
        """)
        let cfg = try Config.load(from: url)
        XCTAssertEqual(cfg.detection.forceStopHotkey, "cmd+shift+x")
        // Manual hotkey untouched by force-stop change.
        XCTAssertEqual(cfg.detection.manualHotkey, "ctrl+option+m")
    }

    func testRegulatedModeRoundTrips() throws {
        let url = writeTOML("""
        [modes]
        regulated_mode = true
        """)
        let cfg = try Config.load(from: url)
        XCTAssertTrue(cfg.modes.regulatedMode)
    }

    func testExpandsTilde() throws {
        let url = writeTOML(#"""
        [recording]
        output_dir = "~/Documents/Meetings/raw"
        """#)
        let cfg = try Config.load(from: url)
        // Tilde must be expanded — not literal "~".
        XCTAssertFalse(cfg.recording.outputDir.path.hasPrefix("~"))
        XCTAssertTrue(cfg.recording.outputDir.path.contains("Documents/Meetings/raw"))
    }

    func testDefaultFallbackInstantiates() {
        // Public API used when no config file exists.
        let cfg = Config.defaultFallback()
        XCTAssertEqual(cfg.detection.manualHotkey, "ctrl+option+m")
        XCTAssertEqual(cfg.transcription.language, "auto")
    }

    func testIgnoresLegacyFieldsWithoutCrashing() throws {
        // Older configs may still have audio_device / capture_mode etc., plus the
        // two knobs HYG2 deleted (sample_rate, debounce_start_sec). We don't read
        // any of them anymore but parsing should silently succeed.
        let url = writeTOML("""
        [recording]
        output_dir = "/tmp/x"
        sample_rate = 16000
        audio_device = "old-aggregate"
        capture_mode = "process_tap"
        mic_device = "old-mic"
        auto_route_output = true

        [detection]
        debounce_start_sec = 12
        debounce_end_sec = 7
        """)
        let cfg = try Config.load(from: url)
        XCTAssertEqual(cfg.recording.outputDir.path, "/tmp/x")
        // The live neighbour still parses; a deleted key alongside it is inert.
        XCTAssertEqual(cfg.detection.debounceEndSec, 7)
    }

    func test_scrubbed_environment_drops_every_managed_token() {
        // SEC14: ffmpeg children spawn with this env; none of the API tokens may survive.
        let base = [
            "ANTHROPIC_API_KEY": "sk-a",
            "NOTION_TOKEN": "ntn",
            "OPENAI_API_KEY": "sk-o",
            "HF_TOKEN": "hf",
            "PATH": "/usr/bin",
            "HOME": "/Users/x",
        ]
        let scrubbed = Secrets.scrubbedEnvironment(from: base)
        for key in KeychainSecrets.managedKeys {
            XCTAssertNil(scrubbed[key], "\(key) must not reach the ffmpeg child")
        }
        // Non-secret entries are preserved so ffmpeg still resolves its own PATH.
        XCTAssertEqual(scrubbed["PATH"], "/usr/bin")
        XCTAssertEqual(scrubbed["HOME"], "/Users/x")
    }

    // MARK: - transcription.diarization_clustering_threshold (DIAR2)

    func testParsesDiarizationClusteringThreshold() throws {
        let url = writeTOML("""
        [transcription]
        diarization_clustering_threshold = 0.6
        """)
        let cfg = try Config.load(from: url)
        XCTAssertEqual(cfg.transcription.diarizationClusteringThreshold, 0.6, accuracy: 1e-9)
    }

    func testDiarizationClusteringThresholdDefaultsWhenAbsent() throws {
        let cfg = try Config.load(from: writeTOML(""))
        XCTAssertEqual(
            cfg.transcription.diarizationClusteringThreshold,
            FluidAudioRunner.defaultClusteringThreshold, accuracy: 1e-9
        )
    }

    func testDiarizationClusteringThresholdClampsToFluidAudioRange() throws {
        let low = try Config.load(from: writeTOML("""
        [transcription]
        diarization_clustering_threshold = 0.1
        """))
        XCTAssertEqual(low.transcription.diarizationClusteringThreshold, 0.5, accuracy: 1e-9)

        let high = try Config.load(from: writeTOML("""
        [transcription]
        diarization_clustering_threshold = 2.0
        """))
        XCTAssertEqual(high.transcription.diarizationClusteringThreshold, 0.9, accuracy: 1e-9)
    }

    // MARK: - transcription.language (HYG2)

    func testParsesTranscriptionLanguage() throws {
        let cfg = try Config.load(from: writeTOML("""
        [transcription]
        language = "uk"
        """))
        XCTAssertEqual(cfg.transcription.language, "uk")
    }

    func testTranscriptionLanguageDefaultsToAutoWhenAbsent() throws {
        // Not "en": before HYG2 wired the key the transcribe call passed
        // `languageHint: nil` (auto-detect), so anything else would make the
        // wiring a silent behaviour change for every config missing the key.
        XCTAssertEqual(try Config.load(from: writeTOML("")).transcription.language, "auto")
    }

    func testUnknownTranscriptionLanguageResolvesToAutoDetect() throws {
        // Config keeps the raw string; the runner is what degrades a bad code to
        // auto-detect, so a typo cannot fail a transcription.
        let cfg = try Config.load(from: writeTOML("""
        [transcription]
        language = "klingon"
        """))
        XCTAssertEqual(cfg.transcription.language, "klingon")
        XCTAssertNil(FluidAudioRunner.resolveLanguage(hint: cfg.transcription.language))
        XCTAssertNil(FluidAudioRunner.resolveLanguage(hint: "auto"))
        XCTAssertNotNil(FluidAudioRunner.resolveLanguage(hint: "en"))
    }
}
