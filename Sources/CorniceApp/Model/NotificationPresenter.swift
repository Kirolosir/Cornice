import AppKit
import UserNotifications
import CorniceKit

/// Posts user notifications.
///
/// Authorisation is requested lazily — the first time the app actually has
/// something to tell the user — rather than at launch. A permission prompt
/// during first launch, before the app has demonstrated why it would ever
/// notify you, is the kind of thing people deny reflexively.
@MainActor
final class NotificationPresenter {

    static let shared = NotificationPresenter()

    private var authorizationState: AuthorizationState = .unknown

    private enum AuthorizationState {
        case unknown
        case granted
        case denied
    }

    private init() {}

    /// A countdown reached zero.
    func timerComplete(label: String) {
        post(
            identifier: "timer-\(label)-\(Int(Date().timeIntervalSince1970))",
            title: "\(label) finished",
            body: "Your timer is done.",
            url: nil
        )
    }

    private func post(identifier: String, title: String, body: String, url: URL?) {
        Task {
            guard await ensureAuthorized() else { return }

            let content = UNMutableNotificationContent()
            content.title = title
            content.body = body
            content.sound = nil          // a build failing does not need a chime
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
        switch authorizationState {
        case .granted: return true
        case .denied: return false
        case .unknown: break
        }

        do {
            let granted = try await UNUserNotificationCenter.current()
                .requestAuthorization(options: [.alert])
            authorizationState = granted ? .granted : .denied
            return granted
        } catch {
            // Happens when the app is not running from a signed bundle, which
            // is the normal state for a local development build. Not an error
            // worth surfacing to the user.
            Log.app.notice("notifications unavailable: \(error.localizedDescription, privacy: .public)")
            authorizationState = .denied
            return false
        }
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
        [.banner, .list]
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
        await MainActor.run { NSWorkspace.shared.open(url) }
    }
}
