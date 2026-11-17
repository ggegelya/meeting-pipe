import Foundation

/// The API tokens live in the macOS login Keychain, not a plaintext `secrets.env` (SEC8, subsumes SEC1).
///
/// All three trees read and write the same generic-password items through the stable `/usr/bin/security`
/// CLI: this daemon, the Python pipeline (`mp.config.load_secrets`), and `scripts/install.sh`. Because the
/// process that actually touches the Keychain is always `/usr/bin/security` (the same binary that created the
/// item), the item's ACL trusts a single stable accessor, so there is no per-access prompt and no per-rebuild
/// cdhash churn (the daemon's ad-hoc / dev-cert identity is never the ACL subject). The service + account
/// naming below is the cross-language contract; keep it in sync with the Python and bash sides.
enum KeychainSecrets {
    /// Keychain generic-password service, matching the bundle id / codesign identifier.
    static let service = "com.meetingpipe.daemon"
    /// The token env-var names this layer manages. `HF_TOKEN` is optional (legacy pyannote opt-in) and only
    /// carried so a migrating `secrets.env` doesn't drop it; the UI edits the two required tokens.
    static let managedKeys = ["ANTHROPIC_API_KEY", "NOTION_TOKEN", "HF_TOKEN", "OPENAI_API_KEY"]
}

/// One read of a secret. `unreadable` is deliberately not `notFound`: a locked Keychain, a denied ACL and
/// a `security` that never ran all look like "no token" to a caller that collapses them, and a caller that
/// then writes or removes on that belief destroys a token that was only temporarily out of reach (SEC23).
enum SecretRead: Equatable {
    case found(String)
    /// `security` status 44, or an item whose value is empty.
    case notFound
    /// Any other outcome. `status` is `security`'s exit code, or -1 when it could not be launched.
    case unreadable(status: Int32, detail: String)
}

/// Reads, writes, and removes a small set of named secrets. Injected into `SecretsStore` and the migration
/// helper so unit tests drive an in-memory fake instead of the real login Keychain.
protocol SecretsBackend {
    func value(for account: String) -> SecretRead
    func set(_ value: String, for account: String) throws
    /// Absent counts as removed. Any other failure throws.
    func remove(_ account: String) throws
}

/// Production `SecretsBackend`: the macOS login Keychain via `/usr/bin/security`.
struct KeychainBackend: SecretsBackend {
    /// What one `security` run produced. `nil` from a runner means it could not be launched.
    typealias Output = (status: Int32, stdout: String, stderr: String)
    typealias Runner = (_ args: [String], _ stdin: Data?) -> Output?

    let service: String
    private let runner: Runner

    init(service: String = KeychainSecrets.service, runner: @escaping Runner = KeychainBackend.run) {
        self.service = service
        self.runner = runner
    }

    func value(for account: String) -> SecretRead {
        guard let result = runner(["find-generic-password", "-s", service, "-a", account, "-w"], nil) else {
            return .unreadable(status: -1, detail: "security not runnable")
        }
        switch result.status {
        case 0:
            let value = result.stdout.trimmingCharacters(in: .newlines)
            return value.isEmpty ? .notFound : .found(value)
        case Self.itemNotFound:
            return .notFound
        default:
            return .unreadable(status: result.status, detail: result.stderr.trimmingCharacters(in: .whitespacesAndNewlines))
        }
    }

    func set(_ value: String, for account: String) throws {
        // The value travels on stdin to `security -i`, so `ps` shows only `security -i` (SEC23). `-w <value>`
        // on the argv would show every token to any same-user `ps` for the length of the call.
        guard let command = Self.addCommand(service: service, account: account, value: value) else {
            throw KeychainError.unquotable
        }
        let result = runner(["-i"], Data((command + "\n").utf8))
        guard result?.status == 0 else {
            throw KeychainError.commandFailed(
                result?.stderr.trimmingCharacters(in: .whitespacesAndNewlines) ?? "security not runnable",
                status: result?.status
            )
        }
    }

    func remove(_ account: String) throws {
        let result = runner(["delete-generic-password", "-s", service, "-a", account], nil)
        guard let result else { throw KeychainError.commandFailed("security not runnable") }
        guard result.status == 0 || result.status == Self.itemNotFound else {
            throw KeychainError.commandFailed(result.stderr.trimmingCharacters(in: .whitespacesAndNewlines), status: result.status)
        }
    }

    /// `security`'s exit status for `errSecItemNotFound`.
    static let itemNotFound: Int32 = 44

    /// The one `add-generic-password` line `security -i` reads. Inside double quotes `security -i` honours a
    /// backslash escape and expands nothing, so only `\` and `"` are escaped. A newline would end the command
    /// early and a control or non-ASCII byte is untested, so those are refused (nil) rather than guessed at;
    /// API tokens are printable ASCII.
    static func addCommand(service: String, account: String, value: String) -> String? {
        func quoted(_ text: String) -> String? {
            guard !text.isEmpty, text.unicodeScalars.allSatisfy({ $0.value >= 0x20 && $0.value < 0x7f }) else { return nil }
            return "\"" + text.replacingOccurrences(of: "\\", with: "\\\\").replacingOccurrences(of: "\"", with: "\\\"") + "\""
        }
        guard let s = quoted(service), let a = quoted(account), let v = quoted(value) else { return nil }
        return "add-generic-password -U -s \(s) -a \(a) -w \(v)"
    }

    enum KeychainError: Error, LocalizedError {
        /// `security`'s stderr, and its exit status when it ran (UX91 logs the status, never the text).
        case commandFailed(String, status: Int32? = nil)
        case unquotable
        var status: Int32? {
            if case .commandFailed(_, let status) = self { return status }
            return nil
        }
        var errorDescription: String? {
            switch self {
            case .commandFailed(let message, _): return "Keychain write failed: \(message)"
            case .unquotable: return "That token contains a character that cannot be stored (only printable ASCII is accepted). Check it was pasted whole."
            }
        }
    }

    /// Matches the Python reader's `timeout=10`.
    static let timeoutSeconds: TimeInterval = 10

    static func run(_ args: [String], stdin: Data?) -> Output? {
        run(executable: "/usr/bin/security", args: args, stdin: stdin, timeout: timeoutSeconds)
    }

    /// `run` with the executable and ceiling injectable, so a test can drive the stdin, timeout and
    /// early-exit paths with `cat`, `sleep` and `true` instead of the real `security`.
    static func run(executable: String, args: [String], stdin: Data?, timeout: TimeInterval) -> Output? {
        // CONC5: `ProcessRunner` drains both pipes while the child runs and kills a hung one (SIGTERM, then
        // SIGKILL after `killGrace`), where this used to abandon it after a SIGTERM that a wedged
        // `security` can ignore. A locked Keychain with no one to answer its dialog would otherwise park the
        // caller (main, for a Preferences save or launch) forever. Past the ceiling the run reads as
        // "could not run", never as "absent" (SEC23's `unreadable`).
        let result = ProcessRunner.run(executable: executable, arguments: args, stdin: stdin,
                                       timeout: timeout, grace: killGrace)
        guard result.launchFailure == nil, !result.timedOut, result.reaped else { return nil }
        return (result.status, result.stdoutText, result.stderrText)
    }

    /// How long a SIGTERMed `security` gets before SIGKILL. Short: this runs on main at launch and on a save.
    static let killGrace: TimeInterval = 2
}
