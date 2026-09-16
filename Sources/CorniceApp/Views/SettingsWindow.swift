import AppKit
import SwiftUI
import CorniceKit

/// Hosts settings in a conventional window.
///
/// Settings live in a real, resizable, focusable window rather than inside the
/// notch panel. The panel is non-activating and closes when the pointer leaves
/// it — which is right for glancing at state and completely wrong for typing a
/// token into a text field.
@MainActor
final class SettingsWindow {

    static let shared = SettingsWindow()

    private var window: NSWindow?

    private init() {}

    func show(model: AppModel, tab: SettingsTab = .general) {
        if let window {
            window.makeKeyAndOrderFront(nil)
            NSApp.activate(ignoringOtherApps: true)
            return
        }

        let view = SettingsView(model: model, initialTab: tab)
        let hosting = NSHostingController(rootView: view)
        let window = NSWindow(contentViewController: hosting)
        window.title = "Cornice Settings"
        window.styleMask = [.titled, .closable, .miniaturizable]
        window.setContentSize(NSSize(width: 520, height: 460))
        window.isReleasedWhenClosed = false
        window.center()
        window.delegate = WindowCloseObserver.shared
        WindowCloseObserver.shared.onClose = { [weak self] in self?.window = nil }

        self.window = window
        window.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }

    /// Tracks closing so the window is rebuilt next time rather than being
    /// re-shown with stale SwiftUI state.
    @MainActor
    private final class WindowCloseObserver: NSObject, NSWindowDelegate {
        static let shared = WindowCloseObserver()
        var onClose: (() -> Void)?

        func windowWillClose(_ notification: Notification) {
            onClose?()
        }
    }
}

enum SettingsTab: String, CaseIterable, Identifiable {
    case general = "General"
    case repositories = "Repositories"
    case servers = "Servers"
    case github = "GitHub"
    case commands = "Commands"
    case about = "About"

    var id: String { rawValue }

    var symbol: String {
        switch self {
        case .general: "gearshape"
        case .repositories: "folder"
        case .servers: "server.rack"
        case .github: "checkmark.seal"
        case .commands: "terminal"
        case .about: "info.circle"
        }
    }
}

struct SettingsView: View {
    @Bindable var model: AppModel
    let initialTab: SettingsTab

    @State private var tab: SettingsTab

    init(model: AppModel, initialTab: SettingsTab) {
        self.model = model
        self.initialTab = initialTab
        _tab = State(initialValue: initialTab)
    }

    var body: some View {
        TabView(selection: $tab) {
            GeneralSettings(model: model)
                .tabItem { Label(SettingsTab.general.rawValue, systemImage: SettingsTab.general.symbol) }
                .tag(SettingsTab.general)

            RepositorySettings(model: model)
                .tabItem { Label(SettingsTab.repositories.rawValue, systemImage: SettingsTab.repositories.symbol) }
                .tag(SettingsTab.repositories)

            ServerSettings(model: model)
                .tabItem { Label(SettingsTab.servers.rawValue, systemImage: SettingsTab.servers.symbol) }
                .tag(SettingsTab.servers)

            GitHubSettings(model: model)
                .tabItem { Label(SettingsTab.github.rawValue, systemImage: SettingsTab.github.symbol) }
                .tag(SettingsTab.github)

            CommandSettings(model: model)
                .tabItem { Label(SettingsTab.commands.rawValue, systemImage: SettingsTab.commands.symbol) }
                .tag(SettingsTab.commands)

            AboutSettings(model: model)
                .tabItem { Label(SettingsTab.about.rawValue, systemImage: SettingsTab.about.symbol) }
                .tag(SettingsTab.about)
        }
        .frame(width: 520, height: 460)
    }
}

// MARK: - General

struct GeneralSettings: View {
    @Bindable var model: AppModel
    @State private var loginItemError: String?

    var body: some View {
        Form {
            Section("Modules") {
                Text("Disabled modules stop refreshing entirely.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                ForEach(ModuleKind.allCases) { module in
                    Toggle(isOn: binding(for: module)) {
                        Label(module.title, systemImage: module.symbol)
                    }
                }
            }

            Section("Activation") {
                Picker("Open on", selection: Binding(
                    get: { model.preferences.activationStyle },
                    set: { style in model.updatePreferences { $0.activationStyle = style } }
                )) {
                    ForEach(ActivationStyle.allCases) { style in
                        Text(style.title).tag(style)
                    }
                }

                if model.preferences.activationStyle == .hover {
                    LabeledContent("Hover delay") {
                        HStack {
                            Slider(
                                value: Binding(
                                    get: { model.preferences.hoverDwell },
                                    set: { value in model.updatePreferences { $0.hoverDwell = value } }
                                ),
                                in: 0...1.0
                            )
                            Text(String(format: "%.2fs", model.preferences.hoverDwell))
                                .font(.caption.monospacedDigit())
                                .frame(width: 44, alignment: .trailing)
                        }
                    }
                    Text("A short delay stops the panel opening as the pointer crosses the menu bar.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }

                Toggle("Hide indicators when nothing needs attention", isOn: Binding(
                    get: { model.preferences.collapseWhenIdle },
                    set: { value in model.updatePreferences { $0.collapseWhenIdle = value } }
                ))
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
                    Text(loginItemError)
                        .font(.caption)
                        .foregroundStyle(.orange)
                }

                Toggle("Notify when a check starts failing", isOn: Binding(
                    get: { model.preferences.notifyOnFailedChecks },
                    set: { value in model.updatePreferences { $0.notifyOnFailedChecks = value } }
                ))
                Toggle("Notify when a focus session ends", isOn: Binding(
                    get: { model.preferences.notifyOnFocusComplete },
                    set: { value in model.updatePreferences { $0.notifyOnFocusComplete = value } }
                ))

                Picker("Open repositories in", selection: Binding(
                    get: { model.preferences.editor },
                    set: { editor in model.updatePreferences { $0.editor = editor } }
                )) {
                    ForEach(SystemActions.installedEditors()) { editor in
                        Text(editor.title).tag(editor)
                    }
                }
            }

            Section("Refresh intervals") {
                interval("Repository", \.repositoryRefreshInterval, range: 5...600)
                interval("Servers", \.serverRefreshInterval, range: 3...300)
                interval("GitHub", \.githubRefreshInterval, range: 60...3600)
                interval("Telemetry", \.telemetryRefreshInterval, range: 1...60)
                Text("GitHub is limited to once a minute at most. Responses are cached and revalidated with ETags, so most refreshes cost no API quota.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
    }

    private func binding(for module: ModuleKind) -> Binding<Bool> {
        Binding(
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
        )
    }

    private func interval(
        _ title: String,
        _ keyPath: WritableKeyPath<Preferences, Double>,
        range: ClosedRange<Double>
    ) -> some View {
        LabeledContent(title) {
            HStack {
                Slider(
                    value: Binding(
                        get: { model.preferences[keyPath: keyPath] },
                        set: { value in model.updatePreferences { $0[keyPath: keyPath] = value } }
                    ),
                    in: range
                )
                Text("\(Int(model.preferences[keyPath: keyPath]))s")
                    .font(.caption.monospacedDigit())
                    .frame(width: 44, alignment: .trailing)
            }
        }
    }
}

// MARK: - Repositories

struct RepositorySettings: View {
    @Bindable var model: AppModel

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Repositories")
                .font(.headline)
            Text("Cornice only reads folders you add here. It never scans your disk for repositories.")
                .font(.caption)
                .foregroundStyle(.secondary)

            List {
                ForEach(model.preferences.repositoryPaths, id: \.self) { path in
                    HStack {
                        Image(systemName: path == model.preferences.activeRepositoryPath
                              ? "largecircle.fill.circle" : "circle")
                            .foregroundStyle(path == model.preferences.activeRepositoryPath ? AnyShapeStyle(.tint) : AnyShapeStyle(.secondary))
                            .onTapGesture { model.selectRepository(path: path) }

                        VStack(alignment: .leading, spacing: 1) {
                            Text((path as NSString).lastPathComponent)
                            Text(Redaction.path(path))
                                .font(.caption)
                                .foregroundStyle(.secondary)
                                .lineLimit(1)
                                .truncationMode(.middle)
                        }

                        Spacer()

                        Button {
                            model.removeRepository(path: path)
                        } label: {
                            Image(systemName: "minus.circle")
                        }
                        .buttonStyle(.borderless)
                        .help("Stop tracking this repository")
                    }
                }
            }
            .listStyle(.inset)

            HStack {
                Button("Add Repository…") { model.chooseRepository() }
                Spacer()
            }
        }
        .padding(16)
    }
}

// MARK: - Servers

struct ServerSettings: View {
    @Bindable var model: AppModel
    @State private var newPort = ""
    @State private var newLabel = ""
    @State private var error: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Monitored ports")
                .font(.headline)
            Text("All monitored ports are checked with a single lsof call, so adding more costs nothing measurable.")
                .font(.caption)
                .foregroundStyle(.secondary)

            List {
                ForEach(model.preferences.monitoredPorts) { port in
                    HStack {
                        Text(verbatim: ":\(port.port)")
                            .font(.body.monospaced())
                            .frame(width: 60, alignment: .leading)
                        Text(port.label ?? "—")
                            .foregroundStyle(.secondary)
                        Spacer()
                        Button {
                            model.updatePreferences { preferences in
                                preferences.monitoredPorts.removeAll { $0.port == port.port }
                            }
                        } label: {
                            Image(systemName: "minus.circle")
                        }
                        .buttonStyle(.borderless)
                    }
                }
            }
            .listStyle(.inset)

            HStack {
                TextField("Port", text: $newPort)
                    .frame(width: 80)
                TextField("Label (optional)", text: $newLabel)
                Button("Add") { add() }
                    .disabled(newPort.isEmpty)
            }

            if let error {
                Text(error).font(.caption).foregroundStyle(.red)
            }
        }
        .padding(16)
    }

    private func add() {
        guard let port = Int(newPort.trimmingCharacters(in: .whitespaces)),
              (1...65_535).contains(port) else {
            error = "Enter a port between 1 and 65535."
            return
        }
        guard !model.preferences.monitoredPorts.contains(where: { $0.port == port }) else {
            error = "That port is already monitored."
            return
        }
        let label = newLabel.trimmingCharacters(in: .whitespaces)
        model.updatePreferences { preferences in
            preferences.monitoredPorts.append(
                MonitoredPort(port: port, label: label.isEmpty ? nil : label)
            )
        }
        newPort = ""
        newLabel = ""
        error = nil
        model.refreshNow(.servers)
    }
}
