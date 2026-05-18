import AppKit
import Combine
import Foundation

/// UI-only preferences persisted via `UserDefaults`.
///
/// These flags affect how the daemon *presents* itself — they're never
/// read by pipeline subprocesses, so they don't belong in
/// `config.toml`. Keeping cosmetic toggles out of the TOML file means
/// config.toml stays a smaller, reviewable artefact and the pipeline
/// side never has to parse them.
///
/// One singleton (`UISettings.shared`) backs every consumer; SwiftUI
/// views observe via `@ObservedObject`, AppKit consumers subscribe to
/// the individual `@Published` streams via Combine. Reads are cheap;
/// writes hit `UserDefaults` (in-memory; the OS flushes on its own
/// cadence).
final class UISettings: ObservableObject {
    static let shared = UISettings()

    enum Theme: String, CaseIterable {
        case system, light, dark
    }

    /// Two cosmetic variants of the menu-bar idle icon. `outline` is the
    /// default (thin ring + waveform bars, current shipping look);
    /// `filled` drops the ring and renders thicker bars so the icon
    /// reads heavier on a busy menu bar.
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

    /// Whether to surface a small lock glyph next to the status-bar
    /// title when the daemon is in regulated mode. Cosmetic: it doesn't
    /// change behaviour, just the visual signal. Defaults to `true` so
    /// existing regulated-mode users see the badge immediately.
    @Published var showRegulatedBadge: Bool {
        didSet { UserDefaults.standard.set(showRegulatedBadge, forKey: Keys.showRegulatedBadge) }
    }

    /// When on, the daemon logs an info line at startup and exports
    /// `MP_VERBOSE=1` into the environment so subprocess invocations
    /// (Python pipeline stages) inherit the flag. Takes effect after a
    /// daemon restart for env propagation; the in-process `Log.event`
    /// gate reads the live value.
    @Published var verboseLogging: Bool {
        didSet { UserDefaults.standard.set(verboseLogging, forKey: Keys.verboseLogging) }
    }

    /// Library playback channel handling. Default mono mixdown matches
    /// the dominant headphone-review case (input + output in both ears);
    /// see ADR 0009.
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
        // `object(forKey:)` returns nil if the key was never set, so we
        // can distinguish "never persisted" (default true) from
        // "persisted false" (respect the user's choice).
        self.showRegulatedBadge = d.object(forKey: Keys.showRegulatedBadge) as? Bool ?? true
        self.verboseLogging = d.bool(forKey: Keys.verboseLogging)
        self.playbackChannelMode = PlaybackChannelMode(
            rawValue: d.string(forKey: Keys.playbackChannelMode) ?? ""
        ) ?? .default
    }

    /// Apply the user's theme choice to `NSApp.appearance`. Called on
    /// launch (after NSApp is set up) and whenever the picker changes.
    /// `nil` means "follow the system" — equivalent to never having
    /// touched the override.
    func applyTheme() {
        switch theme {
        case .system: NSApp.appearance = nil
        case .light:  NSApp.appearance = NSAppearance(named: .aqua)
        case .dark:   NSApp.appearance = NSAppearance(named: .darkAqua)
        }
    }
}
