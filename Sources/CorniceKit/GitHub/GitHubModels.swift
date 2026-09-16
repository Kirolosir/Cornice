import Foundation

/// Validates and splits `owner/repo` slugs.
///
/// Repository slugs reach the app from user input and are interpolated into
/// request paths, so they are validated against GitHub's actual naming rules
/// before they can become part of a URL. Without this, a "repository" of
/// `../../user/repos` would rewrite the endpoint being called.
public enum GitHubSlug {
    /// GitHub allows alphanumerics, hyphens, underscores and dots in both
    /// halves; owners additionally may not start or end with a hyphen. Anything
    /// else — slashes, encoded characters, whitespace — is rejected.
    public static func isValid(_ slug: String) -> Bool {
        split(slug) != nil
    }

    /// Splits into owner and repository, or `nil` when the slug is malformed.
    public static func split(_ slug: String) -> (owner: String, repository: String)? {
        let parts = slug.split(separator: "/", omittingEmptySubsequences: false)
        guard parts.count == 2 else { return nil }
        let owner = String(parts[0])
        let repository = String(parts[1])
        guard isValidComponent(owner), isValidComponent(repository) else { return nil }
        guard !owner.hasPrefix("-"), !owner.hasSuffix("-") else { return nil }
        return (owner, repository)
    }

    private static func isValidComponent(_ component: String) -> Bool {
        guard !component.isEmpty, component.count <= 100 else { return false }
        guard component != ".", component != ".." else { return false }
        return component.allSatisfy { character in
            character.isASCII && (character.isLetter || character.isNumber
                || character == "-" || character == "_" || character == ".")
        }
    }
}

public struct GitHubUser: Codable, Equatable, Sendable {
    public let login: String
    public let avatarURL: URL?
    public let htmlURL: URL?

    enum CodingKeys: String, CodingKey {
        case login
        case avatarURL = "avatar_url"
        case htmlURL = "html_url"
    }
}

/// A pull request, reduced to the fields the panel shows.
public struct PullRequest: Codable, Equatable, Sendable, Identifiable {
    public let id: Int
    public let number: Int
    public let title: String
    public let htmlURL: URL
    public let isDraft: Bool
    public let author: String
    public let repositorySlug: String
    public let updatedAt: Date
    /// True when the current user is on the requested-reviewers list.
    public var awaitingMyReview: Bool

    public init(
        id: Int, number: Int, title: String, htmlURL: URL, isDraft: Bool,
        author: String, repositorySlug: String, updatedAt: Date, awaitingMyReview: Bool
    ) {
        self.id = id
        self.number = number
        self.title = title
        self.htmlURL = htmlURL
        self.isDraft = isDraft
        self.author = author
        self.repositorySlug = repositorySlug
        self.updatedAt = updatedAt
        self.awaitingMyReview = awaitingMyReview
    }
}

/// The search API's PR shape, which differs from the repository PR endpoint.
///
/// Search is used rather than per-repository listing because one query answers
/// "my open PRs across everything" — the alternative is one request per watched
/// repository, which is exactly the kind of quota-burning fan-out the caching
/// layer exists to avoid.
struct SearchIssuesResponse: Codable, Sendable {
    let totalCount: Int
    let items: [Item]

    struct Item: Codable, Sendable {
        let id: Int
        let number: Int
        let title: String
        let htmlURL: URL
        let draft: Bool?
        let user: GitHubUser
        let updatedAt: Date
        /// Search returns the API URL of the parent repository; the slug has to
        /// be recovered from its path because there is no slug field.
        let repositoryURL: URL

        enum CodingKeys: String, CodingKey {
            case id, number, title, draft, user
            case htmlURL = "html_url"
            case updatedAt = "updated_at"
            case repositoryURL = "repository_url"
        }

        /// `https://api.github.com/repos/owner/name` → `owner/name`.
        var repositorySlug: String {
            let components = repositoryURL.pathComponents.filter { $0 != "/" }
            guard components.count >= 3 else { return repositoryURL.lastPathComponent }
            return "\(components[components.count - 2])/\(components[components.count - 1])"
        }
    }

    enum CodingKeys: String, CodingKey {
        case totalCount = "total_count"
        case items
    }
}

/// A GitHub Actions run.
public struct WorkflowRun: Codable, Equatable, Sendable, Identifiable {
    public enum Status: String, Codable, Sendable {
        case queued, inProgress, completed, waiting, requested, pending, unknown

        /// Whether the run is still going, which drives the pulsing indicator.
        public var isActive: Bool {
            switch self {
            case .queued, .inProgress, .waiting, .requested, .pending: true
            case .completed, .unknown: false
            }
        }
    }

    public enum Conclusion: String, Codable, Sendable {
        case success, failure, cancelled, skipped, timedOut, actionRequired, neutral, stale, unknown
    }

    public let id: Int
    public let name: String
    public let status: Status
    public let conclusion: Conclusion?
    public let branch: String
    public let commitMessage: String
    public let commitSHA: String
    public let htmlURL: URL
    public let createdAt: Date
    public let updatedAt: Date
    public let repositorySlug: String

    public init(
        id: Int, name: String, status: Status, conclusion: Conclusion?, branch: String,
        commitMessage: String, commitSHA: String, htmlURL: URL,
        createdAt: Date, updatedAt: Date, repositorySlug: String
    ) {
        self.id = id
        self.name = name
        self.status = status
        self.conclusion = conclusion
        self.branch = branch
        self.commitMessage = commitMessage
        self.commitSHA = commitSHA
        self.htmlURL = htmlURL
        self.createdAt = createdAt
        self.updatedAt = updatedAt
        self.repositorySlug = repositorySlug
    }

    public var shortSHA: String { String(commitSHA.prefix(7)) }

    /// Wall-clock duration, or time so far for a run still going.
    public var duration: TimeInterval { updatedAt.timeIntervalSince(createdAt) }

    public var didFail: Bool {
        conclusion == .failure || conclusion == .timedOut || conclusion == .actionRequired
    }
}

/// Wire format for the Actions endpoint.
///
/// A separate type from `WorkflowRun` so GitHub's spelling — snake case,
/// hyphenated enum values, a nullable conclusion — stays at the boundary
/// instead of leaking into the UI. Unknown enum values decode to `.unknown`
/// rather than throwing, so a new GitHub status cannot empty the panel.
struct WorkflowRunsResponse: Codable, Sendable {
    let totalCount: Int
    let workflowRuns: [Item]

    struct Item: Codable, Sendable {
        let id: Int
        let name: String?
        let status: String?
        let conclusion: String?
        let headBranch: String?
        let headSHA: String
        let htmlURL: URL
        let createdAt: Date
        let updatedAt: Date
        let headCommit: HeadCommit?
        let repository: Repository?

        struct HeadCommit: Codable, Sendable {
            let message: String?
        }

        struct Repository: Codable, Sendable {
            let fullName: String?
            enum CodingKeys: String, CodingKey { case fullName = "full_name" }
        }

        enum CodingKeys: String, CodingKey {
            case id, name, status, conclusion, repository
            case headBranch = "head_branch"
            case headSHA = "head_sha"
            case htmlURL = "html_url"
            case createdAt = "created_at"
            case updatedAt = "updated_at"
            case headCommit = "head_commit"
        }
    }

    enum CodingKeys: String, CodingKey {
        case totalCount = "total_count"
        case workflowRuns = "workflow_runs"
    }
}

extension WorkflowRunsResponse.Item {
    /// Maps the wire shape onto the domain type.
    ///
    /// GitHub spells multi-word values with underscores (`in_progress`,
    /// `timed_out`); they are normalised here so the domain enum can use plain
    /// Swift camel case.
    func toDomain(defaultSlug: String) -> WorkflowRun {
        WorkflowRun(
            id: id,
            name: name ?? "Workflow",
            status: WorkflowRun.Status(rawValue: Self.camelCased(status)) ?? .unknown,
            conclusion: conclusion.flatMap { WorkflowRun.Conclusion(rawValue: Self.camelCased($0)) } ?? (conclusion == nil ? nil : .unknown),
            branch: headBranch ?? "—",
            commitMessage: headCommit?.message?.split(separator: "\n").first.map(String.init) ?? "",
            commitSHA: headSHA,
            htmlURL: htmlURL,
            createdAt: createdAt,
            updatedAt: updatedAt,
            repositorySlug: repository?.fullName ?? defaultSlug
        )
    }

    private static func camelCased(_ raw: String?) -> String {
        guard let raw, !raw.isEmpty else { return "" }
        let parts = raw.split(separator: "_")
        guard let first = parts.first else { return raw }
        return ([String(first)] + parts.dropFirst().map(\.capitalized)).joined()
    }
}
