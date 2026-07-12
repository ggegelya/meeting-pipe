import Foundation
import TOMLKit

/// Mirrors config.example.toml. Loaded once at startup; mutations don't propagate. No audio-device fields: SCStream taps the system bus regardless of output device; AVAudioEngine.inputNode follows the system default input.
struct Config {
    struct Recording {
        var outputDir: URL
        var sampleRate: Int
        var autoConsentApps: [String]
        /// `AVAudioInputNode.setVoiceProcessingEnabled(true)`: Apple VoIP DSP (noise suppression, echo cancellation, AGC), mono only. Costs dynamic range. Default false - see load() comment.
        var voiceProcessing: Bool
        /// Track in-app mute in the meeting client (AX probe, best-effort). Does NOT pause the mic: the default is capture-first (ADR 0016), so the verdict only feeds the per-workflow redaction timeline and the idle backstop; only the regulated / NDA gate zeroes the mic live. No-op when AX is denied or the mute control is unrecognized.
        var honorAppMute: Bool
    }

    struct Detection {
        var debounceStartSec: Double
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

    var recording: Recording
    var detection: Detection
    var modes: Modes

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

        let outputDirRaw = rec?["output_dir"]?.string ?? "~/Documents/Meetings/raw"
        let sampleRate = rec?["sample_rate"]?.int ?? 16000
        let consent = (rec?["auto_consent_apps"]?.array?.compactMap { $0.string }) ?? []
        // Default OFF: VPIO's AGC degrades the HAL device gain system-wide while the engine is running, so other mic users (Teams, Zoom, FaceTime) hear the user as extremely quiet. Opt in via TOML when recording in isolation.
        let voiceProcessing = rec?["voice_processing"]?.bool ?? false
        let honorAppMute = rec?["honor_app_mute"]?.bool ?? true

        let debounceStart = det?["debounce_start_sec"]?.double ?? 5
        let debounceEnd = det?["debounce_end_sec"]?.double ?? 5
        let hotkey = det?["manual_hotkey"]?.string ?? "ctrl+option+m"
        let forceStop = det?["force_stop_hotkey"]?.string ?? "ctrl+option+shift+m"
        let flagMoment = det?["flag_moment_hotkey"]?.string ?? "ctrl+option+f"
        let offTheRecord = det?["off_the_record_hotkey"]?.string ?? "ctrl+option+o"
        let promptTimeout = det?["prompt_timeout_sec"]?.double ?? 30
        let repromptCooldown = det?["reprompt_cooldown_sec"]?.double ?? 60
        // Accept both integer and double TOML literals (`= 120` and `= 120.0`); other detection knobs are doubles-only because their TOML defaults are written as doubles.
        let micOnlySilenceSec: Double = {
            if let d = det?["mic_only_silence_seconds"]?.double { return d }
            if let i = det?["mic_only_silence_seconds"]?.int { return Double(i) }
            return 900
        }()

        let regulated = mod?["regulated_mode"]?.bool ?? false

        return Config(
            recording: Recording(
                outputDir: expandTilde(outputDirRaw),
                sampleRate: sampleRate,
                autoConsentApps: consent,
                voiceProcessing: voiceProcessing,
                honorAppMute: honorAppMute
            ),
            detection: Detection(
                debounceStartSec: debounceStart,
                debounceEndSec: debounceEnd,
                manualHotkey: hotkey,
                forceStopHotkey: forceStop,
                flagMomentHotkey: flagMoment,
                offTheRecordHotkey: offTheRecord,
                promptTimeoutSec: promptTimeout,
                repromptCooldownSec: repromptCooldown,
                micOnlySilenceSec: micOnlySilenceSec
            ),
            modes: Modes(regulatedMode: regulated)
        )
    }

    /// Best-effort fallback when the user hasn't run `cp config.example.toml ...` yet.
    static func defaultFallback() -> Config {
        Config(
            recording: Recording(
                outputDir: expandTilde("~/Documents/Meetings/raw"),
                sampleRate: 16000,
                autoConsentApps: [],
                voiceProcessing: false,
                honorAppMute: true
            ),
            detection: Detection(
                debounceStartSec: 5,
                debounceEndSec: 5,
                manualHotkey: "ctrl+option+m",
                forceStopHotkey: "ctrl+option+shift+m",
                flagMomentHotkey: "ctrl+option+f",
                offTheRecordHotkey: "ctrl+option+o",
                promptTimeoutSec: 30,
                repromptCooldownSec: 60,
                micOnlySilenceSec: 900
            ),
            modes: Modes(regulatedMode: false)
        )
    }

    private static func expandTilde(_ path: String) -> URL {
        let expanded = (path as NSString).expandingTildeInPath
        return URL(fileURLWithPath: expanded)
    }
}

/// Seeds the process env with the managed Keychain tokens (ANTHROPIC_API_KEY / NOTION_TOKEN / HF_TOKEN) so
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
