import Foundation
import CorniceKit

/// A `ServiceContainer` backed entirely by scripted doubles.
///
/// Used by `--capture-docs` to render documentation images, and useful for
/// exercising states that are hard to produce on demand — a failing CI run, a
/// container that is unhealthy, a repository mid-merge-conflict.
///
/// That this is a handful of lines is the payoff from injecting every service
/// through a protocol: the entire application runs against fake data with no
/// changes to any view, view model, or service.
enum PreviewServices {

    static func container() -> ServiceContainer {
        let runner = scriptedRunner()
        let locator = ToolLocator()
        let credentials = EphemeralCredentialStore(
            seed: [GitHubClient.credentialAccount: "preview-token"]
        )

        return ServiceContainer(
            processRunner: runner,
            toolLocator: locator,
            git: GitService(runner: runner, locator: locator),
            ports: PortMonitor(runner: runner, locator: locator),
            telemetry: PreviewTelemetryProbe(),
            github: GitHubClient(
                transport: PreviewTransport(),
                credentials: credentials,
                cache: ResponseCache()
            ),
            docker: PreviewDockerService(),
            commands: CommandRunner(runner: runner, locator: locator),
            credentials: credentials,
            preferences: EphemeralPreferencesStore(previewPreferences()),
            hardware: HardwareIdentityProvider(runner: runner)
        )
    }

    static func previewPreferences() -> Preferences {
        var preferences = Preferences()
        // A directory that exists (so the service's validation passes) but is
        // named like a real project, since the name is rendered in the images.
        let repository = (NSTemporaryDirectory() as NSString)
            .appendingPathComponent("atlas")
        try? FileManager.default.createDirectory(
            atPath: repository, withIntermediateDirectories: true
        )
        preferences.repositoryPaths = [repository]
        preferences.activeRepositoryPath = repository
        preferences.githubLogin = "octocat"
        preferences.githubRepositories = ["acme/atlas", "acme/ledger"]
        preferences.enabledModules = Set(ModuleKind.allCases)
        preferences.monitoredPorts = [
            MonitoredPort(port: 3000, label: "Next"),
            MonitoredPort(port: 5173, label: "Vite"),
            MonitoredPort(port: 8000, label: "FastAPI"),
            MonitoredPort(port: 5432, label: "Postgres"),
        ]
        preferences.commands = [
            CommandSpec(name: "Unit tests", mode: .direct, executable: "/bin/echo",
                        arguments: ["swift", "test"], requiresConfirmation: false),
            CommandSpec(name: "Dev server", mode: .shell, script: "npm run dev"),
            CommandSpec(name: "Typecheck", mode: .shell, script: "npm run typecheck"),
            CommandSpec(name: "Migrate", mode: .shell, script: "alembic upgrade head"),
        ]
        return preferences
    }

    private static func scriptedRunner() -> ScriptedProcessRunner {
        ScriptedProcessRunner(rules: [
            .containing(["status"], .success(stdout: """
            # branch.oid 7c41e9a2b8d3f5610a2c4e6b8d0f2a4c6e8b0d2f
            # branch.head feature/notch-geometry
            # branch.upstream origin/feature/notch-geometry
            # branch.ab +3 -1
            1 M. N... 100644 100644 100644 a b Sources/CorniceKit/Notch/NotchGeometryResolver.swift
            1 M. N... 100644 100644 100644 a b Tests/CorniceKitTests/NotchGeometryTests.swift
            1 .M N... 100644 100644 100644 a b README.md
            ? Scripts/measure.sh
            """)),
            .containing(["log"], .success(
                stdout: "7c41e9a2b8d3f5610a2c4e6b8d0f2a4c6e8b0d2f\u{1f}Measure the notch instead of guessing per model\u{1f}Ada Lovelace\u{1f}2026-09-16T17:41:00Z"
            )),
            .containing(["lsof"], .success(stdout: """
            p41207
            cnode
            Lkirolos
            f22
            n127.0.0.1:3000
            p41338
            cnode
            Lkirolos
            f19
            n*:5173
            p9021
            cpostgres
            Lkirolos
            f7
            n127.0.0.1:5432
            """)),
            .containing(["ps"], .success(stdout: """
            41207 02:14:08
            41338 00:41:22
             9021 3-06:12:55
            """)),
            .containing(["docker", "version"], .success(stdout: "27.1.1")),
            .containing(["docker", "ps"], .success(stdout: """
            {"ID":"9f2b3c4d5e6a","Names":"atlas-api","Status":"Up 2 hours (healthy)","Image":"acme/atlas-api:dev","Ports":"0.0.0.0:8080->8080/tcp, [::]:8080->8080/tcp"}
            {"ID":"1a2b3c4d5e6f","Names":"atlas-postgres","Status":"Up 2 hours","Image":"postgres:16-alpine","Ports":"0.0.0.0:5432->5432/tcp"}
            {"ID":"77aa88bb99cc","Names":"atlas-worker","Status":"Restarting (1) 12 seconds ago","Image":"acme/atlas-worker:dev","Ports":""}
            """)),
            .containing(["system_profiler"], .success(
                stdout: #"{"SPHardwareDataType":[{"machine_name":"MacBook Pro","chip_type":"Apple M3"}]}"#
            )),
        ], fallback: .success(stdout: ""))
    }
}

/// Docker with a populated container list.
///
/// A double rather than the real `DockerService` driven by scripted output,
/// because the real service checks whether the `docker` binary exists before it
/// runs anything — correctly, since that is how it degrades on a machine
/// without Docker. Documenting the populated state therefore needs the
/// availability check bypassed, not the command output faked.
private struct PreviewDockerService: DockerInspecting {
    func availability() async -> DockerAvailability { .available }

    func containers() async throws -> [ContainerSummary] {
        [
            ContainerSummary(
                id: "9f2b3c4d5e6a", name: "atlas-api",
                status: "Up 2 hours (healthy)", image: "acme/atlas-api:dev",
                publishedPorts: [8080]
            ),
            ContainerSummary(
                id: "1a2b3c4d5e6f", name: "atlas-postgres",
                status: "Up 2 hours", image: "postgres:16-alpine",
                publishedPorts: [5432]
            ),
            ContainerSummary(
                id: "77aa88bb99cc", name: "atlas-worker",
                status: "Restarting (1) 12 seconds ago", image: "acme/atlas-worker:dev",
                publishedPorts: []
            ),
        ]
    }

    func stop(containerID: String) async throws {}
    func restart(containerID: String) async throws {}
}

/// Telemetry with plausible, slowly-varying values.
private struct PreviewTelemetryProbe: TelemetryProbing {
    func sample() async -> TelemetrySample {
        let phase = Date().timeIntervalSince1970
        return TelemetrySample(
            cpuUsage: 0.34 + 0.22 * sin(phase * 0.7),
            memoryUsage: 0.61 + 0.04 * sin(phase * 0.3),
            memoryUsedBytes: UInt64(19.6 * 1024 * 1024 * 1024),
            memoryTotalBytes: UInt64(32.0 * 1024 * 1024 * 1024),
            networkInBytesPerSecond: max(0, 900_000 + 700_000 * sin(phase * 1.3)),
            networkOutBytesPerSecond: max(0, 180_000 + 150_000 * sin(phase * 0.9)),
            battery: BatteryState(level: 0.72, isCharging: false, isPluggedIn: false, minutesRemaining: 214),
            capturedAt: .now
        )
    }
}

/// Serves canned GitHub responses.
private actor PreviewTransport: HTTPTransporting {
    func send(_ request: URLRequest) async throws -> (Data, HTTPURLResponse) {
        let path = request.url?.path ?? ""
        let query = request.url?.query ?? ""
        let body: String

        if path.hasSuffix("/user") {
            body = #"{"login":"octocat","avatar_url":null,"html_url":null}"#
        } else if path.contains("/search/issues") {
            body = query.contains("review-requested") ? Self.reviewRequests : Self.myPullRequests
        } else if path.contains("/actions/runs") {
            body = path.contains("ledger") ? Self.failingRun : Self.passingRun
        } else {
            body = #"{"total_count":0,"items":[]}"#
        }

        let response = HTTPURLResponse(
            url: request.url!,
            statusCode: 200,
            httpVersion: "HTTP/1.1",
            headerFields: [
                "x-ratelimit-limit": "5000",
                "x-ratelimit-remaining": "4873",
                "x-ratelimit-reset": "\(Int(Date().addingTimeInterval(2400).timeIntervalSince1970))",
                "ETag": "\"preview\"",
            ]
        )!
        return (Data(body.utf8), response)
    }

    private static let myPullRequests = """
    {"total_count":2,"items":[
      {"id":1,"number":412,"title":"Measure notch geometry at runtime","html_url":"https://github.com/acme/atlas/pull/412","draft":false,
       "user":{"login":"octocat","avatar_url":null,"html_url":null},"updated_at":"2026-09-16T16:10:00Z",
       "repository_url":"https://api.github.com/repos/acme/atlas"},
      {"id":2,"number":409,"title":"Cache GitHub responses with ETags","html_url":"https://github.com/acme/atlas/pull/409","draft":true,
       "user":{"login":"octocat","avatar_url":null,"html_url":null},"updated_at":"2026-09-15T09:22:00Z",
       "repository_url":"https://api.github.com/repos/acme/atlas"}]}
    """

    private static let reviewRequests = """
    {"total_count":2,"items":[
      {"id":3,"number":188,"title":"Drop the per-model notch table","html_url":"https://github.com/acme/ledger/pull/188","draft":false,
       "user":{"login":"graceh","avatar_url":null,"html_url":null},"updated_at":"2026-09-16T18:02:00Z",
       "repository_url":"https://api.github.com/repos/acme/ledger"},
      {"id":4,"number":186,"title":"Terminate subprocesses on timeout","html_url":"https://github.com/acme/ledger/pull/186","draft":false,
       "user":{"login":"krauss","avatar_url":null,"html_url":null},"updated_at":"2026-09-16T11:48:00Z",
       "repository_url":"https://api.github.com/repos/acme/ledger"}]}
    """

    private static let passingRun = """
    {"total_count":1,"workflow_runs":[
      {"id":9001,"name":"CI","status":"completed","conclusion":"success","head_branch":"main",
       "head_sha":"7c41e9a2b8d3f561","html_url":"https://github.com/acme/atlas/actions/runs/9001",
       "created_at":"2026-09-16T17:30:00Z","updated_at":"2026-09-16T17:33:12Z",
       "head_commit":{"message":"Measure the notch instead of guessing"},
       "repository":{"full_name":"acme/atlas"}}]}
    """

    private static let failingRun = """
    {"total_count":1,"workflow_runs":[
      {"id":9002,"name":"CI","status":"completed","conclusion":"failure","head_branch":"feature/rate-limits",
       "head_sha":"b83f0d17aa2c449","html_url":"https://github.com/acme/ledger/actions/runs/9002",
       "created_at":"2026-09-16T18:40:00Z","updated_at":"2026-09-16T18:44:51Z",
       "head_commit":{"message":"Hold quota in reserve for user-initiated refreshes"},
       "repository":{"full_name":"acme/ledger"}}]}
    """
}
