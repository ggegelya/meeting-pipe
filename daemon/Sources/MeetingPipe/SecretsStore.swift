import Combine
import Foundation

/// Observable wrapper over the API tokens in the macOS login Keychain (SEC8). The Preferences UI binds to the
/// published values; a debounced save writes through the injected `SecretsBackend`. An empty string means
/// absent, and clearing a field removes the Keychain item. Replaces the former plaintext `secrets.env`
/// round-trip; the legacy file is migrated once via `migrateEnvFileIfPresent` and then deleted.
///
/// SEC23: a save writes only the accounts whose value changed (so typing in one field never republishes the
/// other tokens), and an account whose read failed at launch is left alone until the user types a value into
/// it: the empty field says "could not read", not "no token", and a save must not turn it into a remove.
final class SecretsStore: ObservableObject {
    private let backend: SecretsBackend

    /// Live values. didSet → debounced save. Empty string means absent.
    @Published var anthropicAPIKey: String { didSet { scheduleSave() } }
    @Published var notionToken: String { didSet { scheduleSave() } }
    /// PROV1: key for the `openai` summarization backend. Optional; only used
    /// when summarization.backend = openai (claude_cli needs no key at all).
    @Published var openaiAPIKey: String { didSet { scheduleSave() } }

    /// Why the last save of an account failed (a token that cannot be stored, the Keychain refusing), keyed by
    /// env-var name, for the Preferences field to show. An account is absent once a later save succeeds.
    @Published private(set) var saveErrors: [String: String] = [:]

    /// Fired after a successful Keychain write.
    let didPersist = PassthroughSubject<Void, Never>()

    private var saveTimer: Timer?
    private var isInitialized = false

    private static let anthropicAccount = "ANTHROPIC_API_KEY"
    private static let notionAccount = "NOTION_TOKEN"
    private static let openaiAccount = "OPENAI_API_KEY"

    /// What the Keychain holds per account as far as this store knows, trimmed. An account missing from the
    /// map is one whose read failed: it is never removed, and is written only once the field is non-empty.
    private var persisted: [String: String] = [:]

    /// The persisted (not merely typed) tokens, readable from any thread. This is where a pipeline spawn
    /// gets the tokens it hands its child: the daemon's own environment carries none (SEC23).
    private let snapshotLock = NSLock()
    private var snapshotValues: [String: String] = [:]

    /// The store the running app uses, for readers that have no reference to it (`PipelineLauncher`,
    /// `NotionDatabaseList`). Set once by `App`; tests inject their own source instead.
    nonisolated(unsafe) static weak var live: SecretsStore?

    init(backend: SecretsBackend = KeychainBackend()) {
        self.backend = backend
        var loaded: [String: String] = [:]
        for account in Self.accounts {
            switch backend.value(for: account) {
            case .found(let value):
                loaded[account] = value
                persisted[account] = value.trimmingCharacters(in: .whitespacesAndNewlines)
            case .notFound:
                loaded[account] = ""
                persisted[account] = ""
            case .unreadable(let status, _):
                loaded[account] = ""
                Log.main.error("SecretsStore: could not read \(account) from the Keychain (status \(status)); leaving it untouched")
                Log.writeLine("main", "could not read \(account) from the Keychain (status \(status)); it will not be written or removed until you type a value into its field (SEC23)")
                Log.event(category: "main", action: "keychain_read_failed",
                          attributes: ["account": account, "status": Int(status)])
            }
        }
        self.anthropicAPIKey = loaded[Self.anthropicAccount] ?? ""
        self.notionToken = loaded[Self.notionAccount] ?? ""
        self.openaiAPIKey = loaded[Self.openaiAccount] ?? ""
        self.snapshotValues = persisted.filter { !$0.value.isEmpty }
        self.isInitialized = true
    }

    private static let accounts = [anthropicAccount, notionAccount, openaiAccount]

    /// The tokens as last written to (or read from) the Keychain, keyed by env-var name.
    var persistedTokens: [String: String] {
        snapshotLock.lock()
        defer { snapshotLock.unlock() }
        return snapshotValues
    }

    /// `persistedTokens` of the live store, or none before one exists.
    static func liveTokens() -> [String: String] { live?.persistedTokens ?? [:] }

    /// Force an immediate save. Used by Apply buttons + tests. Cancels a pending debounced save, which
    /// this one supersedes.
    func saveNow() throws {
        saveTimer?.invalidate()
        saveTimer = nil
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

    /// Write or remove each account whose trimmed value differs from what the Keychain holds. One account
    /// failing does not stop the others; the first failure is thrown once all have been tried.
    private func persist() throws {
        var firstError: Error?
        for (account, value) in [
            (Self.anthropicAccount, anthropicAPIKey),
            (Self.notionAccount, notionToken),
            (Self.openaiAccount, openaiAPIKey),
        ] {
            do {
                try write(value, to: account)
                if saveErrors[account] != nil { saveErrors[account] = nil }
            } catch {
                saveErrors[account] = error.localizedDescription
                Log.main.error("SecretsStore: writing \(account) failed: \(String(describing: error))")
                firstError = firstError ?? error
            }
        }
        if let firstError { throw firstError }
    }

    private func write(_ value: String, to account: String) throws {
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        let known = persisted[account]
        if trimmed.isEmpty {
            // Nothing stored, or unknown (the read failed): nothing to remove.
            guard let known, !known.isEmpty else { return }
            try backend.remove(account)
            persisted[account] = ""
        } else {
            guard trimmed != known else { return }
            try backend.set(trimmed, for: account)
            persisted[account] = trimmed
        }
        snapshotLock.lock()
        snapshotValues[account] = trimmed.isEmpty ? nil : trimmed
        snapshotLock.unlock()
    }

    // MARK: - Migration off the legacy plaintext secrets.env (SEC8)

    /// One-time move of a legacy `secrets.env` into the Keychain, then delete the file. Idempotent: a key
    /// already present in the Keychain is not overwritten, and a missing file is a no-op. Runs at daemon
    /// startup so an update-without-reinstall still migrates; `scripts/install.sh` does the same at install.
    ///
    /// SEC23: the file is removed only when every non-empty managed key in it is now in the Keychain (set
    /// just now, or already there). A failed set, or an existing value that could not be read, keeps the
    /// file for the next launch to retry, and an unreadable key is never overwritten as if it were absent.
    /// Returns true only when the file is gone.
    @discardableResult
    static func migrateEnvFileIfPresent(
        at url: URL = Config.secretsPath,
        backend: SecretsBackend = KeychainBackend()
    ) -> Bool {
        guard let text = try? String(contentsOf: url, encoding: .utf8) else { return false }
        var complete = true
        for (key, value) in parse(text) where !value.isEmpty {
            guard KeychainSecrets.managedKeys.contains(key) else { continue }
            switch backend.value(for: key) {
            case .found:
                continue
            case .notFound:
                do {
                    try backend.set(value, for: key)
                } catch {
                    complete = false
                    Log.writeLine("main", "secrets.env migration: could not store \(key) in the Keychain: \(error.localizedDescription) (SEC23)")
                }
            case .unreadable(let status, _):
                complete = false
                Log.writeLine("main", "secrets.env migration: could not read \(key) from the Keychain (status \(status)); not overwriting it (SEC23)")
            }
        }
        guard complete else {
            Log.writeLine("main", "secrets.env kept: not every token reached the Keychain; the next launch retries (SEC23)")
            return false
        }
        do {
            try FileManager.default.removeItem(at: url)
        } catch {
            Log.writeLine("main", "secrets.env migrated but the file could not be removed: \(error.localizedDescription) (SEC23)")
            return false
        }
        Log.writeLine("main", "migrated secrets.env into the Keychain and removed the file (SEC8)")
        return true
    }

    /// Parse KEY=VALUE lines (comments / blanks skipped, surrounding quotes stripped), preserving order.
    /// Exposed for the migration path + tests.
    static func parse(_ text: String) -> [(key: String, value: String)] {
        var out: [(String, String)] = []
        for raw in text.split(separator: "\n", omittingEmptySubsequences: false) {
            let line = raw.trimmingCharacters(in: .whitespacesAndNewlines)
            if line.isEmpty || line.hasPrefix("#") { continue }
            guard let eq = line.firstIndex(of: "=") else { continue }
            let key = String(line[..<eq]).trimmingCharacters(in: .whitespaces)
            var value = String(line[line.index(after: eq)...]).trimmingCharacters(in: .whitespacesAndNewlines)
            if value.count >= 2, value.hasPrefix("\""), value.hasSuffix("\"") {
                value = String(value.dropFirst().dropLast())
            }
            out.append((key, value))
        }
        return out
    }
}
