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

        // Diagnostic mode: print what the media layer can actually see and
        // exit. Run from inside the bundle so automation permission is
        // attributed to the app rather than to a terminal.
        if arguments.contains("--probe-media") {
            Task { await Self.probeMedia() }
            return
        }

        // The same for audio capture. macOS reports a tap it has denied as
        // running and simply feeds it silence, so "did it start" answers
        // nothing — only measuring what arrives does.
        if arguments.contains("--probe-audio") {
            Task { await Self.probeAudio() }
            return
        }

        // Sends the transport commands and reads the player back, so "the
        // button does nothing" can be told apart from "the player refused" and
        // from "the player has no such setting".
        if arguments.contains("--probe-transport") {
            Task { await Self.probeTransport() }
            return
        }

        Log.app.notice("Cornice starting")

        let services = ServiceContainer.live()
        let model = AppModel(services: services)
        let controller = NotchWindowController(model: model)

        self.model = model
        self.windowController = controller

        UNUserNotificationCenter.current().delegate = notificationDelegate

        installStatusItem(model: model, controller: controller)
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

    func applicationWillTerminate(_ notification: Notification) {
        model?.stopRefreshLoops()
        windowController?.tearDown()
        Log.app.notice("Cornice terminating")
    }

    /// The app keeps running with no windows open — that is its normal state.
    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        false
    }

    /// Prints live player state, for verifying the scripting path.
    private static func probeAudio() async {
        let engine = AudioVisualizerEngine(bandCount: 8)
        let status = engine.start()
        Log.audio.notice("probe: status \(String(describing: status), privacy: .public)")

        guard status == .running else {
            Log.audio.notice("probe: tap did not start")
            exit(0)
        }

        var peakLevel: Float = 0
        var peakBands = [Float](repeating: 0, count: 8)
        var samples = 0
        var barTrace: [[Float]] = []
        for _ in 0..<160 {
            try? await Task.sleep(for: .milliseconds(50))
            let levels = engine.latestLevels()
            if !levels.isSilent { barTrace.append(levels.barHeights(count: 3)) }
            peakLevel = max(peakLevel, levels.level)
            for (index, value) in levels.bands.enumerated() where index < peakBands.count {
                peakBands[index] = max(peakBands[index], value)
            }
            if !levels.isSilent { samples += 1 }
        }
        engine.stop()

        let perBand = peakBands.map { String(format: "%.3f", $0) }.joined(separator: " ")
        Log.audio.notice(
            "probe: peakLevel=\(peakLevel, format: .fixed(precision: 4), privacy: .public) nonSilent=\(samples, privacy: .public)/160 bands=[\(perBand, privacy: .public)]"
        )

        // How much each drawn bar actually moves, which is what "lively" means.
        let summary = (0..<3).map { bar -> String in
            let series = barTrace.map { $0[bar] }
            let lowest = series.min() ?? 0
            let highest = series.max() ?? 0
            let mean = series.reduce(0, +) / Float(max(1, series.count))
            let variance = series.reduce(0) { $0 + pow($1 - mean, 2) } / Float(max(1, series.count))
            return String(format: "bar%d %.2f-%.2f mean %.2f sd %.3f", bar, lowest, highest, mean, variance.squareRoot())
        }
        Log.audio.notice("probe: \(summary.joined(separator: "  "), privacy: .public)")
        exit(0)
    }

    private static func probeTransport() async {
        let coordinator = MediaCoordinator.live()
        guard let before = await coordinator.snapshot() else {
            Log.media.notice("transport probe: no player with a track")
            exit(0)
        }
        Log.media.notice(
            "transport probe: \(before.source.rawValue, privacy: .public) shuffle=\(before.isShuffling, privacy: .public) repeat=\(before.repeatMode.rawValue, privacy: .public)"
        )

        for command in [MediaCommand.cycleRepeat, .toggleShuffle] {
            do {
                let started = Date()
                try await coordinator.perform(command, on: before.source)
                // Poll hard, to find how long the player takes to report the
                // change it has just been told to make.
                var trace: [String] = []
                for _ in 0..<12 {
                    let after = await coordinator.snapshot()
                    let elapsed = Int(Date().timeIntervalSince(started) * 1000)
                    trace.append("\(elapsed)ms:\(after?.repeatMode.rawValue ?? "?")/\(after?.isShuffling == true ? "shuf" : "-")")
                    try? await Task.sleep(for: .milliseconds(60))
                }
                Log.media.notice(
                    "transport probe \(String(describing: command), privacy: .public): \(trace.joined(separator: " "), privacy: .public)"
                )
            } catch {
                Log.media.error(
                    "transport probe: \(String(describing: command), privacy: .public) FAILED \(String(describing: error), privacy: .public)"
                )
            }
        }
        exit(0)
    }

    private static func probeMedia() async {
        let coordinator = MediaCoordinator.live()
        let running = await coordinator.runningSources()
        print("running players:", running.map(\.displayName).joined(separator: ", "))

        guard let snapshot = await coordinator.snapshot() else {
            let denied = await coordinator.allSourcesUnavailable()
            print(denied
                  ? "automation refused — grant Cornice in Privacy & Security › Automation"
                  : "no track loaded")
            exit(0)
        }

        print("""
        source:   \(snapshot.source.displayName)
        state:    \(snapshot.state.rawValue)
        title:    \(snapshot.title)
        artist:   \(snapshot.artist)
        album:    \(snapshot.album)
        duration: \(Format.duration(snapshot.duration))  (\(snapshot.duration)s raw)
        position: \(Format.duration(snapshot.position))
        progress: \(String(format: "%.1f%%", snapshot.progress() * 100))
        shuffle:  \(snapshot.isShuffling)  repeat: \(snapshot.repeatMode.rawValue)
        volume:   \(snapshot.volume.map { String(format: "%.0f%%", $0 * 100) } ?? "n/a")
        artwork:  \(snapshot.artworkURL?.absoluteString ?? "none")
        """)

        if let data = await coordinator.artwork(for: snapshot) {
            print("artwork bytes: \(data.count)")
        }
        exit(0)
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
