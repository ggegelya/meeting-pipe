import Combine
import Foundation
import TOMLKit

/// Why `config.toml` could not be read: TOMLKit's message and, when it gave
/// one, the position (ARCH9). Thrown by `ConfigStore.saveNow` while it is set.
struct ConfigParseError: Error, Equatable {
    let message: String
    let line: Int?
    let column: Int?
    /// The row's copy when the file parses but cannot be trusted (PIPE42: a
    /// regulated switch that is not a boolean, or sits in the wrong table). Nil
    /// for a syntax error, which gets the line-numbered sentence below.
    var summary: String? = nil

    /// The one Preferences row shown in place of the panes while the file is
    /// unreadable. Derived here so the copy is testable without a view.
    var preferencesMessage: String {
        if let summary { return summary }
        let at = line.map { " at line \($0)" } ?? ""
        return "config.toml has a syntax error\(at). Fix it in a text editor, then reopen Preferences."
    }
}

/// Observable wrapper around `~/.config/meeting-pipe/config.toml` that the
/// Preferences view binds to. Persistence is debounced (500 ms) and
/// preserves unknown TOML keys (pipeline-side fields stay untouched). The
/// disk write runs off the main queue.
///
/// UX96: the file is shared with a person's text editor, so the store is never
/// its only author. Every save re-reads the file and writes only the modeled keys
/// the UI changed since the last sync onto what is there now, so a hand edit made
/// while the app runs survives the next Preferences save; and an outside change
/// with no save of the store's own pending is reloaded (`reloadIfChangedOnDisk`,
/// called by Preferences' `show()` and by the file watcher `startWatching()` arms).
///
/// ARCH9: this is the only Swift type that reads `config.toml`. The daemon's
/// launch-time `Config`, the cloud-token policy, the Apple summary context,
/// the workflow migrator, and the Notion picker's regulated check all read a
/// store, so one parse and one failure rule cover every reader. A file that
/// does not parse fails closed: `parseError` is set, `regulatedMode` reads
/// true, and nothing is written back, so the user's file survives untouched
/// instead of being replaced by defaults on the next Preferences edit.
/// `ConfigStoreFenceTests` keeps any other file from parsing it.
final class ConfigStore: ObservableObject {
    private let configURL: URL
    private let writeQueue: DispatchQueue

    /// The document the store last read or wrote; a save starts from a fresh read
    /// of the file instead and makes that the new one, so unknown keys survive.
    /// Empty while a syntax error is set; a file whose regulated switch cannot be
    /// read (PIPE42) keeps its parsed document, though nothing saves it.
    private var rawDocument = TOMLTable()

    /// The file's bytes as the store last agreed with them: what it loaded, or what
    /// its last successful write put there. `nil` while there is no file. A reload
    /// whose bytes match is the store's own write or no change at all (UX96).
    private var syncedBytes: Data?
    /// Every modeled value, keyed `section.key`, as of that same sync. A value that
    /// differs from it now is one the UI changed, and only those keys are written
    /// over a file someone else may have edited since (UX96).
    private var syncedValues: [String: TOMLValue] = [:]
    /// Debounced writes handed to the queue and not yet completed, oldest first.
    private var queuedWrites: [PreparedWrite] = []
    private var writeSequence = 0
    private var midWriteRetries = 0
    private var committedSequence = 0
    private var watcher: FileChangeWatcher?

    /// A rendered save and what the store will have synced to once it lands.
    private struct PreparedWrite {
        let sequence: Int
        let toml: String
        let values: [String: TOMLValue]
    }

    /// Set when the file exists but does not parse (ARCH9), or parses with a
    /// regulated switch that cannot be read as a boolean (PIPE42). While set, saves
    /// are refused and `regulatedMode` is true; after a syntax error every other
    /// value is its default, after a PIPE42 problem the file's. `reloadIfChangedOnDisk()`
    /// clears it once the file is fixed.
    @Published private(set) var parseError: ConfigParseError?

    /// The last save that could not write the file (UX91), cleared by the next one
    /// that does. The controls keep their values; Preferences says the change is
    /// not in effect, and the next edit or **Try again** retries.
    @Published private(set) var saveError: SettingSaveFailure?

    /// The file this store reads and writes, for Preferences' Reveal in Finder.
    var fileURL: URL { configURL }

    /// Live values exposed to SwiftUI. didSet → schedule debounced save. The
    /// declared values are placeholders: `apply(_:)` assigns every one in init.
    @Published var outputDirPath: String = "" {
        didSet {
            // F056: a library chosen in the app is the last known good one too.
            if isInitialized, parseError == nil { lastGoodOutputDir.set(outputDirPath) }
            scheduleSave()
        }
    }

    /// UX94 / F056: where the last file that parsed put the recordings, kept outside config.toml so a
    /// file that stops parsing does not move the library to the default. Injected for tests.
    struct LastGoodOutputDir {
        var get: () -> String?
        var set: (String) -> Void

        static let key = "lastGoodOutputDir"
        /// `UserDefaults.standard`, except under XCTest, where nothing is remembered.
        static var live: LastGoodOutputDir {
            if Log.isRunningUnderTests { return LastGoodOutputDir(get: { nil }, set: { _ in }) }
            return LastGoodOutputDir(
                get: { UserDefaults.standard.string(forKey: key) },
                set: { UserDefaults.standard.set($0, forKey: key) }
            )
        }
    }

    private let lastGoodOutputDir: LastGoodOutputDir

    /// F056: the file does not parse, nothing remembers where the library was, and no old default
    /// holds files, so `outputDirPath` is a guess. A recording start is refused rather than landing
    /// in a folder the Library does not show (`recording_blocked`, reason `config_unreadable`).
    @Published private(set) var recordingRootUnknown = false
    @Published var autoConsentApps: [String] = [] { didSet { scheduleSave() } }
    /// Apple's VoIP DSP on the mic path. Off by default: VPIO drops the HAL
    /// gain system-wide so other clients hear the user quietly. Applies next
    /// recording.
    @Published var voiceProcessing: Bool = false { didSet { scheduleSave() } }
    /// When true, MicGate observes the client's mute button (or system input
    /// mute) and records it to the muted-span timeline (capture-first, ADR 0016):
    /// the mic is still recorded in full, redaction is a per-workflow opt-in, and
    /// only the regulated / NDA gate zeroes the mic live. Off skips mute tracking.
    @Published var honorAppMute: Bool = false { didSet { scheduleSave() } }

    @Published var manualHotkey: String = "" { didSet { scheduleSave() } }
    /// Stop-only hotkey (TECH-C5); second Carbon binding. Default
    /// `ctrl+option+shift+m`.
    @Published var forceStopHotkey: String = "" { didSet { scheduleSave() } }
    /// Flag-moment hotkey (FEAT8); third Carbon binding. Default
    /// `ctrl+option+f`.
    @Published var flagMomentHotkey: String = "" { didSet { scheduleSave() } }
    /// Off-the-record hotkey (MIC14); fourth Carbon binding. Default `ctrl+option+o`.
    @Published var offTheRecordHotkey: String = "" { didSet { scheduleSave() } }
    @Published var promptTimeoutSec: Double = 0 { didSet { scheduleSave() } }
    /// Action when the prompt times out: `"skip"` (default, suppress),
    /// `"record"`, or `"byo"`. Mirrors `[detection.default_prompt_action]`.
    @Published var defaultPromptAction: String = "" { didSet { scheduleSave() } }
    /// Per-bundle re-prompt cooldown (s): suppress fresh `.started` events
    /// from a post-call mic grab. Manual hotkey bypasses it.
    @Published var repromptCooldownSec: Double = 0 { didSet { scheduleSave() } }
    /// Idle backstop auto-stop horizon (s); auto-stop after this much VAD-silent
    /// mic with system also silent (TECH-END3). Default 900 (15 min). TOML key
    /// stays `mic_only_silence_seconds` for back-compat.
    @Published var micOnlySilenceSec: Double = 0 { didSet { scheduleSave() } }

    @Published var regulatedMode: Bool = false { didSet { scheduleSave() } }

    /// Pipeline-side fields surfaced for first-run setup; the pipeline reads
    /// the same TOML at spawn time, so edits apply next recording.
    @Published var notionDatabaseId: String = "" { didSet { scheduleSave() } }
    /// ASR language for the on-device FluidAudio (Parakeet TDT) runner: an ISO
    /// 639-1 code pins it, `"auto"` (the default) lets the SDK detect per meeting.
    /// Mirrors `transcription.language`; read once at Coordinator init and passed
    /// to `SinkDispatcher`, so a change applies on the next daemon launch.
    @Published var transcriptionLanguage: String = "" { didSet { scheduleSave() } }
    /// FluidAudio's speaker-embedding clustering threshold (DIAR2's dial, surfaced by
    /// DIAR3 as the "Speaker separation" control). Clamped on read, and `config`
    /// hands the runner this same value, so Preferences can never show a value the
    /// daemon would not use. Read once at `Coordinator` init and baked into the transcription
    /// runner, so a change applies on the next daemon launch, like `transcriptionLanguage`.
    @Published var diarizationClusteringThreshold: Double = 0 { didSet { scheduleSave() } }
    @Published var summaryLanguage: String = "" { didSet { scheduleSave() } }
    /// The opt-in LLM pass that merges same-speaker labels after transcription
    /// (`summarization.diarize_cleanup`, TECH-DIAR1). Read by `mp run-all` at spawn
    /// time, so a change applies from the next meeting with no relaunch.
    @Published var summarizationDiarizeCleanup: Bool = false { didSet { scheduleSave() } }
    /// Pin `mp digest`'s narrative to the on-device engine whatever
    /// `summarizationBackend` says (`summarization.digest_local_only`, UX63).
    /// Read by `mp digest` at spawn, so a change applies to the next run,
    /// scheduled or on demand, with no relaunch.
    @Published var summarizationDigestLocalOnly: Bool = false { didSet { scheduleSave() } }
    @Published var summarizationSkipAboveChars: Int = 0 { didSet { scheduleSave() } }
    /// PIPE27: the local backend's map-reduce bound, split from the cloud gate above. Absent from
    /// the file it reads as the gate when that is non-zero, else 80,000 (`mp.config
    /// .local_chunk_above_chars`). Written when changed here, and pinned at its shown value when
    /// the gate is changed here (`prepareWrite`), so the two sliders stay independent.
    @Published var summarizationLocalChunkAboveChars: Int = 0 { didSet { scheduleSave() } }
    static let cloudGateKey = "summarization.skip_above_chars"
    static let localChunkKey = "summarization.local_chunk_above_chars"
    /// `summarization.backend`: one of `SummarizationEngine.all`'s ids, or one this build does not
    /// know, kept verbatim so a save writes it back unchanged (ARCH14). A missing key loads as
    /// `ConfigDefaults.summarizationBackend`.
    @Published var summarizationBackend: SummarizationBackend = "" { didSet { scheduleSave() } }
    /// Model id every Anthropic path calls (`summarization.model`): the anthropic and
    /// auto backends, a workflow pinning Anthropic, Re-summarize with…, Ask and the
    /// digest. TOML-only until the Pipeline pane's Anthropic model row, so changing it
    /// meant quitting the app first or having its next save write the old id back.
    @Published var summarizationModel: String = "" { didSet { scheduleSave() } }
    @Published var summarizationLocalModel: String = "" { didSet { scheduleSave() } }
    @Published var summarizationLocalEndpoint: String = "" { didSet { scheduleSave() } }
    /// Model id the `openai` backend calls (`summarization.openai_model`). Ignored
    /// by every other backend. Surfaced by UX45; before that, picking the OpenAI
    /// backend showed an instruction to hand-edit `config.toml`.
    @Published var summarizationOpenAIModel: String = "" { didSet { scheduleSave() } }
    /// Display name stamped on the user's own diarized speaker so "me vs them"
    /// reads as a real name (`summarization.user_label`).
    @Published var summarizationUserLabel: String = "" { didSet { scheduleSave() } }

    // MARK: - Publish targets (UX45)

    /// Where each non-Notion sink writes. Global, not per-workflow, and
    /// deliberately so: a workflow chooses WHICH sinks run, global config says
    /// WHERE they land. All of these were TOML-only until UX45, which meant a
    /// workflow could enable the Obsidian or Filesystem sink and have it silently
    /// fail to run, and the LAN sink could not be selected at all.
    ///
    /// The defaults mirror the pipeline's own (`ObsidianCfg` / `FilesystemCfg` /
    /// `LanCfg` in `config.py`) so Preferences never shows a value the publisher
    /// would not use. They stay inline rather than in `ConfigDefaults` because
    /// only this store reads them Swift-side, which is the rule that file states
    /// for its own contents.
    ///
    /// `obsidian.template_path` and `obsidian.daily_note_backlink` are the two
    /// keys left TOML-only on purpose: both are advanced, neither can stop the
    /// sink from running.
    @Published var obsidianVaultPath: String = "" { didSet { scheduleSave() } }
    @Published var obsidianFolder: String = "" { didSet { scheduleSave() } }
    @Published var obsidianAttachAudio: Bool = false { didSet { scheduleSave() } }
    @Published var obsidianAttachmentsSubfolder: String = "" { didSet { scheduleSave() } }
    @Published var filesystemOutputDir: String = "" { didSet { scheduleSave() } }
    /// Target directory on an already-mounted SMB/NFS share (FEAT1). The publisher
    /// never creates the mount root itself, so a share that is down fails loudly
    /// rather than quietly writing to local disk.
    @Published var lanMountPath: String = "" { didSet { scheduleSave() } }
    /// Optional label, used only in the LAN sink's "share unreachable" message.
    @Published var lanHost: String = "" { didSet { scheduleSave() } }
    /// Whether Notion pages carry the full transcript body. Defaults on, matching
    /// the pipeline: without a switch, every transcript egresses to Notion wherever
    /// that sink runs, and regulated mode was the only in-app lever that stopped it.
    @Published var notionIncludeFullTranscript: Bool = false { didSet { scheduleSave() } }

    /// Whether `mp mcp-serve` may run (AUTO3). Off by default and consumed by
    /// the pipeline: `mcp_serve.main` refuses to start while this is false, so
    /// the Integrations switch is a real kill switch rather than a label. MCP is
    /// the one surface where the *client* picks what leaves this Mac, which is
    /// why it is opt-in where every other integration is on once configured.
    @Published var mcpEnabled: Bool = false { didSet { scheduleSave() } }

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

    /// The legacy global prompt context (`summarization.team_context`), read
    /// straight off the live TOML for the two Swift consumers: the Apple
    /// Intelligence summary and the one-shot workflow migrator. Read-only for the
    /// same reason as `outputSinks`: it is a pipeline-side knob with no control.
    var summarizationTeamContext: String {
        rawDocument["summarization"]?.table?["team_context"]?.string ?? ""
    }

    /// The daemon's value snapshot (ARCH9: `Config` is produced here rather than
    /// parsed a second time). `App` takes it once at launch; a read-only caller
    /// takes it off a store it builds for that read.
    var config: Config {
        Config(
            recording: Config.Recording(
                outputDir: URL(fileURLWithPath: (outputDirPath as NSString).expandingTildeInPath),
                autoConsentApps: autoConsentApps,
                voiceProcessing: voiceProcessing,
                honorAppMute: honorAppMute
            ),
            detection: Config.Detection(
                manualHotkey: manualHotkey,
                forceStopHotkey: forceStopHotkey,
                flagMomentHotkey: flagMomentHotkey,
                offTheRecordHotkey: offTheRecordHotkey,
                promptTimeoutSec: promptTimeoutSec,
                repromptCooldownSec: repromptCooldownSec,
                micOnlySilenceSec: micOnlySilenceSec
            ),
            modes: Config.Modes(regulatedMode: regulatedMode),
            transcription: Config.Transcription(
                diarizationClusteringThreshold: diarizationClusteringThreshold,
                language: transcriptionLanguage
            )
        )
    }

    /// Fired after a successful disk write so subscribers re-read without
    /// polling ("config changed, refresh what you care about").
    let didPersist = PassthroughSubject<Void, Never>()

    /// The debounced save (CONC8): snapshots on main, writes on `writeQueue`.
    private lazy var saver = DebouncedSaver(
        queue: writeQueue,
        prepare: { [weak self] in self?.prepareSave() },
        completion: { [weak self] result in
            guard let self else { return }
            let write = self.queuedWrites.isEmpty ? nil : self.queuedWrites.removeFirst()
            switch result {
            case .success:
                if let write { self.commit(write) }
                self.noteSaveSuccess(sequence: write?.sequence ?? self.writeSequence)
                self.didPersist.send()
            case .failure(let error):
                self.noteSaveFailure(error, sequence: write?.sequence ?? self.writeSequence)
            }
        }
    )

    /// Gates `scheduleSave` until init finishes, so the `didSet` storm from
    /// assigning defaults doesn't write compile-time defaults to the file.
    private var isInitialized: Bool = false

    init(configURL: URL = Config.defaultPath,
         writeQueue: DispatchQueue = DebouncedSaver.makeQueue(label: "com.meetingpipe.configstore.write"),
         legacyHasEntries: @escaping (String) -> Bool = LibraryDefaultPin.defaultHasEntries,
         lastGoodOutputDir: LastGoodOutputDir = .live) {
        self.configURL = configURL
        self.writeQueue = writeQueue
        self.legacyHasEntries = legacyHasEntries
        self.lastGoodOutputDir = lastGoodOutputDir
        let file = Self.read(configURL)
        apply(file)
        markSynced(bytes: file.bytes)
        // Arm last: every assignment's didSet in `apply` no-ops on !isInitialized.
        self.isInitialized = true
    }

    /// Watch the file for edits made outside the app and reload them when no save
    /// of the store's own is pending (UX96). Only the app's long-lived store calls
    /// this: the many stores built for one read must not each hold a descriptor.
    func startWatching() {
        guard watcher == nil else { return }
        let watcher = FileChangeWatcher(url: configURL) { [weak self] in self?.reloadIfChangedOnDisk() }
        watcher.start()
        self.watcher = watcher
    }

    deinit { watcher?.stop() }

    /// The one parse of `config.toml` (ARCH9). A missing file is a fresh user and
    /// reads as an empty document; a file that exists but cannot be read or parsed
    /// is an error, never an empty document, because an empty document is what
    /// the next save would write over the user's file.
    static func read(_ url: URL) -> (document: TOMLTable, parseError: ConfigParseError?, bytes: Data?) {
        guard FileManager.default.fileExists(atPath: url.path) else { return (TOMLTable(), nil, nil) }
        let bytes: Data
        do {
            bytes = try Data(contentsOf: url)
        } catch {
            return (TOMLTable(), ConfigParseError(message: error.localizedDescription, line: nil, column: nil), nil)
        }
        let parsed = parse(bytes)
        return (parsed.document, parsed.parseError, bytes)
    }

    private static func parse(_ bytes: Data) -> (document: TOMLTable, parseError: ConfigParseError?) {
        guard let raw = String(data: bytes, encoding: .utf8) else {
            return (TOMLTable(), ConfigParseError(message: "config.toml is not UTF-8 text", line: nil, column: nil))
        }
        do {
            let doc = try TOMLTable(string: raw)
            // PIPE42: a regulated switch this store cannot read as a boolean is not
            // read as off. The rest of the document still loads, so every other
            // control shows the user's value, but saves are refused (nothing writes
            // `false` over it) and `apply` reads regulated as on, the ARCH9 rule.
            return (doc, regulatedModeProblem(in: doc))
        } catch let error as TOMLParseError {
            let at = error.source.begin
            return (TOMLTable(), ConfigParseError(message: error.description, line: at.line, column: at.column))
        } catch {
            return (TOMLTable(), ConfigParseError(message: String(describing: error), line: nil, column: nil))
        }
    }

    /// Why `modes.regulated_mode` cannot be read as written, or nil. `Config.load`
    /// refuses the same files (pinned by `regulated-mode-golden.json`): a value that
    /// is not a TOML boolean (`"true"`, `1`), and a `modes` table nested under
    /// another, which is what `modes.regulated_mode = true` appended to the end of
    /// the file becomes, since TOML binds a dotted key to the last open table.
    static func regulatedModeProblem(in doc: TOMLTable) -> ConfigParseError? {
        if doc["regulated_mode"] != nil {
            return ConfigParseError(
                message: "regulated_mode is outside the [modes] table",
                line: nil, column: nil,
                summary: "config.toml has regulated_mode above every table, where nothing reads it. "
                    + "Move it under a [modes] header in a text editor; regulated mode stays on until then."
            )
        }
        if let modes = doc["modes"] {
            if let value = modes.table?["regulated_mode"], value.bool == nil {
                return ConfigParseError(
                    message: "modes.regulated_mode must be true or false",
                    line: nil, column: nil,
                    summary: "config.toml sets regulated_mode to something other than true or false. "
                        + "Regulated mode stays on until it is fixed in a text editor."
                )
            }
            if modes.table == nil {
                return ConfigParseError(
                    message: "modes must be a table",
                    line: nil, column: nil,
                    summary: "config.toml has a modes value that is not a [modes] table, so regulated_mode "
                        + "cannot be read. Regulated mode stays on until it is fixed in a text editor."
                )
            }
        }
        // `modes` itself is walked too: a file whose last table is [modes] turns an
        // appended `modes.regulated_mode = true` into `modes.modes.regulated_mode`.
        for key in doc.keys {
            if let path = nestedModes(in: doc[key], path: key) {
                return ConfigParseError(
                    message: "\(path) is a [modes] table nested under [\(key)]",
                    line: nil, column: nil,
                    summary: "config.toml has regulated_mode settings inside [\(key)], where nothing reads them. "
                        + "Move them under their own [modes] header in a text editor; regulated mode stays on until then."
                )
            }
        }
        return nil
    }

    /// The dotted path of a `modes` table anywhere below `node` (tables and arrays
    /// of tables), or nil.
    private static func nestedModes(in node: TOMLValueConvertible?, path: String) -> String? {
        if let table = node?.table {
            for key in table.keys {
                if key == "modes", table[key]?.table != nil { return "\(path).modes" }
                if let found = nestedModes(in: table[key], path: "\(path).\(key)") { return found }
            }
        } else if let array = node?.array {
            for index in 0..<array.count {
                if let found = nestedModes(in: array[index], path: path) { return found }
            }
        }
        return nil
    }

    /// Reload the file when it changed outside the app and the store has no save
    /// of its own pending or in flight (UX96): a hand edit, a restore, or a syntax
    /// error fixed in an editor (ARCH9's reopen-to-retry). Preferences' `show()`
    /// and the file watcher call it. With a save pending it does nothing: that
    /// save re-reads the file itself and keeps the outside change. Bytes that match
    /// the last sync are the store's own write, or no change, and are not reloaded,
    /// so an unsaved edit survives a reopen. Main thread.
    ///
    /// A change the UI made that never landed (its write failed) is laid back on
    /// top of the reloaded file and stays unsaved, so the next save still writes
    /// it; a reload never reverts a control under the user.
    func reloadIfChangedOnDisk() {
        guard !saver.isScheduled, queuedWrites.isEmpty else { return }
        let file = Self.read(configURL)
        guard file.bytes != syncedBytes || (file.parseError != nil) != (parseError != nil) else { return }
        // UX94: a state change is an event (a fix in an editor, or a file newly broken by hand).
        let wasBroken = parseError != nil
        defer {
            if wasBroken != (parseError != nil) { Self.recordParseState(parseError) }
        }
        let current = currentValues()
        let unsaved = current.filter { !Self.same($0.value, syncedValues[$0.key]) }
        reapply(file)
        // A file broken by hand drops the unsaved change with everything else, so a
        // banner saying it is "still on screen" would no longer be true (UX91).
        if file.parseError != nil { saveError = nil }
        if file.parseError == nil, !unsaved.isEmpty {
            let doc = file.document
            for (path, value) in unsaved { Self.set(value, at: path, in: doc) }
            isInitialized = false
            apply((doc, nil, file.bytes))
            isInitialized = true
        }
        didPersist.send()
    }

    /// UX94: `daemon/config_parse_failed` with the position (never the message, which can quote the
    /// file), or `config_parse_recovered`. Both also write a `daemon.log` line.
    static func recordParseState(_ error: ConfigParseError?) {
        if let error {
            var attributes: [String: Any] = [:]
            if let line = error.line { attributes["line"] = line }
            if let column = error.column { attributes["column"] = column }
            Log.failure(category: "daemon", action: "config_parse_failed",
                        reason: "config.toml does not parse; running with regulated mode on and saves refused",
                        attributes: attributes)
        } else {
            Log.event(category: "daemon", action: "config_parse_recovered", attributes: [:])
            Log.writeLine("daemon", "config.toml parses again")
        }
    }

    /// Adopt a fresh read as the store's whole state: values, document and sync.
    private func reapply(_ file: (document: TOMLTable, parseError: ConfigParseError?, bytes: Data?)) {
        isInitialized = false
        apply(file)
        isInitialized = true
        markSynced(bytes: file.bytes)
    }

    private func markSynced(bytes: Data?) {
        syncedBytes = bytes
        syncedValues = currentValues()
    }

    /// A landed write becomes the sync point, unless a later one already landed
    /// (a `saveNow` overtakes a debounced write whose completion is still queued).
    private func commit(_ write: PreparedWrite) {
        guard write.sequence > committedSequence else { return }
        committedSequence = write.sequence
        let keys = Self.changedKeys(from: syncedValues, to: write.values)
        syncedBytes = Data(write.toml.utf8)
        syncedValues = write.values
        // OBS5: names only, never a value: config values include paths and workflow names.
        if !keys.isEmpty {
            Log.event(category: "daemon", action: "config_saved", attributes: ["keys": keys])
            Log.writeLine("daemon", "config.toml saved: \(keys.joined(separator: ", "))")
        }
    }

    /// The dotted key paths (`summarization.backend`) whose value differs between two syncs, sorted.
    static func changedKeys(from old: [String: TOMLValue], to new: [String: TOMLValue]) -> [String] {
        Set(old.keys).union(new.keys).filter { !same(old[$0], new[$0]) }.sorted()
    }

    /// Assign every modeled value from one read. Shared by init and the reload
    /// so the two cannot disagree about a key.
    private func apply(_ file: (document: TOMLTable, parseError: ConfigParseError?, bytes: Data?)) {
        let doc = file.document
        self.rawDocument = doc
        self.parseError = file.parseError

        let rec = doc["recording"]?.table
        let det = doc["detection"]?.table
        let trans = doc["transcription"]?.table
        let mod = doc["modes"]?.table
        let notion = doc["notion"]?.table
        let summ = doc["summarization"]?.table
        let obsidian = doc["obsidian"]?.table
        let filesystem = doc["filesystem"]?.table
        let lan = doc["lan"]?.table
        let mcp = doc["mcp"]?.table

        // STOR6: a missing key falls to the old default while it holds files (`LibraryDefaultPin`).
        // F056: a file that does not parse keeps the library the last parsed file named; with
        // nothing remembered it falls to STOR6's default, and a start is refused when that default
        // is not one the owner's library is known to be in (`recordingRootUnknown`).
        // A PIPE42 file parses (the document is the file's) but cannot be trusted for regulated mode;
        // its `output_dir` is still the owner's, so a value in the document always wins.
        let stor6Default = LibraryDefaultPin.effectiveDefault(LibraryDefaultPin.recordings, hasEntries: legacyHasEntries)
        if let named = rec?["output_dir"]?.string {
            self.outputDirPath = named
            if file.parseError == nil { lastGoodOutputDir.set(named) }
            self.recordingRootUnknown = false
        } else if file.parseError == nil {
            self.outputDirPath = stor6Default
            lastGoodOutputDir.set(stor6Default)
            self.recordingRootUnknown = false
        } else if let remembered = lastGoodOutputDir.get() {
            self.outputDirPath = remembered
            self.recordingRootUnknown = false
        } else {
            self.outputDirPath = stor6Default
            self.recordingRootUnknown = !legacyHasEntries(LibraryDefaultPin.recordings.legacy)
        }
        self.autoConsentApps = (rec?["auto_consent_apps"]?.array?.compactMap { $0.string })
            ?? ConfigDefaults.autoConsentApps
        self.voiceProcessing = rec?["voice_processing"]?.bool ?? ConfigDefaults.voiceProcessing
        self.honorAppMute = rec?["honor_app_mute"]?.bool ?? ConfigDefaults.honorAppMute

        // Both literal forms: TOML separates integer from float literals and TOMLKit
        // does not coerce int to double, and `config.example.toml` writes every
        // seconds knob as an integer, so a `.double`-only read silently discarded
        // a hand-edit and then wrote the default back over it on the next save.
        func seconds(_ key: String, _ fallback: Double) -> Double {
            if let d = det?[key]?.double { return d }
            if let i = det?[key]?.int { return Double(i) }
            return fallback
        }

        self.manualHotkey = det?["manual_hotkey"]?.string ?? ConfigDefaults.manualHotkey
        self.forceStopHotkey = det?["force_stop_hotkey"]?.string ?? ConfigDefaults.forceStopHotkey
        self.flagMomentHotkey = det?["flag_moment_hotkey"]?.string ?? ConfigDefaults.flagMomentHotkey
        self.offTheRecordHotkey = det?["off_the_record_hotkey"]?.string ?? ConfigDefaults.offTheRecordHotkey
        self.promptTimeoutSec = seconds("prompt_timeout_sec", ConfigDefaults.promptTimeoutSec)
        self.defaultPromptAction = det?["default_prompt_action"]?.string ?? "skip"
        self.repromptCooldownSec = seconds("reprompt_cooldown_sec", ConfigDefaults.repromptCooldownSec)
        self.micOnlySilenceSec = seconds("mic_only_silence_seconds", ConfigDefaults.micOnlySilenceSec)

        // Fail closed (ARCH9): a file that does not parse may well say regulated,
        // so capture, the sidecar stamp and the token policy all treat it as on.
        self.regulatedMode = file.parseError != nil
            || (mod?["regulated_mode"]?.bool ?? ConfigDefaults.regulatedMode)

        self.notionDatabaseId = notion?["database_id"]?.string ?? ""
        self.transcriptionLanguage = trans?["language"]?.string ?? ConfigDefaults.transcriptionLanguage
        // Both literal forms, for the same reason as `seconds` above, and clamped
        // through the shared helper so the control reflects the value the
        // runner would actually get from a hand-edited out-of-range config (DIAR3).
        let clusteringRaw: Double = {
            if let d = trans?["diarization_clustering_threshold"]?.double { return d }
            if let i = trans?["diarization_clustering_threshold"]?.int { return Double(i) }
            return ConfigDefaults.diarizationClusteringThreshold
        }()
        self.diarizationClusteringThreshold = SpeakerSeparation.clamp(clusteringRaw)
        self.summaryLanguage = summ?["summary_language"]?.string ?? "auto"
        self.summarizationDiarizeCleanup = summ?["diarize_cleanup"]?.bool ?? false
        self.summarizationDigestLocalOnly = summ?["digest_local_only"]?.bool ?? false
        self.summarizationSkipAboveChars = summ?["skip_above_chars"]?.int ?? 80000
        self.summarizationLocalChunkAboveChars = summ?["local_chunk_above_chars"]?.int
            ?? (summarizationSkipAboveChars != 0 ? summarizationSkipAboveChars : 80000)
        self.summarizationBackend = summ?["backend"]?.string.map(SummarizationBackend.init(rawValue:))
            ?? ConfigDefaults.summarizationBackend
        // Mirrors `Summarization.model` in config.py; ConfigStoreTests reads that source.
        self.summarizationModel = summ?["model"]?.string ?? "claude-sonnet-5-5"
        self.summarizationLocalModel = summ?["local_model"]?.string
            ?? "mlx-community/Qwen2.5-7B-Instruct-4bit"
        self.summarizationLocalEndpoint = summ?["local_endpoint"]?.string
            ?? "http://127.0.0.1:8765"
        self.summarizationOpenAIModel = summ?["openai_model"]?.string ?? "gpt-4o"
        self.summarizationUserLabel = summ?["user_label"]?.string ?? ""

        // UX45 publish targets. Defaults mirror the pipeline's models exactly.
        self.notionIncludeFullTranscript = notion?["include_full_transcript"]?.bool ?? true
        self.mcpEnabled = mcp?["enabled"]?.bool ?? ConfigDefaults.mcpEnabled
        self.obsidianVaultPath = obsidian?["vault_path"]?.string ?? ""
        self.obsidianFolder = obsidian?["folder"]?.string ?? "Meetings"
        self.obsidianAttachAudio = obsidian?["attach_audio"]?.bool ?? true
        self.obsidianAttachmentsSubfolder = obsidian?["attachments_subfolder"]?.string
            ?? "_attachments"
        self.filesystemOutputDir = filesystem?["output_dir"]?.string
            ?? LibraryDefaultPin.effectiveDefault(LibraryDefaultPin.published, hasEntries: legacyHasEntries)
        self.lanMountPath = lan?["mount_path"]?.string ?? "/Volumes/meetings"
        self.lanHost = lan?["host"]?.string ?? ""
    }

    /// STOR6: whether an old default directory holds files; injected so a test never reads the
    /// developer's real library.
    private let legacyHasEntries: (String) -> Bool

    /// STOR6 item 2: whether the file names `[table] key` itself, as opposed to the value being
    /// the default this store filled in.
    func namesKey(_ key: LibraryDefaultPin.Key) -> Bool {
        rawDocument[key.table]?.table?[key.key]?.string != nil
    }

    /// STOR6 item 2: pin each moved default whose old directory holds files and that the file does
    /// not name, then save at once. Returns the keys pinned. Never on a file that did not parse
    /// (saves are refused there anyway, and the store is running on defaults).
    @discardableResult
    func pinLegacyDefaults(hasEntries: ((String) -> Bool)? = nil) -> [LibraryDefaultPin.Key] {
        guard parseError == nil else { return [] }
        let hasEntries = hasEntries ?? legacyHasEntries
        var pinned: [LibraryDefaultPin.Key] = []
        for key in [LibraryDefaultPin.recordings, LibraryDefaultPin.published]
        where LibraryDefaultPin.shouldPin(configNamesKey: namesKey(key), legacyHasEntries: hasEntries(key.legacy)) {
            if key == LibraryDefaultPin.recordings { outputDirPath = key.legacy } else { filesystemOutputDir = key.legacy }
            pinned.append(key)
        }
        guard !pinned.isEmpty else { return [] }
        do {
            try saveNow()
        } catch {
            Log.failure(category: "daemon", action: "library_default_pin_failed", error: error)
            return []
        }
        for key in pinned {
            Log.writeLine("daemon", "kept the library at its old default: wrote \(key.table).\(key.key) = \(key.legacy) into config.toml")
            Log.event(category: "daemon", action: "library_default_pinned", attributes: [
                "key": "\(key.table).\(key.key)",
            ])
        }
        return pinned
    }

    // MARK: - Persistence

    /// Force an immediate save (tests, and Preferences' Try again, UX91), firing
    /// `didPersist` when it lands like the debounced save does. Renders on the calling (main) thread and
    /// writes through `writeQueue`, behind any debounced write already in flight, so the two never share
    /// the `.writing` temp file and the last render wins.
    func saveNow() throws {
        if let parseError { throw parseError }
        let write = try prepareWrite()
        do {
            try saver.performNow { try self.writeToDisk(write.toml) }
        } catch {
            noteSaveFailure(error, sequence: write.sequence)
            throw error
        }
        commit(write)
        noteSaveSuccess(sequence: write.sequence)
        didPersist.send()
    }

    /// The newest write that failed. A success clears `saveError` only when it is
    /// newer: a debounced write that lands behind a failed `saveNow` (or the other way
    /// round, their completions reach main out of order) must not hide or raise a
    /// banner about a file that says something else.
    private var failedSequence = 0

    private func noteSaveSuccess(sequence: Int) {
        if sequence > failedSequence { saveError = nil }
    }

    /// A write that did not land (UX91): published for Preferences and the menu,
    /// recorded once with the error's domain and code. Main thread.
    private func noteSaveFailure(_ error: Error, sequence: Int) {
        let ns = error as NSError
        Log.main.error("ConfigStore persist failed: \(String(describing: error))")
        failedSequence = max(failedSequence, sequence)
        let reason = ns.localizedDescription.split(whereSeparator: \.isNewline).first.map(String.init)
            ?? "the settings file could not be written"
        // A newer write already landed: the file is current, so no banner.
        if sequence > committedSequence {
            saveError = SettingSaveFailure(store: .config, reason: reason, at: Date())
        }
        SettingSaveFailure.record(
            .config,
            attributes: ["domain": ns.domain, "code": ns.code],
            line: "config.toml save failed (\(ns.domain) \(ns.code)); the change is on screen but not in effect"
        )
    }

    /// Debounce a burst of UI changes into one disk write (500 ms).
    private func scheduleSave() {
        guard isInitialized else { return }   // drop the init didSet storm
        guard parseError == nil else { return }   // ARCH9: never write over an unparsed file
        saver.schedule()
    }

    /// On main when the debounce fires: mutate the tree and render it here, so the queue only ever sees an
    /// immutable string (MAINTHREAD-13: it used to convert `rawDocument` off main while `saveNow` mutated it).
    private func prepareSave() -> DebouncedSaver.Work? {
        guard isInitialized, parseError == nil else { return nil }
        let write: PreparedWrite
        do {
            write = try prepareWrite()
        } catch is FileMidWrite where midWriteRetries < 3 {
            midWriteRetries += 1
            saver.schedule()
            return nil
        } catch is FileMidWrite {
            // Still empty after three beats: someone emptied it on purpose.
            midWriteRetries = 0
            syncedBytes = Data()
            return prepareSave()
        } catch {
            return nil
        }
        midWriteRetries = 0
        queuedWrites.append(write)
        return { [self] in try writeToDisk(write.toml) }
    }

    /// Re-read the file and lay the UI's changes onto it (UX96). Main thread, like
    /// the render it ends in; the file is a few KB on local disk.
    ///
    /// A key is written when the UI changed it since the last sync, or when the
    /// file lacks it (a missing file is seeded whole). Every other key keeps what
    /// the file says now, and the store adopts it, so a hand-set `regulated_mode`
    /// both survives the save and reaches the daemon's in-memory readers. A key
    /// changed on both sides keeps the UI's value, the newer deliberate act, and
    /// logs `daemon`/`config_edit_conflict` naming the key, never a value. A file
    /// that no longer parses is not written (ARCH9): the store adopts the failure,
    /// so `parseError` is set and `regulatedMode` reads true, and this throws it.
    private func prepareWrite() throws -> PreparedWrite {
        let file = Self.read(configURL)
        if file.bytes?.isEmpty == true, syncedBytes?.isEmpty == false {
            throw FileMidWrite()
        }
        if let error = file.parseError {
            reapply(file)
            // Subscribers re-read, so the regulated glyph shows the fail-closed state.
            didPersist.send()
            throw error
        }
        let current = currentValues()
        var changed = Set(current.keys.filter { !Self.same(current[$0], syncedValues[$0]) })
        // PIPE27: a file without `local_chunk_above_chars` derives the local bound from the
        // cloud gate, so moving the gate alone would move local chunking with it while the
        // Local chunk size slider showed the old value. Pin the shown value with the gate.
        if changed.contains(Self.cloudGateKey), Self.value(at: Self.localChunkKey, in: file.document) == nil {
            changed.insert(Self.localChunkKey)
        }
        let ownWrite = queuedWrites.contains { Data($0.toml.utf8) == file.bytes }
        if file.bytes != syncedBytes, !ownWrite, !changed.isEmpty {
            let synced = syncedBytes.map { Self.parse($0).document } ?? TOMLTable()
            for path in changed.sorted() {
                let onDisk = Self.value(at: path, in: file.document)
                guard !Self.same(onDisk, Self.value(at: path, in: synced)), !Self.same(onDisk, current[path]) else { continue }
                Log.event(category: "daemon", action: "config_edit_conflict", attributes: ["key": path])
            }
        }
        // Only a missing file is seeded whole. A key someone deleted from an
        // existing file stays deleted unless the UI changed it, so it reads as its
        // default rather than coming back with a stale in-memory value.
        let seed = file.bytes == nil
        let doc = file.document
        write(into: doc) { path, _, _ in seed || changed.contains(path) }
        isInitialized = false
        apply((doc, nil, file.bytes))
        isInitialized = true
        writeSequence += 1
        return PreparedWrite(sequence: writeSequence, toml: currentTOML(), values: currentValues())
    }

    /// Every modeled key and its current value, in write order. The one list the
    /// full write, the changed-key check and the merge share, so no key can be
    /// written by one and missed by another.
    private var modeledValues: [(section: String, key: String, value: TOMLValueConvertible)] {
        [
            ("recording", "output_dir", outputDirPath),
            ("recording", "auto_consent_apps", autoConsentApps),
            ("recording", "voice_processing", voiceProcessing),
            ("recording", "honor_app_mute", honorAppMute),

            ("detection", "manual_hotkey", manualHotkey),
            ("detection", "force_stop_hotkey", forceStopHotkey),
            ("detection", "flag_moment_hotkey", flagMomentHotkey),
            ("detection", "off_the_record_hotkey", offTheRecordHotkey),
            ("detection", "prompt_timeout_sec", promptTimeoutSec),
            ("detection", "default_prompt_action", defaultPromptAction),
            ("detection", "reprompt_cooldown_sec", repromptCooldownSec),
            ("detection", "mic_only_silence_seconds", micOnlySilenceSec),

            ("modes", "regulated_mode", regulatedMode),

            ("transcription", "language", transcriptionLanguage),
            ("transcription", "diarization_clustering_threshold", diarizationClusteringThreshold),

            ("notion", "database_id", notionDatabaseId),
            ("notion", "include_full_transcript", notionIncludeFullTranscript),
            ("mcp", "enabled", mcpEnabled),
            ("summarization", "summary_language", summaryLanguage),
            ("summarization", "diarize_cleanup", summarizationDiarizeCleanup),
            ("summarization", "digest_local_only", summarizationDigestLocalOnly),
            ("summarization", "skip_above_chars", summarizationSkipAboveChars),
            ("summarization", "local_chunk_above_chars", summarizationLocalChunkAboveChars),
            ("summarization", "backend", summarizationBackend.rawValue),
            ("summarization", "model", summarizationModel),
            ("summarization", "local_model", summarizationLocalModel),
            ("summarization", "local_endpoint", summarizationLocalEndpoint),
            ("summarization", "openai_model", summarizationOpenAIModel),
            ("summarization", "user_label", summarizationUserLabel),

            // UX45 publish targets.
            ("obsidian", "vault_path", obsidianVaultPath),
            ("obsidian", "folder", obsidianFolder),
            ("obsidian", "attach_audio", obsidianAttachAudio),
            ("obsidian", "attachments_subfolder", obsidianAttachmentsSubfolder),
            ("filesystem", "output_dir", filesystemOutputDir),
            ("lan", "mount_path", lanMountPath),
            ("lan", "host", lanHost),
        ]
    }

    private func currentValues() -> [String: TOMLValue] {
        Dictionary(uniqueKeysWithValues: modeledValues.map { ("\($0.section).\($0.key)", $0.value.tomlValue) })
    }

    private static func value(at path: String, in doc: TOMLTable) -> TOMLValue? {
        let parts = path.split(separator: ".", maxSplits: 1).map(String.init)
        return doc[parts[0]]?.table?[parts[1]]?.tomlValue
    }

    private static func set(_ value: TOMLValue, at path: String, in doc: TOMLTable) {
        let parts = path.split(separator: ".", maxSplits: 1).map(String.init)
        ensureTable(parts[0], in: doc)[parts[1]] = value
    }

    /// Equal as config values: TOML keeps `45` and `45.0` apart, the store does not
    /// (a seconds knob reads either literal), so a hand-written integer the UI holds
    /// as a double is not a change.
    private static func same(_ a: TOMLValue?, _ b: TOMLValue?) -> Bool {
        if let a, let b, let x = a.double ?? a.int.map(Double.init), let y = b.double ?? b.int.map(Double.init) {
            return x == y
        }
        return a == b
    }

    /// The file read empty where the store last saw content: an editor that
    /// truncates before it writes, caught in between. The debounced save waits a
    /// beat and reads again rather than writing every modeled key into the gap.
    struct FileMidWrite: Error {}

    /// Write the modeled keys `include` picks into `doc`.
    private func write(into doc: TOMLTable, include: (String, String, String) -> Bool) {
        for entry in modeledValues where include("\(entry.section).\(entry.key)", entry.section, entry.key) {
            Self.ensureTable(entry.section, in: doc)[entry.key] = entry.value
        }
    }

    /// Mutate `rawDocument` to reflect every current `@Published` value.
    /// Visible to tests so they can assert the round-trip without disk I/O.
    func writeBack() {
        write(into: rawDocument) { _, _, _ in true }
    }

    /// Replace `configURL` with `toml` atomically. Runs on `writeQueue`.
    func writeToDisk(_ toml: String) throws {
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

    /// Get-or-create a top-level table in `doc`.
    ///
    /// CRITICAL: TOMLKit's subscript SET copies the source node into the
    /// parent, so after `doc[key] = new` the local `new` is detached
    /// and its assignments go to an orphan table. The silent symptom: the
    /// first assignment per fresh table is dropped on save. Re-fetch after
    /// insertion to get a wrapper around the live pointer.
    private static func ensureTable(_ key: String, in doc: TOMLTable) -> TOMLTable {
        if let existing = doc[key]?.table { return existing }
        doc[key] = TOMLTable()
        // Re-fetch: the stored value is a detached copy.
        if let live = doc[key]?.table { return live }
        // Defensive fallback (we just inserted).
        let new = TOMLTable()
        doc[key] = new
        return new
    }

    /// Render the document as TOML, with the options the disk write uses (so tests see the on-disk output).
    /// Main thread only: the tree is not safe to read while `writeBack` mutates it, so the debounce renders
    /// here and hands only the string to the write queue (MAINTHREAD-13). Visible to tests.
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

// MARK: - Auto-record allowlist (UX97)

extension ConfigStore {
    /// Add `bundleID` to `recording.auto_consent_apps` unless it is already there. The one writer
    /// for both the Preferences field and the prompt's "Always for <app>", so an Always pick shows
    /// up in the allowlist Preferences renders, with the same remove tag. False when nothing changed.
    @discardableResult
    func addAutoConsentApp(_ bundleID: String) -> Bool {
        let trimmed = bundleID.trimmingCharacters(in: .whitespaces)
        guard !trimmed.isEmpty, !autoConsentApps.contains(trimmed) else { return false }
        autoConsentApps.append(trimmed)
        return true
    }

    /// Take `bundleID` off the allowlist. The start check reads this same array, so the next
    /// sighting of that app prompts again, with no restart.
    func removeAutoConsentApp(_ bundleID: String) {
        autoConsentApps.removeAll { $0 == bundleID }
    }

    /// Preferences' empty state: true only when no app records without a prompt. Since UX97 this
    /// array is the only list the start check reads, so its emptiness is the whole answer.
    var everyMeetingPrompts: Bool { autoConsentApps.isEmpty }
}
