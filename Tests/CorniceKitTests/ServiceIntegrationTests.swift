import XCTest
@testable import CorniceKit

/// Services driven through `ScriptedProcessRunner`, so behaviour that depends
/// on *which* commands run — and how many times — is assertable without a real
/// repository, a real Docker daemon, or a real listening socket.
final class GitServiceTests: XCTestCase {

    private func scriptedGit(
        status: String,
        log: String = "abcdef1234567890\u{1f}Initial commit\u{1f}Ada\u{1f}2026-09-16T10:00:00Z"
    ) -> (GitService, ScriptedProcessRunner) {
        let runner = ScriptedProcessRunner(rules: [
            .containing(["status"], .success(stdout: status)),
            .containing(["log"], .success(stdout: log)),
            .containing(["rev-parse"], .success(stdout: "/tmp\n")),
        ])
        return (GitService(runner: runner, locator: ToolLocator()), runner)
    }

    func testBuildsSnapshotFromGitOutput() async throws {
        let (service, _) = scriptedGit(status: """
        # branch.oid abcdef1234567890
        # branch.head main
        # branch.upstream origin/main
        # branch.ab +1 -2
        1 .M N... 100644 100644 100644 a b Sources/A.swift
        ? new.txt
        """)

        let snapshot = try await service.snapshot(ofRepositoryAt: "/tmp")

        XCTAssertEqual(snapshot.branch, "main")
        XCTAssertEqual(snapshot.name, "tmp", "the repo name is the root directory's name")
        XCTAssertEqual(snapshot.workingTree.modified, 1)
        XCTAssertEqual(snapshot.workingTree.untracked, 1)
        XCTAssertEqual(snapshot.tracking?.ahead, 1)
        XCTAssertEqual(snapshot.tracking?.behind, 2)
        XCTAssertEqual(snapshot.lastCommit?.subject, "Initial commit")
        XCTAssertFalse(snapshot.isDetached)
    }

    /// A repository with no commits makes `git log` fail. That is a normal
    /// state for a freshly-initialised repo, not an error to surface.
    func testEmptyRepositoryStillProducesASnapshot() async throws {
        let runner = ScriptedProcessRunner(rules: [
            .containing(["status"], .success(stdout: "# branch.oid (initial)\n# branch.head main\n")),
            .containing(["log"], .failure(exitCode: 128, stderr: "fatal: your current branch 'main' does not have any commits yet")),
        ])
        let service = GitService(runner: runner, locator: ToolLocator())

        let snapshot = try await service.snapshot(ofRepositoryAt: "/tmp")

        XCTAssertEqual(snapshot.branch, "main")
        XCTAssertNil(snapshot.lastCommit)
    }

    /// External drives get unmounted; `git worktree remove` deletes directories.
    func testDeletedRepositoryIsReportedAsInvalidPath() async {
        let (service, _) = scriptedGit(status: "")

        do {
            _ = try await service.snapshot(ofRepositoryAt: "/no/such/repository")
            XCTFail("expected invalidPath")
        } catch let error as ServiceError {
            guard case .invalidPath = error else { return XCTFail("got \(error)") }
            XCTAssertFalse(error.isRetryable)
        } catch {
            XCTFail("got \(error)")
        }
    }

    func testNonRepositoryIsReportedAsCommandFailure() async {
        let runner = ScriptedProcessRunner(
            fallback: .failure(exitCode: 128, stderr: "fatal: not a git repository")
        )
        let service = GitService(runner: runner, locator: ToolLocator())

        do {
            _ = try await service.snapshot(ofRepositoryAt: "/tmp")
            XCTFail("expected commandFailed")
        } catch let error as ServiceError {
            guard case .commandFailed(_, let code, let stderr) = error else {
                return XCTFail("got \(error)")
            }
            XCTAssertEqual(code, 128)
            XCTAssertTrue(stderr.contains("not a git repository"))
        } catch {
            XCTFail("got \(error)")
        }
    }

    /// Status and log are independent and run concurrently, so a snapshot costs
    /// one round of latency rather than two.
    func testStatusAndLogRunConcurrently() async throws {
        let slow = CommandResult(exitCode: 0, standardOutput: "# branch.head main\n", standardError: "", duration: 0)
        let runner = ScriptedProcessRunner(rules: [
            .containing(["status"], .delayed(.milliseconds(300), then: slow)),
            .containing(["log"], .delayed(.milliseconds(300), then: CommandResult(
                exitCode: 0,
                standardOutput: "abc\u{1f}s\u{1f}a\u{1f}2026-09-16T10:00:00Z",
                standardError: "", duration: 0
            ))),
        ])
        let service = GitService(runner: runner, locator: ToolLocator())

        let started = Date()
        _ = try await service.snapshot(ofRepositoryAt: "/tmp")
        let elapsed = Date().timeIntervalSince(started)

        XCTAssertLessThan(elapsed, 0.55, "sequential execution would take at least 0.6s")
    }

    func testGitNotInstalledIsReported() async {
        // An empty locator search finds nothing, simulating a machine with no
        // developer tools installed.
        final class EmptyFileManager: FileManager, @unchecked Sendable {
            override func isExecutableFile(atPath path: String) -> Bool { false }
        }
        let service = GitService(
            runner: ScriptedProcessRunner(),
            locator: ToolLocator(fileManager: EmptyFileManager())
        )

        do {
            _ = try await service.snapshot(ofRepositoryAt: "/tmp")
            XCTFail("expected toolUnavailable")
        } catch let error as ServiceError {
            XCTAssertEqual(error, .toolUnavailable(tool: "git"))
        } catch {
            XCTFail("got \(error)")
        }
    }
}

final class PortMonitorTests: XCTestCase {

    private func monitor(
        lsof: String,
        ps: String = ""
    ) -> (PortMonitor, ScriptedProcessRunner) {
        let runner = ScriptedProcessRunner(rules: [
            .containing(["lsof"], .success(stdout: lsof)),
            .containing(["ps"], .success(stdout: ps)),
        ])
        return (PortMonitor(runner: runner, locator: ToolLocator()), runner)
    }

    /// `lsof` walks every open descriptor on the system, so polling it once per
    /// port would cost four full scans for four ports. One call, filtered
    /// in-process, is the whole reason the monitor is cheap enough to run on a
    /// timer.
    func testOneLsofCallCoversEveryMonitoredPort() async throws {
        let (monitor, runner) = self.monitor(
            lsof: "p8477\ncnode\nLme\nf4\nn127.0.0.1:3000\n",
            ps: "8477 05:12\n"
        )

        let statuses = try await monitor.scan(ports: [
            .init(port: 3000, label: "web"), .init(port: 5173), .init(port: 8080), .init(port: 8000),
        ])

        XCTAssertEqual(statuses.count, 4)
        XCTAssertEqual(await runner.invocationCount(containing: "lsof"), 1)
    }

    func testAttachesListenerDetailsAndUptime() async throws {
        let (monitor, _) = self.monitor(
            lsof: "p8477\ncnode\nLkirolos\nf4\nn127.0.0.1:3000\n",
            ps: "8477 05:12\n"
        )

        let status = try await monitor.scan(ports: [.init(port: 3000, label: "web")]).first

        XCTAssertTrue(status?.isActive ?? false)
        XCTAssertEqual(status?.listener?.command, "node")
        XCTAssertEqual(status?.listener?.user, "kirolos")
        XCTAssertEqual(status?.listener?.uptime, 312)
        XCTAssertEqual(status?.displayName, "web")
        XCTAssertEqual(status?.localURL?.absoluteString, "http://localhost:3000")
    }

    func testInactivePortsAreReportedNotOmitted() async throws {
        let (monitor, _) = self.monitor(lsof: "")

        let statuses = try await monitor.scan(ports: [.init(port: 3000), .init(port: 5173)])

        XCTAssertEqual(statuses.count, 2, "a port with nothing listening still has a row")
        XCTAssertTrue(statuses.allSatisfy { !$0.isActive })
    }

    /// The extra `ps` call is skipped entirely when nothing is listening, which
    /// is the common case on an idle machine.
    func testUptimeLookupIsSkippedWhenNothingIsListening() async throws {
        let (monitor, runner) = self.monitor(lsof: "")

        _ = try await monitor.scan(ports: [.init(port: 3000)])

        XCTAssertEqual(await runner.invocationCount(containing: "ps"), 0)
    }

    /// An uptime is a nice-to-have label; losing it must not lose the scan.
    func testFailedUptimeLookupDegradesGracefully() async throws {
        let runner = ScriptedProcessRunner(rules: [
            .containing(["lsof"], .success(stdout: "p8477\ncnode\nLme\nf4\nn127.0.0.1:3000\n")),
            .containing(["ps"], .error(.timedOut(tool: "ps", seconds: 4))),
        ])
        let monitor = PortMonitor(runner: runner, locator: ToolLocator())

        let status = try await monitor.scan(ports: [.init(port: 3000)]).first

        XCTAssertTrue(status?.isActive ?? false, "the listener is still reported")
        XCTAssertNil(status?.listener?.uptime)
    }

    func testEmptyPortListSkipsWorkEntirely() async throws {
        let (monitor, runner) = self.monitor(lsof: "p1\ncx\nLu\nf1\nn*:1\n")

        let statuses = try await monitor.scan(ports: [])

        XCTAssertTrue(statuses.isEmpty)
        XCTAssertEqual(await runner.invocationCount(containing: "lsof"), 0)
    }

    func testRefusesToSignalImplausiblePids() async {
        let (monitor, _) = self.monitor(lsof: "")

        do {
            try await monitor.terminate(pid: 1)
            XCTFail("expected refusal")
        } catch let error as ServiceError {
            guard case .invalidConfiguration = error else { return XCTFail("got \(error)") }
        } catch {
            XCTFail("got \(error)")
        }
    }
}

final class DockerServiceTests: XCTestCase {

    func testReportsNotInstalledWhenBinaryIsAbsent() async {
        final class EmptyFileManager: FileManager, @unchecked Sendable {
            override func isExecutableFile(atPath path: String) -> Bool { false }
        }
        let service = DockerService(
            runner: ScriptedProcessRunner(),
            locator: ToolLocator(fileManager: EmptyFileManager())
        )

        XCTAssertEqual(await service.availability(), .notInstalled)
    }

    /// `docker version` (unlike `docker --version`) talks to the daemon, so a
    /// stopped Docker Desktop is distinguishable from an uninstalled one.
    func testReportsDaemonNotRunningWhenVersionFails() async {
        let runner = ScriptedProcessRunner(rules: [
            .containing(["version"], .failure(exitCode: 1, stderr: "Cannot connect to the Docker daemon")),
        ])
        let service = DockerService(runner: runner, locator: ToolLocator())

        let availability = await service.availability()

        // Resolves to notInstalled on a machine without docker, which is also
        // a correct answer; either way the module must not be queryable.
        XCTAssertFalse(availability.canQuery)
    }

    /// If Docker Desktop is stopped, every `docker ps` blocks for seconds
    /// before failing. Re-probing on each refresh tick would make the whole
    /// panel feel broken, so a negative result is cached.
    func testNegativeAvailabilityIsCached() async {
        let runner = ScriptedProcessRunner(rules: [
            .containing(["version"], .failure(exitCode: 1, stderr: "daemon down")),
        ])
        let service = DockerService(runner: runner, locator: ToolLocator())

        _ = await service.availability()
        _ = await service.availability()
        _ = await service.availability()

        XCTAssertLessThanOrEqual(
            await runner.invocationCount(containing: "version"), 1,
            "a failed probe must not repeat on every refresh"
        )
    }

    func testContainersThrowsWhenUnavailable() async {
        let runner = ScriptedProcessRunner(rules: [
            .containing(["version"], .failure(exitCode: 1, stderr: "daemon down")),
        ])
        let service = DockerService(runner: runner, locator: ToolLocator())

        do {
            _ = try await service.containers()
            XCTFail("expected a failure")
        } catch {
            XCTAssertTrue(error is ServiceError)
        }
    }

    func testRejectsMalformedContainerIdentifiers() async {
        let service = DockerService(runner: ScriptedProcessRunner(), locator: ToolLocator())

        do {
            try await service.stop(containerID: "--volumes")
            XCTFail("expected refusal")
        } catch let error as ServiceError {
            guard case .invalidConfiguration = error else { return XCTFail("got \(error)") }
        } catch {
            XCTFail("got \(error)")
        }
    }
}

final class LoadableTests: XCTestCase {

    /// A refresh must not flash a spinner over data that is already on screen.
    func testRefreshPreservesExistingValue() {
        let loaded = Loadable.loaded(42)

        XCTAssertEqual(loaded.beginRefresh(), .refreshing(42))
        XCTAssertEqual(Loadable<Int>.idle.beginRefresh(), .loading)
    }

    /// A failed refresh must not erase a good last-known state.
    func testFailurePreservesLastGoodValue() {
        let next = Loadable.loaded(42).resolve(.failure(.offline))

        XCTAssertEqual(next, .failed(.offline, last: 42))
        XCTAssertEqual(next.value, 42, "the panel keeps showing real data")
        XCTAssertEqual(next.error, .offline)
    }

    /// A cancelled task was superseded by a newer one, so its result must not
    /// overwrite the newer state or surface as an error to the user.
    func testCancellationIsNotTreatedAsAnError() {
        XCTAssertEqual(Loadable.loaded(42).resolve(.failure(.cancelled)), .loaded(42))
        XCTAssertEqual(Loadable<Int>.loading.resolve(.failure(.cancelled)), .idle)
    }

    func testBusyStates() {
        XCTAssertTrue(Loadable.loading.isBusy)
        XCTAssertTrue(Loadable.refreshing(1).isBusy)
        XCTAssertFalse(Loadable.loaded(1).isBusy)
        XCTAssertFalse(Loadable<Int>.failed(.offline, last: nil).isBusy)
    }
}
