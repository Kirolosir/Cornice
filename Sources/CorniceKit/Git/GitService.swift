import Foundation

/// Reads repository state. Mockable so the view model can be tested without git.
public protocol GitReading: Sendable {
    /// Resolves any path inside a working tree to its repository root.
    func repositoryRoot(containing path: String) async throws -> String
    /// Takes a full snapshot of a repository.
    func snapshot(ofRepositoryAt path: String) async throws -> GitRepositorySnapshot
}

/// Reads git state by shelling out to the `git` binary.
///
/// An actor because it holds a per-repository generation counter used to drop
/// stale results, and because serialising access means a burst of refresh
/// requests for the same repo cannot produce a thundering herd of `git status`
/// processes.
public actor GitService: GitReading {
    private let runner: any ProcessRunning
    private let locator: ToolLocator

    /// Bumped each time a snapshot is requested for a path. A result whose
    /// generation is no longer current is discarded.
    ///
    /// This is the fix for a specific bug: switching repositories quickly
    /// (which is exactly what you do when you are hunting through projects)
    /// would otherwise let a slow `git status` on the *previous* repo land
    /// after the new one and repaint the panel with the wrong repository.
    private var generations: [String: Int] = [:]

    public init(runner: any ProcessRunning, locator: ToolLocator) {
        self.runner = runner
        self.locator = locator
    }

    public func repositoryRoot(containing path: String) async throws -> String {
        let git = try await locator.require("git")
        try Self.validateDirectory(path)
        let result = try await runner.run(
            Command(
                executable: git,
                arguments: ["rev-parse", "--show-toplevel"],
                workingDirectory: path,
                timeout: 5
            )
        )
        guard result.isSuccess else {
            throw ServiceError.invalidPath(path: path, reason: "not inside a git repository")
        }
        let root = result.trimmedOutput
        guard !root.isEmpty else {
            throw ServiceError.unreadableOutput(tool: "git", hint: "rev-parse returned no path")
        }
        return root
    }

    public func snapshot(ofRepositoryAt path: String) async throws -> GitRepositorySnapshot {
        let generation = (generations[path] ?? 0) + 1
        generations[path] = generation

        let git = try await locator.require("git")
        try Self.validateDirectory(path)

        // Status and log are independent, so run them concurrently: the two
        // together are the dominant cost of a refresh, and on a large
        // repository `git status` alone can take a few hundred milliseconds.
        async let statusTask = runner.run(
            Command(
                executable: git,
                arguments: [
                    "status", "--porcelain=v2", "--branch",
                    "--untracked-files=normal", "--no-renames",
                ],
                workingDirectory: path,
                timeout: 12
            )
        )
        async let logTask = runner.run(
            Command(
                executable: git,
                arguments: ["log", "-1", "--format=%H%x1f%s%x1f%an%x1f%aI"],
                workingDirectory: path,
                timeout: 8
            )
        )

        let statusResult = try await statusTask.requireSuccess(tool: "git status")
        // A repository with no commits makes `git log` fail; that is a normal
        // state for a freshly-initialised repo, not an error worth surfacing.
        let logResult = try? await logTask

        guard generations[path] == generation else {
            throw ServiceError.cancelled
        }
        try Task.checkCancellation()

        let status = GitPorcelainParser.parseStatus(statusResult.standardOutput)
        let commit = logResult.flatMap { $0.isSuccess ? GitPorcelainParser.parseCommit($0.standardOutput) : nil }

        Log.git.debug(
            "snapshot \(Redaction.path(path), privacy: .public) in \(statusResult.duration, format: .fixed(precision: 3))s"
        )

        return GitRepositorySnapshot(
            path: path,
            name: (path as NSString).lastPathComponent,
            branch: status.branch,
            detachedHash: status.detachedHash,
            tracking: status.tracking,
            workingTree: status.workingTree,
            lastCommit: commit,
            capturedAt: .now
        )
    }

    /// Guards against a repository directory that has been deleted, renamed, or
    /// unmounted since the user selected it — a genuinely common case with
    /// external drives and with `git worktree remove`.
    private static func validateDirectory(_ path: String) throws {
        var isDirectory: ObjCBool = false
        guard FileManager.default.fileExists(atPath: path, isDirectory: &isDirectory) else {
            throw ServiceError.invalidPath(path: path, reason: "directory no longer exists")
        }
        guard isDirectory.boolValue else {
            throw ServiceError.invalidPath(path: path, reason: "not a directory")
        }
    }
}
