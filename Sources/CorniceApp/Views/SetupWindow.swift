import AppKit
import SwiftUI
import UserNotifications
import CorniceKit

@MainActor
final class SetupWindow {
    static let shared = SetupWindow()
    private var window: NSWindow?

    func show(model: AppModel) {
        if let window { window.makeKeyAndOrderFront(nil); NSApp.activate(ignoringOtherApps: true); return }
        let root = SetupView(model: model) { [weak self] in self?.window?.close(); self?.window = nil }
        let window = NSWindow(contentViewController: NSHostingController(rootView: root))
        window.title = "Welcome to Cornice"
        window.styleMask = [.titled, .closable]
        window.setContentSize(NSSize(width: 500, height: 460))
        window.isReleasedWhenClosed = false
        window.center()
        self.window = window
        window.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }
}

struct SetupView: View {
    @Bindable var model: AppModel
    let close: () -> Void
    @State private var page = 0
    @State private var automaticUpdates = true
    @State private var notificationStatus = "Optional"
    @State private var requestingNotifications = false
    @State private var notificationsDenied = false
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        VStack(alignment: .leading, spacing: 20) {
            HStack(spacing: 12) {
                Image(nsImage: NSImage(contentsOf: Bundle.main.url(forResource: "AppIcon", withExtension: "icns") ?? URL(fileURLWithPath: "/")) ?? NSImage())
                    .resizable().frame(width: 54, height: 54).accessibilityHidden(true)
                VStack(alignment: .leading, spacing: 3) {
                    Text(page == 0 ? "Meet your notch" : page == 1 ? "Connect your music" : "Make it yours")
                        .font(.title2.weight(.semibold))
                    Text("Cornice \(AppUpdater.version)").font(.caption).foregroundStyle(.secondary)
                }
                Spacer()
                Text("\(page + 1) of 3").font(.caption.monospacedDigit()).foregroundStyle(.secondary)
            }
            Group {
                switch page {
                case 0: welcome
                case 1: players
                default: options
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
            .id(page)
            .transition(.opacity)
            HStack {
                if page > 0 { Button("Back") { move(-1) } }
                Button("Set Up Later") { model.finishSetup(); close() }.foregroundStyle(.secondary)
                Spacer()
                Button(page == 2 ? "Done" : "Continue") {
                    if page < 2 { move(1) }
                    else { model.finishSetup(); AppUpdater.shared.setAutomaticChecks(automaticUpdates); close() }
                }
                .buttonStyle(.borderedProminent)
                .keyboardShortcut(.defaultAction)
            }
        }
        .padding(26)
        .frame(width: 500, height: 460)
        .task {
            if model.preferences.hasCompletedSetup { automaticUpdates = AppUpdater.shared.automaticChecks }
            await refreshNotifications()
        }
        .task {
            while !Task.isCancelled {
                if model.preferences.audioVisualizerEnabled { model.sampleLevels() }
                do { try await Task.sleep(for: .milliseconds(500)) } catch { return }
            }
        }
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) { _ in
            Task { await refreshNotifications() }
        }
    }

    private var welcome: some View {
        VStack(alignment: .leading, spacing: 18) {
            Text("Music, timers and a quick look at your Mac, right around the notch.")
                .font(.body).foregroundStyle(.secondary)
            Label("Hover directly over the notch to open it.", systemImage: "cursorarrow.rays")
            Label("Press ⌥⌘D to open it from the keyboard.", systemImage: "keyboard")
            Label("Use ⌘1, ⌘2 and ⌘3 to switch panels.", systemImage: "rectangle.3.group")
            Text("Music controls, audio capture and notifications are optional. You can change them later in Settings.")
                .font(.caption).foregroundStyle(.secondary)
            if Bundle.main.bundleURL.path.hasPrefix("/Volumes/") {
                Label("Move Cornice to Applications, then reopen it there so updates can install.", systemImage: "folder")
                    .font(.callout).foregroundStyle(.orange)
            }
        }
    }

    private var players: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("Open Music or Spotify and play a song. When you connect, macOS may ask whether Cornice can control that player.")
                .font(.callout).foregroundStyle(.secondary)
            ForEach(MediaSource.allCases) { source in
                HStack {
                    Image(systemName: "music.note").frame(width: 20).foregroundStyle(.secondary)
                    Text(source.displayName)
                    Spacer()
                    Text(status(source)).font(.caption).foregroundStyle(.secondary)
                    Button("Open") { open(source) }
                }.padding(12).background(Color.secondary.opacity(0.07), in: RoundedRectangle(cornerRadius: 12))
            }
            HStack {
                Button(model.preferences.mediaAccessEnabled ? "Reconnect Players" : "Connect Players") {
                    model.retryMediaPermission()
                }.buttonStyle(.borderedProminent)
                if model.mediaHealth.values.contains(where: { $0.lastSuccess != nil && $0.failures == 0 && !$0.permissionDenied }) { Label("Connected", systemImage: "checkmark.circle.fill").foregroundStyle(.green) }
            }
            if model.mediaPermissionDenied {
                Button("Open Automation Settings") { model.openAutomationSettings() }
            }
            Text("You don't need a Spotify developer account for song information and normal controls.")
                .font(.caption).foregroundStyle(.secondary)
        }
    }

    private var options: some View {
        VStack(alignment: .leading, spacing: 16) {
            VStack(alignment: .leading, spacing: 5) {
                Toggle("Follow actual audio", isOn: Binding(get: { model.preferences.audioVisualizerEnabled },
                    set: { value in model.updatePreferences { $0.audioVisualizerEnabled = value } }))
                Text(audioStatus).font(.caption).foregroundStyle(.secondary)
            }
            Divider()
            HStack {
                VStack(alignment: .leading, spacing: 4) {
                    Text("Timer and low-battery notifications")
                    Text(notificationStatus).font(.caption).foregroundStyle(.secondary)
                }
                Spacer()
                Button(notificationsDenied ? "Open Settings" : "Allow…") {
                    if notificationsDenied {
                        NSWorkspace.shared.open(URL(string: "x-apple.systempreferences:com.apple.Notifications-Settings.extension")!)
                        return
                    }
                    requestingNotifications = true
                    Task { _ = await NotificationPresenter.shared.requestAccess(); await refreshNotifications(); requestingNotifications = false }
                }.disabled(requestingNotifications || notificationStatus == "Allowed")
            }
            Divider()
            Toggle("Check for updates automatically", isOn: $automaticUpdates)
            Text("Cornice can check for new versions and offer to install them inside the app. You choose when to install.")
                .font(.caption).foregroundStyle(.secondary)
        }
    }

    private var audioStatus: String {
        if !model.preferences.audioVisualizerEnabled { return "Optional. With this off, the bars indicate playback. Audio capture needs macOS 14.2 or later." }
        if model.hasLiveAudio { return "Receiving audio. Samples stay in memory and aren't saved." }
        if case .failed(let reason) = model.visualizerStatus { return reason.message }
        return "Waiting for audio. Allow System Audio Recording if macOS asks, then play a song."
    }
    private func status(_ source: MediaSource) -> String {
        if model.mediaHealth[source]?.permissionDenied == true { return "Access denied" }
        if model.mediaHealth[source]?.failures ?? 0 > 0 { return "Reconnecting…" }
        if model.mediaHealth[source]?.lastSuccess != nil { return "Connected" }
        return model.runningPlayers.contains(source) ? "Open" : "Not running"
    }
    private func open(_ source: MediaSource) {
        guard let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: source.bundleIdentifier) else { return }
        NSWorkspace.shared.openApplication(at: url, configuration: NSWorkspace.OpenConfiguration())
    }
    private func move(_ amount: Int) { withAnimation(reduceMotion ? nil : .easeInOut(duration: 0.16)) { page += amount } }
    private func refreshNotifications() async {
        let access = await NotificationPresenter.accessStatus()
        notificationsDenied = access == .denied
        switch access {
        case .allowed: notificationStatus = "Allowed"
        case .denied: notificationStatus = "Not allowed — change this in System Settings"
        case .notAsked: notificationStatus = "Optional — allow alerts when you want them"
        }
    }
}
