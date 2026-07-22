import AppKit
import SwiftUI

struct GeneralSectionView: View {
    @ObservedObject var store: ConfigStore
    @ObservedObject private var ui = UISettings.shared
    @State private var launchAtLogin: Bool = LaunchAtLoginService.isEnabled

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
                if LaunchAtLoginService.requiresApproval {
                    Text("macOS has marked this login item as needing approval. Open System Settings → General → Login Items and re-enable MeetingPipe.")
                } else {
                    Text("Registers MeetingPipe with macOS via SMAppService. The relaunch-after-quit behaviour takes effect after the launch agent is reinstalled (re-run scripts/install.sh).")
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
        if LaunchAtLoginService.requiresApproval {
            return "Needs approval in System Settings → Login Items."
        }
        return launchAtLogin
            ? "MeetingPipe will start automatically when you log in."
            : "MeetingPipe only starts when you launch it manually."
    }

    /// Re-reads SMAppService status after each set so a `requiresApproval` state doesn't leave the toggle wedged "on" visually.
    private var launchAtLoginBinding: Binding<Bool> {
        Binding(
            get: { launchAtLogin },
            set: { newValue in
                LaunchAtLoginService.set(enabled: newValue)
                launchAtLogin = LaunchAtLoginService.isEnabled
            }
        )
    }
}

// MARK: - Recording
