import Foundation

/// Parses git's machine-readable output.
///
/// Everything here is a pure function over a string, which is the point: git's
/// output has a lot of shapes (detached HEAD, no upstream, renames, merge
/// conflicts, paths containing spaces, a repository with no commits at all) and
/// each one is a fixture in the test target rather than something you discover
/// by checking out an unusual branch.
///
/// `--porcelain=v2` is used rather than v1 because v1 has no stable way to
/// report ahead/behind counts, and because v2's header lines give us the branch
/// and its upstream in the same call that gives us the file counts — one
/// subprocess instead of three.
public enum GitPorcelainParser {

    /// Result of parsing `git status --porcelain=v2 --branch --untracked-files=normal`.
    public struct StatusOutput: Equatable, Sendable {
        public var branch: String?
        public var detachedHash: String?
        public var tracking: GitTracking?
        public var workingTree: GitWorkingTree
    }

    /// Parses the full status output.
    ///
    /// Unrecognised lines are skipped rather than treated as an error: git adds
    /// new record types over time, and a future `!` or `u` variant should
    /// degrade to a slightly-wrong count rather than an empty panel.
    public static func parseStatus(_ output: String) -> StatusOutput {
        var branch: String?
        var detachedHash: String?
        var upstream: String?
        var ahead = 0
        var behind = 0
        var tree = GitWorkingTree()

        for line in output.split(separator: "\n", omittingEmptySubsequences: true) {
            guard let kind = line.first else { continue }
            switch kind {
            case "#":
                parseHeader(
                    line,
                    branch: &branch,
                    detachedHash: &detachedHash,
                    upstream: &upstream,
                    ahead: &ahead,
                    behind: &behind
                )
            case "1", "2":
                // Ordinary ("1") and renamed/copied ("2") entries share the
                // same XY status field in position 1.
                applyChangeCodes(line, to: &tree)
            case "u":
                tree.conflicted += 1
            case "?":
                tree.untracked += 1
            case "!":
                // Ignored files. Only emitted with --ignored, which we do not
                // pass, but skip explicitly so they can never inflate counts.
                continue
            default:
                continue
            }
        }

        let tracking = upstream.map { GitTracking(upstream: $0, ahead: ahead, behind: behind) }
        return StatusOutput(
            branch: branch,
            detachedHash: detachedHash,
            tracking: tracking,
            workingTree: tree
        )
    }

    private static func parseHeader(
        _ line: Substring,
        branch: inout String?,
        detachedHash: inout String?,
        upstream: inout String?,
        ahead: inout Int,
        behind: inout Int
    ) {
        let fields = line.split(separator: " ", omittingEmptySubsequences: true)
        guard fields.count >= 3 else { return }
        let key = fields[1]
        let value = String(fields[2])

        switch key {
        case "branch.head":
            // git writes the literal string "(detached)" here when HEAD is not
            // on a branch. A branch can otherwise be named almost anything, so
            // this exact token is the only reliable signal.
            branch = value == "(detached)" ? nil : value
        case "branch.oid":
            // "(initial)" in a repository that has no commits yet.
            detachedHash = value == "(initial)" ? nil : value
        case "branch.upstream":
            upstream = value
        case "branch.ab":
            // Format: "+<ahead> -<behind>". Absent entirely when there is no
            // upstream, which is why `tracking` is optional.
            for field in fields.dropFirst(2) {
                guard let sign = field.first, let magnitude = Int(field.dropFirst()) else { continue }
                if sign == "+" { ahead = magnitude }
                if sign == "-" { behind = magnitude }
            }
        default:
            return
        }
    }

    /// Reads the two-character XY status field and increments the right counters.
    ///
    /// X is the index (staged) state and Y the working-tree state; `.` means
    /// unchanged in that half. A file can be both — staged, then edited again —
    /// and git reports that as a single entry, so it counts once in each bucket.
    private static func applyChangeCodes(_ line: Substring, to tree: inout GitWorkingTree) {
        let fields = line.split(separator: " ", maxSplits: 2, omittingEmptySubsequences: true)
        guard fields.count >= 2 else { return }
        let codes = fields[1]
        guard codes.count == 2 else { return }
        let staged = codes[codes.startIndex]
        let worktree = codes[codes.index(after: codes.startIndex)]
        if staged != "." { tree.staged += 1 }
        if worktree != "." { tree.modified += 1 }
    }

    /// Parses the single line produced by
    /// `git log -1 --format=%H%x1f%s%x1f%an%x1f%aI`.
    ///
    /// Fields are separated by US (0x1f) rather than by anything printable
    /// because a commit subject can contain any character at all, including
    /// tabs and pipes. Returns `nil` for an empty repository, where `git log`
    /// exits non-zero and prints nothing.
    public static func parseCommit(_ output: String) -> GitCommit? {
        let trimmed = output.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }
        let fields = trimmed.components(separatedBy: "\u{1f}")
        guard fields.count >= 4 else { return nil }
        guard let date = ISO8601DateFormatter.gitFormatter.date(from: fields[3]) else { return nil }
        return GitCommit(
            hash: fields[0],
            subject: fields[1],
            authorName: fields[2],
            authoredAt: date
        )
    }
}

extension ISO8601DateFormatter {
    /// git's `%aI` emits a strict ISO 8601 timestamp with a numeric offset,
    /// e.g. `2026-09-16T18:55:03+02:00`.
    ///
    /// A `nonisolated(unsafe)` shared instance rather than a new formatter per
    /// call: `ISO8601DateFormatter` is expensive to construct, this one is
    /// configured once and never mutated afterwards, and it is only ever read.
    nonisolated(unsafe) static let gitFormatter: ISO8601DateFormatter = {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime]
        return formatter
    }()
}
