import Foundation

/// AI4-FINISH: the per-user LaunchAgent that runs `mp digest` on a weekly schedule.
///
/// The daemon's own LaunchAgent (`com.meetingpipe.daemon`) is installed by
/// `scripts/install.sh`; there is no Swift helper for a *scheduled* agent, so this writes
/// `~/Library/LaunchAgents/com.meetingpipe.digest.plist` with a `StartCalendarInterval`
/// and bootstraps it. The installed plist is the source of truth for *when* the digest
/// fires; `UISettings` remembers the values so the Preferences controls re-render and a
/// toggle can rewrite it. Distinct label from the daemon agent so the two never collide.
enum DigestSchedulerService {
    static let label = "com.meetingpipe.digest"

    static var plistURL: URL {
        FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/LaunchAgents/\(label).plist")
    }

    static var isInstalled: Bool {
        FileManager.default.fileExists(atPath: plistURL.path)
    }

    /// Install (enabled) or remove (disabled) the weekly digest agent. `weekday` is
    /// 1=Monday … 7=Sunday (ISO 8601); `hour` 0–23, `minute` 0–59.
    static func apply(enabled: Bool, weekday: Int, hour: Int, minute: Int) {
        if enabled {
            install(weekday: weekday, hour: hour, minute: minute)
        } else {
            remove()
        }
    }

    /// The plist body. Pure, so the schedule mapping is unit-tested without touching disk
    /// or launchctl.
    static func plistDictionary(
        program: [String], weekday: Int, hour: Int, minute: Int, logDir: String
    ) -> [String: Any] {
        // launchd Weekday: 0 (and 7) = Sunday, 1 = Monday … 6 = Saturday. Our 7 (Sunday) -> 0.
        let launchdWeekday = weekday == 7 ? 0 : weekday
        return [
            "Label": label,
            "ProgramArguments": program,
            // A scheduled one-shot: no RunAtLoad / KeepAlive (those keep the resident
            // daemon alive; the digest agent should fire once at the interval and exit).
            "StartCalendarInterval": [
                "Weekday": launchdWeekday,
                "Hour": max(0, min(23, hour)),
                "Minute": max(0, min(59, minute)),
            ],
            "StandardOutPath": "\(logDir)/digest.out.log",
            "StandardErrorPath": "\(logDir)/digest.err.log",
            "EnvironmentVariables": [
                "PATH": "/opt/homebrew/bin:/usr/local/bin:/usr/bin:/bin",
            ],
        ]
    }

    private static func install(weekday: Int, hour: Int, minute: Int) {
        guard let mp = PipelineLauncher.findMP() else {
            Log.main.error("DigestScheduler: mp not found; cannot install the digest agent")
            return
        }
        let logDir = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Logs/MeetingPipe").path
        let program = [mp.shell] + mp.args + ["digest"]
        let dict = plistDictionary(
            program: program, weekday: weekday, hour: hour, minute: minute, logDir: logDir
        )
        let url = plistURL
        do {
            try FileManager.default.createDirectory(
                at: url.deletingLastPathComponent(), withIntermediateDirectories: true
            )
            let data = try PropertyListSerialization.data(fromPropertyList: dict, format: .xml, options: 0)
            try data.write(to: url, options: .atomic)
        } catch {
            Log.main.error("DigestScheduler: could not write \(url.path): \(String(describing: error))")
            return
        }
        // Re-bootstrap so a schedule change takes effect: bootout the old (may be absent),
        // then bootstrap the freshly written plist.
        bootout()
        launchctl(["bootstrap", "gui/\(getuid())", url.path])
        Log.event(category: "coordinator", action: "digest_schedule_installed", attributes: [
            "weekday": weekday, "hour": hour, "minute": minute,
        ])
    }

    private static func remove() {
        bootout()
        try? FileManager.default.removeItem(at: plistURL)
        Log.event(category: "coordinator", action: "digest_schedule_removed", attributes: [:])
    }

    private static func bootout() {
        // The agent may not be loaded, so ignore a non-zero exit.
        launchctl(["bootout", "gui/\(getuid())", plistURL.path])
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
            Log.main.error("DigestScheduler: launchctl \(args.first ?? "") failed: \(String(describing: error))")
            return false
        }
    }
}
