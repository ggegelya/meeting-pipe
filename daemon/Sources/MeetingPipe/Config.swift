import Foundation
import TOMLKit

/// Mirrors config.example.toml. Loaded once at startup; mutations don't propagate.
///
/// The capture stack (system audio + mic) is fully auto-detected since the
/// rewrite to ScreenCaptureKit + AVAudioEngine. There are no audio-device
/// fields here anymore — SCStream taps the system bus regardless of output
/// device, and AVAudioEngine.inputNode follows the system default input.
struct Config {
    struct Recording {
        var outputDir: URL
        var sampleRate: Int
        var autoConsentApps: [String]
    }

    struct Detection {
        var debounceStartSec: Double
        var debounceEndSec: Double
        var manualHotkey: String
        var promptTimeoutSec: Double
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

        let debounceStart = det?["debounce_start_sec"]?.double ?? 5
        let debounceEnd = det?["debounce_end_sec"]?.double ?? 5
        let hotkey = det?["manual_hotkey"]?.string ?? "ctrl+option+m"
        let promptTimeout = det?["prompt_timeout_sec"]?.double ?? 30

        let regulated = mod?["regulated_mode"]?.bool ?? false

        return Config(
            recording: Recording(
                outputDir: expandTilde(outputDirRaw),
                sampleRate: sampleRate,
                autoConsentApps: consent
            ),
            detection: Detection(
                debounceStartSec: debounceStart,
                debounceEndSec: debounceEnd,
                manualHotkey: hotkey,
                promptTimeoutSec: promptTimeout
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
                autoConsentApps: []
            ),
            detection: Detection(
                debounceStartSec: 5,
                debounceEndSec: 5,
                manualHotkey: "ctrl+option+m",
                promptTimeoutSec: 30
            ),
            modes: Modes(regulatedMode: false)
        )
    }

    private static func expandTilde(_ path: String) -> URL {
        let expanded = (path as NSString).expandingTildeInPath
        return URL(fileURLWithPath: expanded)
    }
}

/// Reads ~/.config/meeting-pipe/secrets.env (KEY=VALUE per line) into the process env.
/// Daemon needs ANTHROPIC_API_KEY / NOTION_TOKEN / HF_TOKEN exported when it spawns
/// the pipeline subprocess.
enum Secrets {
    static func loadIfPresent() {
        let url = Config.secretsPath
        guard let text = try? String(contentsOf: url, encoding: .utf8) else { return }
        for line in text.split(separator: "\n") {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            if trimmed.isEmpty || trimmed.hasPrefix("#") { continue }
            guard let eq = trimmed.firstIndex(of: "=") else { continue }
            let key = String(trimmed[..<eq])
            var value = String(trimmed[trimmed.index(after: eq)...])
            if value.hasPrefix("\"") && value.hasSuffix("\"") && value.count >= 2 {
                value = String(value.dropFirst().dropLast())
            }
            setenv(key, value, 1)
        }
    }
}
