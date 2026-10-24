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
///
/// **UX67 gave it two things that `@StateObject` alone does not provide.**
///
/// The reading is re-taken when the pane appears, not cached for the view's
/// lifetime. The object's lifetime is the view's rather than the window's and
/// nothing re-read on open, on foreground, or on any notification, so a
/// `rebuild.sh` changing the agent underneath left the pane rendering the state
/// that was true when the view was first built. Deliberately not a per-render
/// read: `status()` spawns `launchctl`, and UX55 recorded what an inline read on a
/// hot path costs (one subprocess per download-progress tick on the main queue).
///
/// And the launchctl round-trips run **off the main thread**. A write is up to
/// three subprocess calls, each a `readDataToEndOfFile` plus a `waitUntilExit`,
/// and a `rebuild.sh` boots the same label out and back in while the pane is open,
/// which is when those calls block. On main that wedges every control in the
/// window, including the "Relaunch after quitting" toggle next to this one, which
/// touches launchd not at all and could not otherwise fail. `isBusy` is what the
/// UI shows meanwhile, so an in-flight write reads as busy rather than as dead.
@MainActor
final class LaunchAtLoginModel: ObservableObject {
    @Published private(set) var status: LaunchAtLoginStatus
    /// A launchctl round-trip is in flight. The toggles disable on it, which is
    /// the honest rendering: the machine has not answered yet, so the control has
    /// nothing to show and a second click would only queue another subprocess.
    @Published private(set) var isBusy = false

    private let service: LaunchAtLoginService

    /// The initial read is still synchronous, and stays that way on purpose: the
    /// alternative is a placeholder state rendered before the machine has been
    /// asked, which is the control-lies-about-launchd defect UX42 removed. It is
    /// one bounded `print-disabled` at view construction, not a write.
    init(service: LaunchAtLoginService = LaunchAtLoginService()) {
        self.service = service
        self.status = service.status()
    }

    /// Re-take the reading. Called when the pane appears; a no-op while a call is
    /// already in flight, so a re-appear during a write cannot stack subprocesses.
    ///
    /// The returned task is the seam the tests await on. Discardable because no
    /// caller in the app has anything to do with it.
    @discardableResult
    func refresh() -> Task<Void, Never>? {
        guard !isBusy else { return nil }
        return run { service in service.status() }
    }

    @discardableResult
    func set(enabled: Bool) -> Task<Void, Never>? {
        guard !isBusy else { return nil }
        return run(requested: enabled) { service in service.set(enabled: enabled) }
    }

    private func run(
        requested: Bool? = nil,
        _ work: @escaping @Sendable (LaunchAtLoginService) -> LaunchAtLoginStatus
    ) -> Task<Void, Never> {
        isBusy = true
        let service = self.service
        return Task {
            let result = await Task.detached(priority: .userInitiated) {
                work(service)
            }.value
            self.status = result
            self.isBusy = false
            guard let requested,
                  let refusal = LaunchAtLoginRefusal.decide(requested: requested, status: result)
            else { return }
            // UX67 candidate A: the switch is correctly showing the machine and the
            // machine declined. Under `daemon` rather than a new `preferences`
            // category, which is where the other Preferences-originated events
            // already live (CONVENTIONS: don't invent a category unless you are
            // adding a subsystem).
            Log.event(category: "daemon", action: "launch_at_login_write_refused", attributes: [
                "requested": refusal.requested,
                "resulting_state": String(describing: refusal.resulting),
                "reason": refusal.reason,
            ])
        }
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
                // toggle; cut in the DSN1 IA pass. The glyph is the outline one,
                // unconditionally: `UISettings.menuBarIconStyle` outlived this
                // control by a year with nothing writing it, and ARCH6 removed the
                // property and the branch it fed.
            }

            SettingsGroup("Startup") {
                SettingsToggleRow("Launch at login",
                    sublabel: launchAtLoginSublabel,
                    isOn: launchAtLoginBinding)
                    .disabled(launchAtLogin.isBusy)
                SettingsToggleRow("Relaunch after quitting",
                    sublabel: "On: Quit restarts MeetingPipe in the menu bar. Off: Quit fully closes it. Either way a crash still auto-recovers.",
                    isOn: Binding(
                        get: { !ui.disableAutoRestart },
                        set: { ui.disableAutoRestart = !$0 }
                    ),
                    showsDivider: false)
            } footer: {
                if let error = launchAtLogin.status.error {
                    FailureNotice(failure: FailurePresentation(diagnostics: error, operation: .processing, title: "Couldn't change launch at login"))
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
                    sublabel: "Cut your microphone out of a stretch while recording; toggle again to resume. The other side of the call is still transcribed.") {
                    SettingsHotkeyField(text: $store.offTheRecordHotkey)
                }
            } footer: {
                Text("Click a field, then press the chord you want to bind (one or more of ⌃⌥⇧⌘ plus a letter). The toggle hotkey starts/stops; the force-stop hotkey only stops, so panic-pressing can never accidentally start a recording; the flag hotkey marks the current moment while a recording is running; the off-the-record hotkey (also a toggle on the recording HUD) marks a stretch to keep out of the notes. Restart MeetingPipe after changing.")
            }
        }
        // UX67: the pane's appear-equivalent. `install.sh` and `rebuild.sh` both
        // move the login agent, and neither tells this window, so a reading taken
        // once at view construction goes stale without anything invalidating it.
        .onAppear { launchAtLogin.refresh() }
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
