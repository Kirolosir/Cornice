import AppKit
import SwiftUI
import CorniceKit

/// Hosts settings in a conventional window.
///
/// A real, focusable window rather than a pane inside the surface: the surface
/// is non-activating and closes when the pointer leaves it, which is right for
/// glancing at a track and completely wrong for reading permission explanations.
@MainActor
final class SettingsWindow {

    static let shared = SettingsWindow()

    private var window: NSWindow?

    private init() {}

    func show(model: AppModel) {
        if let window {
            window.makeKeyAndOrderFront(nil)
            NSApp.activate(ignoringOtherApps: true)
            return
        }

        let hosting = NSHostingController(rootView: SettingsView(model: model))
        let window = NSWindow(contentViewController: hosting)
        window.title = "Cornice Settings"
        window.styleMask = [.titled, .closable, .miniaturizable]
        window.setContentSize(NSSize(width: 480, height: 470))
        window.isReleasedWhenClosed = false
        window.center()
        window.delegate = WindowCloseObserver.shared
        WindowCloseObserver.shared.onClose = { [weak self] in self?.window = nil }

        self.window = window
        window.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }

    /// Rebuilds the window next time rather than re-showing stale SwiftUI state.
    @MainActor
    private final class WindowCloseObserver: NSObject, NSWindowDelegate {
        static let shared = WindowCloseObserver()
        var onClose: (() -> Void)?
        func windowWillClose(_ notification: Notification) { onClose?() }
    }
}

struct SettingsView: View {
    @Bindable var model: AppModel

    var body: some View {
        TabView {
            GeneralSettings(model: model)
                .tabItem { Label("General", systemImage: "gearshape") }
            VisualizerSettings(model: model)
                .tabItem { Label("Visualiser", systemImage: "waveform") }
            AboutSettings(model: model)
                .tabItem { Label("About", systemImage: "info.circle") }
        }
        .frame(width: 480, height: 470)
    }
}

struct GeneralSettings: View {
    @Bindable var model: AppModel
    @State private var loginItemError: String?

    var body: some View {
        Form {
            Section("Opening") {
                Picker("Open on", selection: Binding(
                    get: { model.preferences.activationStyle },
                    set: { style in model.updatePreferences { $0.activationStyle = style } }
                )) {
                    ForEach(ActivationStyle.allCases) { Text($0.title).tag($0) }
                }

                if model.preferences.activationStyle == .hover {
                    LabeledContent("Open after") {
                        HStack {
                            Slider(
                                value: Binding(
                                    get: { model.preferences.hoverDwell },
                                    set: { value in model.updatePreferences { $0.hoverDwell = value } }
                                ),
                                in: 0...0.6
                            )
                            Text(String(format: "%.2fs", model.preferences.hoverDwell))
                                .font(.caption.monospacedDigit())
                                .frame(width: 44, alignment: .trailing)
                        }
                    }
                    Text("The surface responds to your pointer immediately; this is how long it waits before opening fully.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }

            Section("Collapsed surface") {
                Picker("Show", selection: Binding(
                    get: { model.preferences.idleDisplay },
                    set: { value in model.updatePreferences { $0.idleDisplay = value } }
                )) {
                    ForEach(IdleDisplay.allCases) { Text($0.title).tag($0) }
                }
                Toggle("Tint the panel with album artwork", isOn: Binding(
                    get: { model.preferences.tintFromArtwork },
                    set: { value in model.updatePreferences { $0.tintFromArtwork = value } }
                ))
            }

            Section("Panels") {
                ForEach(ModuleKind.allCases) { module in
                    Toggle(isOn: Binding(
                        get: { model.preferences.enabledModules.contains(module) },
                        set: { enabled in
                            model.updatePreferences { preferences in
                                if enabled {
                                    preferences.enabledModules.insert(module)
                                } else {
                                    preferences.enabledModules.remove(module)
                                }
                            }
                        }
                    )) {
                        Label(module.title, systemImage: module.symbol)
                    }
                    // Media is the point of the app.
                    .disabled(module == .media)
                }
            }

            Section("System") {
                Toggle("Launch at login", isOn: Binding(
                    get: { model.preferences.launchAtLogin },
                    set: { enabled in
                        loginItemError = LoginItem.setEnabled(enabled)
                        if loginItemError == nil {
                            model.updatePreferences { $0.launchAtLogin = enabled }
                        }
                    }
                ))
                if let loginItemError {
                    Text(loginItemError).font(.caption).foregroundStyle(.orange)
                }
                Toggle("Notify when a timer finishes", isOn: Binding(
                    get: { model.preferences.notifyOnTimerComplete },
                    set: { value in model.updatePreferences { $0.notifyOnTimerComplete = value } }
                ))

                LabeledContent("Automation") {
                    HStack {
                        Text(model.mediaPermissionDenied ? "Not allowed" : "Allowed")
                            .foregroundStyle(model.mediaPermissionDenied ? .orange : .secondary)
                        Button("Open Settings") { model.openAutomationSettings() }
                    }
                }
                Text("Cornice reads and controls Music and Spotify through macOS automation. It uses no private frameworks.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
    }
}

struct VisualizerSettings: View {
    @Bindable var model: AppModel

    var body: some View {
        Form {
            Section("Audio-reactive visualiser") {
                Toggle("Follow the music", isOn: Binding(
                    get: { model.preferences.audioVisualizerEnabled },
                    set: { value in model.updatePreferences { $0.audioVisualizerEnabled = value } }
                ))

                Text("""
                The visualiser reads the audio your Mac is playing and runs a \
                spectrum analysis on it, so the bars follow the actual music \
                rather than animating on a timer.

                macOS will ask for permission to record system audio the first \
                time you turn this on. Audio is analysed in memory and \
                discarded — nothing is recorded, written to disk, or sent \
                anywhere.
                """)
                .font(.caption)
                .foregroundStyle(.secondary)

                switch model.visualizerStatus {
                case .running:
                    Label("Capturing system audio", systemImage: "checkmark.circle.fill")
                        .foregroundStyle(.green)
                        .font(.caption)
                case .stopped:
                    Label("Off", systemImage: "circle")
                        .foregroundStyle(.secondary)
                        .font(.caption)
                case .failed(let reason):
                    VStack(alignment: .leading, spacing: 6) {
                        Label(reason.message, systemImage: "exclamationmark.triangle")
                            .foregroundStyle(.orange)
                            .font(.caption)
                            .fixedSize(horizontal: false, vertical: true)
                        if reason == .permissionDenied {
                            Button("Open Privacy Settings") { model.openAudioRecordingSettings() }
                        }
                    }
                }
            }

            Section("Timers") {
                Text("Presets shown in the Timers panel.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                HStack {
                    ForEach(model.preferences.timerPresetsMinutes, id: \.self) { minutes in
                        Text(verbatim: "\(minutes)m")
                            .font(.caption.monospacedDigit())
                            .padding(.horizontal, 8)
                            .padding(.vertical, 3)
                            .background(Capsule().fill(Color.secondary.opacity(0.15)))
                    }
                    Spacer()
                }
            }

            Section("Refresh") {
                LabeledContent("Player polling") {
                    HStack {
                        Slider(
                            value: Binding(
                                get: { model.preferences.mediaRefreshInterval },
                                set: { value in model.updatePreferences { $0.mediaRefreshInterval = value } }
                            ),
                            in: 0.25...5
                        )
                        Text(String(format: "%.2fs", model.preferences.mediaRefreshInterval))
                            .font(.caption.monospacedDigit())
                            .frame(width: 48, alignment: .trailing)
                    }
                }
                Text("The playhead is advanced locally between polls, so a slower interval does not make the scrubber stutter.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
    }
}

struct AboutSettings: View {
    @Bindable var model: AppModel

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Cornice")
                .font(.title2.weight(.semibold))
            Text("A media surface for the MacBook notch.")
                .foregroundStyle(.secondary)

            Divider()

            Text("This Mac").font(.headline)

            Grid(alignment: .leading, horizontalSpacing: 12, verticalSpacing: 6) {
                if let hardware = model.hardware {
                    row("Model", hardware.catalogName ?? hardware.marketingName ?? "Unknown")
                    row("Identifier", hardware.modelIdentifier)
                    if let chip = hardware.chip { row("Chip", chip) }
                }
                if let profile = model.notchProfile {
                    row("Display", "\(Int(profile.screenFrame.width)) × \(Int(profile.screenFrame.height)) pt")
                    row("Notch", "\(Int(profile.rect.width)) × \(Int(profile.rect.height)) pt")
                    row("Measured by", sourceDescription(profile.source))
                }
            }
            .font(.callout)

            Text("""
            The notch is measured on this display rather than looked up by \
            model. Its size in points changes with the scaled resolution you \
            pick in Displays settings, so the same MacBook reports different \
            numbers in different modes.
            """)
            .font(.caption)
            .foregroundStyle(.secondary)
            .fixedSize(horizontal: false, vertical: true)

            Spacer()

            Text("Keyboard shortcut: ⌥⌘D")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
        .padding(16)
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    @ViewBuilder
    private func row(_ label: String, _ value: String) -> some View {
        GridRow {
            Text(label).foregroundStyle(.secondary)
            Text(value).textSelection(.enabled)
        }
    }

    private func sourceDescription(_ source: NotchSource) -> String {
        switch source {
        case .measured: "Measured from this display"
        case .catalogFallback: "Derived from the safe-area inset"
        case .syntheticCenter: "No notch — centred in the menu bar"
        }
    }
}
