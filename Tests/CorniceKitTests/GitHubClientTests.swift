import XCTest
@testable import CorniceKit

/// A transport that replays scripted responses and records what was sent.
///
/// Live GitHub access from a test suite would be slow, would need a real token
/// in CI, and could not reproduce the cases that matter most — rate-limit
/// exhaustion, a 304, an expired token.
private actor StubTransport: HTTPTransporting {
    struct Reply {
        var status: Int
        var body: Data
        var headers: [String: String]

        init(status: Int = 200, body: Data = Data(), headers: [String: String] = [:]) {
            self.status = status
            self.body = body
            self.headers = headers
        }
    }

    private var replies: [Reply]
    private var error: (any Error)?
    private(set) var requests: [URLRequest] = []

    init(replies: [Reply] = [], error: (any Error)? = nil) {
        self.replies = replies
        self.error = error
    }

    var requestCount: Int { requests.count }

    func conditionalRequestCount() -> Int {
        requests.filter { $0.value(forHTTPHeaderField: "If-None-Match") != nil }.count
    }

    func lastAuthorizationHeader() -> String? {
        requests.last?.value(forHTTPHeaderField: "Authorization")
    }

    func send(_ request: URLRequest) async throws -> (Data, HTTPURLResponse) {
        requests.append(request)
        if let error { throw error }
        let reply = replies.isEmpty ? Reply() : replies.removeFirst()
        let response = HTTPURLResponse(
            url: request.url!,
            statusCode: reply.status,
            httpVersion: "HTTP/1.1",
            headerFields: reply.headers
        )!
        return (reply.body, response)
    }
}

final class GitHubClientTests: XCTestCase {

    private func userBody(login: String = "octocat") -> Data {
        Data(#"{"login":"\#(login)","avatar_url":null,"html_url":null}"#.utf8)
    }

    private func rateLimitHeaders(remaining: Int = 4999, limit: Int = 5000) -> [String: String] {
        [
            "x-ratelimit-limit": "\(limit)",
            "x-ratelimit-remaining": "\(remaining)",
            "x-ratelimit-reset": "\(Int(Date().addingTimeInterval(3600).timeIntervalSince1970))",
        ]
    }

    // MARK: - Decoding

    func testDecodesSearchResults() throws {
        let json = Data("""
        {"total_count":1,"items":[{
          "id":1,"number":42,"title":"Measure the notch instead of guessing",
          "html_url":"https://github.com/acme/tools/pull/42","draft":false,
          "user":{"login":"octocat","avatar_url":null,"html_url":null},
          "updated_at":"2026-09-16T10:00:00Z",
          "repository_url":"https://api.github.com/repos/acme/tools"}]}
        """.utf8)

        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        let response = try decoder.decode(SearchIssuesResponse.self, from: json)

        XCTAssertEqual(response.items.count, 1)
        XCTAssertEqual(response.items[0].number, 42)
        // The search API gives an API URL, not a slug; it has to be recovered.
        XCTAssertEqual(response.items[0].repositorySlug, "acme/tools")
    }

    func testDecodesWorkflowRunsAndNormalisesEnums() throws {
        let json = Data("""
        {"total_count":1,"workflow_runs":[{
          "id":9,"name":"CI","status":"in_progress","conclusion":null,
          "head_branch":"main","head_sha":"abcdef1234567890",
          "html_url":"https://github.com/acme/tools/actions/runs/9",
          "created_at":"2026-09-16T10:00:00Z","updated_at":"2026-09-16T10:02:30Z",
          "head_commit":{"message":"Fix flake\\n\\nlonger body"},
          "repository":{"full_name":"acme/tools"}}]}
        """.utf8)

        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        let run = try decoder.decode(WorkflowRunsResponse.self, from: json)
            .workflowRuns[0].toDomain(defaultSlug: "fallback/slug")

        XCTAssertEqual(run.status, .inProgress, "in_progress must map to camel case")
        XCTAssertTrue(run.status.isActive)
        XCTAssertNil(run.conclusion, "a running job has no conclusion yet")
        XCTAssertEqual(run.commitMessage, "Fix flake", "only the subject line is shown")
        XCTAssertEqual(run.shortSHA, "abcdef1")
        XCTAssertEqual(run.duration, 150)
        XCTAssertEqual(run.repositorySlug, "acme/tools")
    }

    /// A status GitHub adds later must not throw and empty the whole panel.
    func testUnknownEnumValuesDecodeToUnknown() throws {
        let json = Data("""
        {"total_count":1,"workflow_runs":[{
          "id":9,"name":null,"status":"quantum_superposition","conclusion":"mystified",
          "head_branch":null,"head_sha":"abc",
          "html_url":"https://github.com/a/b/actions/runs/9",
          "created_at":"2026-09-16T10:00:00Z","updated_at":"2026-09-16T10:00:00Z"}]}
        """.utf8)

        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        let run = try decoder.decode(WorkflowRunsResponse.self, from: json)
            .workflowRuns[0].toDomain(defaultSlug: "a/b")

        XCTAssertEqual(run.status, .unknown)
        XCTAssertEqual(run.conclusion, .unknown)
        XCTAssertEqual(run.name, "Workflow", "a null name falls back")
        XCTAssertEqual(run.branch, "—")
        XCTAssertEqual(run.repositorySlug, "a/b", "falls back to the requested slug")
    }

    func testFailureConclusionsAreFlagged() {
        func run(_ conclusion: WorkflowRun.Conclusion?) -> WorkflowRun {
            WorkflowRun(
                id: 1, name: "CI", status: .completed, conclusion: conclusion,
                branch: "main", commitMessage: "", commitSHA: "abc",
                htmlURL: URL(string: "https://example.com")!,
                createdAt: .now, updatedAt: .now, repositorySlug: "a/b"
            )
        }

        XCTAssertTrue(run(.failure).didFail)
        XCTAssertTrue(run(.timedOut).didFail)
        XCTAssertTrue(run(.actionRequired).didFail)
        XCTAssertFalse(run(.success).didFail)
        XCTAssertFalse(run(.cancelled).didFail, "a cancelled run is not a failing check")
        XCTAssertFalse(run(nil).didFail)
    }

    // MARK: - Token verification

    func testVerifyTokenReturnsUser() async throws {
        let transport = StubTransport(replies: [
            .init(status: 200, body: userBody(), headers: rateLimitHeaders()),
        ])
        let client = GitHubClient(transport: transport, credentials: EphemeralCredentialStore())

        let user = try await client.verifyToken("ghp_example")

        XCTAssertEqual(user.login, "octocat")
        let header = await transport.lastAuthorizationHeader()
        XCTAssertEqual(header, "Bearer ghp_example")
    }

    func testExpiredTokenIsReportedAsUnauthorized() async {
        let transport = StubTransport(replies: [.init(status: 401, body: Data(#"{"message":"Bad credentials"}"#.utf8))])
        let client = GitHubClient(transport: transport, credentials: EphemeralCredentialStore())

        do {
            _ = try await client.verifyToken("ghp_expired")
            XCTFail("expected unauthorized")
        } catch let error as ServiceError {
            guard case .unauthorized = error else { return XCTFail("got \(error)") }
            XCTAssertFalse(error.isRetryable, "retrying a bad token cannot help")
            XCTAssertFalse(error.detail.contains("ghp_expired"), "the token must never appear in an error")
        } catch {
            XCTFail("got \(error)")
        }
    }

    // MARK: - Status mapping

    /// GitHub returns 403 both for quota exhaustion and for ordinary permission
    /// failures. The remaining-count header is what distinguishes them, and the
    /// two need opposite handling.
    func testRateLimited403MapsToRateLimited() {
        let response = HTTPURLResponse(
            url: URL(string: "https://api.github.com/user")!,
            statusCode: 403, httpVersion: nil,
            headerFields: [
                "x-ratelimit-limit": "5000",
                "x-ratelimit-remaining": "0",
                "x-ratelimit-reset": "\(Int(Date().addingTimeInterval(600).timeIntervalSince1970))",
            ]
        )!

        XCTAssertThrowsError(try GitHubClient.validate(response: response, data: Data())) { error in
            guard case ServiceError.rateLimited(let resetAt) = error else {
                return XCTFail("got \(error)")
            }
            XCTAssertNotNil(resetAt)
        }
    }

    func testPermission403MapsToUnauthorized() {
        let response = HTTPURLResponse(
            url: URL(string: "https://api.github.com/user")!,
            statusCode: 403, httpVersion: nil,
            headerFields: ["x-ratelimit-remaining": "4000"]
        )!

        XCTAssertThrowsError(try GitHubClient.validate(response: response, data: Data())) { error in
            guard case ServiceError.unauthorized = error else { return XCTFail("got \(error)") }
        }
    }

    /// The secondary (abuse) limiter returns 429 with `Retry-After` and none of
    /// the `x-ratelimit-*` headers.
    func testSecondaryRateLimitUsesRetryAfter() {
        let response = HTTPURLResponse(
            url: URL(string: "https://api.github.com/search/issues")!,
            statusCode: 429, httpVersion: nil,
            headerFields: ["Retry-After": "60"]
        )!

        XCTAssertThrowsError(try GitHubClient.validate(response: response, data: Data())) { error in
            guard case ServiceError.rateLimited(let resetAt) = error else {
                return XCTFail("got \(error)")
            }
            XCTAssertNotNil(resetAt, "Retry-After must be honoured")
        }
    }

    func testErrorBodyMessageIsSurfacedButBounded() {
        let long = String(repeating: "x", count: 5000)
        let response = HTTPURLResponse(
            url: URL(string: "https://api.github.com/user")!,
            statusCode: 500, httpVersion: nil, headerFields: [:]
        )!

        XCTAssertThrowsError(
            try GitHubClient.validate(response: response, data: Data(#"{"message":"\#(long)"}"#.utf8))
        ) { error in
            guard case ServiceError.api(let status, let message) = error else {
                return XCTFail("got \(error)")
            }
            XCTAssertEqual(status, 500)
            XCTAssertLessThanOrEqual(message.count, 200, "an error body must not flood a tooltip")
        }
    }

    // MARK: - Offline

    func testOfflineFallsBackToCachedDigest() async throws {
        let cache = ResponseCache()
        let credentials = EphemeralCredentialStore(seed: [GitHubClient.credentialAccount: "ghp_x"])

        // Warm the cache with a good response.
        let warm = StubTransport(replies: [
            .init(status: 200, body: userBody(), headers: rateLimitHeaders()),
            .init(status: 200, body: Data(#"{"total_count":0,"items":[]}"#.utf8), headers: rateLimitHeaders()),
            .init(status: 200, body: Data(#"{"total_count":0,"items":[]}"#.utf8), headers: rateLimitHeaders()),
        ])
        _ = try await GitHubClient(transport: warm, credentials: credentials, cache: cache)
            .digest(watching: [], userInitiated: true)

        // Now the network is gone; the cached viewer must still resolve.
        let offline = StubTransport(error: URLError(.notConnectedToInternet))
        let digest = try await GitHubClient(transport: offline, credentials: credentials, cache: cache)
            .digest(watching: [], userInitiated: true)

        XCTAssertEqual(digest.viewer, "octocat", "cached data beats an empty panel")
    }

    func testOfflineWithNoCacheThrowsOffline() async {
        let transport = StubTransport(error: URLError(.notConnectedToInternet))
        let credentials = EphemeralCredentialStore(seed: [GitHubClient.credentialAccount: "ghp_x"])
        let client = GitHubClient(transport: transport, credentials: credentials, cache: ResponseCache())

        do {
            _ = try await client.digest(watching: [], userInitiated: true)
            XCTFail("expected offline")
        } catch let error as ServiceError {
            XCTAssertEqual(error, .offline)
            XCTAssertTrue(error.isRetryable)
        } catch {
            XCTFail("got \(error)")
        }
    }

    func testMissingTokenIsReportedBeforeAnyRequest() async {
        let transport = StubTransport()
        let client = GitHubClient(transport: transport, credentials: EphemeralCredentialStore())

        do {
            _ = try await client.digest(watching: [], userInitiated: true)
            XCTFail("expected unauthorized")
        } catch let error as ServiceError {
            guard case .unauthorized = error else { return XCTFail("got \(error)") }
            let count = await transport.requestCount
            XCTAssertEqual(count, 0, "no request should be sent without a credential")
        } catch {
            XCTFail("got \(error)")
        }
    }

    /// Malformed slugs are dropped before they can be interpolated into a path.
    func testMalformedSlugsAreNeverRequested() async throws {
        let credentials = EphemeralCredentialStore(seed: [GitHubClient.credentialAccount: "ghp_x"])
        let transport = StubTransport(replies: [
            .init(status: 200, body: userBody(), headers: rateLimitHeaders()),
            .init(status: 200, body: Data(#"{"total_count":0,"items":[]}"#.utf8), headers: rateLimitHeaders()),
            .init(status: 200, body: Data(#"{"total_count":0,"items":[]}"#.utf8), headers: rateLimitHeaders()),
        ])
        let client = GitHubClient(transport: transport, credentials: credentials, cache: ResponseCache())

        _ = try await client.digest(watching: ["../../admin", "no-slash"], userInitiated: true)

        let requests = await transport.requests
        XCTAssertFalse(
            requests.contains { $0.url?.absoluteString.contains("admin") ?? false },
            "a traversal attempt must never reach the network"
        )
    }
}
