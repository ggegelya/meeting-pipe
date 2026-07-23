import Foundation

/// STOR4: the per-user LaunchAgent that runs `mp backup <dir>` unattended.
///
/// The corpus is irreplaceable, and until this the only backups were the ones the
/// owner remembered to take (Preferences ▸ Storage ▸ "Back up now", or the CLI);
/// doctor merely reported how stale that was. Same mechanism as the digest agent
/// (`LaunchAgentScheduler`), one behavioural difference: a backup defaults to
/// **daily**, because a weekly cadence means up to seven days of new meetings are
/// only ever on one disk.
///
/// The destination is baked into the plist's `ProgramArguments`, so changing it in
/// Preferences has to rewrite the agent, not just the remembered path.
enum BackupSchedulerService {
    static let label = "com.meetingpipe.backup"

    /// How often the scheduled backup runs. Raw values are the persisted
    /// `UISettings` strings.
    enum Frequency: String, CaseIterable {
        case daily
        case weekly
    }

    static var plistURL: URL { LaunchAgentScheduler.plistURL(label: label) }

    static var isInstalled: Bool { LaunchAgentScheduler.isInstalled(label: label) }

    /// Install (enabled, with a destination) or remove the backup agent. A nil
    /// `destination` removes it however the toggle is set: an agent whose
    /// `ProgramArguments` have no directory would fail every night into a log
    /// nobody reads, which is worse than no schedule at all.
    static func apply(
        enabled: Bool, destination: String?, frequency: Frequency,
        weekday: Int, hour: Int, minute: Int
    ) {
        guard enabled, let destination, !destination.isEmpty else {
            LaunchAgentScheduler.remove(label: label)
            Log.event(category: "coordinator", action: "backup_schedule_removed", attributes: [:])
            return
        }
        let installed = LaunchAgentScheduler.install(
            label: label,
            arguments: ["backup", destination],
            schedule: schedule(frequency: frequency, weekday: weekday, hour: hour, minute: minute),
            logBasename: "backup"
        )
        guard installed else { return }
        Log.event(category: "coordinator", action: "backup_schedule_installed", attributes: [
            "frequency": frequency.rawValue, "weekday": weekday, "hour": hour, "minute": minute,
        ])
    }

    /// Daily drops the weekday entirely (launchd reads a missing `Weekday` as
    /// "every day"); weekly pins it. Pure, so both shapes are unit-tested.
    static func schedule(
        frequency: Frequency, weekday: Int, hour: Int, minute: Int
    ) -> LaunchAgentScheduler.Schedule {
        LaunchAgentScheduler.Schedule(
            weekday: frequency == .weekly ? weekday : nil, hour: hour, minute: minute
        )
    }
}
