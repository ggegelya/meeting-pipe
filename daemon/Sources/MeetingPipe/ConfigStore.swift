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
    @Published var autoConsentApps: [String] { didSet { scheduleSave() } }
    /// Apple's VoIP DSP on the mic path. Off by default: VPIO drops the HAL
    /// gain system-wide so other clients hear the user quietly. Applies next
    /// recording.
    @Published var voiceProcessing: Bool { didSet { scheduleSave() } }
    /// When true, MicGate observes the client's mute button (or system input
    /// mute) and records it to the muted-span timeline (capture-first, ADR 0016):
    /// the mic is still recorded in full, redaction is a per-workflow opt-in, and
    /// only the regulated / NDA gate zeroes the mic live. Off skips mute tracking.
    @Published var honorAppMute: Bool { didSet { scheduleSave() } }

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
    /// ASR language for the on-device FluidAudio (Parakeet TDT) runner: an ISO
    /// 639-1 code pins it, `"auto"` (the default) lets the SDK detect per meeting.
    /// Mirrors `transcription.language`; read once at Coordinator init and passed
    /// to `SinkDispatcher`, so a change applies on the next daemon launch.
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

    /// Opt-in LoRA adapter the local backend serves (`summarization.local_adapter_path`,
    /// LOCAL9), read straight off the live TOML. Read-only for the same reason as
    /// `outputSinks` below: the warm-server preloader has to know it (a preloader
    /// left serving the base model after the user opts into an adapter is exactly
    /// the LOCAL11 staleness), but it has no Preferences control, and persisting a
    /// knob nothing renders is what the CI5 dead-knob fence exists to catch.
    /// Empty (the pipeline's own default) means the base model.
    var summarizationLocalAdapterPath: String {
        rawDocument["summarization"]?.table?["local_adapter_path"]?.string ?? ""
    }

    /// Global publish sinks (`output.sinks`), read straight off the live TOML.
    /// Read-only, so the setup checklist (UX22) can tell whether a notion sink
    /// is active without this becoming a persisted, Preferences-rendered knob
    /// that the CI5 dead-knob fence would flag. `output.sinks` is already a live
    /// pipeline key; defaults to the pipeline's own default when absent.
    var outputSinks: [String] {
        if let arr = rawDocument["output"]?.table?["sinks"]?.array {
            return arr.compactMap { $0.string }
        }
        return ["notion"]
    }

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

        self.outputDirPath = rec?["output_dir"]?.string ?? ConfigDefaults.outputDirPath
        self.autoConsentApps = (rec?["auto_consent_apps"]?.array?.compactMap { $0.string })
            ?? ConfigDefaults.autoConsentApps
        self.voiceProcessing = rec?["voice_processing"]?.bool ?? ConfigDefaults.voiceProcessing
        self.honorAppMute = rec?["honor_app_mute"]?.bool ?? ConfigDefaults.honorAppMute

        // Both literal forms, for the reason spelled out in `Config.load`: TOMLKit
        // does not coerce int to double, and `config.example.toml` writes every
        // seconds knob as an integer, so a `.double`-only read silently discarded
        // a hand-edit and then wrote the default back over it on the next save.
        func seconds(_ key: String, _ fallback: Double) -> Double {
            if let d = det?[key]?.double { return d }
            if let i = det?[key]?.int { return Double(i) }
            return fallback
        }

        self.debounceEndSec = seconds("debounce_end_sec", ConfigDefaults.debounceEndSec)
        self.manualHotkey = det?["manual_hotkey"]?.string ?? ConfigDefaults.manualHotkey
        self.forceStopHotkey = det?["force_stop_hotkey"]?.string ?? ConfigDefaults.forceStopHotkey
        self.flagMomentHotkey = det?["flag_moment_hotkey"]?.string ?? ConfigDefaults.flagMomentHotkey
        self.offTheRecordHotkey = det?["off_the_record_hotkey"]?.string ?? ConfigDefaults.offTheRecordHotkey
        self.promptTimeoutSec = seconds("prompt_timeout_sec", ConfigDefaults.promptTimeoutSec)
        self.defaultPromptAction = det?["default_prompt_action"]?.string ?? "skip"
        self.repromptCooldownSec = seconds("reprompt_cooldown_sec", ConfigDefaults.repromptCooldownSec)
        self.micOnlySilenceSec = seconds("mic_only_silence_seconds", ConfigDefaults.micOnlySilenceSec)

        self.regulatedMode = mod?["regulated_mode"]?.bool ?? ConfigDefaults.regulatedMode

        self.notionDatabaseId = notion?["database_id"]?.string ?? ""
        self.transcriptionLanguage = trans?["language"]?.string ?? ConfigDefaults.transcriptionLanguage
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
        ensureTable("recording")["auto_consent_apps"] = autoConsentApps
        ensureTable("recording")["voice_processing"] = voiceProcessing
        ensureTable("recording")["honor_app_mute"] = honorAppMute

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
