import SwiftUI
import CorniceKit

// MARK: - GitHub

struct GitHubSettings: View {
    @Bindable var model: AppModel

    @State private var token = ""
    @State private var newRepository = ""
    @State private var status: Status?
    @State private var isVerifying = false

    private enum Status {
        case failure(String)
        case success(String)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("GitHub")
                .font(.headline)

            if let login = model.preferences.githubLogin {
                connected(login: login)
            } else {
                connectForm
            }

            Divider()

            Text("Watched repositories")
                .font(.headline)
            Text("Cornice shows the most recent workflow run for each. Pull requests are found across all your repositories without listing them here.")
                .font(.caption)
                .foregroundStyle(.secondary)

            List {
                ForEach(model.preferences.githubRepositories, id: \.self) { slug in
                    HStack {
                        Text(slug).font(.body.monospaced())
                        Spacer()
                        Button {
                            model.removeWatchedRepository(slug)
                        } label: {
                            Image(systemName: "minus.circle")
                        }
                        .buttonStyle(.borderless)
                    }
                }
            }
            .listStyle(.inset)
            .frame(minHeight: 90)

            HStack {
                TextField("owner/repository", text: $newRepository)
                    .onSubmit { addRepository() }
                Button("Add") { addRepository() }
                    .disabled(newRepository.isEmpty)
            }
        }
        .padding(16)
    }

    private func connected(login: String) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 6) {
                Image(systemName: "checkmark.circle.fill").foregroundStyle(.green)
                Text("Connected as **\(login)**")
                Spacer()
                Button("Disconnect") {
                    Task { await model.disconnectGitHub() }
                }
            }
            Text("The token is stored in your login Keychain, marked device-only so it is never synced to iCloud or restored onto another Mac.")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
    }

    private var connectForm: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Paste a personal access token. Cornice only reads — the `repo` scope for private repositories, or `public_repo` if you only need public ones.")
                .font(.caption)
                .foregroundStyle(.secondary)

            HStack {
                // A secure field, so the token is not shoulder-surfable and is
                // excluded from screenshots of this window.
                SecureField("ghp_…", text: $token)
                    .onSubmit { connect() }
                Button(isVerifying ? "Checking…" : "Connect") { connect() }
                    .disabled(token.isEmpty || isVerifying)
            }

            Text("The token is verified against GitHub before it is saved, and is written only to the Keychain — never to the settings file and never to a log.")
                .font(.caption)
                .foregroundStyle(.secondary)

            Link("Create a token on GitHub",
                 destination: URL(string: "https://github.com/settings/tokens/new?scopes=repo&description=Cornice")!)
                .font(.caption)

            if let status {
                switch status {
                case .failure(let message):
                    Text(message).font(.caption).foregroundStyle(.red)
                case .success(let message):
                    Text(message).font(.caption).foregroundStyle(.green)
                }
            }
        }
    }

    private func connect() {
        isVerifying = true
        status = nil
        Task {
            let failure = await model.connectGitHub(token: token)
            isVerifying = false
            if let failure {
                status = .failure(failure)
            } else {
                // Clear the field immediately: the token is in the Keychain now
                // and there is no reason for it to stay in view state.
                token = ""
                status = .success("Connected.")
            }
        }
    }

    private func addRepository() {
        if let failure = model.addWatchedRepository(newRepository) {
            status = .failure(failure)
        } else {
            newRepository = ""
            status = nil
        }
    }
}

// MARK: - Commands

struct CommandSettings: View {
    @Bindable var model: AppModel
    @State private var editing: CommandSpec?

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Commands")
                .font(.headline)
            Text("Commands run exactly as written here, in the active repository unless a working directory is set. Cornice never creates, imports, or suggests commands.")
                .font(.caption)
                .foregroundStyle(.secondary)

            List {
                ForEach(model.preferences.commands) { spec in
                    HStack {
                        VStack(alignment: .leading, spacing: 1) {
                            HStack(spacing: 5) {
                                Text(spec.name)
                                if spec.mode == .shell {
                                    Text("sh")
                                        .font(.caption2)
                                        .padding(.horizontal, 4)
                                        .padding(.vertical, 1)
                                        .background(Color.secondary.opacity(0.2), in: Capsule())
                                }
                                if spec.requiresConfirmation {
                                    Image(systemName: "hand.raised")
                                        .font(.caption2)
                                        .foregroundStyle(.secondary)
                                        .help("Asks before running")
                                }
                            }
                            Text(spec.displayCommand)
                                .font(.caption.monospaced())
                                .foregroundStyle(.secondary)
                                .lineLimit(1)
                        }
                        Spacer()
                        Button { editing = spec } label: { Image(systemName: "pencil") }
                            .buttonStyle(.borderless)
                        Button {
                            model.updatePreferences { preferences in
                                preferences.commands.removeAll { $0.id == spec.id }
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
                Button("Add Command…") {
                    editing = CommandSpec(name: "", mode: .direct, executable: "")
                }
                Spacer()
            }
        }
        .padding(16)
        .sheet(item: $editing) { spec in
            CommandEditor(spec: spec) { saved in
                model.updatePreferences { preferences in
                    if let index = preferences.commands.firstIndex(where: { $0.id == saved.id }) {
                        preferences.commands[index] = saved
                    } else {
                        preferences.commands.append(saved)
                    }
                }
                editing = nil
            } onCancel: {
                editing = nil
            }
        }
    }
}

/// Editor for one command.
///
/// Validation runs on every keystroke and the Save button stays disabled until
/// the spec is valid, so an invalid command cannot be persisted and then fail
/// confusingly at the moment you press Run.
struct CommandEditor: View {
    @State private var spec: CommandSpec
    let onSave: (CommandSpec) -> Void
    let onCancel: () -> Void

    init(spec: CommandSpec, onSave: @escaping (CommandSpec) -> Void, onCancel: @escaping () -> Void) {
        _spec = State(initialValue: spec)
        self.onSave = onSave
        self.onCancel = onCancel
    }

    private var validationError: String? { spec.validate() }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text(spec.name.isEmpty ? "New Command" : "Edit Command")
                .font(.headline)

            Form {
                TextField("Name", text: $spec.name)

                Picker("Mode", selection: $spec.mode) {
                    Text("Run a program").tag(CommandSpec.Mode.direct)
                    Text("Shell script").tag(CommandSpec.Mode.shell)
                }
                .pickerStyle(.segmented)

                switch spec.mode {
                case .direct:
                    TextField("Program", text: $spec.executable, prompt: Text("npm"))
                    TextField("Arguments", text: Binding(
                        get: { spec.arguments.joined(separator: " ") },
                        // Split on whitespace only. Direct mode passes each
                        // argument to execve verbatim, so there is no quoting
                        // to honour and nothing is re-interpreted.
                        set: { spec.arguments = $0.split(separator: " ").map(String.init) }
                    ), prompt: Text("run test"))
                    Text("Arguments are passed directly to the program. Shell syntax such as && or | will not work here — use shell mode for that.")
                        .font(.caption)
                        .foregroundStyle(.secondary)

                case .shell:
                    TextField("Script", text: $spec.script, prompt: Text("npm ci && npm test"), axis: .vertical)
                        .lineLimit(2...5)
                        .font(.body.monospaced())
                    Text("Runs through /bin/sh. Only what you type here is executed — nothing is interpolated into it.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }

                TextField("Working directory", text: Binding(
                    get: { spec.workingDirectory ?? "" },
                    set: { spec.workingDirectory = $0.isEmpty ? nil : $0 }
                ), prompt: Text("Active repository"))

                Toggle("Ask before running", isOn: $spec.requiresConfirmation)

                LabeledContent("Timeout") {
                    HStack {
                        Slider(value: $spec.timeout, in: 5...3600)
                        Text("\(Int(spec.timeout))s")
                            .font(.caption.monospacedDigit())
                            .frame(width: 48, alignment: .trailing)
                    }
                }
            }
            .formStyle(.grouped)

            if let validationError {
                Label(validationError, systemImage: "exclamationmark.triangle")
                    .font(.caption)
                    .foregroundStyle(.orange)
            }

            HStack {
                Spacer()
                Button("Cancel", action: onCancel)
                Button("Save") { onSave(spec) }
                    .keyboardShortcut(.defaultAction)
                    .disabled(validationError != nil)
            }
        }
        .padding(16)
        .frame(width: 460)
    }
}

// MARK: - About

struct AboutSettings: View {
    @Bindable var model: AppModel

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Cornice")
                .font(.title2.weight(.semibold))
            Text("A developer command surface along the top edge of your Mac.")
                .foregroundStyle(.secondary)

            Divider()

            Text("This Mac")
                .font(.headline)

            Grid(alignment: .leading, horizontalSpacing: 12, verticalSpacing: 6) {
                if let hardware = model.hardware {
                    row("Model", hardware.catalogName ?? hardware.marketingName ?? "Unknown")
                    row("Identifier", hardware.modelIdentifier)
                    if let chip = hardware.chip { row("Chip", chip) }
                }
                if let profile = model.notchProfile {
                    row("Display", "\(Int(profile.screenFrame.width)) × \(Int(profile.screenFrame.height)) pt")
                    row("Notch", "\(Int(profile.rect.width)) × \(Int(profile.rect.height)) pt")
                    row("Share of width", String(format: "%.2f%%", profile.widthFraction * 100))
                    row("Source", sourceDescription(profile.source))
                }
            }
            .font(.callout)

            Text(explanation)
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)

            Spacer()

            HStack {
                Text("Keyboard shortcut: ⌥⌘D")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Spacer()
            }
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

    private var explanation: String {
        """
        The notch is measured on this display rather than looked up by model. \
        Its size in points changes with the scaled resolution you choose in \
        Displays settings, so the same MacBook reports different numbers in \
        different modes — a per-model table would be wrong for anyone not using \
        the default scaling.
        """
    }
}
