import AppKit
import CorniceKit

/// User-initiated operations.
///
/// Split from `AppModel` so the refresh/state machinery and the verb list stay
/// separately readable — this file answers "what can the user do?", the other
/// answers "how does state change over time?".
@MainActor
extension AppModel {

    // MARK: - Preferences

    /// Mutates preferences and persists the result.
    ///
    /// Every settings change funnels through here so there is exactly one place
    /// that writes, one place that re-sanitises, and one place that decides
    /// whether the refresh loops need rebuilding. Scattering `save()` calls
    /// through the settings views is how half of them end up forgotten.
    func updatePreferences(_ mutate: (inout Preferences) -> Void) {
        var updated = preferences
        mutate(&updated)
        let sanitized = updated.sanitized()
        guard sanitized != preferences else { return }

        let schedulingChanged = sanitized.enabledModules != preferences.enabledModules
            || sanitized.repositoryRefreshInterval != preferences.repositoryRefreshInterval
            || sanitized.serverRefreshInterval != preferences.serverRefreshInterval
            || sanitized.githubRefreshInterval != preferences.githubRefreshInterval
            || sanitized.telemetryRefreshInterval != preferences.telemetryRefreshInterval

        applyPreferences(sanitized)

        Task { [services = self.serviceContainer] in
            do { try await services.preferences.save(sanitized) }
            catch { Log.settings.error("could not save preferences: \(error.localizedDescription, privacy: .public)") }
        }

        if schedulingChanged { restartRefreshLoops() }
    }

    // MARK: - Repositories

    /// Opens a folder picker and adds the chosen repository.
    ///
    /// The picker is the only way a repository path enters the app. There is no
    /// text field to paste a path into and no scanning of the filesystem for
    /// repositories — which keeps the app's view of the disk limited to folders
    /// the user explicitly handed it.
    func chooseRepository() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.allowsMultipleSelection = false
        panel.prompt = "Add Repository"
        panel.message = "Choose a folder inside the Git repository you want to track."

        // The app is an accessory with no windows of its own, so the picker
        // needs the app brought forward or it opens behind everything.
        NSApp.activate(ignoringOtherApps: true)
        guard panel.runModal() == .OK, let url = panel.url else { return }

        Task { [services = self.serviceContainer] in
            do {
                // Resolve to the repository root: the user may well have picked
                // a subdirectory, and tracking `repo/Sources` would show the
                // same data under a misleading name.
                let root = try await services.git.repositoryRoot(containing: url.path)
                self.addRepository(path: root)
            } catch let error as ServiceError {
                self.presentAlert(
                    title: "Not a Git repository",
                    message: error.detail
                )
            } catch {
                self.presentAlert(title: "Could not read that folder", message: "\(error)")
            }
        }
    }

    func addRepository(path: String) {
        updatePreferences { preferences in
            preferences.repositoryPaths.removeAll { $0 == path }
            preferences.repositoryPaths.insert(path, at: 0)
            preferences.activeRepositoryPath = path
        }
        refreshNow(.repository)
    }

    func removeRepository(path: String) {
        updatePreferences { preferences in
            preferences.repositoryPaths.removeAll { $0 == path }
            if preferences.activeRepositoryPath == path {
                preferences.activeRepositoryPath = preferences.repositoryPaths.first
            }
        }
        refreshNow(.repository)
    }

    func selectRepository(path: String) {
        guard preferences.activeRepositoryPath != path else { return }
        updatePreferences { $0.activeRepositoryPath = path }
        // Clear immediately rather than showing the previous repository's data
        // under the new repository's name while the command runs.
        clearRepositoryState()
        refreshNow(.repository)
    }

    // MARK: - Repository actions

    func copyBranchName() {
        guard let branch = repository.value?.branch else { return }
        copyToPasteboard(branch, describedAs: "Branch name")
    }

    func copyCommitHash() {
        guard let hash = repository.value?.lastCommit?.hash else { return }
        copyToPasteboard(hash, describedAs: "Commit hash")
    }

    func revealRepositoryInFinder() {
        guard let path = repository.value?.path else { return }
        SystemActions.revealInFinder(path: path)
    }

    func openRepositoryInTerminal() {
        guard let path = repository.value?.path else { return }
        SystemActions.openInTerminal(path: path)
    }

    func openRepositoryInEditor() {
        guard let path = repository.value?.path else { return }
        SystemActions.open(path: path, in: preferences.editor) { [weak self] message in
            self?.presentAlert(title: "Could not open editor", message: message)
        }
    }

    // MARK: - Ports

    func openPort(_ status: PortStatus) {
        guard let url = status.localURL else { return }
        NSWorkspace.shared.open(url)
    }

    func copyPortURL(_ status: PortStatus) {
        guard let url = status.localURL else { return }
        copyToPasteboard(url.absoluteString, describedAs: "Local URL")
    }

    /// Asks before terminating a listener.
    ///
    /// Stopping a dev server can discard unsaved in-memory state, so it is
    /// confirmed, the confirmation names the process and port explicitly, and
    /// the signal sent is SIGTERM so the server can shut down cleanly.
    func requestTerminate(_ status: PortStatus) {
        guard let listener = status.listener else { return }
        pendingConfirmation = PendingConfirmation(
            title: "Stop \(listener.command)?",
            message: "This sends SIGTERM to process \(listener.pid), which is listening on port \(status.port).",
            detail: "Unsaved state in that process may be lost.",
            confirmLabel: "Stop Server",
            isDestructive: true
        ) { [weak self] in
            guard let self else { return }
            do {
                try await self.serviceContainer.ports.terminate(pid: listener.pid)
                self.refreshNow(.servers)
            } catch let error as ServiceError {
                self.presentAlert(title: "Could not stop the process", message: error.detail)
            } catch {
                self.presentAlert(title: "Could not stop the process", message: "\(error)")
            }
        }
    }

    // MARK: - Containers

    func openContainerPort(_ port: Int) {
        guard let url = URL(string: "http://localhost:\(port)") else { return }
        NSWorkspace.shared.open(url)
    }

    func copyContainerName(_ container: ContainerSummary) {
        copyToPasteboard(container.name, describedAs: "Container name")
    }

    func requestContainerAction(_ container: ContainerSummary, restart: Bool) {
        pendingConfirmation = PendingConfirmation(
            title: restart ? "Restart \(container.name)?" : "Stop \(container.name)?",
            message: restart
                ? "The container will be stopped and started again."
                : "The container will be stopped. Its data volumes are not affected.",
            detail: "\(container.image) · \(container.shortID)",
            confirmLabel: restart ? "Restart" : "Stop",
            isDestructive: !restart
        ) { [weak self] in
            guard let self else { return }
            do {
                if restart {
                    try await self.serviceContainer.docker.restart(containerID: container.id)
                } else {
                    try await self.serviceContainer.docker.stop(containerID: container.id)
                }
                self.refreshNow(.containers)
            } catch let error as ServiceError {
                self.presentAlert(title: "Docker command failed", message: error.detail)
            } catch {
                self.presentAlert(title: "Docker command failed", message: "\(error)")
            }
        }
    }

    // MARK: - GitHub

    func openPullRequest(_ pullRequest: PullRequest) {
        NSWorkspace.shared.open(pullRequest.htmlURL)
    }

    func openWorkflowRun(_ run: WorkflowRun) {
        NSWorkspace.shared.open(run.htmlURL)
    }

    /// Validates a token, then stores it in the Keychain.
    ///
    /// Verify-before-store, so a typo is reported immediately instead of
    /// becoming an empty panel later. The token is passed straight to the
    /// verifier and the store; it is never held in observable state, never
    /// written to preferences, and never logged.
    func connectGitHub(token: String) async -> String? {
        let trimmed = token.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return "Paste a personal access token." }

        do {
            let user = try await serviceContainer.github.verifyToken(trimmed)
            try await serviceContainer.credentials.store(
                trimmed, for: GitHubClient.credentialAccount
            )
            updatePreferences { $0.githubLogin = user.login }
            refreshNow(.github)
            return nil
        } catch let error as ServiceError {
            return error.detail
        } catch {
            return "Could not reach GitHub."
        }
    }

    func disconnectGitHub() async {
        try? await serviceContainer.credentials.delete(account: GitHubClient.credentialAccount)
        updatePreferences { $0.githubLogin = nil }
        clearGitHubState()
    }

    func addWatchedRepository(_ slug: String) -> String? {
        let trimmed = slug.trimmingCharacters(in: .whitespacesAndNewlines)
        guard GitHubSlug.isValid(trimmed) else {
            return "Use the owner/repository form, for example acme/tools."
        }
        guard !preferences.githubRepositories.contains(trimmed) else {
            return "That repository is already being watched."
        }
        updatePreferences { $0.githubRepositories.append(trimmed) }
        refreshNow(.github)
        return nil
    }

    func removeWatchedRepository(_ slug: String) {
        updatePreferences { $0.githubRepositories.removeAll { $0 == slug } }
        refreshNow(.github)
    }

    // MARK: - Focus timer

    func toggleFocusTimer() {
        mutateFocus { $0.toggle() }
    }

    func resetFocusTimer() {
        mutateFocus { $0.reset() }
    }

    func setFocusDuration(minutes: Int) {
        mutateFocus { $0.setDuration(minutes: minutes) }
        updatePreferences { $0.focusDurationMinutes = minutes }
    }

    /// Advances the timer. Driven by the UI's display timer, which is a repaint
    /// trigger — the timer's own state is derived from wall-clock time, so a
    /// missed tick changes nothing.
    func tickFocusTimer() {
        var timer = focus
        let completed = timer.tick()
        applyFocus(timer)
        if completed, preferences.notifyOnFocusComplete {
            NotificationPresenter.shared.focusComplete(minutes: Int(timer.state.total / 60))
        }
    }

    // MARK: - Commands

    func run(_ spec: CommandSpec) {
        guard spec.isValid else { return }
        if spec.requiresConfirmation {
            pendingConfirmation = PendingConfirmation(
                title: "Run “\(spec.name)”?",
                message: spec.mode == .shell
                    ? "This runs the following through /bin/sh:"
                    : "This runs the following program directly:",
                // The exact command, verbatim and in full. A confirmation that
                // summarises what it is about to run is not a confirmation.
                detail: spec.displayCommand,
                confirmLabel: "Run",
                isDestructive: false
            ) { [weak self] in
                await self?.execute(spec)
            }
        } else {
            Task { await execute(spec) }
        }
    }

    private func execute(_ spec: CommandSpec) async {
        let placeholder = CommandRun(
            specID: spec.id, name: spec.name, displayCommand: spec.displayCommand
        )
        appendCommandRun(placeholder)

        let finished = await serviceContainer.commands.execute(
            spec, defaultWorkingDirectory: preferences.activeRepositoryPath
        )
        replaceCommandRun(id: placeholder.id, with: finished)

        // A command that changes the tree or starts a server should be
        // reflected without waiting for the next poll.
        refreshNow(.repository, userInitiated: false)
        refreshNow(.servers, userInitiated: false)
    }

    // MARK: - Confirmation

    func confirmPending() {
        guard let pending = pendingConfirmation else { return }
        pendingConfirmation = nil
        Task { await pending.action() }
    }

    func cancelPending() {
        pendingConfirmation = nil
    }

    // MARK: - Helpers

    func copyToPasteboard(_ value: String, describedAs description: String) {
        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()
        pasteboard.setString(value, forType: .string)
        // Logs the description, never the value: a commit subject or a URL can
        // carry information the user would not expect to find in a log.
        Log.app.debug("copied \(description, privacy: .public) to the pasteboard")
        flashCopyConfirmation(description)
    }

    func presentAlert(title: String, message: String) {
        let alert = NSAlert()
        alert.messageText = title
        alert.informativeText = message
        alert.alertStyle = .warning
        alert.addButton(withTitle: "OK")
        NSApp.activate(ignoringOtherApps: true)
        alert.runModal()
    }
}
