import Combine
import Foundation

/// Observable wrapper around `~/.config/meeting-pipe/secrets.env`.
///
/// Mirrors the role `ConfigStore` plays for `config.toml`, but for the
/// shell-style KEY=VALUE secrets file. The Preferences UI binds to the
/// published values; persistence is debounced and atomic and preserves
/// any keys the UI doesn't model (other env entries, comments).
///
/// File mode is enforced as 0600 on every write — the file holds API
/// keys; if the user runs this on a multi-user box, world-readable
/// secrets would be a real leak. We don't `chmod` after write; we
/// ensure the temp file is mode 0600 before the atomic replace, so the
/// final file inherits the right perms.
final class SecretsStore: ObservableObject {
    private let secretsURL: URL
    private let writeQueue = DispatchQueue(label: "com.meetingpipe.secretsstore.write", qos: .utility)

    /// Live values. didSet → debounced save. Empty string means absent.
    @Published var anthropicAPIKey: String { didSet { scheduleSave() } }
    @Published var notionToken: String { didSet { scheduleSave() } }

    /// Notification fired after a successful disk write — the daemon's
    /// pipeline launcher re-reads `secrets.env` per-spawn so new values
    /// take effect on the next recording. Listeners can also nudge any
    /// in-memory caches.
    let didPersist = PassthroughSubject<Void, Never>()

    private var saveTimer: Timer?
    private var isInitialized: Bool = false

    /// The full set of lines we read from disk, in order. We mutate the
    /// values for keys we model and leave everything else (comments,
    /// foreign keys) untouched. This is the secrets-side equivalent of
    /// ConfigStore's preserve-unknown-keys behavior.
    private var rawLines: [String] = []

    init(secretsURL: URL = Config.secretsPath) {
        self.secretsURL = secretsURL

        let raw = (try? String(contentsOf: secretsURL, encoding: .utf8)) ?? ""
        self.rawLines = raw.split(separator: "\n", omittingEmptySubsequences: false).map(String.init)
        let parsed = Self.parse(lines: self.rawLines)
        self.anthropicAPIKey = parsed["ANTHROPIC_API_KEY"] ?? ""
        self.notionToken = parsed["NOTION_TOKEN"] ?? ""
        self.isInitialized = true
    }

    /// Force an immediate save. Used by Apply buttons + tests.
    func saveNow() throws {
        writeBack()
        try persistToDisk()
    }

    private func scheduleSave() {
        guard isInitialized else { return }
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
                    Log.main.error("SecretsStore persist failed: \(String(describing: error))")
                }
            }
        }
    }

    /// Project the published values back into `rawLines`, replacing or
    /// appending the relevant `KEY=VALUE` lines. Visible to tests so
    /// they can check the round-trip without disk I/O.
    func writeBack() {
        rawLines = Self.upsert(lines: rawLines, key: "ANTHROPIC_API_KEY", value: anthropicAPIKey)
        rawLines = Self.upsert(lines: rawLines, key: "NOTION_TOKEN", value: notionToken)
    }

    private func persistToDisk() throws {
        let body = rawLines.joined(separator: "\n")
        // Ensure the file ends with a newline — POSIX text-file convention,
        // and `set -a; . secrets.env; set +a` is happier with it.
        let normalized = body.hasSuffix("\n") ? body : body + "\n"
        let dir = secretsURL.deletingLastPathComponent()
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let tmp = secretsURL.appendingPathExtension("writing")
        // Write the temp file with mode 0600 BEFORE the atomic replace
        // so the final file is never visible to other users on the
        // system, even momentarily.
        try normalized.data(using: .utf8)?.write(to: tmp, options: .atomic)
        try FileManager.default.setAttributes(
            [.posixPermissions: 0o600],
            ofItemAtPath: tmp.path
        )
        if FileManager.default.fileExists(atPath: secretsURL.path) {
            _ = try FileManager.default.replaceItemAt(secretsURL, withItemAt: tmp)
        } else {
            try FileManager.default.moveItem(at: tmp, to: secretsURL)
        }
        // Belt-and-suspenders: replaceItemAt preserves the destination's
        // existing perms, so if the file was created earlier with the
        // wrong mode (e.g. by hand), force 0600 here too.
        try? FileManager.default.setAttributes(
            [.posixPermissions: 0o600],
            ofItemAtPath: secretsURL.path
        )
    }

    /// Render current contents (visible to tests).
    func currentText() -> String {
        rawLines.joined(separator: "\n")
    }

    // MARK: - Parsing helpers

    private static func parse(lines: [String]) -> [String: String] {
        var out: [String: String] = [:]
        for raw in lines {
            let line = raw.trimmingCharacters(in: .whitespaces)
            if line.isEmpty || line.hasPrefix("#") { continue }
            guard let eq = line.firstIndex(of: "=") else { continue }
            let key = String(line[..<eq]).trimmingCharacters(in: .whitespaces)
            var value = String(line[line.index(after: eq)...])
            if value.count >= 2, value.hasPrefix("\""), value.hasSuffix("\"") {
                value = String(value.dropFirst().dropLast())
            }
            out[key] = value
        }
        return out
    }

    /// Replace the first KEY= line with the new value, or append a new
    /// line at the end. Comments and other keys are left untouched.
    static func upsert(lines: [String], key: String, value: String) -> [String] {
        var copy = lines
        let prefix = "\(key)="
        for i in copy.indices {
            let trimmed = copy[i].trimmingCharacters(in: .whitespaces)
            if trimmed.hasPrefix(prefix) {
                copy[i] = "\(key)=\(value)"
                return copy
            }
            // `KEY = value` (with spaces) — uncommon but tolerate it.
            if let eq = trimmed.firstIndex(of: "="),
               trimmed[..<eq].trimmingCharacters(in: .whitespaces) == key {
                copy[i] = "\(key)=\(value)"
                return copy
            }
        }
        copy.append("\(key)=\(value)")
        return copy
    }
}
