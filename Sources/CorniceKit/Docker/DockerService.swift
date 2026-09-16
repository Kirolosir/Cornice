import Foundation

/// A running container, reduced to what fits in a panel row.
public struct ContainerSummary: Equatable, Sendable, Identifiable {
    public let id: String
    public let name: String
    /// Docker's human status string, e.g. "Up 4 minutes (healthy)".
    public let status: String
    public let image: String
    /// Host ports mapped to the container, deduplicated and sorted.
    public let publishedPorts: [Int]

    public init(id: String, name: String, status: String, image: String, publishedPorts: [Int]) {
        self.id = id
        self.name = name
        self.status = status
        self.image = image
        self.publishedPorts = publishedPorts
    }

    public var shortID: String { String(id.prefix(12)) }

    /// Docker reports health in parentheses when a HEALTHCHECK is defined.
    public var isUnhealthy: Bool { status.localizedCaseInsensitiveContains("unhealthy") }
    public var isRestarting: Bool { status.localizedCaseInsensitiveContains("restarting") }
}

/// Whether the Docker module can show anything at all.
public enum DockerAvailability: Equatable, Sendable {
    /// The `docker` binary is not installed.
    case notInstalled
    /// Installed, but the daemon is not accepting connections.
    case daemonNotRunning
    case available

    public var canQuery: Bool { self == .available }
}

public protocol DockerInspecting: Sendable {
    func availability() async -> DockerAvailability
    func containers() async throws -> [ContainerSummary]
    func stop(containerID: String) async throws
    func restart(containerID: String) async throws
}

/// Reads container state via the `docker` CLI.
///
/// The CLI rather than the Unix socket API: it is the interface Docker actually
/// documents for this, it works unchanged with Colima, Rancher Desktop, and
/// OrbStack (all of which put the socket somewhere different), and it avoids
/// pinning the app to a particular Engine API version.
///
/// Availability is cached with a cooldown because the failure mode matters: if
/// Docker Desktop is not running, every `docker ps` blocks for several seconds
/// before failing. Retrying that on a refresh timer would make the whole panel
/// feel broken, so a negative result is remembered for a while.
public actor DockerService: DockerInspecting {
    private let runner: any ProcessRunning
    private let locator: ToolLocator

    private var cachedAvailability: (value: DockerAvailability, checkedAt: Date)?
    /// How long a negative availability result is trusted before re-probing.
    private static let unavailableCooldown: TimeInterval = 60
    /// How long a positive result is trusted.
    private static let availableCooldown: TimeInterval = 15

    public init(runner: any ProcessRunning, locator: ToolLocator) {
        self.runner = runner
        self.locator = locator
    }

    public func availability() async -> DockerAvailability {
        if let cached = cachedAvailability {
            let cooldown = cached.value == .available
                ? Self.availableCooldown
                : Self.unavailableCooldown
            if Date().timeIntervalSince(cached.checkedAt) < cooldown { return cached.value }
        }

        let result = await probeAvailability()
        cachedAvailability = (result, .now)
        return result
    }

    private func probeAvailability() async -> DockerAvailability {
        guard let docker = await locator.locate("docker") else { return .notInstalled }
        do {
            // `docker version` talks to the daemon, unlike `docker --version`
            // which only prints the client build and succeeds while the daemon
            // is stopped. The short timeout keeps a hung daemon from stalling
            // the refresh cycle.
            let result = try await runner.run(
                Command(
                    executable: docker,
                    arguments: ["version", "--format", "{{.Server.Version}}"],
                    timeout: 4
                )
            )
            return result.isSuccess ? .available : .daemonNotRunning
        } catch {
            return .daemonNotRunning
        }
    }

    public func containers() async throws -> [ContainerSummary] {
        let availability = await availability()
        guard availability.canQuery else {
            throw availability == .notInstalled
                ? ServiceError.toolUnavailable(tool: "docker")
                : ServiceError.commandFailed(tool: "docker", exitCode: 1, stderr: "Docker daemon is not running.")
        }

        let docker = try await locator.require("docker")
        let result = try await runner.run(
            Command(
                executable: docker,
                // A JSON object per line. Chosen over `--format json` on the
                // whole list because older Docker versions do not support that,
                // and over table output because container names and images
                // contain characters that break column parsing.
                arguments: ["ps", "--format", "{{json .}}"],
                timeout: 8
            )
        ).requireSuccess(tool: "docker ps")

        return DockerOutputParser.parseContainers(result.standardOutput)
    }

    /// Stops a container. The caller must have obtained explicit confirmation.
    public func stop(containerID: String) async throws {
        try await lifecycle("stop", containerID: containerID, timeout: 30)
    }

    /// Restarts a container. The caller must have obtained explicit confirmation.
    public func restart(containerID: String) async throws {
        try await lifecycle("restart", containerID: containerID, timeout: 45)
    }

    private func lifecycle(_ verb: String, containerID: String, timeout: Double) async throws {
        // Container IDs are hex; names are also accepted by docker, but this
        // app only ever passes IDs it read back from `docker ps`. Validating
        // anyway means a corrupted preferences file or a malformed response
        // cannot turn into an argument that docker interprets as a flag.
        guard DockerOutputParser.isValidContainerID(containerID) else {
            throw ServiceError.invalidConfiguration(reason: "invalid container id")
        }
        let docker = try await locator.require("docker")
        Log.docker.notice("\(verb, privacy: .public) container \(containerID.prefix(12), privacy: .public)")
        _ = try await runner.run(
            Command(executable: docker, arguments: [verb, containerID], timeout: timeout)
        ).requireSuccess(tool: "docker \(verb)")
        // The container list changed, so the next refresh should re-probe
        // rather than trust a cached "available" reading from before the change.
        cachedAvailability = nil
    }
}
