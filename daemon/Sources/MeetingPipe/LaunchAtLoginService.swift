import Foundation
import ServiceManagement

/// Thin wrapper around `SMAppService.mainApp` (macOS 13+). Registers the
/// app to launch at login and reads back the current status. We collapse
/// SMAppService's four-state `.status` enum into a simple Bool for the UI
/// (`isEnabled`) and expose `.requiresApproval` separately so callers can
/// surface a "go enable it in System Settings" hint when needed.
///
/// `.requiresApproval` happens when the user previously disabled the
/// login item from System Settings → General → Login Items. SMAppService
/// can't override that — they have to flip it back on themselves.
enum LaunchAtLoginService {
    /// True iff the main app is currently registered AND approved by the
    /// user. Maps to `.enabled` in SMAppService's vocabulary.
    static var isEnabled: Bool {
        SMAppService.mainApp.status == .enabled
    }

    /// True iff the user has explicitly disabled the login item from
    /// System Settings → General → Login Items. In that state
    /// `register()` returns success but `status` stays `.requiresApproval`
    /// — the UI needs to tell the user "go re-enable in System Settings"
    /// rather than spin a futile toggle.
    static var requiresApproval: Bool {
        SMAppService.mainApp.status == .requiresApproval
    }

    /// Toggle: register on `true`, unregister on `false`. SMAppService
    /// throws on failure (unsigned binary in some sandboxes, missing
    /// bundle id, ...); we log and swallow so the UI toggle never spins
    /// forever. The caller re-reads `isEnabled` after the call to refresh
    /// its bound state.
    static func set(enabled: Bool) {
        do {
            if enabled {
                if SMAppService.mainApp.status != .enabled {
                    try SMAppService.mainApp.register()
                }
            } else {
                if SMAppService.mainApp.status == .enabled {
                    try SMAppService.mainApp.unregister()
                }
            }
        } catch {
            Log.main.error("LaunchAtLoginService toggle failed: \(String(describing: error))")
        }
    }
}
