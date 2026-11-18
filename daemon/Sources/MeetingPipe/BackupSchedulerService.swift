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
    ///
    /// STOR10: `backup_schedule_installed` is written only once launchd holds the agent; anything
    /// else is `backup_schedule_failed` with the reason's class, and the error comes back so
    /// Preferences can say it beside the toggle. Runs `launchctl`, so call it off main (UX67).
    @discardableResult
    static func apply(
        enabled: Bool, destination: String?, frequency: Frequency,
        weekday: Int, hour: Int, minute: Int,
        env: LaunchAgentScheduler.Environment = .live
    ) -> Result<Void, LaunchAgentScheduler.InstallError> {
        guard enabled, let destination, !destination.isEmpty else {
            LaunchAgentScheduler.remove(label: label, env: env)
            Log.event(category: "coordinator", action: "backup_schedule_removed", attributes: [:])
            return .success(())
        }
        let result = LaunchAgentScheduler.install(
            label: label,
            arguments: ["backup", destination],
            schedule: schedule(frequency: frequency, weekday: weekday, hour: hour, minute: minute),
            logBasename: "backup",
            env: env
        )
        switch result {
        case .success:
            Log.event(category: "coordinator", action: "backup_schedule_installed", attributes: [
                "frequency": frequency.rawValue, "weekday": weekday, "hour": hour, "minute": minute,
            ])
        case .failure(let error):
            Log.failure(category: "coordinator", action: "backup_schedule_failed", error: error, attributes: [
                "reason": error.kind, "frequency": frequency.rawValue,
            ])
        }
        return result
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
