import AppKit
import SwiftUI

struct PromptSectionView: View {
    @ObservedObject var store: ConfigStore

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            SettingsSectionHeader("Prompt",
                caption: "What happens the moment a meeting is detected.")

            SettingsGroup("When a meeting is detected") {
                SettingsStackRow("Prompt timeout", showsDivider: false) {
                    SettingsSlider(
                        value: $store.promptTimeoutSec,
                        range: 1...120,
                        step: 1,
                        format: { "\(Int($0)) s" }
                    )
                }
                SettingsRow("Default action",
                    sublabel: defaultActionSublabel) {
                    // Dropdown (not segmented): "Record (BYO)" widened the
                    // segmented control enough to shove the Prompt tab off-screen
                    // (same fix as the Pipeline backend picker). A menu stays a
                    // fixed width regardless of label length.
                    SettingsMenuPicker(
                        selection: $store.defaultPromptAction,
                        options: [
                            ("skip",   "Skip"),
                            ("record", "Record"),
                            ("byo",    "Record (BYO)"),
                        ]
                    )
                }
                SettingsStackRow("Re-prompt cooldown",
                    sublabel: "After a recording or skip, suppress new prompts for the same app for this many seconds. Catches post-call mic flickers from Teams/Zoom.") {
                    SettingsSlider(
                        value: $store.repromptCooldownSec,
                        range: 0...300,
                        step: 5,
                        format: { "\(Int($0)) s" }
                    )
                }
            } footer: {
                Text("The floating prompt panel asks whether to record. If you don't respond, the default action above fires when the timeout elapses.")
            }

            SettingsGroup("Stop conditions") {
                SettingsStackRow("Mic-only silence backstop",
                    sublabel: "Auto-stop if your mic is silent AND no system audio plays for this many seconds. Catches the 'everyone else left and I forgot to stop' case.",
                    showsDivider: false) {
                    SettingsSlider(
                        value: $store.micOnlySilenceSec,
                        range: 60...1800,
                        step: 30,
                        format: { Self.formatMinutesOrSeconds(Int($0)) }
                    )
                }
            } footer: {
                Text("Gated on voice activity, not raw level, so a brief pause does not trigger it. A 'still meeting?' nudge fires partway through; a quiet-but-live native call is kept and re-nudged rather than stopped.")
            }
            // Regulated mode moved to the Permissions pane in the DSN1 IA pass:
            // it is a privacy / egress control, not a prompt concern. The
            // cosmetic "Show menu-bar lock" toggle was cut at the same time.
        }
    }

    private var defaultActionSublabel: String {
        switch store.defaultPromptAction {
        case "record":
            return "Auto-start an auto-summary recording when the prompt times out."
        case "byo":
            return "Auto-start a BYO recording (no Anthropic call; paste bundle on stop)."
        default:
            return "Suppress the call (no recording) when the prompt times out."
        }
    }

    /// Show exact-minute values as "N min", otherwise raw seconds. Keeps the silence-backstop slider readable across its 1-to-30-minute range.
    private static func formatMinutesOrSeconds(_ seconds: Int) -> String {
        if seconds % 60 == 0 { return "\(seconds / 60) min" }
        return "\(seconds) s"
    }
}

// MARK: - Pipeline
