import Combine
import Foundation

/// Observable wrapper over the API tokens in the macOS login Keychain (SEC8). The Preferences UI binds to the
/// published values; a debounced save writes through the injected `SecretsBackend`. An empty string means
/// absent, and clearing a field removes the Keychain item. Replaces the former plaintext `secrets.env`
/// round-trip; the legacy file is migrated once via `migrateEnvFileIfPresent` and then deleted.
final class SecretsStore: ObservableObject {
    private let backend: SecretsBackend

    /// Live values. didSet → debounced save. Empty string means absent.
    @Published var anthropicAPIKey: String { didSet { scheduleSave() } }
    @Published var notionToken: String { didSet { scheduleSave() } }

    /// Fired after a successful Keychain write. `App` mirrors the values into the process env so the next
    /// pipeline spawn + the in-daemon Notion database picker pick them up without a restart.
    let didPersist = PassthroughSubject<Void, Never>()

    private var saveTimer: Timer?
    private var isInitialized = false

    private static let anthropicAccount = "ANTHROPIC_API_KEY"
    private static let notionAccount = "NOTION_TOKEN"

    init(backend: SecretsBackend = KeychainBackend()) {
        self.backend = backend
        self.anthropicAPIKey = backend.value(for: Self.anthropicAccount) ?? ""
        self.notionToken = backend.value(for: Self.notionAccount) ?? ""
        self.isInitialized = true
    }

    /// Force an immediate save. Used by Apply buttons + tests.
    func saveNow() throws {
        try persist()
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
            do {
                try self.persist()
                self.didPersist.send()
            } catch {
                Log.main.error("SecretsStore persist failed: \(String(describing: error))")
            }
        }
    }

    private func persist() throws {
        try write(anthropicAPIKey, to: Self.anthropicAccount)
        try write(notionToken, to: Self.notionAccount)
    }

    private func write(_ value: String, to account: String) throws {
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.isEmpty {
            backend.remove(account)
        } else {
            try backend.set(trimmed, for: account)
        }
    }

    // MARK: - Migration off the legacy plaintext secrets.env (SEC8)

    /// One-time move of a legacy `secrets.env` into the Keychain, then delete the file. Idempotent: a key
    /// already present in the Keychain is not overwritten, and a missing file is a no-op. Runs at daemon
    /// startup so an update-without-reinstall still migrates; `scripts/install.sh` does the same at install.
    @discardableResult
    static func migrateEnvFileIfPresent(
        at url: URL = Config.secretsPath,
        backend: SecretsBackend = KeychainBackend()
    ) -> Bool {
        guard let text = try? String(contentsOf: url, encoding: .utf8) else { return false }
        for (key, value) in parse(text) where !value.isEmpty {
            guard KeychainSecrets.managedKeys.contains(key), backend.value(for: key) == nil else { continue }
            try? backend.set(value, for: key)
        }
        try? FileManager.default.removeItem(at: url)
        Log.writeLine("main", "migrated secrets.env into the Keychain and removed the file (SEC8)")
        return true
    }

    /// Parse KEY=VALUE lines (comments / blanks skipped, surrounding quotes stripped), preserving order.
    /// Exposed for the migration path + tests.
    static func parse(_ text: String) -> [(key: String, value: String)] {
        var out: [(String, String)] = []
        for raw in text.split(separator: "\n", omittingEmptySubsequences: false) {
            let line = raw.trimmingCharacters(in: .whitespaces)
            if line.isEmpty || line.hasPrefix("#") { continue }
            guard let eq = line.firstIndex(of: "=") else { continue }
            let key = String(line[..<eq]).trimmingCharacters(in: .whitespaces)
            var value = String(line[line.index(after: eq)...]).trimmingCharacters(in: .whitespaces)
            if value.count >= 2, value.hasPrefix("\""), value.hasSuffix("\"") {
                value = String(value.dropFirst().dropLast())
            }
            out.append((key, value))
        }
        return out
    }
}
