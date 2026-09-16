import AppKit
import Observation
import SwiftUI
import CorniceKit

/// Whether the surface is showing its collapsed or expanded form.
enum SurfaceState: Equatable {
    case collapsed
    case expanded
}

/// All observable application state.
///
/// One `@Observable` on the main actor, holding `Loadable` values fed by
/// per-module refresh tasks. It is deliberately a coordinator, not a worker:
/// every actual operation is delegated to a service in the container, so this
/// type contains scheduling and state transitions and nothing else. That is
/// what keeps "which git command runs" out of the view layer.
@MainActor
@Observable
final class AppModel {

    // MARK: - Configuration

    private(set) var preferences: Preferences = Preferences()

    // MARK: - Surface

    private(set) var surfaceState: SurfaceState = .collapsed
    /// Whether the pointer is over the surface. Owned by the window controller,
    /// which tracks it against the window's own bounds rather than through
    /// SwiftUI hover state — see `NotchContentView`.
    private(set) var isHovering = false
    var activeModule: ModuleKind = .repository

    /// Geometry of the display the surface is docked to.
    private(set) var notchProfile: NotchProfile?
    private(set) var hardware: HardwareIdentity?

    // MARK: - Module state

    private(set) var repository: Loadable<GitRepositorySnapshot> = .idle
    private(set) var ports: Loadable<[PortStatus]> = .idle
    private(set) var github: Loadable<GitHubDigest> = .idle
    private(set) var containers: Loadable<[ContainerSummary]> = .idle
    private(set) var dockerAvailability: DockerAvailability = .notInstalled
    private(set) var telemetry = TelemetryHistory(capacity: 48)
    private(set) var focus = FocusTimer()
    private(set) var commandRuns: [CommandRun] = []
    private(set) var cacheSavings: Double = 0

    /// Set when a destructive action is awaiting confirmation.
    var pendingConfirmation: PendingConfirmation?

    struct PendingConfirmation: Identifiable {
        let id = UUID()
        let title: String
        let message: String
        let detail: String?
        let confirmLabel: String
        let isDestructive: Bool
        let action: @MainActor () async -> Void
    }

    // MARK: - Dependencies

    /// Internal rather than private so the actions extension can reach it.
    let serviceContainer: ServiceContainer
    private var refreshTasks: [ModuleKind: Task<Void, Never>] = [:]
    /// Guards against a second manual refresh starting while one is running.
    private var manualRefreshes: Set<ModuleKind> = []
    private var copyConfirmationTask: Task<Void, Never>?

    init(services: ServiceContainer) {
        self.serviceContainer = services
    }

    // MARK: - Mutators for the actions extension

    // Observable state is `private(set)` so it only ever changes through a
    // named operation. These are the narrow seams `AppModel+Actions` writes
    // through, rather than making every property publicly settable.

    func applyPreferences(_ updated: Preferences) {
        preferences = updated
        // Picking up a new configured duration mid-session would move a
        // deadline the user is already counting down against, so it only
        // applies while the timer is idle.
        if case .idle = focus.state {
            focus.setDuration(minutes: updated.focusDurationMinutes)
        }
    }

    func applyFocus(_ updated: FocusTimer) {
        focus = updated
    }

    func mutateFocus(_ mutate: (inout FocusTimer) -> Void) {
        var copy = focus
        mutate(&copy)
        focus = copy
    }

    func clearRepositoryState() {
        repository = .idle
    }

    func clearGitHubState() {
        github = .idle
        cacheSavings = 0
    }

    func appendCommandRun(_ run: CommandRun) {
        commandRuns.insert(run, at: 0)
        // The panel shows a short history; an unbounded list would grow for as
        // long as the app runs.
        if commandRuns.count > 12 {
            commandRuns.removeLast(commandRuns.count - 12)
        }
    }

    func replaceCommandRun(id: UUID, with run: CommandRun) {
        guard let index = commandRuns.firstIndex(where: { $0.id == id }) else {
            appendCommandRun(run)
            return
        }
        commandRuns[index] = run
    }

    /// Brief acknowledgement that something was copied.
    ///
    /// The panel does not take focus and there is no status area to write to,
    /// so without this a copy button gives no feedback at all and people click
    /// it twice to be sure.
    private(set) var copyConfirmation: String?

    func flashCopyConfirmation(_ description: String) {
        copyConfirmation = description
        copyConfirmationTask?.cancel()
        copyConfirmationTask = Task { [weak self] in
            try? await Task.sleep(for: .seconds(1.6))
            guard !Task.isCancelled else { return }
            self?.copyConfirmation = nil
        }
    }

    // MARK: - Lifecycle

    /// Loads preferences and starts the refresh loops.
    func start() async {
        preferences = await serviceContainer.preferences.load()
        focus.setDuration(minutes: preferences.focusDurationMinutes)
        hardware = await serviceContainer.hardware.identity()
        Log.app.notice("running on \(self.hardware?.displayName ?? "unknown", privacy: .public)")
        restartRefreshLoops()
    }

    /// Cancels every loop. Called on termination and whenever the module set changes.
    func stopRefreshLoops() {
        for task in refreshTasks.values { task.cancel() }
        refreshTasks.removeAll()
    }

    // MARK: - Surface transitions

    func expand() {
        guard surfaceState != .expanded else { return }
        surfaceState = .expanded
        // Expanding is a strong signal that the user wants current data, so the
        // visible module refreshes immediately rather than waiting for its tick.
        refreshNow(activeModule, userInitiated: true)
        // Telemetry runs at a higher rate while visible; restart its loop to
        // pick up the faster cadence.
        restartLoop(for: .telemetry)
    }

    func collapse() {
        guard surfaceState != .collapsed else { return }
        surfaceState = .collapsed
        pendingConfirmation = nil
        restartLoop(for: .telemetry)
    }

    func toggle() {
        surfaceState == .expanded ? collapse() : expand()
    }

    func setHovering(_ hovering: Bool) {
        isHovering = hovering
    }

    func select(module: ModuleKind) {
        guard activeModule != module else { return }
        activeModule = module
        refreshNow(module, userInitiated: true)
    }

    // MARK: - Geometry

    func updateGeometry(_ profile: NotchProfile?) {
        guard notchProfile != profile else { return }
        notchProfile = profile
        if let profile {
            Log.window.notice("geometry: \(profile.debugSummary, privacy: .public)")
        }
    }

    // MARK: - Refresh scheduling

    /// Starts a loop per enabled module.
    ///
    /// Each module gets an independent task so one failing integration cannot
    /// stall the others: a hung Docker daemon must not stop the git panel
    /// updating. Cancelling and rebuilding the whole set on a preference change
    /// is cheap and avoids having to reason about partially-updated schedules.
    func restartRefreshLoops() {
        stopRefreshLoops()
        for module in preferences.enabledModules {
            restartLoop(for: module)
        }
    }

    private func restartLoop(for module: ModuleKind) {
        refreshTasks[module]?.cancel()
        guard preferences.enabledModules.contains(module) else { return }

        refreshTasks[module] = Task { [weak self] in
            guard let self else { return }
            while !Task.isCancelled {
                await self.refresh(module, userInitiated: false)
                let interval = await self.interval(for: module)
                // A cancelled sleep exits the loop rather than throwing onward.
                do { try await Task.sleep(for: .seconds(interval)) } catch { return }
            }
        }
    }

    /// Refresh cadence, adjusted for whether the panel is actually on screen.
    ///
    /// The single most effective thing this app does for idle cost: a collapsed
    /// panel has no visible telemetry, so sampling it several times a second
    /// would be pure waste. Modules whose collapsed state shows nothing back
    /// right off; modules that feed the collapsed indicators keep their cadence.
    private func interval(for module: ModuleKind) -> Double {
        let isVisible = surfaceState == .expanded
        switch module {
        case .telemetry:
            // Only drawn when expanded. Collapsed, a slow trickle keeps the
            // sparkline populated for when it opens.
            return isVisible ? preferences.telemetryRefreshInterval : 15
        case .repository:
            return preferences.repositoryRefreshInterval
        case .servers:
            return preferences.serverRefreshInterval
        case .github:
            return preferences.githubRefreshInterval
        case .containers:
            return isVisible ? 10 : 45
        case .commands, .focus:
            // Event-driven, not polled. A long sleep keeps the task parked.
            return 3600
        }
    }

    /// Runs one refresh for a module, off the main actor, folding the result back.
    private func refresh(_ module: ModuleKind, userInitiated: Bool) async {
        switch module {
        case .repository: await refreshRepository()
        case .servers: await refreshPorts()
        case .github: await refreshGitHub(userInitiated: userInitiated)
        case .telemetry: await refreshTelemetry()
        case .containers: await refreshContainers()
        case .commands, .focus: return
        }
    }

    /// Fire-and-forget refresh, used by buttons and by `expand()`.
    func refreshNow(_ module: ModuleKind, userInitiated: Bool = true) {
        guard preferences.enabledModules.contains(module) else { return }
        guard !manualRefreshes.contains(module) else { return }
        manualRefreshes.insert(module)
        Task { [weak self] in
            await self?.refresh(module, userInitiated: userInitiated)
            self?.manualRefreshes.remove(module)
        }
    }

    // MARK: - Module refreshes

    private func refreshRepository() async {
        guard let path = preferences.activeRepositoryPath else {
            repository = .idle
            return
        }
        repository = repository.beginRefresh()
        do {
            let snapshot = try await serviceContainer.git.snapshot(ofRepositoryAt: path)
            // The active repository may have changed while the command ran.
            guard preferences.activeRepositoryPath == path else { return }
            repository = .loaded(snapshot)
        } catch let error as ServiceError {
            guard preferences.activeRepositoryPath == path else { return }
            repository = repository.resolve(.failure(error))
        } catch {
            repository = repository.resolve(.failure(.cancelled))
        }
    }

    private func refreshPorts() async {
        let monitored = preferences.monitoredPorts
        guard !monitored.isEmpty else {
            ports = .loaded([])
            return
        }
        ports = ports.beginRefresh()
        do {
            ports = .loaded(try await serviceContainer.ports.scan(ports: monitored))
        } catch let error as ServiceError {
            ports = ports.resolve(.failure(error))
        } catch {
            ports = ports.resolve(.failure(.cancelled))
        }
    }

    private func refreshGitHub(userInitiated: Bool) async {
        github = github.beginRefresh()
        let previousFailures = Set((github.value?.failedRuns ?? []).map(\.id))
        do {
            let digest = try await serviceContainer.github.digest(
                watching: preferences.githubRepositories,
                userInitiated: userInitiated
            )
            github = .loaded(digest)
            cacheSavings = await serviceContainer.github.cacheStatistics().savedFraction
            notifyAboutNewFailures(in: digest, previouslyKnown: previousFailures)
        } catch let error as ServiceError {
            github = github.resolve(.failure(error))
        } catch {
            github = github.resolve(.failure(.cancelled))
        }
    }

    private func refreshTelemetry() async {
        telemetry.append(await serviceContainer.telemetry.sample())
    }

    private func refreshContainers() async {
        dockerAvailability = await serviceContainer.docker.availability()
        guard dockerAvailability.canQuery else {
            containers = .loaded([])
            return
        }
        containers = containers.beginRefresh()
        do {
            containers = .loaded(try await serviceContainer.docker.containers())
        } catch let error as ServiceError {
            containers = containers.resolve(.failure(error))
        } catch {
            containers = containers.resolve(.failure(.cancelled))
        }
    }

    // MARK: - Notifications

    /// Notifies once per newly-failing run.
    ///
    /// Diffing against the previously-known set matters: without it, every
    /// refresh while a run stays red would fire another notification, and the
    /// user would turn the feature off within the hour.
    private func notifyAboutNewFailures(in digest: GitHubDigest, previouslyKnown: Set<Int>) {
        guard preferences.notifyOnFailedChecks else { return }
        for run in digest.failedRuns where !previouslyKnown.contains(run.id) {
            NotificationPresenter.shared.checkFailed(run)
        }
    }
}
