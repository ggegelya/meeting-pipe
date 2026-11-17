import Foundation

/// A Preferences change that did not reach its store (UX91): `config.toml` for
/// `ConfigStore`, the login Keychain for `SecretsStore`. The control keeps the new
/// value (reverting a field under the user's cursor is worse), so this is what says
/// the change is on screen but not in effect: Preferences shows it above every pane
/// and the menu bar adds one row while either store holds one.
struct SettingSaveFailure: Equatable {
    enum Store: String {
        case config
        case keychain
    }

    let store: Store
    /// One line for the banner. Never a value, and never a `security` call's stderr.
    let reason: String
    let at: Date

    /// One `daemon`/`config_save_failed` event (no value) and the same fact in
    /// `daemon.log`, which os.Logger alone never reached.
    static func record(_ store: Store, attributes: [String: Any], line: String) {
        var attributes = attributes
        attributes["store"] = store.rawValue
        Log.event(category: "daemon", action: "config_save_failed", attributes: attributes)
        Log.writeLine("daemon", line)
    }
}
