import Foundation

/// A single commit, as much of one as the collapsed surface needs.
public struct GitCommit: Equatable, Sendable, Codable {
    public let hash: String
    public let subject: String
    public let authorName: String
    public let authoredAt: Date

    public init(hash: String, subject: String, authorName: String, authoredAt: Date) {
        self.hash = hash
        self.subject = subject
        self.authorName = authorName
        self.authoredAt = authoredAt
    }

    /// Seven characters, the length git itself abbreviates to by default.
    public var shortHash: String { String(hash.prefix(7)) }
}

/// Counts of changed files, split the way `git status` splits them.
///
/// Kept as a separate type because the collapsed surface shows only
/// `totalChanges` while the expanded panel breaks it down, and because the
/// arithmetic ("is this tree clean?") has enough edge cases — conflicts with no
/// staged changes, untracked-only trees — to be worth testing on its own.
public struct GitWorkingTree: Equatable, Sendable, Codable {
    public var staged: Int
    public var modified: Int
    public var untracked: Int
    public var conflicted: Int

    public init(staged: Int = 0, modified: Int = 0, untracked: Int = 0, conflicted: Int = 0) {
        self.staged = staged
        self.modified = modified
        self.untracked = untracked
        self.conflicted = conflicted
    }

    /// A tree is clean only when nothing at all is outstanding. Untracked files
    /// count: `git status` calls that tree dirty, and so should we.
    public var isClean: Bool {
        staged == 0 && modified == 0 && untracked == 0 && conflicted == 0
    }

    public var totalChanges: Int { staged + modified + untracked + conflicted }
}

/// Where the branch sits relative to its upstream.
public struct GitTracking: Equatable, Sendable, Codable {
    public let upstream: String
    public let ahead: Int
    public let behind: Int

    public init(upstream: String, ahead: Int, behind: Int) {
        self.upstream = upstream
        self.ahead = ahead
        self.behind = behind
    }

    public var isSynced: Bool { ahead == 0 && behind == 0 }
}

/// Everything the app knows about a repository at one instant.
public struct GitRepositorySnapshot: Equatable, Sendable, Codable, Identifiable {
    /// Absolute path to the repository root.
    public let path: String
    /// Directory name of the root — what the UI calls the repo.
    public let name: String
    /// Branch name, or `nil` when HEAD is detached.
    public let branch: String?
    /// The commit HEAD points at, when detached.
    public let detachedHash: String?
    public let tracking: GitTracking?
    public let workingTree: GitWorkingTree
    public let lastCommit: GitCommit?
    /// When this snapshot was taken, for the "as of" label and staleness checks.
    public let capturedAt: Date

    public var id: String { path }

    public init(
        path: String,
        name: String,
        branch: String?,
        detachedHash: String?,
        tracking: GitTracking?,
        workingTree: GitWorkingTree,
        lastCommit: GitCommit?,
        capturedAt: Date
    ) {
        self.path = path
        self.name = name
        self.branch = branch
        self.detachedHash = detachedHash
        self.tracking = tracking
        self.workingTree = workingTree
        self.lastCommit = lastCommit
        self.capturedAt = capturedAt
    }

    /// What to show where a branch name goes, including the detached-HEAD case
    /// that would otherwise render as an empty label.
    public var branchLabel: String {
        if let branch { return branch }
        if let detachedHash { return "detached @ \(detachedHash.prefix(7))" }
        return "unknown"
    }

    public var isDetached: Bool { branch == nil }
}
