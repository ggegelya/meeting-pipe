import Foundation

/// AI4-FINISH: the per-user LaunchAgent that runs `mp digest` on a weekly schedule.
///
/// The plist body and the `launchctl` dance live in `LaunchAgentScheduler` (STOR4
/// lifted them out when the backup agent became a second caller). What stays here
/// is what is specific to the digest: its label, its `mp` subcommand, and its
/// events. Distinct label from the daemon agent so the two never collide.
enum DigestSchedulerService {
    static let label = "com.meetingpipe.digest"

    static var plistURL: URL { LaunchAgentScheduler.plistURL(label: label) }

    static var isInstalled: Bool { LaunchAgentScheduler.isInstalled(label: label) }

    /// Install (enabled) or remove (disabled) the weekly digest agent. `weekday` is
    /// 1=Monday … 7=Sunday (ISO 8601); `hour` 0–23, `minute` 0–59.
    static func apply(enabled: Bool, weekday: Int, hour: Int, minute: Int) {
        guard enabled else {
            LaunchAgentScheduler.remove(label: label)
            Log.event(category: "coordinator", action: "digest_schedule_removed", attributes: [:])
            return
        }
        let installed = LaunchAgentScheduler.install(
            label: label,
            arguments: ["digest"],
            schedule: .init(weekday: weekday, hour: hour, minute: minute),
            logBasename: "digest"
        )
        guard installed else { return }
        Log.event(category: "coordinator", action: "digest_schedule_installed", attributes: [
            "weekday": weekday, "hour": hour, "minute": minute,
        ])
    }
}
