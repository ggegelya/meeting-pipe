import Foundation

/// One `launchctl` invocation's outcome. `output` merges stdout and stderr: the
/// one thing we parse (`print-disabled`) writes to stdout, the one thing we
/// surface (a failure reason) writes to stderr, and no caller wants them apart.
struct LaunchctlResult: Equatable {
    let status: Int32
    let output: String

    var ok: Bool { status == 0 }
}

/// The seam UX42 put in front of `/bin/launchctl`, so the launch-at-login state
/// machine is unit-testable without mutating the developer's own login item.
/// `LaunchAtLoginServiceTests` drives the whole thing through a fake.
protocol LaunchctlRunning {
    func run(_ arguments: [String]) -> LaunchctlResult
}

/// What launchd will actually do at the next login.
enum LaunchAtLoginState: Equatable {
    /// The agent is installed and carries no disabled override, so `RunAtLoad` fires.
    case enabled
    /// The agent is installed but disabled in launchd's overrides database.
    case disabled
    /// No plist under `~/Library/LaunchAgents/`, so nothing starts the app at login.
    case notInstalled
}

/// A state read, plus a user-visible reason when launchctl refused. The error is
/// rendered in the Preferences footer rather than swallowed to the log, because a
/// silent failure here is how the toggle came to lie in the first place.
struct LaunchAtLoginStatus: Equatable {
    let state: LaunchAtLoginState
    let error: String?

    var isOn: Bool { state == .enabled }
}

/// Launch at login, owned by the one mechanism that actually starts the app: the
/// `com.meetingpipe.daemon` LaunchAgent that `scripts/install.sh` writes.
///
/// UX42 rewrote this. It used to wrap `SMAppService.mainApp`, which was honest
/// about SMAppService and blind to launchd: the LaunchAgent carries
/// `RunAtLoad=true`, so the app started at login whatever the toggle said, and
/// turning the toggle off unregistered a login item that had never launched
/// anything. Two mechanisms, never introduced. Now there is one.
///
/// Two things are deliberate:
///
/// - **Off is `disable`, never `bootout`.** The agent owns the running process,
///   so booting it out kills the app under the user's pointer. `disable` writes
///   launchd's per-user overrides database, which stops the *next* login-start
///   and leaves this instance alone.
/// - **The plist's `RunAtLoad` is never rewritten.** It stays `true` and the
///   overrides database is the single owner of on/off. A `RunAtLoad=false` belt
///   would be the weaker of the two anyway (`install.sh` regenerates the plist
///   from `scripts/launchd.plist.template` on every run, while the overrides
///   database survives that), it only takes effect after a bootout+bootstrap,
///   which is exactly the app-killing move the previous point rules out, and it
///   would break `rebuild.sh`, whose bootstrap relies on `RunAtLoad` to bring
///   the daemon back. One writer, one reader.
///
/// The cost of dropping SMAppService, recorded rather than lost: MeetingPipe no
/// longer appears under System Settings ▸ General ▸ Login Items, so there is no
/// system-level surface for this switch. That is worth revisiting in a notarized,
/// Developer-ID world (D8), where SMAppService could own login-start and the
/// agent could shrink to supervision alone. It is not worth two mechanisms today.
struct LaunchAtLoginService {
    /// Also the app's bundle id. A known sharp edge, carried rather than fixed
    /// (UX42 scope): `launchctl print` output and System Settings ▸ Login Items
    /// entries read ambiguously because of it. Renaming either is a migration.
    static let label = "com.meetingpipe.daemon"

    static var defaultPlistPath: String {
        FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/LaunchAgents/\(LaunchAtLoginService.label).plist").path
    }

    private let runner: LaunchctlRunning
    private let uid: uid_t
    private let plistPath: String
    private let plistExists: (String) -> Bool

    init(
        runner: LaunchctlRunning = ProcessLaunchctl(),
        uid: uid_t = getuid(),
        plistPath: String = LaunchAtLoginService.defaultPlistPath,
        plistExists: @escaping (String) -> Bool = { FileManager.default.fileExists(atPath: $0) }
    ) {
        self.runner = runner
        self.uid = uid
        self.plistPath = plistPath
        self.plistExists = plistExists
    }

    private var domain: String { "gui/\(uid)" }
    private var target: String { "\(domain)/\(LaunchAtLoginService.label)" }

    /// Read the truth from launchd, not from a preference we hope matches it.
    func status() -> LaunchAtLoginStatus {
        guard plistExists(plistPath) else {
            return LaunchAtLoginStatus(state: .notInstalled, error: nil)
        }
        let result = runner.run(["print-disabled", domain])
        guard result.ok else {
            // Can't read the override, so report the plist's own intent
            // (`RunAtLoad=true`) and say plainly that it may not be the truth.
            // Reporting a confident value we did not read is the original bug.
            return LaunchAtLoginStatus(
                state: .enabled,
                error: Self.failure("read whether MeetingPipe starts at login", result)
                    + " The switch shows the launch agent's own setting, which may not match."
            )
        }
        let overridden = Self.parseDisabled(result.output, label: LaunchAtLoginService.label)
        return LaunchAtLoginStatus(state: overridden == true ? .disabled : .enabled, error: nil)
    }

    /// Turn login-start on or off, then report what launchd is left holding.
    @discardableResult
    func set(enabled: Bool) -> LaunchAtLoginStatus {
        guard plistExists(plistPath) else {
            return LaunchAtLoginStatus(
                state: .notInstalled,
                error: "The MeetingPipe launch agent is not installed, so nothing can start it at login. Run scripts/install.sh."
            )
        }
        return enabled ? turnOn() : turnOff()
    }

    private func turnOn() -> LaunchAtLoginStatus {
        let cleared = runner.run(["enable", target])
        guard cleared.ok else {
            return reread(after: Self.failure("turn launch at login on", cleared))
        }
        // `enable` only clears the override. A plist that was never loaded, or
        // that was booted out (an uninstall, a rebuild that died mid-flight),
        // still needs bootstrapping before `RunAtLoad` can fire at all. Order
        // matters: bootstrapping a still-disabled service fails.
        if !runner.run(["print", target]).ok {
            let loaded = runner.run(["bootstrap", domain, plistPath])
            guard loaded.ok else {
                return LaunchAtLoginStatus(
                    state: .enabled,
                    error: Self.failure("load the MeetingPipe launch agent", loaded)
                )
            }
        }
        return LaunchAtLoginStatus(state: .enabled, error: nil)
    }

    private func turnOff() -> LaunchAtLoginStatus {
        let result = runner.run(["disable", target])
        guard result.ok else {
            return reread(after: Self.failure("turn launch at login off", result))
        }
        return LaunchAtLoginStatus(state: .disabled, error: nil)
    }

    /// After a refused write, report what launchd is actually holding rather than
    /// what the user asked for, with our own message on top.
    private func reread(after message: String) -> LaunchAtLoginStatus {
        LaunchAtLoginStatus(state: status().state, error: message)
    }

    /// Parse `launchctl print-disabled gui/<uid>` for one label. Its lines read
    /// `\t\t"com.meetingpipe.daemon" => disabled` inside a `disabled services = {}`
    /// block. Returns nil when the label carries no override line at all, which
    /// launchd reads as "not disabled" rather than as an error.
    static func parseDisabled(_ output: String, label: String) -> Bool? {
        for raw in output.split(separator: "\n") {
            let line = raw.trimmingCharacters(in: .whitespaces)
            // The closing quote is load-bearing: without it a sibling label that
            // merely starts with ours (`com.meetingpipe.daemon.helper`) matches.
            guard line.hasPrefix("\"\(label)\"") else { continue }
            guard let arrow = line.range(of: "=>") else { continue }
            return line[arrow.upperBound...].trimmingCharacters(in: .whitespaces) == "disabled"
        }
        return nil
    }

    private static func failure(_ what: String, _ result: LaunchctlResult) -> String {
        let detail = result.output.trimmingCharacters(in: .whitespacesAndNewlines)
        let tail = detail.isEmpty ? "" : " \(detail)"
        return "Could not \(what): launchctl exited \(result.status).\(tail)"
    }
}

/// The real runner. Reads the pipe to EOF before waiting, so a chatty
/// `print-disabled` (every login item on the machine) cannot fill the buffer and
/// deadlock the wait.
struct ProcessLaunchctl: LaunchctlRunning {
    func run(_ arguments: [String]) -> LaunchctlResult {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/launchctl")
        process.arguments = arguments
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = pipe
        do {
            try process.run()
            let data = pipe.fileHandleForReading.readDataToEndOfFile()
            process.waitUntilExit()
            return LaunchctlResult(
                status: process.terminationStatus,
                output: String(data: data, encoding: .utf8) ?? ""
            )
        } catch {
            Log.main.error("launchctl \(arguments.first ?? "") could not spawn: \(String(describing: error))")
            return LaunchctlResult(status: -1, output: String(describing: error))
        }
    }
}
