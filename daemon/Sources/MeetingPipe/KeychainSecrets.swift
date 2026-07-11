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

/// Reads, writes, and removes a small set of named secrets. Injected into `SecretsStore` and the migration
/// helper so unit tests drive an in-memory fake instead of the real login Keychain.
protocol SecretsBackend {
    func value(for account: String) -> String?
    func set(_ value: String, for account: String) throws
    func remove(_ account: String)
}

/// Production `SecretsBackend`: the macOS login Keychain via `/usr/bin/security`.
struct KeychainBackend: SecretsBackend {
    let service: String

    init(service: String = KeychainSecrets.service) {
        self.service = service
    }

    func value(for account: String) -> String? {
        guard let result = Self.run(["find-generic-password", "-s", service, "-a", account, "-w"]),
              result.status == 0 else {
            return nil
        }
        let value = result.stdout.trimmingCharacters(in: .newlines)
        return value.isEmpty ? nil : value
    }

    func set(_ value: String, for account: String) throws {
        // `-U` updates the item in place when it already exists. The secret rides the argv here, so it is
        // briefly visible in `ps`; `security` offers no non-interactive stdin form. Acceptable on a
        // single-user Mac and strictly better than a persistent world-readable file.
        let result = Self.run(["add-generic-password", "-U", "-s", service, "-a", account, "-w", value])
        guard result?.status == 0 else {
            throw KeychainError.commandFailed(result?.stderr.trimmingCharacters(in: .newlines) ?? "security not runnable")
        }
    }

    func remove(_ account: String) {
        _ = Self.run(["delete-generic-password", "-s", service, "-a", account])
    }

    enum KeychainError: Error, LocalizedError {
        case commandFailed(String)
        var errorDescription: String? {
            switch self {
            case .commandFailed(let message): return "Keychain write failed: \(message)"
            }
        }
    }

    private static func run(_ args: [String]) -> (status: Int32, stdout: String, stderr: String)? {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/security")
        process.arguments = args
        let out = Pipe()
        let err = Pipe()
        process.standardOutput = out
        process.standardError = err
        do {
            try process.run()
        } catch {
            return nil
        }
        // The output is a single token, well under the pipe buffer, so drain-after-exit cannot deadlock.
        process.waitUntilExit()
        let stdout = String(data: out.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""
        let stderr = String(data: err.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""
        return (process.terminationStatus, stdout, stderr)
    }
}
