import AppKit
import UserNotifications
import CorniceKit

/// Composition root and application lifecycle.
@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {

    private var model: AppModel?
    private var windowController: NotchWindowController?
    private var statusItem: NSStatusItem?
    private let notificationDelegate = NotificationDelegate()

    func applicationDidFinishLaunching(_ notification: Notification) {
        // Documentation mode: render the interface to PNGs and exit without
        // ever showing a window. Keeps README images reproducible in one
        // command instead of being hand-captured and slowly going stale.
        let arguments = CommandLine.arguments
        if let index = arguments.firstIndex(of: "--capture-docs"),
           index + 1 < arguments.count {
            let directory = arguments[index + 1]
            Task { await DocsCapture.run(outputDirectory: directory) }
            return
        }

        if Probes.runDetached(arguments) { return }

        Log.app.notice("Cornice starting")

        let services = ServiceContainer.live()
        let model = AppModel(services: services)
        let controller = NotchWindowController(model: model)

        self.model = model
        self.windowController = controller

        UNUserNotificationCenter.current().delegate = notificationDelegate

        installStatusItem(model: model, controller: controller)

        Probes.runAttached(arguments, model: model, controller: controller)

        controller.install()

        Task {
            await model.start()
            // Launch-at-login can be changed from System Settings, so the
            // stored preference is reconciled with the system's actual state
            // rather than trusted.
            let systemState = LoginItem.isEnabled
            if systemState != model.preferences.launchAtLogin {
                model.updatePreferences { $0.launchAtLogin = systemState }
            }
        }
    }

    /// Where the Spotify sign-in comes back to.
    ///
    /// The browser is handed a `cornice://spotify-callback` redirect, and macOS
    /// routes it here through the URL type declared in `Info.plist`. The code it
    /// carries is worthless without the PKCE verifier held in this process, and
    /// the `state` it carries is checked against the one this process generated,
    /// so a URL from anywhere else is refused rather than redeemed.
    func application(_ application: NSApplication, open urls: [URL]) {
        for url in urls where url.scheme == "cornice" && url.host == "spotify-callback" {
            model?.completeSpotifySignIn(url)
        }
    }

    func applicationWillTerminate(_ notification: Notification) {
        TimerAlarm.shared.stop()
        model?.stopRefreshLoops()
        windowController?.tearDown()
        Log.app.notice("Cornice terminating")
    }

    /// The app keeps running with no windows open. That is its normal state.
    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        false
    }

    // MARK: - Status item

    /// A menu-bar item, because an accessory app with no Dock icon otherwise
    /// has no discoverable way to reach settings or quit.
    private func installStatusItem(model: AppModel, controller: NotchWindowController) {
        let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        item.button?.image = NSImage(
            systemSymbolName: "rectangle.topthird.inset.filled",
            accessibilityDescription: "Cornice"
        )
        item.button?.image?.isTemplate = true

        let menu = NSMenu()
        menu.addItem(
            withTitle: "Toggle Panel",
            action: #selector(togglePanel),
            keyEquivalent: "d"
        ).keyEquivalentModifierMask = [.command, .option]
        menu.addItem(.separator())
        menu.addItem(withTitle: "Settings…", action: #selector(openSettings), keyEquivalent: ",")
        menu.addItem(.separator())
        menu.addItem(withTitle: "Quit Cornice", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")

        for menuItem in menu.items where menuItem.action != #selector(NSApplication.terminate(_:)) {
            menuItem.target = self
        }

        item.menu = menu
        statusItem = item
    }

    @objc private func togglePanel() {
        windowController?.toggle()
    }

    @objc private func openSettings() {
        guard let model else { return }
        SettingsWindow.shared.show(model: model)
    }

}
