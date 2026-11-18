import Foundation

/// The per-user LaunchAgent mechanism shared by the scheduled `mp` jobs (AI4's
/// weekly digest, STOR4's automatic backup).
///
/// The daemon's own resident agent (`com.meetingpipe.daemon`) is installed by
/// `scripts/install.sh`. These are *scheduled one-shots* instead: a
/// `StartCalendarInterval` plist under `~/Library/LaunchAgents/`, bootstrapped
/// with `launchctl`. The installed plist is the source of truth for when a job
/// fires; `UISettings` remembers the values so the Preferences controls
/// re-render and a toggle can rewrite it.
///
/// STOR4 lifted this out of `DigestSchedulerService` when the backup agent
/// became its second caller, rather than copying the plist writer (the
/// module-private copy in `publish_fs` that PIPE7 deleted is the cautionary
/// precedent). Callers own their label, program, and events; this owns the
/// plist body and the launchctl dance.
enum LaunchAgentScheduler {

    /// When a scheduled job fires. `weekday` nil means every day; otherwise
    /// 1=Monday … 7=Sunday (ISO 8601, mapped to launchd's numbering on write).
    struct Schedule: Equatable {
        let weekday: Int?
        let hour: Int
        let minute: Int
    }

    /// STOR10: what the install and the remove touch, injectable so a test never writes, loads or
    /// removes the owner's real agents. `runner` is UX42's watchdogged `launchctl` seam.
    struct Environment {
        var runner: LaunchctlRunning = ProcessLaunchctl()
        var agentsDir: URL = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/LaunchAgents", isDirectory: true)
        var findMP: () -> PipelineLauncher.MPInvocation? = { PipelineLauncher.findMP() }
        var uid: uid_t = getuid()

        static var live: Environment { Environment() }
    }

    /// STOR10: why a schedule did not take. `launchctl`'s exit status and output are kept, since a
    /// refused bootstrap used to go to `/dev/null` and the toggle read as on.
    enum InstallError: Error, Equatable, LocalizedError {
        case mpNotFound
        case plistWriteFailed(String)
        case bootstrapFailed(status: Int32, output: String)
        case notLoaded(output: String)

        var errorDescription: String? {
            switch self {
            case .mpNotFound:
                return "the mp command could not be found, so nothing can run on the schedule"
            case .plistWriteFailed(let reason):
                return "the schedule file could not be written: \(reason)"
            case .bootstrapFailed(let status, let output):
                return "macOS refused the schedule (launchctl \(status))\(Self.detail(output))"
            case .notLoaded(let output):
                return "macOS accepted the schedule but did not load it\(Self.detail(output))"
            }
        }

        /// The fixed class an event carries; the text above can name a path.
        var kind: String {
            switch self {
            case .mpNotFound: return "mp_not_found"
            case .plistWriteFailed: return "plist_write_failed"
            case .bootstrapFailed: return "bootstrap_failed"
            case .notLoaded: return "not_loaded"
            }
        }

        private static func detail(_ output: String) -> String {
            let line = output.split(whereSeparator: \.isNewline).first.map(String.init) ?? ""
            return line.isEmpty ? "" : ": \(line.prefix(200))"
        }
    }

    static func plistURL(label: String, env: Environment = .live) -> URL {
        env.agentsDir.appendingPathComponent("\(label).plist")
    }

    static func isInstalled(label: String, env: Environment = .live) -> Bool {
        FileManager.default.fileExists(atPath: plistURL(label: label, env: env).path)
    }

    /// The plist body. Pure, so the schedule mapping is unit-tested without
    /// touching disk or launchctl.
    static func plistDictionary(
        label: String, program: [String], schedule: Schedule, logBasename: String, logDir: String
    ) -> [String: Any] {
        var interval: [String: Int] = [
            "Hour": max(0, min(23, schedule.hour)),
            "Minute": max(0, min(59, schedule.minute)),
        ]
        // launchd Weekday: 0 (and 7) = Sunday, 1 = Monday … 6 = Saturday. Our 7 (Sunday) -> 0.
        // Omitting the key entirely is how launchd expresses "every day".
        if let weekday = schedule.weekday {
            interval["Weekday"] = weekday == 7 ? 0 : weekday
        }
        return [
            "Label": label,
            "ProgramArguments": program,
            // A scheduled one-shot: no RunAtLoad / KeepAlive (those keep the resident
            // daemon alive; these agents should fire once at the interval and exit).
            "StartCalendarInterval": interval,
            "StandardOutPath": "\(logDir)/\(logBasename).out.log",
            "StandardErrorPath": "\(logDir)/\(logBasename).err.log",
            "EnvironmentVariables": [
                "PATH": "/opt/homebrew/bin:/usr/local/bin:/usr/bin:/bin",
                // STOR10: `mp` stamps its attempt marker and events `trigger: scheduled`.
                "MP_TRIGGER": "scheduled",
            ],
        ]
    }

    /// Where a scheduled agent's stdout/stderr land, beside the daemon's own logs.
    static var logDir: String {
        FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Logs/MeetingPipe").path
    }

    /// Write and bootstrap the agent, then confirm launchd holds it. `arguments` are appended to the
    /// resolved `mp` invocation, so a caller passes `["digest"]` / `["backup", dir]`, never a path.
    ///
    /// STOR10: success is `launchctl print` finding the agent, not bootstrap's exit status: the
    /// bootout before it can exit non-zero harmlessly, and a bootstrap that exits zero for a plist
    /// launchd then drops would read as on. Off main: every call is a `launchctl` round trip (UX67).
    static func install(
        label: String, arguments: [String], schedule: Schedule, logBasename: String,
        env: Environment = .live
    ) -> Result<Void, InstallError> {
        guard let mp = env.findMP() else { return .failure(.mpNotFound) }
        let dict = plistDictionary(
            label: label,
            program: [mp.shell] + mp.args + arguments,
            schedule: schedule,
            logBasename: logBasename,
            logDir: logDir
        )
        let url = plistURL(label: label, env: env)
        do {
            try FileManager.default.createDirectory(
                at: url.deletingLastPathComponent(), withIntermediateDirectories: true
            )
            let data = try PropertyListSerialization.data(fromPropertyList: dict, format: .xml, options: 0)
            try data.write(to: url, options: .atomic)
        } catch {
            return .failure(.plistWriteFailed(error.localizedDescription))
        }
        // Re-bootstrap so a schedule change takes effect: bootout the old (may be absent, so its
        // status is ignored), then bootstrap the freshly written plist.
        _ = env.runner.run(["bootout", "gui/\(env.uid)", url.path])
        let bootstrap = env.runner.run(["bootstrap", "gui/\(env.uid)", url.path])
        let loaded = env.runner.run(["print", "gui/\(env.uid)/\(label)"])
        if loaded.ok { return .success(()) }
        if !bootstrap.ok { return .failure(.bootstrapFailed(status: bootstrap.status, output: bootstrap.output)) }
        return .failure(.notLoaded(output: loaded.output))
    }

    static func remove(label: String, env: Environment = .live) {
        let url = plistURL(label: label, env: env)
        _ = env.runner.run(["bootout", "gui/\(env.uid)", url.path])
        try? FileManager.default.removeItem(at: url)
    }
}
