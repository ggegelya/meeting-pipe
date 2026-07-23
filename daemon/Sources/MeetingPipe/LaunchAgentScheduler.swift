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

    static func plistURL(label: String) -> URL {
        FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/LaunchAgents/\(label).plist")
    }

    static func isInstalled(label: String) -> Bool {
        FileManager.default.fileExists(atPath: plistURL(label: label).path)
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
            ],
        ]
    }

    /// Where a scheduled agent's stdout/stderr land, beside the daemon's own logs.
    static var logDir: String {
        FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Logs/MeetingPipe").path
    }

    /// Write and bootstrap the agent. `arguments` are appended to the resolved `mp`
    /// invocation, so a caller passes `["digest"]` / `["backup", dir]`, never a path.
    /// Returns false when `mp` could not be resolved or the plist could not be written.
    @discardableResult
    static func install(
        label: String, arguments: [String], schedule: Schedule, logBasename: String
    ) -> Bool {
        guard let mp = PipelineLauncher.findMP() else {
            Log.main.error("LaunchAgentScheduler: mp not found; cannot install \(label)")
            return false
        }
        let dict = plistDictionary(
            label: label,
            program: [mp.shell] + mp.args + arguments,
            schedule: schedule,
            logBasename: logBasename,
            logDir: logDir
        )
        let url = plistURL(label: label)
        do {
            try FileManager.default.createDirectory(
                at: url.deletingLastPathComponent(), withIntermediateDirectories: true
            )
            let data = try PropertyListSerialization.data(fromPropertyList: dict, format: .xml, options: 0)
            try data.write(to: url, options: .atomic)
        } catch {
            Log.main.error("LaunchAgentScheduler: could not write \(url.path): \(String(describing: error))")
            return false
        }
        // Re-bootstrap so a schedule change takes effect: bootout the old (may be absent),
        // then bootstrap the freshly written plist.
        bootout(label: label)
        launchctl(["bootstrap", "gui/\(getuid())", url.path])
        return true
    }

    static func remove(label: String) {
        bootout(label: label)
        try? FileManager.default.removeItem(at: plistURL(label: label))
    }

    private static func bootout(label: String) {
        // The agent may not be loaded, so ignore a non-zero exit.
        launchctl(["bootout", "gui/\(getuid())", plistURL(label: label).path])
    }

    @discardableResult
    private static func launchctl(_ args: [String]) -> Bool {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/bin/launchctl")
        p.arguments = args
        p.standardOutput = FileHandle.nullDevice
        p.standardError = FileHandle.nullDevice
        do {
            try p.run()
            p.waitUntilExit()
            return p.terminationStatus == 0
        } catch {
            Log.main.error("LaunchAgentScheduler: launchctl \(args.first ?? "") failed: \(String(describing: error))")
            return false
        }
    }
}
