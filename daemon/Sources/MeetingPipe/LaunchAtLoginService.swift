import Foundation
import ServiceManagement

/// Thin wrapper around `SMAppService.mainApp` (macOS 13+). Collapses the four-state status into `isEnabled` (Bool) and `requiresApproval` (Bool). `requiresApproval` means the user disabled the login item in System Settings; `register()` returns success but status stays `.requiresApproval` until they re-enable it manually.
enum LaunchAtLoginService {
    /// True iff the login item is registered and approved (maps to `.enabled`).
    static var isEnabled: Bool {
        SMAppService.mainApp.status == .enabled
    }

    /// True iff the user explicitly disabled the login item in System Settings. The UI should prompt "re-enable in System Settings" rather than spin a toggle.
    static var requiresApproval: Bool {
        SMAppService.mainApp.status == .requiresApproval
    }

    /// Register (`true`) or unregister (`false`). SMAppService can throw (unsigned binary, missing bundle id, etc.); errors are logged and swallowed so the UI toggle never stalls. Caller re-reads `isEnabled` to refresh.
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
