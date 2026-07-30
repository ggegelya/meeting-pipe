import AppKit
import Combine
import SwiftUI

/// The General pane's live view of what launchd will do at the next login (UX42).
///
/// A `@StateObject` rather than `@State`, because reading the truth means shelling
/// out to `launchctl` and a `@State` initial-value expression is re-evaluated on
/// every re-render of the enclosing view. `ConfigStore` publishes on every
/// keystroke in this pane's hotkey fields, so `@State` would have meant one
/// subprocess per character typed; `@StateObject` takes an autoclosure SwiftUI
/// calls once per view identity.
final class LaunchAtLoginModel: ObservableObject {
    @Published private(set) var status: LaunchAtLoginStatus

    private let service: LaunchAtLoginService

    init(service: LaunchAtLoginService = LaunchAtLoginService()) {
        self.service = service
        self.status = service.status()
    }

    func set(enabled: Bool) {
        status = service.set(enabled: enabled)
    }
}

struct GeneralSectionView: View {
    @ObservedObject var store: ConfigStore
    @ObservedObject private var ui = UISettings.shared
    @StateObject private var launchAtLogin = LaunchAtLoginModel()

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            SettingsSectionHeader("General",
                caption: "Global hotkeys, appearance, and startup behaviour.")

            SettingsGroup("Appearance") {
                SettingsRow("Theme",
                    sublabel: "Override the system appearance. SwiftUI windows and the recording HUD follow this choice.",
                    showsDivider: false) {
                    SettingsSegmented(
                        selection: $ui.theme,
                        options: [
                            (.light,  "Light"),
                            (.system, "System"),
                            (.dark,   "Dark"),
                        ]
                    )
                }
                // Menu-bar icon style (outline vs filled) was a cosmetic-only
                // toggle; cut in the DSN1 IA pass. The glyph stays at its
                // default; UISettings.menuBarIconStyle remains for the status bar.
            }

            SettingsGroup("Startup") {
                SettingsToggleRow("Launch at login",
                    sublabel: launchAtLoginSublabel,
                    isOn: launchAtLoginBinding)
                SettingsToggleRow("Relaunch after quitting",
                    sublabel: "On: Quit restarts MeetingPipe in the menu bar. Off: Quit fully closes it. Either way a crash still auto-recovers.",
                    isOn: Binding(
                        get: { !ui.disableAutoRestart },
                        set: { ui.disableAutoRestart = !$0 }
                    ),
                    showsDivider: false)
            } footer: {
                if let error = launchAtLogin.status.error {
                    Text(error)
                } else {
                    Text("Launch at login enables or disables the com.meetingpipe.daemon launch agent, the one thing that actually starts MeetingPipe when you log in. Turning it off leaves the app you are using alone; it just does not come back at the next login. Relaunch after quitting is that same agent's work, so with launch at login off, a MeetingPipe you opened yourself stays closed when you quit it.")
                }
            }

            SettingsGroup("Sound") {
                // TECH-DSN5: one opt-in, default-off post-call completion tone.
                SettingsToggleRow("Play a tone when a meeting finishes",
                    sublabel: "A short system tone when the summary is ready. Off by default, and never during a call.",
                    isOn: $ui.playCompletionTone,
                    showsDivider: false)
            }

            SettingsGroup("Hotkeys") {
                SettingsRow("Manual toggle",
                    sublabel: "Start or stop a recording from anywhere.",
                    showsDivider: false) {
                    SettingsHotkeyField(text: $store.manualHotkey)
                }
                SettingsRow("Force stop",
                    sublabel: "Stop immediately, even if detection still thinks a meeting is live.") {
                    SettingsHotkeyField(text: $store.forceStopHotkey)
                }
                SettingsRow("Flag moment",
                    sublabel: "Mark the current moment while recording; it surfaces in the summary and as a chip in the transcript.") {
                    SettingsHotkeyField(text: $store.flagMomentHotkey)
                }
                SettingsRow("Off the record",
                    sublabel: "Mark a sensitive stretch as off the record while recording; toggle again to resume. The marked span is kept out of the notes.") {
                    SettingsHotkeyField(text: $store.offTheRecordHotkey)
                }
            } footer: {
                Text("Click a field, then press the chord you want to bind (one or more of ⌃⌥⇧⌘ plus a letter). The toggle hotkey starts/stops; the force-stop hotkey only stops, so panic-pressing can never accidentally start a recording; the flag hotkey marks the current moment while a recording is running; the off-the-record hotkey (also a toggle on the recording HUD) marks a stretch to keep out of the notes. Restart MeetingPipe after changing.")
            }
        }
    }

    private var launchAtLoginSublabel: String {
        switch launchAtLogin.status.state {
        case .enabled:      return "MeetingPipe will start automatically when you log in."
        case .disabled:     return "MeetingPipe only starts when you launch it manually."
        case .notInstalled: return "No launch agent is installed, so nothing starts MeetingPipe at login. Run scripts/install.sh."
        }
    }

    /// The switch renders whatever launchd is left holding after the write, not
    /// what was asked for, so a refused `launchctl` cannot leave the control
    /// showing a state the machine does not have (UX42). The reason lands in the
    /// group footer.
    private var launchAtLoginBinding: Binding<Bool> {
        Binding(
            get: { launchAtLogin.status.isOn },
            set: { launchAtLogin.set(enabled: $0) }
        )
    }
}

// MARK: - Recording
