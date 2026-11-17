import AppKit
import SwiftUI

/// UX91: one row above every Preferences pane while a change failed to save. It sits
/// above the controls rather than replacing them (unlike `ConfigParseErrorPane`): the
/// file is still readable, and the user may want to undo the change instead.
struct SettingsSaveBanner: View {
    @ObservedObject var store: ConfigStore
    @ObservedObject var secrets: SecretsStore

    /// What the row says, derived here so the copy is testable without a view.
    struct Model: Equatable {
        let message: String
        /// Only a config failure has a file to show.
        let offersReveal: Bool

        static func make(config: SettingSaveFailure?, keychain: SettingSaveFailure?) -> Model? {
            guard let failure = config ?? keychain else { return nil }
            return Model(message: "Your last change was not saved: \(failure.reason)", offersReveal: config != nil)
        }
    }

    var body: some View {
        if let model = Model.make(config: store.saveError, keychain: secrets.saveError) {
            SettingsGroup {
                SettingsRow(model.message,
                            sublabel: "The change is still on screen but not in effect.",
                            showsDivider: false) {
                    Button("Try again") { retry() }
                        .buttonStyle(.mpGhost)
                    if model.offersReveal {
                        Button("Reveal in Finder") {
                            NSWorkspace.shared.activateFileViewerSelecting([store.fileURL])
                        }
                        .buttonStyle(.mpGhost)
                    }
                }
            }
            .padding(.bottom, MPSpace.s5)
        }
    }

    private func retry() {
        // A local file write is quick, so the config retries synchronously; a Keychain
        // write is a `security` subprocess a locked keychain can park, so it goes
        // through the debounced saver off main instead (CONC8).
        if store.saveError != nil { try? store.saveNow() }
        if secrets.saveError != nil { secrets.retrySave() }
    }
}
