import Foundation
import ServiceManagement
import CorniceKit

/// Launch-at-login, via `SMAppService`.
///
/// `SMAppService.mainApp` is the modern replacement for the deprecated
/// `SMLoginItemSetEnabled` and the long-deprecated login-items AppleScript.
/// It requires no helper bundle and no extra entitlement, and the user can
/// revoke it from System Settings (where they will look for it), rather than
/// only from inside this app.
enum LoginItem {

    static var isEnabled: Bool {
        SMAppService.mainApp.status == .enabled
    }

    /// Returns an error message, or `nil` on success.
    ///
    /// The common failure is running from an unsigned build outside
    /// `/Applications`, where the service cannot be registered. That is the
    /// normal state during development, so it is reported as a clear
    /// explanation rather than swallowed.
    @discardableResult
    static func setEnabled(_ enabled: Bool) -> String? {
        do {
            if enabled {
                try SMAppService.mainApp.register()
            } else {
                try SMAppService.mainApp.unregister()
            }
            Log.app.notice("launch at login \(enabled ? "enabled" : "disabled", privacy: .public)")
            return nil
        } catch {
            Log.app.error("login item change failed: \(error.localizedDescription, privacy: .public)")
            return "Could not change the login item. This usually means the app is not in /Applications, or the build is unsigned."
        }
    }
}
