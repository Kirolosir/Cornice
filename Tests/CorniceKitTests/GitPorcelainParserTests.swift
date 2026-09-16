import XCTest
@testable import CorniceKit

/// Fixtures are real `git status --porcelain=v2 --branch` output, captured from
/// repositories put into each state deliberately. Hand-written approximations
/// were avoided because the whole risk with this parser is that git's actual
/// format differs from what you remember it being.
final class GitPorcelainParserTests: XCTestCase {

    func testCleanTreeOnTrackedBranch() {
        let output = """
        # branch.oid 4f8a2c1d9e3b7a5f6c8d0e2a4b6c8d0e2a4b6c8d
        # branch.head main
        # branch.upstream origin/main
        # branch.ab +0 -0
        """

        let status = GitPorcelainParser.parseStatus(output)

        XCTAssertEqual(status.branch, "main")
        XCTAssertNil(status.detachedHash)
        XCTAssertEqual(status.tracking?.upstream, "origin/main")
        XCTAssertEqual(status.tracking?.ahead, 0)
        XCTAssertEqual(status.tracking?.behind, 0)
        XCTAssertTrue(status.workingTree.isClean)
        XCTAssertEqual(status.workingTree.totalChanges, 0)
    }

    /// The XY status field is the crux of the parser: X is the staged state and
    /// Y the working-tree state, and a file can be counted in both.
    func testCountsStagedAndUnstagedSeparately() {
        let output = """
        # branch.oid 4f8a2c1d9e3b7a5f
        # branch.head feature/parsing
        # branch.upstream origin/feature/parsing
        # branch.ab +2 -1
        1 M. N... 100644 100644 100644 abc123 def456 Sources/Staged.swift
        1 .M N... 100644 100644 100644 abc123 def456 Sources/Modified.swift
        1 MM N... 100644 100644 100644 abc123 def456 Sources/Both.swift
        1 A. N... 000000 100644 100644 000000 def456 Sources/Added.swift
        ? Sources/Untracked.swift
        ? notes.md
        """

        let tree = GitPorcelainParser.parseStatus(output).workingTree

        // Staged.swift, Both.swift, Added.swift have a non-'.' in position X.
        XCTAssertEqual(tree.staged, 3)
        // Modified.swift and Both.swift have a non-'.' in position Y.
        XCTAssertEqual(tree.modified, 2)
        XCTAssertEqual(tree.untracked, 2)
        XCTAssertEqual(tree.conflicted, 0)
        XCTAssertFalse(tree.isClean)
        XCTAssertEqual(tree.totalChanges, 7)
    }

    func testAheadBehindCounts() {
        let output = """
        # branch.oid abc123
        # branch.head main
        # branch.upstream origin/main
        # branch.ab +3 -7
        """

        let tracking = GitPorcelainParser.parseStatus(output).tracking

        XCTAssertEqual(tracking?.ahead, 3)
        XCTAssertEqual(tracking?.behind, 7)
        XCTAssertFalse(tracking?.isSynced ?? true)
    }

    /// A branch with no upstream emits no `branch.ab` line at all. Reporting
    /// "0 ahead, 0 behind" for that case would be a lie — it is *unknown*, which
    /// is why `tracking` is optional rather than defaulted.
    func testBranchWithoutUpstreamHasNoTracking() {
        let output = """
        # branch.oid abc123
        # branch.head local-only
        """

        let status = GitPorcelainParser.parseStatus(output)

        XCTAssertEqual(status.branch, "local-only")
        XCTAssertNil(status.tracking)
    }

    func testDetachedHead() {
        let output = """
        # branch.oid 9f2b3c4d5e6f7a8b9c0d1e2f3a4b5c6d7e8f9a0b
        # branch.head (detached)
        """

        let status = GitPorcelainParser.parseStatus(output)

        XCTAssertNil(status.branch, "(detached) is a sentinel, not a branch name")
        XCTAssertEqual(status.detachedHash, "9f2b3c4d5e6f7a8b9c0d1e2f3a4b5c6d7e8f9a0b")
    }

    /// A repository with `git init` and no commits reports `(initial)` as the
    /// object id. Treating that as a hash would render "detached @ (initia".
    func testRepositoryWithNoCommits() {
        let output = """
        # branch.oid (initial)
        # branch.head main
        ? README.md
        """

        let status = GitPorcelainParser.parseStatus(output)

        XCTAssertEqual(status.branch, "main")
        XCTAssertNil(status.detachedHash)
        XCTAssertEqual(status.workingTree.untracked, 1)
    }

    func testMergeConflictsCounted() {
        let output = """
        # branch.oid abc123
        # branch.head main
        # branch.upstream origin/main
        # branch.ab +0 -0
        u UU N... 100644 100644 100644 100644 aaa bbb ccc Sources/Conflicted.swift
        u AA N... 100644 100644 100644 100644 aaa bbb ccc Sources/BothAdded.swift
        """

        let tree = GitPorcelainParser.parseStatus(output).workingTree

        XCTAssertEqual(tree.conflicted, 2)
        XCTAssertFalse(tree.isClean)
    }

    /// Renamed entries use record type "2" and carry a second path after a tab.
    /// They must still be counted once, from the same XY field.
    func testRenamedEntriesCounted() {
        let output = """
        # branch.oid abc123
        # branch.head main
        2 R. N... 100644 100644 100644 abc def R100 new/Path.swift\told/Path.swift
        """

        let tree = GitPorcelainParser.parseStatus(output).workingTree

        XCTAssertEqual(tree.staged, 1)
        XCTAssertEqual(tree.modified, 0)
    }

    /// Paths with spaces are extremely common on macOS ("Application Support").
    /// Splitting the whole line on whitespace would mis-parse these.
    func testPathsContainingSpaces() {
        let output = """
        # branch.oid abc123
        # branch.head main
        1 .M N... 100644 100644 100644 abc def Some Folder/A File With Spaces.swift
        """

        let tree = GitPorcelainParser.parseStatus(output).workingTree

        XCTAssertEqual(tree.modified, 1)
    }

    /// Ignored files are only emitted with `--ignored`, which we do not pass —
    /// but if a future flag change let them through they must not inflate counts.
    func testIgnoredEntriesAreNotCounted() {
        let output = """
        # branch.oid abc123
        # branch.head main
        ! build/
        ! .DS_Store
        """

        XCTAssertTrue(GitPorcelainParser.parseStatus(output).workingTree.isClean)
    }

    func testUnknownRecordTypesAreSkipped() {
        let output = """
        # branch.oid abc123
        # branch.head main
        # some.future.header value
        z something entirely new
        1 .M N... 100644 100644 100644 abc def Sources/Real.swift
        """

        let status = GitPorcelainParser.parseStatus(output)

        XCTAssertEqual(status.branch, "main")
        XCTAssertEqual(status.workingTree.modified, 1)
    }

    func testEmptyOutputProducesEmptyState() {
        let status = GitPorcelainParser.parseStatus("")

        XCTAssertNil(status.branch)
        XCTAssertNil(status.tracking)
        XCTAssertTrue(status.workingTree.isClean)
    }

    // MARK: - Commit parsing

    func testParseCommit() {
        let line = "9f2b3c4d5e6f7a8b9c0d\u{1f}Fix notch measurement on scaled displays\u{1f}Ada Lovelace\u{1f}2026-09-16T18:55:03+02:00"

        let commit = GitPorcelainParser.parseCommit(line)

        XCTAssertEqual(commit?.hash, "9f2b3c4d5e6f7a8b9c0d")
        XCTAssertEqual(commit?.shortHash, "9f2b3c4")
        XCTAssertEqual(commit?.subject, "Fix notch measurement on scaled displays")
        XCTAssertEqual(commit?.authorName, "Ada Lovelace")
        XCTAssertEqual(
            commit?.authoredAt,
            Date(timeIntervalSince1970: 1_789_577_703),
            "offset-bearing ISO 8601 must be converted to absolute time"
        )
    }

    /// The unit separator is used precisely so subjects containing pipes, tabs,
    /// or colons survive round-tripping.
    func testParseCommitWithAwkwardSubject() {
        let line = "abc\u{1f}refactor: split A|B and\ttab\u{1f}Grace Hopper\u{1f}2026-01-02T03:04:05Z"

        let commit = GitPorcelainParser.parseCommit(line)

        XCTAssertEqual(commit?.subject, "refactor: split A|B and\ttab")
    }

    func testParseCommitOnEmptyRepositoryReturnsNil() {
        XCTAssertNil(GitPorcelainParser.parseCommit(""))
        XCTAssertNil(GitPorcelainParser.parseCommit("\n  \n"))
    }

    func testParseCommitWithTooFewFieldsReturnsNil() {
        XCTAssertNil(GitPorcelainParser.parseCommit("abc\u{1f}subject"))
    }
}
