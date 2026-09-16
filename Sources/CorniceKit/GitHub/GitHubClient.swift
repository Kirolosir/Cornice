import Foundation

/// Abstracts `URLSession` so tests can script HTTP responses.
public protocol HTTPTransporting: Sendable {
    func send(_ request: URLRequest) async throws -> (Data, HTTPURLResponse)
}

extension URLSession: HTTPTransporting {
    public func send(_ request: URLRequest) async throws -> (Data, HTTPURLResponse) {
        let (data, response) = try await data(for: request)
        guard let http = response as? HTTPURLResponse else {
            throw ServiceError.unreadableOutput(tool: "github", hint: "non-HTTP response")
        }
        return (data, http)
    }
}

/// What the GitHub module shows.
public struct GitHubDigest: Equatable, Sendable {
    public var viewer: String?
    public var myPullRequests: [PullRequest]
    public var reviewRequests: [PullRequest]
    public var workflowRuns: [WorkflowRun]
    public var rateLimit: RateLimitSnapshot?
    public var fetchedAt: Date
    /// True when everything here came from cache because the network was down.
    public var isStale: Bool

    public init(
        viewer: String? = nil,
        myPullRequests: [PullRequest] = [],
        reviewRequests: [PullRequest] = [],
        workflowRuns: [WorkflowRun] = [],
        rateLimit: RateLimitSnapshot? = nil,
        fetchedAt: Date = .now,
        isStale: Bool = false
    ) {
        self.viewer = viewer
        self.myPullRequests = myPullRequests
        self.reviewRequests = reviewRequests
        self.workflowRuns = workflowRuns
        self.rateLimit = rateLimit
        self.fetchedAt = fetchedAt
        self.isStale = isStale
    }

    /// Runs that failed, newest first — what the collapsed surface escalates.
    public var failedRuns: [WorkflowRun] {
        workflowRuns.filter(\.didFail).sorted { $0.updatedAt > $1.updatedAt }
    }
}

public protocol GitHubProviding: Sendable {
    func digest(watching slugs: [String], userInitiated: Bool) async throws -> GitHubDigest
    func verifyToken(_ token: String) async throws -> GitHubUser
}

/// Talks to the GitHub REST API.
///
/// The token is read from the credential store on demand and held only for the
/// duration of a request. It is never stored in a property, never written to a
/// log, and never included in an error message — `ServiceError.unauthorized`
/// carries an explanation, not the credential.
public actor GitHubClient: GitHubProviding {

    private static let apiRoot = URL(string: "https://api.github.com")!
    /// Account name under which the token is filed in the credential store.
    public static let credentialAccount = "github-token"

    private let transport: any HTTPTransporting
    private let credentials: any CredentialStoring
    private let cache: ResponseCache
    private var gate = RateLimitGate()

    /// Decoder configured for GitHub's timestamps, which are ISO 8601 with a
    /// `Z` suffix throughout the REST API.
    private let decoder: JSONDecoder = {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return decoder
    }()

    public init(
        transport: any HTTPTransporting,
        credentials: any CredentialStoring,
        cache: ResponseCache = ResponseCache()
    ) {
        self.transport = transport
        self.credentials = credentials
        self.cache = cache
    }

    /// Current quota, for the diagnostics row.
    public func rateLimit() -> RateLimitSnapshot? { gate.snapshot }

    public func cacheStatistics() async -> (hits: Int, conditionalHits: Int, misses: Int, savedFraction: Double) {
        await cache.statistics()
    }

    /// Checks a token and returns who it belongs to.
    ///
    /// Called when the user pastes a token, so they find out immediately
    /// whether it works rather than seeing an empty panel later. The token is a
    /// parameter rather than being read from the store because at this point it
    /// has not been saved — we only persist it once it is known to be valid.
    public func verifyToken(_ token: String) async throws -> GitHubUser {
        let request = try buildRequest(path: "/user", token: token)
        let (data, response) = try await perform(request)
        try Self.validate(response: response, data: data)
        return try decoder.decode(GitHubUser.self, from: data)
    }

    public func digest(watching slugs: [String], userInitiated: Bool) async throws -> GitHubDigest {
        guard let token = try await credentials.read(account: Self.credentialAccount) else {
            throw ServiceError.unauthorized(detail: "Connect a GitHub token in Settings.")
        }

        if case .deny(let until) = gate.decide(userInitiated: userInitiated) {
            Log.github.notice("refusing request: local rate-limit gate until \(until)")
            throw ServiceError.rateLimited(resetAt: until)
        }

        let viewer = try await self.viewer(token: token)

        // The three queries are independent, so they overlap. Search covers all
        // repositories in one request each; only the Actions status needs a
        // per-repository call, and that list is explicitly chosen by the user.
        async let mineTask = searchPullRequests(
            query: "is:open is:pr author:\(viewer.login) archived:false",
            viewerLogin: viewer.login, token: token
        )
        async let reviewsTask = searchPullRequests(
            query: "is:open is:pr review-requested:\(viewer.login) archived:false",
            viewerLogin: viewer.login, token: token, markAwaitingReview: true
        )
        async let runsTask = workflowRuns(slugs: slugs, token: token)

        // Each strand degrades on its own: a failing Actions call must not
        // remove the pull requests that loaded perfectly well.
        let mine = (try? await mineTask) ?? []
        let reviews = (try? await reviewsTask) ?? []
        let runs = (try? await runsTask) ?? []

        return GitHubDigest(
            viewer: viewer.login,
            myPullRequests: mine,
            reviewRequests: reviews,
            workflowRuns: runs,
            rateLimit: gate.snapshot,
            fetchedAt: .now,
            isStale: false
        )
    }

    // MARK: - Endpoints

    private func viewer(token: String) async throws -> GitHubUser {
        let request = try buildRequest(path: "/user", token: token)
        let data = try await cachedData(for: request, key: "viewer")
        return try decoder.decode(GitHubUser.self, from: data)
    }

    private func searchPullRequests(
        query: String,
        viewerLogin: String,
        token: String,
        markAwaitingReview: Bool = false
    ) async throws -> [PullRequest] {
        var components = URLComponents(
            url: Self.apiRoot.appendingPathComponent("/search/issues"),
            resolvingAgainstBaseURL: false
        )!
        components.queryItems = [
            URLQueryItem(name: "q", value: query),
            URLQueryItem(name: "per_page", value: "20"),
            URLQueryItem(name: "sort", value: "updated"),
        ]
        guard let url = components.url else {
            throw ServiceError.invalidConfiguration(reason: "could not build search URL")
        }
        let request = try buildRequest(url: url, token: token)
        let data = try await cachedData(for: request, key: "search:\(query)")
        let response = try decoder.decode(SearchIssuesResponse.self, from: data)

        return response.items.map { item in
            PullRequest(
                id: item.id,
                number: item.number,
                title: item.title,
                htmlURL: item.htmlURL,
                isDraft: item.draft ?? false,
                author: item.user.login,
                repositorySlug: item.repositorySlug,
                updatedAt: item.updatedAt,
                awaitingMyReview: markAwaitingReview
            )
        }
    }

    /// Latest workflow run per watched repository.
    ///
    /// `per_page=1` because only the most recent run is shown: asking for a
    /// page of 30 and discarding 29 would transfer far more data for no benefit,
    /// and the response would change (and so miss the ETag) every time *any*
    /// run in that repository updated.
    private func workflowRuns(slugs: [String], token: String) async throws -> [WorkflowRun] {
        let valid = slugs.compactMap { slug -> String? in
            guard GitHubSlug.isValid(slug) else {
                Log.github.notice("skipping malformed repository slug")
                return nil
            }
            return slug
        }
        guard !valid.isEmpty else { return [] }

        return await withTaskGroup(of: WorkflowRun?.self) { group in
            for slug in valid {
                group.addTask { [weak self] in
                    guard let self else { return nil }
                    return try? await self.latestRun(slug: slug, token: token)
                }
            }
            var runs: [WorkflowRun] = []
            for await run in group {
                if let run { runs.append(run) }
            }
            return runs.sorted { $0.updatedAt > $1.updatedAt }
        }
    }

    private func latestRun(slug: String, token: String) async throws -> WorkflowRun? {
        guard let parts = GitHubSlug.split(slug) else { return nil }
        var components = URLComponents(
            url: Self.apiRoot.appendingPathComponent("/repos/\(parts.owner)/\(parts.repository)/actions/runs"),
            resolvingAgainstBaseURL: false
        )!
        components.queryItems = [URLQueryItem(name: "per_page", value: "1")]
        guard let url = components.url else { return nil }

        let request = try buildRequest(url: url, token: token)
        let data = try await cachedData(for: request, key: "runs:\(slug)")
        let response = try decoder.decode(WorkflowRunsResponse.self, from: data)
        return response.workflowRuns.first?.toDomain(defaultSlug: slug)
    }

    // MARK: - Transport

    private func buildRequest(path: String, token: String) throws -> URLRequest {
        try buildRequest(url: Self.apiRoot.appendingPathComponent(path), token: token)
    }

    private func buildRequest(url: URL, token: String) throws -> URLRequest {
        var request = URLRequest(url: url)
        request.httpMethod = "GET"
        request.setValue("application/vnd.github+json", forHTTPHeaderField: "Accept")
        request.setValue("2022-11-28", forHTTPHeaderField: "X-GitHub-Api-Version")
        request.setValue("Cornice", forHTTPHeaderField: "User-Agent")
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        // The app does its own caching keyed on ETags, and URLSession's
        // heuristic cache would otherwise hide 304s from the counters.
        request.cachePolicy = .reloadIgnoringLocalCacheData
        request.timeoutInterval = 15
        return request
    }

    /// Runs a request through the cache: fresh hit, then conditional request,
    /// then full fetch. Falls back to stale data when the network is gone.
    private func cachedData(for request: URLRequest, key: String) async throws -> Data {
        if let fresh = await cache.fresh(for: key) { return fresh }

        var conditional = request
        if let etag = await cache.etag(for: key) {
            conditional.setValue(etag, forHTTPHeaderField: "If-None-Match")
        }

        let data: Data
        let response: HTTPURLResponse
        do {
            (data, response) = try await perform(conditional)
        } catch ServiceError.offline {
            // Showing yesterday's pull requests with a "stale" marker is more
            // useful than showing nothing because the Wi-Fi dropped.
            if let stored = await cache.stored(for: key) {
                Log.github.notice("offline; serving cached response for \(key, privacy: .public)")
                return stored
            }
            throw ServiceError.offline
        }

        if let snapshot = RateLimitSnapshot.parse(headers: response.allHeaderFields) {
            gate.snapshot = snapshot
        }

        if response.statusCode == 304 {
            await cache.touch(key)
            guard let stored = await cache.stored(for: key) else {
                // A 304 with nothing cached should be impossible, since we only
                // send If-None-Match when we hold an entry. Treat it as a miss
                // and let the next refresh fetch in full.
                throw ServiceError.unreadableOutput(tool: "github", hint: "304 with no cached body")
            }
            return stored
        }

        try Self.validate(response: response, data: data)
        let etag = response.value(forHTTPHeaderField: "ETag")
        await cache.store(data, etag: etag, rateLimit: gate.snapshot, for: key)
        return data
    }

    private func perform(_ request: URLRequest) async throws -> (Data, HTTPURLResponse) {
        do {
            return try await transport.send(request)
        } catch let error as ServiceError {
            throw error
        } catch let error as URLError {
            switch error.code {
            case .notConnectedToInternet, .networkConnectionLost, .cannotFindHost,
                 .cannotConnectToHost, .dnsLookupFailed, .internationalRoamingOff,
                 .dataNotAllowed:
                throw ServiceError.offline
            case .timedOut:
                throw ServiceError.timedOut(tool: "github", seconds: request.timeoutInterval)
            case .cancelled:
                throw ServiceError.cancelled
            default:
                throw ServiceError.api(status: error.errorCode, message: error.localizedDescription)
            }
        }
    }

    /// Maps HTTP status codes onto `ServiceError`.
    ///
    /// The 403 case matters: GitHub uses it both for "you are out of quota" and
    /// for ordinary permission failures, and the two need very different
    /// handling — one is retryable after a wait, the other never is. The
    /// remaining-count header is what distinguishes them.
    static func validate(response: HTTPURLResponse, data: Data) throws {
        switch response.statusCode {
        case 200...299:
            return
        case 304:
            return
        case 401:
            throw ServiceError.unauthorized(
                detail: "GitHub rejected the token. It may have expired or been revoked."
            )
        case 403, 429:
            let snapshot = RateLimitSnapshot.parse(headers: response.allHeaderFields)
            if snapshot?.remaining == 0 || response.statusCode == 429 {
                throw ServiceError.rateLimited(resetAt: snapshot?.resetsAt ?? retryAfter(response))
            }
            throw ServiceError.unauthorized(
                detail: "The token does not have access to that resource. Check its scopes."
            )
        case 404:
            throw ServiceError.api(status: 404, message: "Not found, or the token cannot see it.")
        default:
            throw ServiceError.api(status: response.statusCode, message: Self.message(from: data))
        }
    }

    /// Honours `Retry-After` for GitHub's secondary (abuse) rate limiter, which
    /// does not send the `x-ratelimit-*` headers.
    private static func retryAfter(_ response: HTTPURLResponse) -> Date? {
        guard let raw = response.value(forHTTPHeaderField: "Retry-After"),
              let seconds = Double(raw) else { return nil }
        return Date().addingTimeInterval(seconds)
    }

    /// Pulls GitHub's `message` field out of an error body, without ever
    /// echoing the whole payload into a log or a tooltip.
    private static func message(from data: Data) -> String {
        guard let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let message = object["message"] as? String
        else { return "Unexpected response." }
        return String(message.prefix(200))
    }
}
