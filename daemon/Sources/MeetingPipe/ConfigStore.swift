import Combine
import Foundation
import TOMLKit

/// Observable wrapper around `~/.config/meeting-pipe/config.toml`.
///
/// Owns load/persist round-trips so the SwiftUI Preferences view can bind
/// directly to the published values. Persisting is debounced (500ms) and
/// preserves any TOML keys we don't model in `Config` — pipeline-side
/// fields like `transcription.model` or `summarization.team_context`
/// stay in the file untouched, so editing daemon-only fields here can't
/// nuke the Python side's settings.
///
/// Threading: `@Published` updates fire on whatever queue the setter runs
/// on; SwiftUI views observe via `ObservableObject`. Persistence uses
/// `DispatchQueue.main` for the timer and a background queue for the
/// disk write so we don't block the UI on slow flash.
final class ConfigStore: ObservableObject {
    private let configURL: URL
    private let writeQueue = DispatchQueue(label: "com.meetingpipe.configstore.write", qos: .utility)

    /// Toml document we read at load. We mutate it in place and re-convert
    /// to a string when persisting — that's how unknown keys survive.
    private var rawDocument: TOMLTable

    /// Live values exposed to SwiftUI. didSet → schedule debounced save.
    @Published var outputDirPath: String { didSet { scheduleSave() } }
    @Published var sampleRate: Int { didSet { scheduleSave() } }
    @Published var autoConsentApps: [String] { didSet { scheduleSave() } }
    /// Apple's VoIP DSP chain (noise suppression, AGC, echo cancel) on
    /// the mic capture path. Off by default because VPIO drops the HAL
    /// device gain system-wide while the engine runs, so Teams / Zoom /
    /// FaceTime hear the user quietly for the duration of the recording.
    /// Takes effect on the next recording (Recorder binds it at start).
    @Published var voiceProcessing: Bool { didSet { scheduleSave() } }
    /// When true, MicGate's per-buffer apply zeroes mic frames whenever
    /// the meeting client reports the user as muted (Teams / Zoom /
    /// Slack / Webex AX scrape) or the system input mute is engaged.
    /// Off keeps the mic recording even while you appear muted in-app.
    @Published var honorAppMute: Bool { didSet { scheduleSave() } }

    @Published var debounceStartSec: Double { didSet { scheduleSave() } }
    @Published var debounceEndSec: Double { didSet { scheduleSave() } }
    @Published var manualHotkey: String { didSet { scheduleSave() } }
    /// Stop-only hotkey (TECH-C5). Same parser as `manualHotkey`; the
    /// daemon registers it as a second Carbon binding. Default
    /// `ctrl+option+shift+m`.
    @Published var forceStopHotkey: String { didSet { scheduleSave() } }
    @Published var promptTimeoutSec: Double { didSet { scheduleSave() } }
    /// What the prompt panel does when the user ignores it for
    /// `promptTimeoutSec`. Default `"skip"` keeps the historical
    /// behaviour (state goes to `.suppressed`, no recording). `"record"`
    /// auto-starts an auto-summary recording; `"byo"` auto-starts a
    /// BYO recording (manual-paste bundle). Anything else falls back to
    /// `"skip"`. Mirrors `[detection.default_prompt_action]`.
    @Published var defaultPromptAction: String { didSet { scheduleSave() } }
    /// Per-bundle re-prompt cooldown (seconds). After a recording for
    /// a bundle ends, or its prompt is skipped/timed out, the detector
    /// can keep firing fresh `.started` events from the post-call
    /// surface (Teams chat reclaiming the mic for a second, Zoom's
    /// post-meeting toast holding the audio session, etc.). Suppress
    /// new prompts for the same bundle for this long. Manual hotkey
    /// always bypasses the cooldown.
    @Published var repromptCooldownSec: Double { didSet { scheduleSave() } }
    /// Window (seconds) for the MicOnlySilenceBackstop (TECH-C7).
    /// Force-stops the recording after this many seconds of mic-only
    /// silence while the system audio channel is also silent. Default
    /// 480 (8 minutes). Catches the "everyone else left and the user
    /// forgot to stop" case.
    @Published var micOnlySilenceSec: Double { didSet { scheduleSave() } }

    @Published var regulatedMode: Bool { didSet { scheduleSave() } }

    /// Pipeline-side fields surfaced in the UI for first-run setup.
    /// The pipeline reads these from the same TOML file at subprocess
    /// spawn time, so changes here take effect on the next recording
    /// without restarting the daemon.
    @Published var notionDatabaseId: String { didSet { scheduleSave() } }
    /// Transcription language. ISO 639-1 code (e.g. "en") forces Whisper
    /// to skip its first-30 s auto-detect (which mis-fires on accented
    /// speech and silence-heavy openings). "auto" opts back into per-
    /// meeting detection. Mirrors `transcription.language` in the
    /// pipeline config.
    @Published var transcriptionLanguage: String { didSet { scheduleSave() } }
    @Published var summaryLanguage: String { didSet { scheduleSave() } }
    @Published var summarizationSkipAboveChars: Int { didSet { scheduleSave() } }
    /// Backend selection for the summarize stage. Mirrors
    /// `summarization.backend` in the pipeline config; see
    /// `pipeline/src/mp/summarize.py::_select_backend`.
    /// Valid values: "anthropic", "local", "auto".
    @Published var summarizationBackend: String { didSet { scheduleSave() } }
    @Published var summarizationLocalModel: String { didSet { scheduleSave() } }
    @Published var summarizationLocalEndpoint: String { didSet { scheduleSave() } }

    /// Fired AFTER a successful disk write so subscribers (the daemon's
    /// Coordinator) can re-read affected fields without polling. Sends
    /// nothing — it's a "config changed, refresh whatever you care about"
    /// notification.
    let didPersist = PassthroughSubject<Void, Never>()

    private var saveTimer: Timer?

    /// Set true at the end of `init`. `didSet` callbacks fire while we
    /// assign the `@Published` defaults during init; gating `scheduleSave`
    /// on this flag prevents a spurious immediate write of compile-time
    /// defaults to the user's config file when init runs off the main
    /// thread (where the previous `Thread.current.isMainThread` re-entry
    /// guard didn't actually catch the re-entry).
    private var isInitialized: Bool = false

    init(configURL: URL = Config.defaultPath) throws {
        self.configURL = configURL
        let raw: String
        do {
            raw = try String(contentsOf: configURL, encoding: .utf8)
        } catch {
            // Bootstrapping a fresh user: no config file yet. Start with
            // an empty TOML and the daemon's compile-time defaults.
            raw = ""
        }
        let doc = (try? TOMLTable(string: raw)) ?? TOMLTable()
        self.rawDocument = doc

        let rec = doc["recording"]?.table
        let det = doc["detection"]?.table
        let trans = doc["transcription"]?.table
        let mod = doc["modes"]?.table
        let notion = doc["notion"]?.table
        let summ = doc["summarization"]?.table

        self.outputDirPath = rec?["output_dir"]?.string ?? "~/Documents/Meetings/raw"
        self.sampleRate = rec?["sample_rate"]?.int ?? 16000
        self.autoConsentApps = (rec?["auto_consent_apps"]?.array?.compactMap { $0.string }) ?? []
        self.voiceProcessing = rec?["voice_processing"]?.bool ?? false
        self.honorAppMute = rec?["honor_app_mute"]?.bool ?? true

        self.debounceStartSec = det?["debounce_start_sec"]?.double ?? 5
        self.debounceEndSec = det?["debounce_end_sec"]?.double ?? 5
        self.manualHotkey = det?["manual_hotkey"]?.string ?? "ctrl+option+m"
        self.forceStopHotkey = det?["force_stop_hotkey"]?.string ?? "ctrl+option+shift+m"
        self.promptTimeoutSec = det?["prompt_timeout_sec"]?.double ?? 30
        self.defaultPromptAction = det?["default_prompt_action"]?.string ?? "skip"
        self.repromptCooldownSec = det?["reprompt_cooldown_sec"]?.double ?? 60
        self.micOnlySilenceSec = det?["mic_only_silence_seconds"]?.double
            ?? det?["mic_only_silence_seconds"]?.int.map(Double.init)
            ?? 480

        self.regulatedMode = mod?["regulated_mode"]?.bool ?? false

        self.notionDatabaseId = notion?["database_id"]?.string ?? ""
        self.transcriptionLanguage = trans?["language"]?.string ?? "en"
        self.summaryLanguage = summ?["summary_language"]?.string ?? "auto"
        self.summarizationSkipAboveChars = summ?["skip_above_chars"]?.int ?? 80000
        self.summarizationBackend = summ?["backend"]?.string ?? "anthropic"
        self.summarizationLocalModel = summ?["local_model"]?.string
            ?? "mlx-community/Qwen2.5-3B-Instruct-4bit"
        self.summarizationLocalEndpoint = summ?["local_endpoint"]?.string
            ?? "http://127.0.0.1:8765"

        // Arming this last is the whole point — every prior `self.x = …`
        // triggered didSet which now no-ops on `!isInitialized`.
        self.isInitialized = true
    }

    // MARK: - Persistence

    /// Force an immediate save (used by tests and "Apply" buttons).
    func saveNow() throws {
        writeBack()
        try persistToDisk()
    }

    /// Debounce: collapse a burst of UI changes into a single disk write.
    /// 500ms is below human-noticeable latency but high enough that
    /// dragging a slider doesn't thrash the file system.
    private func scheduleSave() {
        // Drop the storm of didSet callbacks fired during init.
        guard isInitialized else { return }
        // Timer.scheduledTimer must be called from a thread with a run
        // loop. Hop to main if a non-UI setter raced in.
        guard Thread.current.isMainThread else {
            DispatchQueue.main.async { [weak self] in self?.scheduleSave() }
            return
        }
        saveTimer?.invalidate()
        saveTimer = Timer.scheduledTimer(withTimeInterval: 0.5, repeats: false) { [weak self] _ in
            guard let self = self else { return }
            self.writeBack()
            self.writeQueue.async {
                do {
                    try self.persistToDisk()
                    DispatchQueue.main.async { self.didPersist.send() }
                } catch {
                    Log.main.error("ConfigStore persist failed: \(String(describing: error))")
                }
            }
        }
    }

    /// Mutate `rawDocument` to reflect current `@Published` values.
    /// Visible to tests so they can assert the round-trip without disk I/O.
    func writeBack() {
        ensureTable("recording")["output_dir"] = outputDirPath
        ensureTable("recording")["sample_rate"] = sampleRate
        ensureTable("recording")["auto_consent_apps"] = autoConsentApps
        ensureTable("recording")["voice_processing"] = voiceProcessing
        ensureTable("recording")["honor_app_mute"] = honorAppMute

        ensureTable("detection")["debounce_start_sec"] = debounceStartSec
        ensureTable("detection")["debounce_end_sec"] = debounceEndSec
        ensureTable("detection")["manual_hotkey"] = manualHotkey
        ensureTable("detection")["force_stop_hotkey"] = forceStopHotkey
        ensureTable("detection")["prompt_timeout_sec"] = promptTimeoutSec
        ensureTable("detection")["default_prompt_action"] = defaultPromptAction
        ensureTable("detection")["reprompt_cooldown_sec"] = repromptCooldownSec
        ensureTable("detection")["mic_only_silence_seconds"] = micOnlySilenceSec

        ensureTable("modes")["regulated_mode"] = regulatedMode

        ensureTable("transcription")["language"] = transcriptionLanguage

        ensureTable("notion")["database_id"] = notionDatabaseId
        ensureTable("summarization")["summary_language"] = summaryLanguage
        ensureTable("summarization")["skip_above_chars"] = summarizationSkipAboveChars
        ensureTable("summarization")["backend"] = summarizationBackend
        ensureTable("summarization")["local_model"] = summarizationLocalModel
        ensureTable("summarization")["local_endpoint"] = summarizationLocalEndpoint
    }

    /// Render `rawDocument` and replace `configURL` atomically.
    private func persistToDisk() throws {
        // Pass a FormatOptions set WITHOUT `.allowLiteralStrings` so all
        // strings round-trip with double quotes (`key = "value"`) rather
        // than TOML's literal-string single-quote form (`key = 'value'`).
        // Other tools (vim TOML highlighters, external linters, our own
        // tests) all expect the canonical basic-string output, and the
        // single-quote form was breaking ConfigStore round-trip
        // assertions under Xcode 26.5 / Swift 6 once TOMLKit started
        // preferring literal strings for value-only payloads.
        let toml = rawDocument.convert(
            to: .toml,
            options: [
                .allowMultilineStrings,
                .allowUnicodeStrings,
                .allowBinaryIntegers,
                .allowOctalIntegers,
                .allowHexadecimalIntegers,
                .indentations,
            ]
        )
        try FileManager.default.createDirectory(
            at: configURL.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        let tmp = configURL.appendingPathExtension("writing")
        try toml.data(using: .utf8)?.write(to: tmp, options: .atomic)
        // Propagate the replace error rather than swallowing with `try?` —
        // a silent failure here would mean every subsequent Preferences
        // edit also vanishes (the user thinks they saved, but the file
        // didn't change), and the user has no signal anything is wrong.
        // The caller logs at error level via the writeQueue's catch.
        if FileManager.default.fileExists(atPath: configURL.path) {
            _ = try FileManager.default.replaceItemAt(configURL, withItemAt: tmp)
        } else {
            try FileManager.default.moveItem(at: tmp, to: configURL)
        }
    }

    /// Get-or-create a top-level table in `rawDocument`.
    ///
    /// CRITICAL: TOMLKit's subscript SET on `TOMLTable` (the underlying
    /// `tableReplaceOrInsertNode` C call) COPIES the source node into
    /// the parent's backing store. After `rawDocument[key] = new`, the
    /// local `new` is detached from the persisted document — any
    /// subscript assignment on it goes to an orphan table that nobody
    /// renders. The symptom is silent: the FIRST assignment per
    /// fresh top-level table (e.g. `notion.database_id` when the user
    /// has no `[notion]` block yet) is dropped on save while every
    /// subsequent assignment lands.
    ///
    /// Re-fetching the table from `rawDocument` after insertion gives
    /// us a Swift wrapper around the SAME C-level pointer that
    /// `persistToDisk` will serialize, so subsequent assignments
    /// persist correctly.
    private func ensureTable(_ key: String) -> TOMLTable {
        if let existing = rawDocument[key]?.table { return existing }
        rawDocument[key] = TOMLTable()
        // Re-fetch: the value we just stored is a detached copy.
        // `rawDocument[key]?.table` wraps the live pointer.
        if let live = rawDocument[key]?.table { return live }
        // Defensive fallback (shouldn't happen — we just inserted).
        let new = TOMLTable()
        rawDocument[key] = new
        return new
    }

    /// Render the current document as a TOML string. Visible to tests.
    /// Mirrors `persistToDisk`'s format options so test assertions see
    /// the same canonical basic-string output that actually lands on
    /// disk.
    func currentTOML() -> String {
        rawDocument.convert(
            to: .toml,
            options: [
                .allowMultilineStrings,
                .allowUnicodeStrings,
                .allowBinaryIntegers,
                .allowOctalIntegers,
                .allowHexadecimalIntegers,
                .indentations,
            ]
        )
    }
}
