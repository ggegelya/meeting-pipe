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

    @Published var debounceStartSec: Double { didSet { scheduleSave() } }
    @Published var debounceEndSec: Double { didSet { scheduleSave() } }
    @Published var manualHotkey: String { didSet { scheduleSave() } }
    @Published var promptTimeoutSec: Double { didSet { scheduleSave() } }

    @Published var regulatedMode: Bool { didSet { scheduleSave() } }

    /// Fired AFTER a successful disk write so subscribers (the daemon's
    /// Coordinator) can re-read affected fields without polling. Sends
    /// nothing — it's a "config changed, refresh whatever you care about"
    /// notification.
    let didPersist = PassthroughSubject<Void, Never>()

    private var saveTimer: Timer?

    /// `now: Date` is monkey-patchable for tests that don't want to wait
    /// the debounce window. Production callers use the no-arg overload.
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
        let mod = doc["modes"]?.table

        self.outputDirPath = rec?["output_dir"]?.string ?? "~/Documents/Meetings/raw"
        self.sampleRate = rec?["sample_rate"]?.int ?? 16000
        self.autoConsentApps = (rec?["auto_consent_apps"]?.array?.compactMap { $0.string }) ?? []

        self.debounceStartSec = det?["debounce_start_sec"]?.double ?? 5
        self.debounceEndSec = det?["debounce_end_sec"]?.double ?? 5
        self.manualHotkey = det?["manual_hotkey"]?.string ?? "ctrl+option+m"
        self.promptTimeoutSec = det?["prompt_timeout_sec"]?.double ?? 30

        self.regulatedMode = mod?["regulated_mode"]?.bool ?? false
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
        // Avoid re-entry during init: didSet fires while published vars
        // are being assigned in init. Once we have a saveTimer-capable
        // run loop, we're past init.
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

        ensureTable("detection")["debounce_start_sec"] = debounceStartSec
        ensureTable("detection")["debounce_end_sec"] = debounceEndSec
        ensureTable("detection")["manual_hotkey"] = manualHotkey
        ensureTable("detection")["prompt_timeout_sec"] = promptTimeoutSec

        ensureTable("modes")["regulated_mode"] = regulatedMode
    }

    /// Render `rawDocument` and replace `configURL` atomically.
    private func persistToDisk() throws {
        let toml = rawDocument.convert(to: .toml)
        try FileManager.default.createDirectory(
            at: configURL.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        let tmp = configURL.appendingPathExtension("writing")
        try toml.data(using: .utf8)?.write(to: tmp, options: .atomic)
        if FileManager.default.fileExists(atPath: configURL.path) {
            _ = try? FileManager.default.replaceItemAt(configURL, withItemAt: tmp)
        } else {
            try FileManager.default.moveItem(at: tmp, to: configURL)
        }
    }

    /// Get-or-create a top-level table in `rawDocument`.
    private func ensureTable(_ key: String) -> TOMLTable {
        if let existing = rawDocument[key]?.table { return existing }
        let new = TOMLTable()
        rawDocument[key] = new
        return new
    }

    /// Render the current document as a TOML string. Visible to tests.
    func currentTOML() -> String {
        rawDocument.convert(to: .toml)
    }
}
