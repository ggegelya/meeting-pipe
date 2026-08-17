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
/// `Sendable` because UX67 moved the calls off the main thread: the service is
/// handed to a detached task, so everything it holds crosses a concurrency
/// boundary. `ProcessLaunchctl` is stateless and gets it for free; a fake with
/// state owes a lock rather than an `@unchecked` (`daemon/CLAUDE.md`).
protocol LaunchctlRunning: Sendable {
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

/// A write that did not move the switch, reduced to what is worth logging (UX67).
///
/// The control renders whatever launchd is left holding rather than what was
/// asked for, which is UX42's design and correct. Its cost is that a `launchctl`
/// refusing every write is indistinguishable, at the control, from a dead toggle:
/// the switch snaps back either way, and the only difference is a message in the
/// group footer that nobody is looking for. So the refusal is recorded too, and
/// the next occurrence is a log line rather than another walkthrough report.
///
/// Pure and separate from the emit so the decision is testable without reading a
/// log file back.
struct LaunchAtLoginRefusal: Equatable {
    let requested: Bool
    let resulting: LaunchAtLoginState
    /// The service's own message, which already carries the `launchctl` exit
    /// status and the tail of its stderr.
    let reason: String

    /// Nil when the write landed, which is the overwhelmingly common case and
    /// must stay silent: a log line per successful toggle is noise that makes the
    /// interesting one harder to find.
    static func decide(requested: Bool, status: LaunchAtLoginStatus) -> LaunchAtLoginRefusal? {
        guard status.isOn != requested else { return nil }
        return LaunchAtLoginRefusal(
            requested: requested,
            resulting: status.state,
            // A refusal with no message is the sharper case, not a reason to stay
            // quiet: it means the write "succeeded" and the state still did not
            // move, which no footer would have shown either.
            reason: status.error ?? "launchctl reported no error"
        )
    }
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
struct LaunchAtLoginService: Sendable {
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
    private let plistExists: @Sendable (String) -> Bool

    init(
        runner: LaunchctlRunning = ProcessLaunchctl(),
        uid: uid_t = getuid(),
        plistPath: String = LaunchAtLoginService.defaultPlistPath,
        plistExists: @escaping @Sendable (String) -> Bool = { FileManager.default.fileExists(atPath: $0) }
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
///
/// **Every call is bounded (UX67).** `readDataToEndOfFile` returns when the pipe
/// closes, which is when the child dies, so a `launchctl` that never exits blocks
/// this call forever. That is the same freeze class as a stuck `stopCapture` or a
/// wedged AX round-trip, and here it sat behind a Preferences toggle: a
/// `rebuild.sh` boots the `com.meetingpipe.daemon` label out and back in while the
/// pane is open, which is exactly when `bootstrap` and `print` on that domain
/// block. The watchdog kills the child at the ceiling, which unblocks the read and
/// the wait together and leaves a non-zero status the callers already know how to
/// report. `LaunchAtLoginModel` also keeps these calls off the main thread; this
/// bound is the second half, so a caller that forgets still cannot hang forever.
struct ProcessLaunchctl: LaunchctlRunning {
    /// Generous against a slow `print-disabled` on a machine with many agents,
    /// and short enough that a wedged call is over before a person gives up on
    /// the control.
    static let ceilingSeconds: Double = 5

    func run(_ arguments: [String]) -> LaunchctlResult {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/launchctl")
        process.arguments = arguments
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = pipe
        do {
            try process.run()
            let watchdog = DispatchWorkItem {
                guard process.isRunning else { return }
                Log.main.error("launchctl \(arguments.first ?? "") exceeded its ceiling; terminating")
                process.terminate()
            }
            DispatchQueue.global(qos: .userInitiated)
                .asyncAfter(deadline: .now() + ProcessLaunchctl.ceilingSeconds, execute: watchdog)
            let data = pipe.fileHandleForReading.readDataToEndOfFile()
            process.waitUntilExit()
            watchdog.cancel()
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
