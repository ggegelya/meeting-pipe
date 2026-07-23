import AppKit
import Combine
import Foundation

/// UI-only preferences persisted via `UserDefaults`. Cosmetic/presentation flags that the pipeline never reads - kept out of `config.toml` so that file stays small and pipeline-parseable. SwiftUI views use `@ObservedObject`; AppKit consumers subscribe to `@Published` streams via Combine.
final class UISettings: ObservableObject {
    static let shared = UISettings()

    enum Theme: String, CaseIterable {
        case system, light, dark
    }

    /// `outline` (default): thin ring + waveform bars. `filled`: no ring, thicker bars for a heavier look on a busy menu bar.
    enum MenuBarIconStyle: String, CaseIterable {
        case outline, filled
    }

    @Published var theme: Theme {
        didSet {
            UserDefaults.standard.set(theme.rawValue, forKey: Keys.theme)
            applyTheme()
        }
    }

    @Published var menuBarIconStyle: MenuBarIconStyle {
        didSet { UserDefaults.standard.set(menuBarIconStyle.rawValue, forKey: Keys.menuBarIconStyle) }
    }

    /// Show a lock glyph in the status-bar title when regulated mode is on. Cosmetic only; defaults to `true` so existing users see the badge immediately.
    @Published var showRegulatedBadge: Bool {
        didSet { UserDefaults.standard.set(showRegulatedBadge, forKey: Keys.showRegulatedBadge) }
    }

    /// Exports `MP_VERBOSE=1` at daemon launch so pipeline subprocesses inherit it. Env propagation requires a restart; verbose-only event fields (e.g. correction transcript text, SEC14) read this live value in-process.
    @Published var verboseLogging: Bool {
        didSet { UserDefaults.standard.set(verboseLogging, forKey: Keys.verboseLogging) }
    }

    /// Playback channel mode. Default mono mixdown matches the headphone-review case (input + output in both ears); see ADR 0009.
    @Published var playbackChannelMode: PlaybackChannelMode {
        didSet {
            UserDefaults.standard.set(playbackChannelMode.rawValue, forKey: Keys.playbackChannelMode)
        }
    }

    /// Opt-in: start the local MLX summarization server at app launch so the first local-backend summary skips the model cold-start (TECH-A15). Default OFF because a warm model holds multiple GB resident even while idle (the task's RAM stop-and-ask). Only acts when the summarization backend is `local` and the model is already cached; the daemon, not the pipeline, reads this.
    @Published var preloadLocalModelAtLaunch: Bool {
        didSet { UserDefaults.standard.set(preloadLocalModelAtLaunch, forKey: Keys.preloadLocalModelAtLaunch) }
    }

    /// Opt-out of relaunch-on-quit (TECH-UX7). Default OFF: quitting relaunches via the LaunchAgent so the menu-bar app comes back. When ON, "Quit" means quit. The `AppDelegate` reads this to pick the process exit code the LaunchAgent's `KeepAlive = { SuccessfulExit = false }` keys off (non-zero relaunches, zero does not).
    @Published var disableAutoRestart: Bool {
        didSet { UserDefaults.standard.set(disableAutoRestart, forKey: Keys.disableAutoRestart) }
    }

    /// Opt-in (TECH-DSN5): play one short system tone when a meeting finishes processing (the summary is ready). Default OFF so the app stays silent unless asked; never plays during a call. The done notification's sound is separate and may be suppressed by Focus, so this is the reliable audible "done" cue for those who want it.
    @Published var playCompletionTone: Bool {
        didSet { UserDefaults.standard.set(playCompletionTone, forKey: Keys.playCompletionTone) }
    }

    /// AI4-FINISH weekly-digest schedule. When enabled, `DigestSchedulerService` installs
    /// a per-user LaunchAgent that runs `mp digest` at the chosen weekday + time. These are
    /// the source of truth the controls re-render from; the installed plist is what actually
    /// fires. The daemon, not the pipeline, reads them (the agent invokes `mp digest` directly).
    @Published var digestScheduleEnabled: Bool {
        didSet { UserDefaults.standard.set(digestScheduleEnabled, forKey: Keys.digestScheduleEnabled) }
    }

    /// Weekday for the scheduled digest, 1=Monday … 7=Sunday (ISO 8601). Default Monday.
    @Published var digestWeekday: Int {
        didSet { UserDefaults.standard.set(digestWeekday, forKey: Keys.digestWeekday) }
    }

    /// Hour (0–23) for the scheduled digest. Default 9.
    @Published var digestHour: Int {
        didSet { UserDefaults.standard.set(digestHour, forKey: Keys.digestHour) }
    }

    /// Minute (0–59) for the scheduled digest. Default 0.
    @Published var digestMinute: Int {
        didSet { UserDefaults.standard.set(digestMinute, forKey: Keys.digestMinute) }
    }

    /// STOR3: the folder `mp backup` writes to, remembered so the user picks a
    /// destination once. UI-only (the pipeline takes it as a CLI arg, never reads
    /// this key); nil until the user first chooses one. STOR4 also bakes it into
    /// the scheduled agent's `ProgramArguments`, so changing it rewrites the plist.
    @Published var backupDestinationPath: String? {
        didSet { UserDefaults.standard.set(backupDestinationPath, forKey: Keys.backupDestinationPath) }
    }

    /// STOR4 automatic-backup schedule, the same shape as the digest one above:
    /// these are what the controls re-render from, the installed plist is what
    /// fires. Only meaningful with a `backupDestinationPath`.
    @Published var backupScheduleEnabled: Bool {
        didSet { UserDefaults.standard.set(backupScheduleEnabled, forKey: Keys.backupScheduleEnabled) }
    }

    /// `daily` or `weekly` (`BackupSchedulerService.Frequency`). Default daily: a
    /// weekly backup leaves up to seven days of meetings on one disk.
    @Published var backupFrequency: BackupSchedulerService.Frequency {
        didSet { UserDefaults.standard.set(backupFrequency.rawValue, forKey: Keys.backupFrequency) }
    }

    /// Weekday for a weekly backup, 1=Monday … 7=Sunday (ISO 8601). Ignored when
    /// the frequency is daily. Default Sunday.
    @Published var backupWeekday: Int {
        didSet { UserDefaults.standard.set(backupWeekday, forKey: Keys.backupWeekday) }
    }

    /// Hour (0–23) for the scheduled backup. Default 21: late enough that the
    /// day's meetings are in, early enough that the Mac is usually still awake.
    @Published var backupHour: Int {
        didSet { UserDefaults.standard.set(backupHour, forKey: Keys.backupHour) }
    }

    /// Minute (0–59) for the scheduled backup. Default 0.
    @Published var backupMinute: Int {
        didSet { UserDefaults.standard.set(backupMinute, forKey: Keys.backupMinute) }
    }

    private enum Keys {
        static let theme = "mp.ui.theme"
        static let menuBarIconStyle = "mp.ui.menuBarIconStyle"
        static let showRegulatedBadge = "mp.ui.showRegulatedBadge"
        static let verboseLogging = "mp.ui.verboseLogging"
        static let playbackChannelMode = "mp.ui.playbackChannelMode"
        static let preloadLocalModelAtLaunch = "mp.ui.preloadLocalModelAtLaunch"
        static let disableAutoRestart = "mp.ui.disableAutoRestart"
        static let playCompletionTone = "mp.ui.playCompletionTone"
        static let digestScheduleEnabled = "mp.ui.digestScheduleEnabled"
        static let digestWeekday = "mp.ui.digestWeekday"
        static let digestHour = "mp.ui.digestHour"
        static let digestMinute = "mp.ui.digestMinute"
        static let backupDestinationPath = "mp.ui.backupDestinationPath"
        static let backupScheduleEnabled = "mp.ui.backupScheduleEnabled"
        static let backupFrequency = "mp.ui.backupFrequency"
        static let backupWeekday = "mp.ui.backupWeekday"
        static let backupHour = "mp.ui.backupHour"
        static let backupMinute = "mp.ui.backupMinute"
    }

    private init() {
        let d = UserDefaults.standard
        self.theme = Theme(rawValue: d.string(forKey: Keys.theme) ?? "") ?? .system
        self.menuBarIconStyle = MenuBarIconStyle(rawValue: d.string(forKey: Keys.menuBarIconStyle) ?? "")
            ?? .outline
        // `object(forKey:)` is nil when the key was never written, distinguishing "never persisted" (default true) from an explicitly saved false.
        self.showRegulatedBadge = d.object(forKey: Keys.showRegulatedBadge) as? Bool ?? true
        self.verboseLogging = d.bool(forKey: Keys.verboseLogging)
        self.playbackChannelMode = PlaybackChannelMode(
            rawValue: d.string(forKey: Keys.playbackChannelMode) ?? ""
        ) ?? .default
        self.preloadLocalModelAtLaunch = d.bool(forKey: Keys.preloadLocalModelAtLaunch)
        self.disableAutoRestart = d.bool(forKey: Keys.disableAutoRestart)
        self.playCompletionTone = d.bool(forKey: Keys.playCompletionTone)
        self.digestScheduleEnabled = d.bool(forKey: Keys.digestScheduleEnabled)
        // `object(forKey:)` so a never-set key falls to the default instead of 0.
        self.digestWeekday = d.object(forKey: Keys.digestWeekday) as? Int ?? 1
        self.digestHour = d.object(forKey: Keys.digestHour) as? Int ?? 9
        self.digestMinute = d.object(forKey: Keys.digestMinute) as? Int ?? 0
        self.backupDestinationPath = d.string(forKey: Keys.backupDestinationPath)
        self.backupScheduleEnabled = d.bool(forKey: Keys.backupScheduleEnabled)
        self.backupFrequency = BackupSchedulerService.Frequency(
            rawValue: d.string(forKey: Keys.backupFrequency) ?? ""
        ) ?? .daily
        self.backupWeekday = d.object(forKey: Keys.backupWeekday) as? Int ?? 7
        self.backupHour = d.object(forKey: Keys.backupHour) as? Int ?? 21
        self.backupMinute = d.object(forKey: Keys.backupMinute) as? Int ?? 0
    }

    /// Apply the theme to `NSApp.appearance`. `nil` restores the system default.
    func applyTheme() {
        switch theme {
        case .system: NSApp.appearance = nil
        case .light:  NSApp.appearance = NSAppearance(named: .aqua)
        case .dark:   NSApp.appearance = NSAppearance(named: .darkAqua)
        }
    }
}
