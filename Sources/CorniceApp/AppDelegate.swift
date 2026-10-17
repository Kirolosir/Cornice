import AppKit
import UserNotifications
import CorniceKit

/// Composition root and application lifecycle.
@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {

    private var model: AppModel?
    private var windowController: NotchWindowController?
    private var statusItem: NSStatusItem?
    private var awaitingQuit = false
    private let notificationDelegate = NotificationDelegate()

    func applicationDidFinishLaunching(_ notification: Notification) {
        // Save README screenshots using preview data, then exit without opening a window.
        let arguments = CommandLine.arguments
        if let index = arguments.firstIndex(of: "--capture-docs"),
           index + 1 < arguments.count {
            let directory = arguments[index + 1]
            Task { await DocsCapture.run(outputDirectory: directory) }
            return
        }

        if Probes.runDetached(arguments) { return }

        Log.app.notice("Cornice starting")

        let preview = arguments.contains("--preview-ui") || Bundle.main.bundleIdentifier == "dev.cornice.preview"
        let services = preview ? PreviewServices.container() : ServiceContainer.live()
        let model = AppModel(services: services)
        let controller = NotchWindowController(model: model)

        self.model = model
        self.windowController = controller

        UNUserNotificationCenter.current().delegate = notificationDelegate

        AppUpdater.shared.start()
        AppUpdater.shared.beforeRelaunch = { [weak model] in await model?.persistForRelaunch() }
        model.onCheckForUpdates = { AppUpdater.shared.check() }
        model.onShowSetup = { [weak model] in
            guard let model else { return }
            SetupWindow.shared.show(model: model)
        }
        installStatusItem(model: model, controller: controller)
        installApplicationMenu()

        Probes.runAttached(arguments, model: model, controller: controller)

        controller.install()

        Task {
            await model.start()
            if !model.preferences.hasCompletedSetup { SetupWindow.shared.show(model: model) }
            else if preview { SettingsWindow.shared.show(model: model) }
            // Launch-at-login can be changed from System Settings, so the
            // stored preference is reconciled with the system's actual state
            // rather than trusted.
            let systemState = LoginItem.isEnabled
            if systemState != model.preferences.launchAtLogin {
                model.updatePreferences { $0.launchAtLogin = systemState }
            }
        }
    }

    /// Handles the Spotify sign-in callback. Check the saved state and PKCE verifier before
    /// using the code.
    func application(_ application: NSApplication, open urls: [URL]) {
        for url in urls where url.scheme == "cornice" && url.host == "spotify-callback" {
            model?.completeSpotifySignIn(url)
        }
    }

    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        guard let model else { return .terminateNow }
        guard !awaitingQuit else { return .terminateLater }
        awaitingQuit = true
        model.shutDown()
        Task {
            await model.persistForRelaunch()
            sender.reply(toApplicationShouldTerminate: true)
        }
        return .terminateLater
    }

    func applicationWillTerminate(_ notification: Notification) {
        TimerAlarm.shared.stop()
        model?.shutDown()
        windowController?.tearDown()
        Log.app.notice("Cornice terminating")
    }

    /// The app keeps running with no windows open. That is its normal state.
    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        false
    }

    // MARK: - Status item

    private func installApplicationMenu() {
        let menu = NSMenu()
        let appItem = NSMenuItem()
        let appMenu = NSMenu(title: "Cornice")
        let settings = appMenu.addItem(withTitle: "Settings…", action: #selector(openSettings), keyEquivalent: ",")
        settings.target = self
        let updates = appMenu.addItem(withTitle: "Check for Updates…", action: #selector(checkForUpdates), keyEquivalent: "")
        updates.target = self
        appMenu.addItem(.separator())
        appMenu.addItem(withTitle: "Quit Cornice", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
        appItem.submenu = appMenu
        menu.addItem(appItem)

        // AppKit text fields use the Edit menu for the usual shortcuts, including
        // Select All while editing timer presets or the Spotify client ID.
        let editItem = NSMenuItem()
        let editMenu = NSMenu(title: "Edit")
        editMenu.addItem(withTitle: "Undo", action: Selector(("undo:")), keyEquivalent: "z")
        let redo = editMenu.addItem(withTitle: "Redo", action: Selector(("redo:")), keyEquivalent: "z")
        redo.keyEquivalentModifierMask = [.command, .shift]
        editMenu.addItem(.separator())
        editMenu.addItem(withTitle: "Cut", action: #selector(NSText.cut(_:)), keyEquivalent: "x")
        editMenu.addItem(withTitle: "Copy", action: #selector(NSText.copy(_:)), keyEquivalent: "c")
        editMenu.addItem(withTitle: "Paste", action: #selector(NSText.paste(_:)), keyEquivalent: "v")
        editMenu.addItem(withTitle: "Select All", action: #selector(NSText.selectAll(_:)), keyEquivalent: "a")
        editItem.submenu = editMenu
        menu.addItem(editItem)
        NSApp.mainMenu = menu
    }

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
        menu.addItem(withTitle: "Set Up Cornice…", action: #selector(openSetup), keyEquivalent: "")
        menu.addItem(withTitle: "Check for Updates…", action: #selector(checkForUpdates), keyEquivalent: "")
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

    @objc private func openSetup() {
        guard let model else { return }
        SetupWindow.shared.show(model: model)
    }

    @objc private func checkForUpdates() { AppUpdater.shared.check() }

    @objc private func openSettings() {
        guard let model else { return }
        SettingsWindow.shared.show(model: model)
    }

}
