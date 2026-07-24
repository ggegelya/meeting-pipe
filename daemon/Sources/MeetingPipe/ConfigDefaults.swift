import Foundation

/// The compile-time default for every `config.toml` knob more than one reader needs (ARCH5).
///
/// Three sites read these: `Config.load` (the per-key TOML fallback), `Config.defaultFallback`
/// (the whole struct, for a user who has not copied `config.example.toml` yet), and
/// `ConfigStore.init` (the Preferences-backed store). Each used to spell the literals itself,
/// so changing a default meant three edits and missing one showed up as Preferences disagreeing
/// with the running daemon about a value neither had been told to change.
///
/// `config.example.toml` documents these same values for the user; CI5's dead-knob fence keeps
/// that file and the readers honest about each other, so a new knob belongs in both.
///
/// Knobs only one site reads (the store's Notion and summarization keys) stay at their call
/// site: there is nothing to keep in sync, and moving them here would only add a lookup.
enum ConfigDefaults {

    // MARK: - [recording]

    static let outputDirPath = "~/Documents/Meetings/raw"
    static let autoConsentApps: [String] = []
    /// Off: VPIO's AGC degrades the HAL device gain system-wide while the engine runs, so other
    /// mic users (Teams, Zoom, FaceTime) hear the user as extremely quiet. Opt in for isolated recording.
    static let voiceProcessing = false
    static let honorAppMute = true

    // MARK: - [detection]

    static let debounceEndSec: Double = 5
    static let manualHotkey = "ctrl+option+m"
    static let forceStopHotkey = "ctrl+option+shift+m"
    static let flagMomentHotkey = "ctrl+option+f"
    static let offTheRecordHotkey = "ctrl+option+o"
    static let promptTimeoutSec: Double = 30
    static let repromptCooldownSec: Double = 60
    /// TECH-END3 idle backstop, 15 minutes. The TOML key stays `mic_only_silence_seconds`.
    static let micOnlySilenceSec: TimeInterval = 900

    // MARK: - [modes]

    static let regulatedMode = false

    // MARK: - [transcription]

    /// `"auto"`, not `"en"`: before HYG2 wired this key the transcribe call passed
    /// `languageHint: nil`, i.e. auto-detect. Defaulting to `"en"` would turn that
    /// wiring into a silent behaviour change pinning every meeting to English on any
    /// config that never set the key.
    static let transcriptionLanguage = "auto"
}
