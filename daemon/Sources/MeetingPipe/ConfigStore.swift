import Combine
import Foundation
import TOMLKit

/// Observable wrapper around `~/.config/meeting-pipe/config.toml` that the
/// Preferences view binds to. Persistence is debounced (500 ms) and
/// preserves unknown TOML keys (pipeline-side fields stay untouched). The
/// disk write runs off the main queue.
final class ConfigStore: ObservableObject {
    private let configURL: URL
    private let writeQueue = DispatchQueue(label: "com.meetingpipe.configstore.write", qos: .utility)

    /// Read once at load, mutated in place and re-serialized on persist;
    /// that's how unknown keys survive.
    private var rawDocument: TOMLTable

    /// Live values exposed to SwiftUI. didSet → schedule debounced save.
    @Published var outputDirPath: String { didSet { scheduleSave() } }
    @Published var sampleRate: Int { didSet { scheduleSave() } }
    @Published var autoConsentApps: [String] { didSet { scheduleSave() } }
    /// Apple's VoIP DSP on the mic path. Off by default: VPIO drops the HAL
    /// gain system-wide so other clients hear the user quietly. Applies next
    /// recording.
    @Published var voiceProcessing: Bool { didSet { scheduleSave() } }
    /// When true, MicGate zeroes mic frames while the client reports muted
    /// (or system input mute is on); off keeps recording through in-app mute.
    @Published var honorAppMute: Bool { didSet { scheduleSave() } }

    @Published var debounceStartSec: Double { didSet { scheduleSave() } }
    @Published var debounceEndSec: Double { didSet { scheduleSave() } }
    @Published var manualHotkey: String { didSet { scheduleSave() } }
    /// Stop-only hotkey (TECH-C5); second Carbon binding. Default
    /// `ctrl+option+shift+m`.
    @Published var forceStopHotkey: String { didSet { scheduleSave() } }
    /// Flag-moment hotkey (FEAT8); third Carbon binding. Default
    /// `ctrl+option+f`.
    @Published var flagMomentHotkey: String { didSet { scheduleSave() } }
    /// Off-the-record hotkey (MIC14); fourth Carbon binding. Default `ctrl+option+o`.
    @Published var offTheRecordHotkey: String { didSet { scheduleSave() } }
    @Published var promptTimeoutSec: Double { didSet { scheduleSave() } }
    /// Action when the prompt times out: `"skip"` (default, suppress),
    /// `"record"`, or `"byo"`. Mirrors `[detection.default_prompt_action]`.
    @Published var defaultPromptAction: String { didSet { scheduleSave() } }
    /// Per-bundle re-prompt cooldown (s): suppress fresh `.started` events
    /// from a post-call mic grab. Manual hotkey bypasses it.
    @Published var repromptCooldownSec: Double { didSet { scheduleSave() } }
    /// Idle backstop auto-stop horizon (s); auto-stop after this much VAD-silent
    /// mic with system also silent (TECH-END3). Default 900 (15 min). TOML key
    /// stays `mic_only_silence_seconds` for back-compat.
    @Published var micOnlySilenceSec: Double { didSet { scheduleSave() } }

    @Published var regulatedMode: Bool { didSet { scheduleSave() } }

    /// Pipeline-side fields surfaced for first-run setup; the pipeline reads
    /// the same TOML at spawn time, so edits apply next recording.
    @Published var notionDatabaseId: String { didSet { scheduleSave() } }
    /// ISO 639-1 code (e.g. "en") forces Whisper to skip its flaky 30 s
    /// auto-detect; "auto" re-enables it. Mirrors `transcription.language`.
    @Published var transcriptionLanguage: String { didSet { scheduleSave() } }
    @Published var summaryLanguage: String { didSet { scheduleSave() } }
    @Published var summarizationSkipAboveChars: Int { didSet { scheduleSave() } }
    /// Summarize backend: "anthropic" | "local" | "auto". Mirrors
    /// `summarization.backend`.
    @Published var summarizationBackend: String { didSet { scheduleSave() } }
    @Published var summarizationLocalModel: String { didSet { scheduleSave() } }
    @Published var summarizationLocalEndpoint: String { didSet { scheduleSave() } }
    /// Display name stamped on the user's own diarized speaker so "me vs them"
    /// reads as a real name (`summarization.user_label`).
    @Published var summarizationUserLabel: String { didSet { scheduleSave() } }

    /// Fired after a successful disk write so subscribers re-read without
    /// polling ("config changed, refresh what you care about").
    let didPersist = PassthroughSubject<Void, Never>()

    private var saveTimer: Timer?

    /// Gates `scheduleSave` until init finishes, so the `didSet` storm from
    /// assigning defaults doesn't write compile-time defaults to the file.
    private var isInitialized: Bool = false

    init(configURL: URL = Config.defaultPath) throws {
        self.configURL = configURL
        let raw: String
        do {
            raw = try String(contentsOf: configURL, encoding: .utf8)
        } catch {
            // Fresh user, no config yet: empty TOML + compile-time defaults.
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
        self.flagMomentHotkey = det?["flag_moment_hotkey"]?.string ?? "ctrl+option+f"
        self.offTheRecordHotkey = det?["off_the_record_hotkey"]?.string ?? "ctrl+option+o"
        self.promptTimeoutSec = det?["prompt_timeout_sec"]?.double ?? 30
        self.defaultPromptAction = det?["default_prompt_action"]?.string ?? "skip"
        self.repromptCooldownSec = det?["reprompt_cooldown_sec"]?.double ?? 60
        self.micOnlySilenceSec = det?["mic_only_silence_seconds"]?.double
            ?? det?["mic_only_silence_seconds"]?.int.map(Double.init)
            ?? 900

        self.regulatedMode = mod?["regulated_mode"]?.bool ?? false

        self.notionDatabaseId = notion?["database_id"]?.string ?? ""
        self.transcriptionLanguage = trans?["language"]?.string ?? "en"
        self.summaryLanguage = summ?["summary_language"]?.string ?? "auto"
        self.summarizationSkipAboveChars = summ?["skip_above_chars"]?.int ?? 80000
        self.summarizationBackend = summ?["backend"]?.string ?? "anthropic"
        self.summarizationLocalModel = summ?["local_model"]?.string
            ?? "mlx-community/Qwen2.5-7B-Instruct-4bit"
        self.summarizationLocalEndpoint = summ?["local_endpoint"]?.string
            ?? "http://127.0.0.1:8765"
        self.summarizationUserLabel = summ?["user_label"]?.string ?? ""

        // Arm last: every prior assignment's didSet no-ops on !isInitialized.
        self.isInitialized = true
    }

    // MARK: - Persistence

    /// Force an immediate save (used by tests and "Apply" buttons).
    func saveNow() throws {
        writeBack()
        try persistToDisk()
    }

    /// Debounce a burst of UI changes into one disk write (500 ms).
    private func scheduleSave() {
        guard isInitialized else { return }   // drop the init didSet storm
        // Timer.scheduledTimer needs a run loop; hop to main if a non-UI
        // setter raced in.
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
        ensureTable("detection")["flag_moment_hotkey"] = flagMomentHotkey
        ensureTable("detection")["off_the_record_hotkey"] = offTheRecordHotkey
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
        ensureTable("summarization")["user_label"] = summarizationUserLabel
    }

    /// Render `rawDocument` and replace `configURL` atomically.
    private func persistToDisk() throws {
        // Omit `.allowLiteralStrings` so strings serialize as canonical
        // double-quoted basic strings; the single-quote form broke
        // round-trip assertions once TOMLKit started preferring it.
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
        // Propagate the replace error (not `try?`): a silent failure means
        // every later edit also vanishes with no signal to the user.
        if FileManager.default.fileExists(atPath: configURL.path) {
            _ = try FileManager.default.replaceItemAt(configURL, withItemAt: tmp)
        } else {
            try FileManager.default.moveItem(at: tmp, to: configURL)
        }
    }

    /// Get-or-create a top-level table in `rawDocument`.
    ///
    /// CRITICAL: TOMLKit's subscript SET copies the source node into the
    /// parent, so after `rawDocument[key] = new` the local `new` is detached
    /// and its assignments go to an orphan table. The silent symptom: the
    /// first assignment per fresh table is dropped on save. Re-fetch after
    /// insertion to get a wrapper around the live pointer.
    private func ensureTable(_ key: String) -> TOMLTable {
        if let existing = rawDocument[key]?.table { return existing }
        rawDocument[key] = TOMLTable()
        // Re-fetch: the stored value is a detached copy.
        if let live = rawDocument[key]?.table { return live }
        // Defensive fallback (we just inserted).
        let new = TOMLTable()
        rawDocument[key] = new
        return new
    }

    /// Render the document as TOML; mirrors `persistToDisk`'s options so
    /// tests see the on-disk output. Visible to tests.
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
