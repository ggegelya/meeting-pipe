import Foundation
import TOMLKit

/// Mirrors config.example.toml. Loaded once at startup; mutations don't propagate. No audio-device fields: SCStream taps the system bus regardless of output device; AVAudioEngine.inputNode follows the system default input.
struct Config {
    struct Recording {
        var outputDir: URL
        var autoConsentApps: [String]
        /// `AVAudioInputNode.setVoiceProcessingEnabled(true)`: Apple VoIP DSP (noise suppression, echo cancellation, AGC), mono only. Costs dynamic range. Default false - see load() comment.
        var voiceProcessing: Bool
        /// Track in-app mute in the meeting client (AX probe, best-effort). Does NOT pause the mic: the default is capture-first (ADR 0016), so the verdict only feeds the per-workflow redaction timeline and the idle backstop; only the regulated / NDA gate zeroes the mic live. No-op when AX is denied or the mute control is unrecognized.
        var honorAppMute: Bool
    }

    struct Detection {
        /// End-side debounce only. There is deliberately no start-side twin: `.idle` -> `.starting` fires on the first PRIMARY `.live` so the prompt panel appears promptly, and the real start gate is `PromotionEngine.confirmRecording()` (the recorder arming), not a timer. HYG2 deleted the dead `debounce_start_sec` knob rather than inserting a delay that would only cost the head of every meeting.
        var debounceEndSec: Double
        var manualHotkey: String
        /// Stop-only hotkey (TECH-C5). Distinct from `manualHotkey` so the user can force-stop without risking an accidental new recording start when the daemon is idle. Default `ctrl+option+shift+m`.
        var forceStopHotkey: String
        /// Flag-moment hotkey (FEAT8). Stamps a timestamp marker on the active recording; a no-op when idle. Default `ctrl+option+f`.
        var flagMomentHotkey: String
        /// Off-the-record hotkey (MIC14). Toggles a manual redaction span on the active recording; a no-op when idle. Default `ctrl+option+o`.
        var offTheRecordHotkey: String
        var promptTimeoutSec: Double
        /// Suppress detector-driven prompts for a bundle for this many seconds after a recording/prompt ends. Guards against the Teams post-call mic re-acquisition that fires a spurious new prompt. Manual hotkey always bypasses.
        var repromptCooldownSec: Double
        /// TECH-END3 idle backstop: auto-stop after this many seconds of VAD-silent mic plus silent system audio (the forgotten-recording case). Default 900 s (15 min). The TOML key stays `mic_only_silence_seconds` for back-compat.
        var micOnlySilenceSec: TimeInterval
    }

    struct Modes {
        var regulatedMode: Bool
    }

    struct Transcription {
        /// FluidAudio diarization clustering threshold (see `FluidAudioRunner.defaultClusteringThreshold`
        /// for the why). Clamped to FluidAudio's valid 0.5-0.9 range on load, so a
        /// stray hand-edit degrades gracefully instead of producing nonsense clusters.
        var diarizationClusteringThreshold: Double
        /// ASR language hint passed to FluidAudio: `"auto"` (the default) lets the SDK
        /// detect per meeting, an ISO 639-1 code pins it. `FluidAudioRunner.resolveLanguage`
        /// maps an unknown code back to auto-detect, so a typo degrades rather than fails.
        var language: String
    }

    var recording: Recording
    var detection: Detection
    var modes: Modes
    var transcription: Transcription

    static let defaultPath: URL = {
        FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(Endpoints.Paths.configRelative)
    }()

    static let secretsPath: URL = {
        FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(Endpoints.Paths.secretsRelative)
    }()

    static func load(from url: URL = Config.defaultPath) throws -> Config {
        let raw = try String(contentsOf: url, encoding: .utf8)
        let toml = try TOMLTable(string: raw)

        let rec = toml["recording"]?.table
        let det = toml["detection"]?.table
        let mod = toml["modes"]?.table
        let tra = toml["transcription"]?.table

        let outputDirRaw = rec?["output_dir"]?.string ?? ConfigDefaults.outputDirPath
        let consent = (rec?["auto_consent_apps"]?.array?.compactMap { $0.string })
            ?? ConfigDefaults.autoConsentApps
        let voiceProcessing = rec?["voice_processing"]?.bool ?? ConfigDefaults.voiceProcessing
        let honorAppMute = rec?["honor_app_mute"]?.bool ?? ConfigDefaults.honorAppMute

        // TOML distinguishes integer from float literals and TOMLKit does not
        // coerce between them, so reading a seconds knob through `.double` alone
        // silently ignores `debounce_end_sec = 7` and falls back to the default.
        // That matters because `config.example.toml` writes every one of these as
        // an integer, so hand-editing the shipped file was a no-op (HYG2: the same
        // "changed a setting, nothing happened" class as the three dead knobs, and
        // why `mic_only_silence_seconds` already read both).
        func seconds(_ key: String, _ fallback: Double) -> Double {
            if let d = det?[key]?.double { return d }
            if let i = det?[key]?.int { return Double(i) }
            return fallback
        }

        let debounceEnd = seconds("debounce_end_sec", ConfigDefaults.debounceEndSec)
        let hotkey = det?["manual_hotkey"]?.string ?? ConfigDefaults.manualHotkey
        let forceStop = det?["force_stop_hotkey"]?.string ?? ConfigDefaults.forceStopHotkey
        let flagMoment = det?["flag_moment_hotkey"]?.string ?? ConfigDefaults.flagMomentHotkey
        let offTheRecord = det?["off_the_record_hotkey"]?.string ?? ConfigDefaults.offTheRecordHotkey
        let promptTimeout = seconds("prompt_timeout_sec", ConfigDefaults.promptTimeoutSec)
        let repromptCooldown = seconds("reprompt_cooldown_sec", ConfigDefaults.repromptCooldownSec)
        let micOnlySilenceSec = seconds("mic_only_silence_seconds", ConfigDefaults.micOnlySilenceSec)

        let regulated = mod?["regulated_mode"]?.bool ?? ConfigDefaults.regulatedMode

        // Accept both double and integer literals; clamp to FluidAudio's documented range.
        let clusteringRaw: Double = {
            if let d = tra?["diarization_clustering_threshold"]?.double { return d }
            if let i = tra?["diarization_clustering_threshold"]?.int { return Double(i) }
            return FluidAudioRunner.defaultClusteringThreshold
        }()
        let clusteringThreshold = min(0.9, max(0.5, clusteringRaw))
        let language = tra?["language"]?.string ?? ConfigDefaults.transcriptionLanguage

        return Config(
            recording: Recording(
                outputDir: expandTilde(outputDirRaw),
                autoConsentApps: consent,
                voiceProcessing: voiceProcessing,
                honorAppMute: honorAppMute
            ),
            detection: Detection(
                debounceEndSec: debounceEnd,
                manualHotkey: hotkey,
                forceStopHotkey: forceStop,
                flagMomentHotkey: flagMoment,
                offTheRecordHotkey: offTheRecord,
                promptTimeoutSec: promptTimeout,
                repromptCooldownSec: repromptCooldown,
                micOnlySilenceSec: micOnlySilenceSec
            ),
            modes: Modes(regulatedMode: regulated),
            transcription: Transcription(
                diarizationClusteringThreshold: clusteringThreshold,
                language: language
            )
        )
    }

    /// Best-effort fallback when the user hasn't run `cp config.example.toml ...` yet.
    static func defaultFallback() -> Config {
        Config(
            recording: Recording(
                outputDir: expandTilde(ConfigDefaults.outputDirPath),
                autoConsentApps: ConfigDefaults.autoConsentApps,
                voiceProcessing: ConfigDefaults.voiceProcessing,
                honorAppMute: ConfigDefaults.honorAppMute
            ),
            detection: Detection(
                debounceEndSec: ConfigDefaults.debounceEndSec,
                manualHotkey: ConfigDefaults.manualHotkey,
                forceStopHotkey: ConfigDefaults.forceStopHotkey,
                flagMomentHotkey: ConfigDefaults.flagMomentHotkey,
                offTheRecordHotkey: ConfigDefaults.offTheRecordHotkey,
                promptTimeoutSec: ConfigDefaults.promptTimeoutSec,
                repromptCooldownSec: ConfigDefaults.repromptCooldownSec,
                micOnlySilenceSec: ConfigDefaults.micOnlySilenceSec
            ),
            modes: Modes(regulatedMode: ConfigDefaults.regulatedMode),
            transcription: Transcription(
                diarizationClusteringThreshold: FluidAudioRunner.defaultClusteringThreshold,
                language: ConfigDefaults.transcriptionLanguage
            )
        )
    }

    private static func expandTilde(_ path: String) -> URL {
        let expanded = (path as NSString).expandingTildeInPath
        return URL(fileURLWithPath: expanded)
    }
}

/// Seeds the process env with the managed Keychain tokens (`KeychainSecrets.managedKeys`: ANTHROPIC_API_KEY / NOTION_TOKEN / HF_TOKEN / OPENAI_API_KEY) so
/// pipeline subprocesses inherit them and the in-daemon Notion database picker can read NOTION_TOKEN (SEC8).
/// Reads through the same `/usr/bin/security` path every tree uses.
enum Secrets {
    static func loadIfPresent(backend: SecretsBackend = KeychainBackend()) {
        for key in KeychainSecrets.managedKeys {
            if let value = backend.value(for: key), !value.isEmpty {
                setenv(key, value, 1)
            }
        }
    }

    /// The daemon seeds the managed API tokens into its own env (`loadIfPresent`) so pipeline
    /// subprocesses can inherit them. A child that needs none of them, like ffmpeg, should not
    /// see them (SEC14); this returns the process env with every managed token stripped.
    static func scrubbedEnvironment(from base: [String: String] = ProcessInfo.processInfo.environment) -> [String: String] {
        var env = base
        for key in KeychainSecrets.managedKeys {
            env.removeValue(forKey: key)
        }
        return env
    }
}
