import AppKit
import UserNotifications
import CorniceKit

/// Ask for notification permission when the first notice is sent, rather than during
/// startup.
@MainActor
final class NotificationPresenter {

    static let shared = NotificationPresenter()

    private var authorizationRequest: Task<Bool, Never>?

    private init() {}

    /// A countdown reached zero.
    func timerComplete(label: String) {
        post(
            identifier: "timer-\(label)-\(Int(Date().timeIntervalSince1970))",
            title: "\(label) finished",
            body: "Your timer is done.",
            url: nil,
            playsSound: false
        )
    }

    func focusTransition(_ message: String, quiet: Bool) {
        post(identifier: "focus-\(UUID().uuidString)", title: message,
             body: "Open Cornice to see your session.", url: nil, playsSound: !quiet)
    }

    func requestAccess() async -> Bool { await ensureAuthorized() }

    func lowBattery(level: Double) {
        let percent = Int((level * 100).rounded())
        post(
            identifier: "low-battery",
            title: "Battery Low",
            body: "Your Mac is at \(percent)%. Connect it to power or turn on Low Power Mode.",
            url: nil,
            playsSound: true
        )
    }

    private func post(
        identifier: String,
        title: String,
        body: String,
        url: URL?,
        playsSound: Bool
    ) {
        Task {
            guard await ensureAuthorized() else { return }

            let content = UNMutableNotificationContent()
            content.title = title
            content.body = body
            content.sound = playsSound ? .default : nil
            if let url {
                content.userInfo = ["url": url.absoluteString]
            }

            let request = UNNotificationRequest(
                identifier: identifier,
                content: content,
                trigger: nil             // deliver immediately
            )
            do {
                try await UNUserNotificationCenter.current().add(request)
            } catch {
                Log.app.error("could not post notification: \(error.localizedDescription, privacy: .public)")
            }
        }
    }

    private func ensureAuthorized() async -> Bool {
        let settings = await UNUserNotificationCenter.current().notificationSettings()
        switch settings.authorizationStatus {
        case .authorized, .provisional, .ephemeral: return true
        case .denied: return false
        default: break
        }
        if let authorizationRequest { return await authorizationRequest.value }
        let request = Task { () -> Bool in
            do {
                return try await UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound])
            } catch {
                Log.app.notice("notifications unavailable")
                return false
            }
        }
        authorizationRequest = request
        let granted = await request.value
        authorizationRequest = nil
        return granted
    }

}

/// Opens the linked run when a notification is clicked.
final class NotificationDelegate: NSObject, UNUserNotificationCenterDelegate {

    /// Shows notifications even while the app is frontmost. The app has no
    /// windows of its own, so "frontmost" is not a reason to suppress them.
    func userNotificationCenter(
        _ center: UNUserNotificationCenter,
        willPresent notification: UNNotification
    ) async -> UNNotificationPresentationOptions {
        notification.request.content.sound == nil ? [.banner, .list] : [.banner, .list, .sound]
    }

    func userNotificationCenter(
        _ center: UNUserNotificationCenter,
        didReceive response: UNNotificationResponse
    ) async {
        guard let raw = response.notification.request.content.userInfo["url"] as? String,
              let url = URL(string: raw),
              // Only ever open https links we constructed from GitHub's own
              // response. A notification payload should not be able to launch
              // an arbitrary scheme.
              url.scheme == "https"
        else { return }
        await MainActor.run { _ = NSWorkspace.shared.open(url) }
    }
}
