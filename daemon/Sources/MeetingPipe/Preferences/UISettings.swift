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

    /// Exports `MP_VERBOSE=1` at daemon launch so pipeline subprocesses inherit it. Env propagation requires a restart; the in-process `Log.event` gate reads the live value.
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

    private enum Keys {
        static let theme = "mp.ui.theme"
        static let menuBarIconStyle = "mp.ui.menuBarIconStyle"
        static let showRegulatedBadge = "mp.ui.showRegulatedBadge"
        static let verboseLogging = "mp.ui.verboseLogging"
        static let playbackChannelMode = "mp.ui.playbackChannelMode"
        static let preloadLocalModelAtLaunch = "mp.ui.preloadLocalModelAtLaunch"
        static let disableAutoRestart = "mp.ui.disableAutoRestart"
        static let playCompletionTone = "mp.ui.playCompletionTone"
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
