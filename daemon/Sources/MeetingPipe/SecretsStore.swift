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
///
/// CONC8: the save runs on a `DebouncedSaver`'s utility queue, never on main, because every Keychain call is a
/// `security` subprocess that a locked keychain can park. The snapshot is taken on main; `saveStates` reports
/// Saving, then Saved or Failed, back to the key fields.
final class SecretsStore: ObservableObject {
    private let backend: SecretsBackend

    /// Live values. didSet → debounced save. Empty string means absent.
    @Published var anthropicAPIKey: String { didSet { scheduleSave() } }
    @Published var notionToken: String { didSet { scheduleSave() } }
    /// PROV1: key for the `openai` summarization backend. Optional; only used
    /// when summarization.backend = openai (claude_cli needs no key at all).
    @Published var openaiAPIKey: String { didSet { scheduleSave() } }

    /// Where each account's save stands, keyed by env-var name; an account never edited is absent. Only an
    /// edit sets `saving`; `saved` falls back to absent after a moment so the field's own state shows again.
    enum SaveState: Equatable {
        case saving
        case saved
        /// The error kind, never a value.
        case failed(String)
    }
    @Published private(set) var saveStates: [String: SaveState] = [:]

    /// Why the last save of an account failed (a token that cannot be stored, the Keychain refusing), keyed by
    /// env-var name, for the Preferences field to show.
    var saveErrors: [String: String] {
        saveStates.compactMapValues { if case .failed(let message) = $0 { return message } else { return nil } }
    }

    /// UX91: the banner's and the menu's view of a failed save, naming the account and
    /// never a value or `security`'s stderr. Cleared once no account is left failed.
    @Published private(set) var saveError: SettingSaveFailure?

    /// Retry a failed save through the debounced saver, so the `security` calls stay
    /// off main (Preferences' Try again). `prepareSave` retries any failed account.
    func retrySave() { scheduleSave() }

    /// Fired on main after a save in which every attempted account landed.
    let didPersist = PassthroughSubject<Void, Never>()

    private var isInitialized = false

    /// The debounced save (CONC8): snapshots on main, writes on its own utility queue.
    private lazy var saver = DebouncedSaver(
        queue: DebouncedSaver.makeQueue(label: "com.meetingpipe.secretsstore.write"),
        prepare: { [weak self] in self?.prepareSave() },
        completion: { [weak self] result in self?.finishSave(result) }
    )

    /// The values the last `prepareSave` snapshotted, main-confined: an account whose value differs from it
    /// was edited since, which is what marks it `saving`.
    private var lastSnapshot: [String: String] = [:]

    private static let anthropicAccount = "ANTHROPIC_API_KEY"
    private static let notionAccount = "NOTION_TOKEN"
    private static let openaiAccount = "OPENAI_API_KEY"

    /// What the Keychain holds per account as far as this store knows, trimmed. An account missing from the
    /// map is one whose read failed: it is never removed, and is written only once the field is non-empty.
    /// Written by the save queue, so guarded by `snapshotLock` with `snapshotValues`.
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
        self.lastSnapshot = Self.trimmedValues(loaded)
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

    /// Force an immediate save and wait for it (tests, and any caller that must know). The Keychain calls
    /// still run on the saver's queue, not on the calling thread; this blocks the caller until they finish.
    func saveNow() throws {
        markSaving()
        do {
            try saver.performNow(makeWork(snapshot: currentValues()))
            finishSave(.success(()))
        } catch {
            finishSave(.failure(error))
            throw (error as? SaveFailure)?.first ?? error
        }
    }

    private func scheduleSave() {
        guard isInitialized else { return }
        saver.schedule()
    }

    private func currentValues() -> [String: String] {
        Self.trimmedValues([
            Self.anthropicAccount: anthropicAPIKey,
            Self.notionAccount: notionToken,
            Self.openaiAccount: openaiAPIKey,
        ])
    }

    private static func trimmedValues(_ raw: [String: String]) -> [String: String] {
        raw.mapValues { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
    }

    /// Main: mark every account edited since the last snapshot as `saving`, and return those accounts.
    @discardableResult
    private func markSaving() -> Set<String> {
        let now = currentValues()
        let edited = Set(now.filter { lastSnapshot[$0.key] != $0.value }.keys)
        lastSnapshot = now
        for account in edited { saveStates[account] = .saving }
        return edited
    }

    /// Main, when the debounce fires. Nothing edited and nothing failed means nothing to do, so no
    /// subprocess is spawned for a timer that a no-op edit (typing a character and deleting it) armed.
    private func prepareSave() -> DebouncedSaver.Work? {
        guard isInitialized else { return nil }
        let attempted = markSaving()
        let retrying = saveStates.contains { if case .failed = $0.value { return true } else { return false } }
        guard !attempted.isEmpty || retrying else { return nil }
        return makeWork(snapshot: lastSnapshot)
    }

    /// The accounts whose save failed, with the first underlying error.
    struct SaveFailure: Error {
        let errors: [String: String]
        let first: Error
        /// Each failed account's own error (UX91's event and banner reason).
        var perAccount: [String: Error] = [:]
    }

    /// Runs on the saver's queue. Writes or removes each account whose trimmed value differs from what the
    /// Keychain holds; one account failing does not stop the others. Throws `SaveFailure` naming the failed
    /// accounts, or nothing when every difference landed.
    private func makeWork(snapshot: [String: String]) -> DebouncedSaver.Work {
        return { [self] in
            var errors: [String: String] = [:]
            var perAccount: [String: Error] = [:]
            var firstError: Error?
            for account in Self.accounts {
                do {
                    try write(snapshot[account] ?? "", to: account)
                } catch {
                    Log.main.error("SecretsStore: writing \(account) failed: \(String(describing: error))")
                    errors[account] = error.localizedDescription
                    perAccount[account] = error
                    firstError = firstError ?? error
                }
            }
            if let firstError { throw SaveFailure(errors: errors, first: firstError, perAccount: perAccount) }
        }
    }

    /// Main: settle `saving` accounts from the save's outcome.
    private func finishSave(_ result: Result<Void, Error>) {
        var failed: [String: String] = [:]
        if case .failure(let error) = result {
            failed = (error as? SaveFailure)?.errors ?? Dictionary(uniqueKeysWithValues: Self.accounts.map { ($0, error.localizedDescription) })
        }
        var settledSaved: [String] = []
        for account in Self.accounts {
            if let message = failed[account] {
                saveStates[account] = .failed(message)
            } else if let state = saveStates[account], state != .saved {
                saveStates[account] = .saved
                settledSaved.append(account)
            }
        }
        if failed.isEmpty { didPersist.send() }
        // OBS5: which account landed and whether it now holds a value. Never the value.
        for account in settledSaved {
            Log.event(category: "daemon", action: "secret_saved", attributes: [
                "account": account,
                "set": !(lastSnapshot[account] ?? "").isEmpty,
            ])
        }
        noteSaveOutcome(failed: failed, error: result)
        if !settledSaved.isEmpty {
            DispatchQueue.main.asyncAfter(deadline: .now() + 2.5) { [weak self] in
                for account in settledSaved where self?.saveStates[account] == .saved { self?.saveStates[account] = nil }
            }
        }
    }

    /// UX91: publish the failure for the banner and the menu, and record one event per
    /// failed account (its name, `security`'s exit status, the error's domain and code).
    private func noteSaveOutcome(failed: [String: String], error result: Result<Void, Error>) {
        guard !failed.isEmpty, case .failure(let error) = result else {
            let stillFailed = saveStates.values.contains { if case .failed = $0 { return true } else { return false } }
            if !stillFailed { saveError = nil }
            return
        }
        let perAccount = (error as? SaveFailure)?.perAccount ?? [:]
        let accounts = failed.keys.sorted()
        let more = accounts.count > 1 ? " and \(accounts.count - 1) more" : ""
        let first = perAccount[accounts[0]] ?? error
        let reason: String
        if case KeychainBackend.KeychainError.unquotable? = first as? KeychainBackend.KeychainError {
            // Try again cannot fix this one: the token itself has to change.
            reason = "\(accounts[0]) has a character the Keychain cannot store, so paste it again\(more)"
        } else {
            reason = "the Keychain refused to store \(accounts[0])\(more)"
        }
        saveError = SettingSaveFailure(store: .keychain, reason: reason, at: Date())
        for account in accounts {
            let own = perAccount[account] ?? error
            let ns = own as NSError
            var attributes: [String: Any] = ["account": account, "domain": ns.domain, "code": ns.code]
            let securityStatus = (own as? KeychainBackend.KeychainError)?.status
            if let securityStatus { attributes["status"] = Int(securityStatus) }
            let status = securityStatus.map { " (security status \($0))" } ?? ""
            SettingSaveFailure.record(
                .keychain,
                attributes: attributes,
                line: "Keychain save of \(account) failed\(status); the field shows the new value but it is not in effect"
            )
        }
    }

    private func write(_ trimmed: String, to account: String) throws {
        snapshotLock.lock()
        let known = persisted[account]
        snapshotLock.unlock()
        if trimmed.isEmpty {
            // Nothing stored, or unknown (the read failed): nothing to remove.
            guard let known, !known.isEmpty else { return }
            try backend.remove(account)
        } else {
            guard trimmed != known else { return }
            try backend.set(trimmed, for: account)
        }
        snapshotLock.lock()
        persisted[account] = trimmed
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
