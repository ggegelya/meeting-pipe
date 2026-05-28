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

    private enum Keys {
        static let theme = "mp.ui.theme"
        static let menuBarIconStyle = "mp.ui.menuBarIconStyle"
        static let showRegulatedBadge = "mp.ui.showRegulatedBadge"
        static let verboseLogging = "mp.ui.verboseLogging"
        static let playbackChannelMode = "mp.ui.playbackChannelMode"
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
