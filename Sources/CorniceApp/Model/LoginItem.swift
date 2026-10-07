import Foundation
import ServiceManagement
import CorniceKit

/// Manage launch at login with SMAppService. The user can also change it in System
/// Settings.
enum LoginItem {

    static var isEnabled: Bool {
        SMAppService.mainApp.status == .enabled
    }

    /// Return nil on success or a readable error. Registration can fail when running a
    /// development build outside Applications.
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
