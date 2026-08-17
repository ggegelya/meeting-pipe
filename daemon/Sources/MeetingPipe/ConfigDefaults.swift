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

    // MARK: - [mcp]

    /// Off (AUTO3). MCP is the one surface where an outside client decides what
    /// leaves this Mac, so it is opt-in; the pipeline's `MCPCfg.enabled` carries
    /// the same default, and `mcp_serve` refuses to start without it.
    static let mcpEnabled = false

    // MARK: - [transcription]

    /// `"auto"`, not `"en"`: before HYG2 wired this key the transcribe call passed
    /// `languageHint: nil`, i.e. auto-detect. Defaulting to `"en"` would turn that
    /// wiring into a silent behaviour change pinning every meeting to English on any
    /// config that never set the key.
    static let transcriptionLanguage = "auto"

    /// FluidAudio's speaker-embedding clustering threshold (DIAR2's dial, DIAR3's
    /// Preferences control). It sits below FluidAudio's own 0.7 on purpose: merging
    /// several people into one voice puts a confidently wrong name on the summary's
    /// attendees and action owners, while over-splitting only shows one person as two
    /// unnamed clusters you can merge in-app. Moved here once `ConfigStore` became a
    /// third reader; `FluidAudioRunner.defaultClusteringThreshold` is the alias the
    /// transcription default arguments use, so there is still one literal.
    ///
    /// **0.55 is measured, not guessed** (DIAR2's sweep, closed 2026-08-04 against the
    /// owner's hand-labelled corpus). Over 35 meetings the median raw cluster count per
    /// meeting went 3 at 0.7, 4 at 0.65, and 9 at 0.55, so the under-clustering behind
    /// the original 5-people-in-one-voice defect is gone as a systemic condition. The
    /// cost side of the tradeoff measured at **zero**: across all 14 hand-corrected
    /// meetings, at every threshold, the owner never once named two clusters as the
    /// same person, which is what over-splitting would look like on disk. Note this is
    /// the *lowest* position the Preferences control offers ("More distinct"), so the
    /// shipped default is deliberately at the safe end of the range rather than in the
    /// middle of it. Residual merges at 0.55 exist and are **not** threshold-reachable
    /// (see DIAR4/DIAR5); lower does not fix them, it only adds debris clusters.
    static let diarizationClusteringThreshold: Double = 0.55
}
