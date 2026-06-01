import Combine
import Foundation

/// Observable wrapper around `~/.config/meeting-pipe/secrets.env`. Preferences UI binds to published values; persistence is debounced, atomic, and preserves keys the UI doesn't model. Mode 0600 is enforced on the temp file before the atomic replace so the final file is never visible world-readable, even momentarily.
final class SecretsStore: ObservableObject {
    private let secretsURL: URL
    private let writeQueue = DispatchQueue(label: "com.meetingpipe.secretsstore.write", qos: .utility)

    /// Live values. didSet → debounced save. Empty string means absent.
    @Published var anthropicAPIKey: String { didSet { scheduleSave() } }
    @Published var notionToken: String { didSet { scheduleSave() } }

    /// Fired after a successful disk write. The pipeline launcher re-reads `secrets.env` per-spawn; listeners can also nudge in-memory caches.
    let didPersist = PassthroughSubject<Void, Never>()

    private var saveTimer: Timer?
    private var isInitialized: Bool = false

    /// Lines read from disk, in order. Modeled keys are updated in-place; comments and unmodeled keys are left untouched (same round-trip contract as ConfigStore).
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

    /// Project published values back into `rawLines` (upsert KEY=VALUE). Visible to tests for round-trip verification without disk I/O.
    func writeBack() {
        rawLines = Self.upsert(lines: rawLines, key: "ANTHROPIC_API_KEY", value: anthropicAPIKey)
        rawLines = Self.upsert(lines: rawLines, key: "NOTION_TOKEN", value: notionToken)
    }

    private func persistToDisk() throws {
        let body = rawLines.joined(separator: "\n")
        // Ensure the file ends with a newline (POSIX convention; `set -a; . secrets.env; set +a` requires it).
        let normalized = body.hasSuffix("\n") ? body : body + "\n"
        let dir = secretsURL.deletingLastPathComponent()
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let tmp = secretsURL.appendingPathExtension("writing")
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
        // replaceItemAt preserves the destination's existing perms, so force 0600 again in case the file was created with the wrong mode (e.g. by hand).
        try? FileManager.default.setAttributes(
            [.posixPermissions: 0o600],
            ofItemAtPath: secretsURL.path
        )
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

    /// Replace the first KEY= line with the new value, or append. Comments and other keys are left untouched.
    static func upsert(lines: [String], key: String, value: String) -> [String] {
        var copy = lines
        let prefix = "\(key)="
        for i in copy.indices {
            let trimmed = copy[i].trimmingCharacters(in: .whitespaces)
            if trimmed.hasPrefix(prefix) {
                copy[i] = "\(key)=\(value)"
                return copy
            }
            // `KEY = value` (with spaces) - uncommon but tolerate it.
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
