import XCTest
@testable import CorniceKit

/// Command configuration is the one place the app runs code the user supplied,
/// so validation is tested as a security boundary rather than as form polish.
final class CommandSpecTests: XCTestCase {

    func testValidDirectCommand() {
        let spec = CommandSpec(name: "Tests", mode: .direct, executable: "npm", arguments: ["test"])

        XCTAssertNil(spec.validate())
        XCTAssertEqual(spec.displayCommand, "npm test")
    }

    func testValidShellCommand() {
        let spec = CommandSpec(name: "Dev", mode: .shell, script: "npm ci && npm run dev")

        XCTAssertNil(spec.validate())
        XCTAssertEqual(spec.displayCommand, "npm ci && npm run dev")
    }

    func testNameIsRequired() {
        XCTAssertNotNil(CommandSpec(name: "", executable: "npm").validate())
        XCTAssertNotNil(CommandSpec(name: "   ", executable: "npm").validate())
        XCTAssertNotNil(
            CommandSpec(name: String(repeating: "x", count: 100), executable: "npm").validate()
        )
    }

    /// A NUL byte truncates a C string, so a value containing one would execute
    /// as something shorter than the confirmation dialog displayed — breaking
    /// the guarantee that the user approved what actually ran.
    func testNullBytesAreRejectedInEveryField() {
        XCTAssertNotNil(CommandSpec(name: "a\u{0}b", mode: .shell, script: "ls").validate())
        XCTAssertNotNil(CommandSpec(name: "ok", mode: .shell, script: "ls\u{0}rm -rf /").validate())
        XCTAssertNotNil(
            CommandSpec(name: "ok", mode: .direct, executable: "npm", arguments: ["a\u{0}b"]).validate()
        )
    }

    /// Direct mode passes arguments straight to execve, so `&&` would be a
    /// literal argument rather than an operator. Saying so beats silently doing
    /// something the user did not intend.
    func testShellSyntaxIsRejectedInDirectMode() {
        for executable in ["npm test && echo", "ls | grep x", "echo `whoami`", "a;b", "$(id)"] {
            XCTAssertNotNil(
                CommandSpec(name: "x", mode: .direct, executable: executable).validate(),
                "\(executable) should be rejected in direct mode"
            )
        }
    }

    func testAbsoluteExecutableMustExist() {
        XCTAssertNotNil(CommandSpec(name: "x", mode: .direct, executable: "/no/such/binary").validate())
        XCTAssertNil(CommandSpec(name: "x", mode: .direct, executable: "/bin/echo").validate())
    }

    func testShellScriptMustNotBeEmptyOrEnormous() {
        XCTAssertNotNil(CommandSpec(name: "x", mode: .shell, script: "   ").validate())
        XCTAssertNotNil(
            CommandSpec(name: "x", mode: .shell, script: String(repeating: "a", count: 3000)).validate()
        )
    }

    func testWorkingDirectoryMustBeAnExistingAbsolutePath() {
        XCTAssertNotNil(
            CommandSpec(name: "x", mode: .shell, script: "ls", workingDirectory: "relative/path").validate()
        )
        XCTAssertNotNil(
            CommandSpec(name: "x", mode: .shell, script: "ls", workingDirectory: "/no/such/dir").validate()
        )
        XCTAssertNil(
            CommandSpec(name: "x", mode: .shell, script: "ls", workingDirectory: "/tmp").validate()
        )
    }

    func testTimeoutMustBeInRange() {
        XCTAssertNotNil(CommandSpec(name: "x", mode: .shell, script: "ls", timeout: 0).validate())
        XCTAssertNotNil(CommandSpec(name: "x", mode: .shell, script: "ls", timeout: 100_000).validate())
        XCTAssertNil(CommandSpec(name: "x", mode: .shell, script: "ls", timeout: 60).validate())
    }

    func testOutputTailKeepsOnlyRecentNonEmptyLines() {
        let output = (1...50).map { "line \($0)" }.joined(separator: "\n")

        let tail = CommandRunner.tail(of: output)

        XCTAssertTrue(tail.hasSuffix("line 50"))
        XCTAssertEqual(tail.split(separator: "\n").count, 12)
        XCTAssertEqual(CommandRunner.tail(of: "a\n\n\nb\n"), "a\nb", "blank lines are dropped")
    }
}

final class DockerParserTests: XCTestCase {

    func testParsesContainerList() {
        let output = """
        {"ID":"a1b2c3d4e5f6","Names":"api,api_1","Status":"Up 4 minutes (healthy)","Image":"node:22","Ports":"0.0.0.0:3000->3000/tcp"}
        {"ID":"f6e5d4c3b2a1","Names":"db","Status":"Up 2 hours","Image":"postgres:16","Ports":""}
        """

        let containers = DockerOutputParser.parseContainers(output)

        XCTAssertEqual(containers.count, 2)
        XCTAssertEqual(containers[0].name, "api", "docker joins names with commas; the first is canonical")
        XCTAssertEqual(containers[0].publishedPorts, [3000])
        XCTAssertEqual(containers[0].shortID, "a1b2c3d4e5f6")
        XCTAssertFalse(containers[0].isUnhealthy)
    }

    /// Docker sometimes interleaves warnings on stdout. One bad line must not
    /// empty the whole panel.
    func testMalformedLinesAreSkipped() {
        let output = """
        {"ID":"a1b2c3d4e5f6","Names":"api","Status":"Up","Image":"n","Ports":""}
        WARNING: something happened
        {"not":"a container"}
        """

        XCTAssertEqual(DockerOutputParser.parseContainers(output).count, 1)
    }

    /// Only mappings with an arrow are reachable from the host. A bare
    /// `9229/tcp` is exposed inside the container network only, so offering to
    /// open it in a browser would just fail.
    func testOnlyPublishedPortsAreExtracted() {
        XCTAssertEqual(DockerOutputParser.parsePorts("9229/tcp"), [])
        XCTAssertEqual(DockerOutputParser.parsePorts("0.0.0.0:8080->80/tcp"), [8080])
    }

    func testIPv4AndIPv6MappingsDeduplicate() {
        let ports = DockerOutputParser.parsePorts("0.0.0.0:8080->80/tcp, [::]:8080->80/tcp")

        XCTAssertEqual(ports, [8080])
    }

    func testMultiplePortsAreSorted() {
        let ports = DockerOutputParser.parsePorts("0.0.0.0:6379->6379/tcp, 0.0.0.0:5432->5432/tcp")

        XCTAssertEqual(ports, [5432, 6379])
    }

    func testHealthAndRestartStatesAreDetected() {
        func container(_ status: String) -> ContainerSummary {
            ContainerSummary(id: "a1b2c3d4e5f6", name: "x", status: status, image: "i", publishedPorts: [])
        }

        XCTAssertTrue(container("Up 3 minutes (unhealthy)").isUnhealthy)
        XCTAssertTrue(container("Restarting (1) 2 seconds ago").isRestarting)
        XCTAssertFalse(container("Up 3 minutes (healthy)").isUnhealthy)
    }

    /// Container IDs are interpolated into an argument list, so anything that
    /// could be read as a flag must be rejected.
    func testContainerIDValidation() {
        XCTAssertTrue(DockerOutputParser.isValidContainerID("a1b2c3d4e5f6"))
        XCTAssertTrue(DockerOutputParser.isValidContainerID(String(repeating: "a", count: 64)))
        XCTAssertFalse(DockerOutputParser.isValidContainerID("A1B2C3D4E5F6"), "uppercase is not docker's format")
        XCTAssertFalse(DockerOutputParser.isValidContainerID("--rm"))
        XCTAssertFalse(DockerOutputParser.isValidContainerID("abc"), "too short")
        XCTAssertFalse(DockerOutputParser.isValidContainerID(""))
        XCTAssertFalse(DockerOutputParser.isValidContainerID("a1b2c3d4e5f6; rm -rf /"))
    }
}

final class GitHubSlugTests: XCTestCase {

    func testAcceptsWellFormedSlugs() {
        XCTAssertTrue(GitHubSlug.isValid("owner/repo"))
        XCTAssertTrue(GitHubSlug.isValid("my-org/my.repo_2"))
        XCTAssertEqual(GitHubSlug.split("acme/tools")?.owner, "acme")
        XCTAssertEqual(GitHubSlug.split("acme/tools")?.repository, "tools")
    }

    /// Slugs are interpolated into request paths, so a traversal attempt would
    /// rewrite which endpoint is called.
    func testRejectsPathTraversalAndMalformedInput() {
        for slug in ["../../etc/passwd", "owner", "owner/repo/extra", "own er/repo",
                     "-bad/repo", "bad-/repo", "", "/", "owner/", "/repo",
                     "owner/../other", "owner/%2e%2e"] {
            XCTAssertFalse(GitHubSlug.isValid(slug), "\(slug) must be rejected")
        }
    }

    func testRejectsOverlyLongComponents() {
        XCTAssertFalse(GitHubSlug.isValid("\(String(repeating: "a", count: 200))/repo"))
    }
}
