import XCTest
@testable import CorniceKit

/// A transport that answers from a script instead of a socket.
private final class StubTransport: HTTPTransport, @unchecked Sendable {
    private let lock = NSLock()
    private var replies: [HTTPReply]
    private(set) var sent: [URLRequest] = []

    init(_ replies: [HTTPReply]) { self.replies = replies }

    func send(_ request: URLRequest) async throws -> HTTPReply {
        lock.withLock {
            sent.append(request)
            guard !replies.isEmpty else {
                return HTTPReply(status: 500, body: Data("{}".utf8))
            }
            return replies.removeFirst()
        }
    }

    var bodies: [String] {
        lock.withLock { sent.map { String(data: $0.httpBody ?? Data(), encoding: .utf8) ?? "" } }
    }
}

private func tokenReply(
    access: String = "access-1",
    refresh: String? = "refresh-1",
    expiresIn: Int = 3600
) -> HTTPReply {
    var object: [String: Any] = ["access_token": access, "expires_in": expiresIn]
    if let refresh { object["refresh_token"] = refresh }
    return HTTPReply(status: 200, body: try! JSONSerialization.data(withJSONObject: object))
}

final class SpotifyWebTests: XCTestCase {

    // MARK: - PKCE

    func testChallengeIsTheUnpaddedURLSafeDigestOfTheVerifier() {
        // The one vector RFC 7636 spells out, so a mistake in the encoding shows
        // up here rather than as an opaque `invalid_grant` from Spotify.
        let pkce = SpotifyPKCE(verifier: "dBjftJeZ4CVP-mB92K27uhbUJU1p1r_wW1gFWFOEjXk")
        XCTAssertEqual(pkce.challenge, "E9Melhoa2OwvFrEMTJguCHaoeK1t8URWbuGJSstw-cM")
    }

    func testChallengeCarriesNoCharacterThatWouldNeedEscaping() {
        for _ in 0..<50 {
            let challenge = SpotifyPKCE.random().challenge
            XCTAssertFalse(challenge.contains("+"))
            XCTAssertFalse(challenge.contains("/"))
            XCTAssertFalse(challenge.contains("="))
        }
    }

    func testVerifiersAreDistinctAndWithinTheLengthTheSpecAllows() {
        let verifiers = Set((0..<20).map { _ in SpotifyPKCE.random().verifier })
        XCTAssertEqual(verifiers.count, 20)
        for verifier in verifiers {
            XCTAssertGreaterThanOrEqual(verifier.count, 43)
            XCTAssertLessThanOrEqual(verifier.count, 128)
        }
    }

    // MARK: - Authorize URL

    func testAuthorizeURLCarriesEverythingSpotifyRequires() {
        let pkce = SpotifyPKCE(verifier: "verifier")
        let url = SpotifyAuthorization.authorizeURL(
            clientID: "abc123", pkce: pkce, state: "state-value"
        )
        let items = URLComponents(url: url, resolvingAgainstBaseURL: false)!.queryItems ?? []
        func value(_ name: String) -> String? { items.first { $0.name == name }?.value }

        XCTAssertEqual(url.host, "accounts.spotify.com")
        XCTAssertEqual(value("client_id"), "abc123")
        XCTAssertEqual(value("response_type"), "code")
        XCTAssertEqual(value("redirect_uri"), "cornice://spotify-callback")
        XCTAssertEqual(value("code_challenge_method"), "S256")
        XCTAssertEqual(value("code_challenge"), pkce.challenge)
        XCTAssertEqual(value("state"), "state-value")
    }

    func testOnlyPlaybackScopesAreRequested() {
        // Asking for more than the feature needs is a thing users notice on the
        // consent screen, and rightly.
        XCTAssertEqual(SpotifyScope.required, ["user-read-playback-state", "user-modify-playback-state"])
    }

    // MARK: - Redirect

    func testCodeIsReadFromAMatchingRedirect() throws {
        let url = URL(string: "cornice://spotify-callback?code=the-code&state=s1")!
        XCTAssertEqual(try SpotifyAuthorization.code(from: url, expectedState: "s1"), "the-code")
    }

    func testRedirectWithTheWrongStateIsRefused() {
        // Without this check any process able to open a cornice:// URL could
        // feed the app a code of its choosing.
        let url = URL(string: "cornice://spotify-callback?code=the-code&state=attacker")!
        XCTAssertThrowsError(try SpotifyAuthorization.code(from: url, expectedState: "s1")) { error in
            guard case ServiceError.unauthorized = error else {
                return XCTFail("expected unauthorized, got \(error)")
            }
        }
    }

    func testCancelledSignInReadsAsCancelledRatherThanAsAFailure() {
        let url = URL(string: "cornice://spotify-callback?error=access_denied&state=s1")!
        XCTAssertThrowsError(try SpotifyAuthorization.code(from: url, expectedState: "s1")) { error in
            guard case ServiceError.unauthorized(let detail) = error else {
                return XCTFail("expected unauthorized, got \(error)")
            }
            XCTAssertTrue(detail.contains("cancelled"))
        }
    }

    // MARK: - Token responses

    func testTokenResponseIsRead() throws {
        let now = Date(timeIntervalSince1970: 1_000_000)
        let tokens = try SpotifyAuthorization.tokens(from: tokenReply().body, now: now)
        XCTAssertEqual(tokens.accessToken, "access-1")
        XCTAssertEqual(tokens.refreshToken, "refresh-1")
        XCTAssertEqual(tokens.expiresAt, now.addingTimeInterval(3600))
    }

    func testARefreshThatOmitsTheRefreshTokenKeepsTheOldOne() throws {
        // Spotify usually leaves it out on refresh. Treating that as "no token"
        // would sign the user out about once an hour.
        let reply = tokenReply(access: "access-2", refresh: nil)
        let tokens = try SpotifyAuthorization.tokens(from: reply.body, carryingOver: "refresh-1")
        XCTAssertEqual(tokens.accessToken, "access-2")
        XCTAssertEqual(tokens.refreshToken, "refresh-1")
    }

    func testAnErrorBodyBecomesAnUnauthorizedErrorCarryingItsDescription() {
        let body = Data(#"{"error":"invalid_grant","error_description":"Refresh token revoked"}"#.utf8)
        XCTAssertThrowsError(try SpotifyAuthorization.tokens(from: body)) { error in
            guard case ServiceError.unauthorized(let detail) = error else {
                return XCTFail("expected unauthorized, got \(error)")
            }
            XCTAssertEqual(detail, "Refresh token revoked")
        }
    }

    func testTokenRequestIsFormEncoded() {
        let request = SpotifyAuthorization.exchangeRequest(
            code: "code/with+specials",
            clientID: "abc",
            pkce: SpotifyPKCE(verifier: "v-1")
        )
        let body = String(data: request.httpBody!, encoding: .utf8)!
        XCTAssertEqual(request.value(forHTTPHeaderField: "Content-Type"), "application/x-www-form-urlencoded")
        // The slash and plus must survive the round trip; a form decoder would
        // otherwise read the plus as a space.
        XCTAssertTrue(body.contains("code=code%2Fwith%2Bspecials"))
        XCTAssertTrue(body.contains("grant_type=authorization_code"))
        XCTAssertTrue(body.contains("code_verifier=v-1"))
    }

    // MARK: - Repeat states

    func testRepeatModesMapToSpotifysVocabulary() {
        XCTAssertEqual(SpotifyWebRemote.state(for: .one), "track")
        XCTAssertEqual(SpotifyWebRemote.state(for: .all), "context")
        XCTAssertEqual(SpotifyWebRemote.state(for: .off), "off")

        XCTAssertEqual(SpotifyWebRemote.mode(from: "track"), .one)
        XCTAssertEqual(SpotifyWebRemote.mode(from: "context"), .all)
        XCTAssertEqual(SpotifyWebRemote.mode(from: "off"), .off)
        XCTAssertEqual(SpotifyWebRemote.mode(from: nil), .off)
    }

    // MARK: - Status codes

    func testPremiumRefusalExplainsItself() {
        let body = Data(#"{"error":{"status":403,"message":"Player command failed: Premium required"}}"#.utf8)
        XCTAssertThrowsError(try SpotifyWebRemote.check(HTTPReply(status: 403, body: body))) { error in
            guard case ServiceError.unauthorized(let detail) = error else {
                return XCTFail("expected unauthorized, got \(error)")
            }
            XCTAssertTrue(detail.contains("Premium"))
        }
    }

    func testNoActiveDeviceSaysWhatToDoAboutIt() {
        XCTAssertThrowsError(try SpotifyWebRemote.check(HTTPReply(status: 404, body: Data()))) { error in
            guard case ServiceError.api(_, let message) = error else {
                return XCTFail("expected api error, got \(error)")
            }
            XCTAssertTrue(message.contains("Start playing"))
        }
    }

    func testRateLimitCarriesItsRetryAfter() {
        let reply = HTTPReply(status: 429, body: Data(), headers: ["Retry-After": "30"])
        XCTAssertThrowsError(try SpotifyWebRemote.check(reply)) { error in
            guard case ServiceError.rateLimited(let resetAt) = error else {
                return XCTFail("expected rateLimited, got \(error)")
            }
            XCTAssertNotNil(resetAt)
        }
    }

    func testSuccessfulStatusesRaiseNothing() throws {
        for status in [200, 202, 204] {
            XCTAssertNoThrow(try SpotifyWebRemote.check(HTTPReply(status: status, body: Data())))
        }
    }

    // MARK: - The remote, end to end against a stub

    func testSettingRepeatOneSendsTrackToSpotify() async throws {
        let transport = StubTransport([tokenReply(), HTTPReply(status: 204, body: Data())])
        let remote = SpotifyWebRemote(
            clientID: "abc",
            store: EphemeralTokenStore(token: "refresh-1"),
            transport: transport
        )

        try await remote.setRepeat(.one)

        let command = transport.sent.last!
        XCTAssertEqual(command.httpMethod, "PUT")
        XCTAssertEqual(command.url?.path(), "/v1/me/player/repeat")
        XCTAssertEqual(command.url?.query(), "state=track")
        XCTAssertEqual(command.value(forHTTPHeaderField: "Authorization"), "Bearer access-1")
    }

    func testPlaybackStateReportsTheRealThreeStateRepeat() async throws {
        let player = Data(#"""
        {"repeat_state":"track","shuffle_state":true,"is_playing":true,"device":{"name":"MacBook Air"}}
        """#.utf8)
        let transport = StubTransport([tokenReply(), HTTPReply(status: 200, body: player)])
        let remote = SpotifyWebRemote(
            clientID: "abc",
            store: EphemeralTokenStore(token: "refresh-1"),
            transport: transport
        )

        let state = try await remote.playbackState()
        XCTAssertEqual(state?.repeatMode, .one)
        XCTAssertEqual(state?.isShuffling, true)
        XCTAssertEqual(state?.deviceName, "MacBook Air")
    }

    func testNothingPlayingAnywhereIsNotAnError() async throws {
        let transport = StubTransport([tokenReply(), HTTPReply(status: 204, body: Data())])
        let remote = SpotifyWebRemote(
            clientID: "abc",
            store: EphemeralTokenStore(token: "refresh-1"),
            transport: transport
        )
        let state = try await remote.playbackState()
        XCTAssertNil(state)
    }

    func testAnExpiredAccessTokenIsRefreshedOnceAndTheCommandRetried() async throws {
        let transport = StubTransport([
            tokenReply(access: "stale"),                    // first refresh
            HTTPReply(status: 401, body: Data()),           // command refused
            tokenReply(access: "fresh"),                    // second refresh
            HTTPReply(status: 204, body: Data()),           // command accepted
        ])
        let remote = SpotifyWebRemote(
            clientID: "abc",
            store: EphemeralTokenStore(token: "refresh-1"),
            transport: transport
        )

        try await remote.setRepeat(.one)

        XCTAssertEqual(transport.sent.count, 4)
        XCTAssertEqual(
            transport.sent.last?.value(forHTTPHeaderField: "Authorization"),
            "Bearer fresh"
        )
    }

    func testARevokedRefreshTokenIsDiscardedRatherThanRetriedForever() async {
        let revoked = Data(#"{"error":"invalid_grant","error_description":"Revoked"}"#.utf8)
        let store = EphemeralTokenStore(token: "refresh-1")
        let remote = SpotifyWebRemote(
            clientID: "abc",
            store: store,
            transport: StubTransport([HTTPReply(status: 400, body: revoked)])
        )

        do {
            try await remote.setRepeat(.one)
            XCTFail("expected the revoked token to raise")
        } catch {
            guard case ServiceError.unauthorized = error else {
                return XCTFail("expected unauthorized, got \(error)")
            }
        }
        XCTAssertNil(store.loadRefreshToken())
    }

    func testSignInRoundTrip() async throws {
        let store = EphemeralTokenStore()
        let transport = StubTransport([tokenReply(refresh: "refresh-new")])
        let remote = SpotifyWebRemote(clientID: "abc", store: store, transport: transport)

        let status = await remote.status()
        XCTAssertEqual(status, .signedOut)

        let url = try await remote.beginSignIn()
        let items = URLComponents(url: url, resolvingAgainstBaseURL: false)!.queryItems ?? []
        let state = items.first { $0.name == "state" }!.value!

        try await remote.completeSignIn(
            callback: URL(string: "cornice://spotify-callback?code=c1&state=\(state)")!
        )

        XCTAssertEqual(store.loadRefreshToken(), "refresh-new")
        let after = await remote.status()
        XCTAssertEqual(after, .signedIn)
    }

    func testWithoutAClientIDSignInIsNotOffered() async {
        let remote = SpotifyWebRemote(
            clientID: "", store: EphemeralTokenStore(), transport: StubTransport([])
        )
        let status = await remote.status()
        XCTAssertEqual(status, .unconfigured)
        do {
            _ = try await remote.beginSignIn()
            XCTFail("expected sign-in to be refused without a client ID")
        } catch {
            guard case ServiceError.invalidConfiguration = error else {
                return XCTFail("expected invalidConfiguration, got \(error)")
            }
        }
    }
}
