import XCTest
@testable import CorniceKit

/// These run real processes. The behaviours under test (timeout escalation,
/// cancellation, pipe draining) only exist at the boundary with the OS, so a
/// mock would test nothing.
final class SubprocessRunnerTests: XCTestCase {

    private let runner = SubprocessRunner()

    func testCapturesStandardOutput() async throws {
        let result = try await runner.run(Command(executable: "/bin/echo", arguments: ["hello world"]))

        XCTAssertEqual(result.trimmedOutput, "hello world")
        XCTAssertEqual(result.exitCode, 0)
        XCTAssertTrue(result.isSuccess)
        XCTAssertFalse(result.wasTruncated)
    }

    func testCapturesExitCodeAndStandardError() async throws {
        let result = try await runner.run(
            Command(executable: "/bin/sh", arguments: ["-c", "echo oops >&2; exit 3"])
        )

        XCTAssertEqual(result.exitCode, 3)
        XCTAssertEqual(result.standardError.trimmingCharacters(in: .whitespacesAndNewlines), "oops")
        XCTAssertFalse(result.isSuccess)
    }

    /// Arguments go to execve as an array, never through a shell. A branch or
    /// path containing shell metacharacters is data, not syntax.
    func testArgumentsAreNeverShellInterpreted() async throws {
        let hostile = "; rm -rf /tmp/should-not-happen"

        let result = try await runner.run(Command(executable: "/bin/echo", arguments: [hostile]))

        XCTAssertEqual(result.trimmedOutput, hostile)
    }

    func testTimeoutTerminatesTheProcess() async {
        let started = Date()

        do {
            _ = try await runner.run(
                Command(executable: "/bin/sleep", arguments: ["30"], timeout: 0.5)
            )
            XCTFail("expected a timeout")
        } catch let error as ServiceError {
            guard case .timedOut(_, let seconds) = error else { return XCTFail("got \(error)") }
            XCTAssertEqual(seconds, 0.5)
        } catch {
            XCTFail("got \(error)")
        }

        XCTAssertLessThan(
            Date().timeIntervalSince(started), 5,
            "the runner must return promptly, not wait out the child"
        )
    }

    func testCancellationTerminatesTheProcess() async {
        // Captured explicitly rather than through `self`: the child task needs
        // the runner, not the test case, and sending the test case across an
        // isolation boundary is what the compiler objects to.
        let runner = runner
        let task = Task {
            try await runner.run(Command(executable: "/bin/sleep", arguments: ["30"], timeout: 30))
        }
        try? await Task.sleep(for: .milliseconds(200))

        task.cancel()

        do {
            _ = try await task.value
            XCTFail("expected cancellation")
        } catch let error as ServiceError {
            XCTAssertEqual(error, .cancelled)
        } catch {
            XCTFail("got \(error)")
        }
    }

    func testMissingExecutableIsReportedAsUnavailable() async {
        do {
            _ = try await runner.run(Command(executable: "/nonexistent/tool"))
            XCTFail("expected toolUnavailable")
        } catch let error as ServiceError {
            XCTAssertEqual(error, .toolUnavailable(tool: "tool"))
        } catch {
            XCTFail("got \(error)")
        }
    }

    /// A repository directory can be deleted or unmounted while the app watches it.
    func testMissingWorkingDirectoryIsRejectedBeforeLaunch() async {
        do {
            _ = try await runner.run(
                Command(executable: "/bin/echo", workingDirectory: "/no/such/dir")
            )
            XCTFail("expected invalidPath")
        } catch let error as ServiceError {
            guard case .invalidPath = error else { return XCTFail("got \(error)") }
        } catch {
            XCTFail("got \(error)")
        }
    }

    /// A runaway command must not grow the app's memory without bound.
    func testOutputIsCappedAndFlagged() async throws {
        let result = try await runner.run(Command(
            executable: "/bin/sh",
            arguments: ["-c", "for i in $(seq 1 5000); do echo aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa; done"],
            maxOutputBytes: 4096
        ))

        XCTAssertTrue(result.wasTruncated)
        XCTAssertLessThanOrEqual(result.standardOutput.utf8.count, 4096)
    }

    /// A child that reads stdin must get EOF rather than blocking until the
    /// timeout expires.
    func testStandardInputIsClosed() async throws {
        let result = try await runner.run(
            Command(executable: "/bin/sh", arguments: ["-c", "cat; echo done"], timeout: 3)
        )

        XCTAssertEqual(result.trimmedOutput, "done")
    }

    /// Pipe reads block, so they run on a dedicated queue rather than the
    /// cooperative pool. If they did not, enough concurrent commands would
    /// exhaust the pool and deadlock.
    func testConcurrentCommandsDoNotDeadlock() async {
        let started = Date()
        let runner = runner

        await withTaskGroup(of: Void.self) { group in
            for index in 0..<16 {
                group.addTask {
                    _ = try? await runner.run(
                        Command(executable: "/bin/echo", arguments: ["\(index)"])
                    )
                }
            }
        }

        XCTAssertLessThan(Date().timeIntervalSince(started), 15)
    }

    /// The environment is built from scratch rather than inherited, so
    /// subprocess behaviour does not drift with how the app was launched.
    func testBaseEnvironmentIsApplied() async throws {
        let result = try await runner.run(
            Command(executable: "/bin/sh", arguments: ["-c", "echo $LC_ALL:$GIT_TERMINAL_PROMPT"])
        )

        XCTAssertEqual(
            result.trimmedOutput, "C:0",
            "LC_ALL keeps git output machine-readable; GIT_TERMINAL_PROMPT stops it hanging on auth"
        )
    }

    func testEnvironmentOverridesWin() async throws {
        let result = try await runner.run(Command(
            executable: "/bin/sh",
            arguments: ["-c", "echo $LC_ALL"],
            environment: ["LC_ALL": "en_US.UTF-8"]
        ))

        XCTAssertEqual(result.trimmedOutput, "en_US.UTF-8")
    }

    func testDurationIsRecorded() async throws {
        let result = try await runner.run(Command(executable: "/bin/sleep", arguments: ["0.2"]))

        XCTAssertGreaterThan(result.duration, 0.15)
        XCTAssertLessThan(result.duration, 5)
    }

    func testRequireSuccessTruncatesDiagnostics() {
        let result = CommandResult(
            exitCode: 1,
            standardOutput: "",
            standardError: String(repeating: "e", count: 2000),
            duration: 0
        )

        XCTAssertThrowsError(try result.requireSuccess(tool: "git")) { error in
            guard case ServiceError.commandFailed(_, _, let stderr) = error else {
                return XCTFail("got \(error)")
            }
            XCTAssertLessThanOrEqual(stderr.count, 400)
        }
    }
}

final class ToolLocatorTests: XCTestCase {

    func testFindsToolsOnTheStandardPath() async {
        let locator = ToolLocator()

        let echo = await locator.locate("echo")
        XCTAssertEqual(echo, "/bin/echo")
    }

    /// A GUI app does not inherit the user's shell PATH, so lookups must not
    /// depend on it. Homebrew locations are searched explicitly.
    func testSearchPathsIncludeHomebrewLocations() {
        XCTAssertTrue(ToolLocator.searchPaths.contains("/opt/homebrew/bin"))
        XCTAssertTrue(ToolLocator.searchPaths.contains("/usr/local/bin"))
    }

    func testMissingToolReturnsNilAndThrowsOnRequire() async {
        let locator = ToolLocator()

        let missing = await locator.locate("definitely-not-a-real-tool-xyz")
        XCTAssertNil(missing)
        do {
            _ = try await locator.require("definitely-not-a-real-tool-xyz")
            XCTFail("expected toolUnavailable")
        } catch let error as ServiceError {
            XCTAssertEqual(error, .toolUnavailable(tool: "definitely-not-a-real-tool-xyz"))
        } catch {
            XCTFail("got \(error)")
        }
    }
}
