import Foundation
import CorniceKit

/// Every service the app needs, in one injectable bundle.
///
/// Dependency injection by construction rather than by framework: the app has
/// one composition root (`AppDelegate`), roughly a dozen services, and no need
/// for runtime resolution. A container of `let` properties gives the testability
/// benefit — swap the whole set for scripted doubles — without a registry, a
/// resolver, or property-wrapper magic that has to be debugged later.
struct ServiceContainer: Sendable {
    let processRunner: any ProcessRunning
    let toolLocator: ToolLocator
    let git: any GitReading
    let ports: any PortMonitoring
    let telemetry: any TelemetryProbing
    let github: GitHubClient
    let docker: any DockerInspecting
    let commands: any CommandExecuting
    let credentials: any CredentialStoring
    let preferences: any PreferencesPersisting
    let hardware: HardwareIdentityProvider

    /// The real thing.
    static func live() -> ServiceContainer {
        let runner = SubprocessRunner()
        let locator = ToolLocator()
        let credentials = KeychainCredentialStore()
        return ServiceContainer(
            processRunner: runner,
            toolLocator: locator,
            git: GitService(runner: runner, locator: locator),
            ports: PortMonitor(runner: runner, locator: locator),
            telemetry: HostTelemetryProbe(),
            github: GitHubClient(
                transport: URLSession(configuration: .ephemeral),
                credentials: credentials
            ),
            docker: DockerService(runner: runner, locator: locator),
            commands: CommandRunner(runner: runner, locator: locator),
            credentials: credentials,
            preferences: PreferencesStore(),
            hardware: HardwareIdentityProvider(runner: runner)
        )
    }
}
