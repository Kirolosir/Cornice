import CryptoKit
import Foundation
import Security

/// OAuth for a desktop app that cannot keep a secret.
///
/// Spotify's scripting dictionary exposes repeat as one boolean, which cannot
/// express "repeat this track". The Web API can — `PUT /me/player/repeat` takes
/// `off`, `context` or `track` — so reaching real repeat-one means signing in.
///
/// The flow is authorization code with PKCE (RFC 7636), and it is PKCE rather
/// than the classic exchange for a concrete reason: anything shipped inside an
/// app bundle is readable by anyone holding the bundle, so a client *secret*
/// would not be one. Instead the app invents a random `verifier`, sends only its
/// SHA-256 hash when it opens the browser, and presents the verifier itself when
/// redeeming the code. Intercepting the redirect yields a code that cannot be
/// spent without the verifier, which never leaves this process.
public struct SpotifyPKCE: Sendable, Equatable {

    /// The random secret, held until the code is redeemed.
    public let verifier: String
    /// Its SHA-256 digest, base64url-encoded. This is the half that travels.
    public let challenge: String

    public init(verifier: String) {
        self.verifier = verifier
        self.challenge = Data(SHA256.hash(data: Data(verifier.utf8))).base64URLEncoded()
    }

    /// A fresh pair, from 64 bytes of `SecRandomCopyBytes`.
    ///
    /// Encoded, that lands at 86 characters — inside the 43...128 the spec
    /// allows, and well past the entropy it asks for.
    public static func random() -> SpotifyPKCE {
        var bytes = [UInt8](repeating: 0, count: 64)
        let status = SecRandomCopyBytes(kSecRandomDefault, bytes.count, &bytes)
        precondition(status == errSecSuccess, "the system random source failed")
        return SpotifyPKCE(verifier: Data(bytes).base64URLEncoded())
    }
}

/// What Cornice asks Spotify for, and nothing more.
///
/// Reading playback state is what lets the panel show the player's *real*
/// repeat and shuffle rather than a guess; modifying it is what the buttons do.
/// No library, playlist, email, or follower scopes are requested.
public enum SpotifyScope {
    public static let required = [
        "user-read-playback-state",
        "user-modify-playback-state",
    ]

    public static var joined: String { required.joined(separator: " ") }
}

/// An access token and the refresh token that outlives it.
public struct SpotifyTokens: Sendable, Equatable, Codable {
    public var accessToken: String
    public var refreshToken: String
    public var expiresAt: Date

    public init(accessToken: String, refreshToken: String, expiresAt: Date) {
        self.accessToken = accessToken
        self.refreshToken = refreshToken
        self.expiresAt = expiresAt
    }

    /// Whether the access token is good for another call.
    ///
    /// Thirty seconds of slack, because the token can expire between the check
    /// and the request arriving — and a request refused for staleness costs a
    /// round trip to discover.
    public func isFresh(at now: Date = .now) -> Bool {
        expiresAt > now.addingTimeInterval(30)
    }
}

/// Builds the two requests the sign-in needs, and reads their answers.
///
/// Deliberately free of networking and of state: every method is a pure
/// transformation, so the whole handshake can be tested without a socket and
/// without a Spotify account.
public enum SpotifyAuthorization {

    public static let authorizeEndpoint = URL(string: "https://accounts.spotify.com/authorize")!
    public static let tokenEndpoint = URL(string: "https://accounts.spotify.com/api/token")!

    /// Where Spotify sends the browser back to. Registered in `Info.plist` and
    /// in the Spotify dashboard; the two must match exactly, including the
    /// trailing path.
    public static let redirectURI = "cornice://spotify-callback"

    /// The URL to open in the user's browser.
    public static func authorizeURL(
        clientID: String,
        pkce: SpotifyPKCE,
        state: String
    ) -> URL {
        var components = URLComponents(url: authorizeEndpoint, resolvingAgainstBaseURL: false)!
        components.queryItems = [
            URLQueryItem(name: "client_id", value: clientID),
            URLQueryItem(name: "response_type", value: "code"),
            URLQueryItem(name: "redirect_uri", value: redirectURI),
            URLQueryItem(name: "scope", value: SpotifyScope.joined),
            URLQueryItem(name: "code_challenge_method", value: "S256"),
            URLQueryItem(name: "code_challenge", value: pkce.challenge),
            URLQueryItem(name: "state", value: state),
        ]
        return components.url!
    }

    /// The authorization code carried by the redirect.
    ///
    /// `state` is compared against what was sent. A redirect that does not
    /// carry back the value this process generated did not come from the sign-in
    /// this process started, and is refused rather than redeemed.
    public static func code(from url: URL, expectedState: String) throws -> String {
        guard let components = URLComponents(url: url, resolvingAgainstBaseURL: false) else {
            throw ServiceError.unreadableOutput(tool: "Spotify", hint: "malformed redirect")
        }
        let items = components.queryItems ?? []
        func value(_ name: String) -> String? {
            items.first { $0.name == name }?.value
        }

        if let denial = value("error") {
            throw ServiceError.unauthorized(detail: denial == "access_denied"
                ? "Sign-in was cancelled."
                : "Spotify refused the sign-in: \(denial).")
        }
        guard value("state") == expectedState else {
            throw ServiceError.unauthorized(detail: "The sign-in reply did not match the request.")
        }
        guard let code = value("code"), !code.isEmpty else {
            throw ServiceError.unreadableOutput(tool: "Spotify", hint: "redirect carried no code")
        }
        return code
    }

    /// Redeems the code for tokens.
    public static func exchangeRequest(
        code: String,
        clientID: String,
        pkce: SpotifyPKCE
    ) -> URLRequest {
        form(fields: [
            "grant_type": "authorization_code",
            "code": code,
            "redirect_uri": redirectURI,
            "client_id": clientID,
            "code_verifier": pkce.verifier,
        ])
    }

    /// Trades a refresh token for a new access token.
    public static func refreshRequest(refreshToken: String, clientID: String) -> URLRequest {
        form(fields: [
            "grant_type": "refresh_token",
            "refresh_token": refreshToken,
            "client_id": clientID,
        ])
    }

    /// Reads a token response.
    ///
    /// A refresh response may omit `refresh_token`, which means "keep using the
    /// one you have" — dropping it there would sign the user out roughly every
    /// hour, so the previous value is carried forward.
    public static func tokens(
        from data: Data,
        carryingOver previous: String? = nil,
        now: Date = .now
    ) throws -> SpotifyTokens {
        guard let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw ServiceError.unreadableOutput(tool: "Spotify", hint: "token response was not JSON")
        }
        if let error = object["error"] as? String {
            let description = object["error_description"] as? String
            throw ServiceError.unauthorized(detail: description ?? error)
        }
        guard let access = object["access_token"] as? String else {
            throw ServiceError.unreadableOutput(tool: "Spotify", hint: "token response carried no access token")
        }
        guard let refresh = (object["refresh_token"] as? String) ?? previous else {
            throw ServiceError.unreadableOutput(tool: "Spotify", hint: "token response carried no refresh token")
        }
        let lifetime = (object["expires_in"] as? Double) ?? 3600
        return SpotifyTokens(
            accessToken: access,
            refreshToken: refresh,
            expiresAt: now.addingTimeInterval(lifetime)
        )
    }

    /// An opaque value tying a redirect back to the request that caused it.
    public static func randomState() -> String {
        var bytes = [UInt8](repeating: 0, count: 16)
        let status = SecRandomCopyBytes(kSecRandomDefault, bytes.count, &bytes)
        precondition(status == errSecSuccess, "the system random source failed")
        return Data(bytes).base64URLEncoded()
    }

    private static func form(fields: [String: String]) -> URLRequest {
        var request = URLRequest(url: tokenEndpoint)
        request.httpMethod = "POST"
        request.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
        request.timeoutInterval = 15

        // Percent-encoding by hand rather than through URLComponents: the token
        // endpoint takes a form *body*, and a verifier is base64url, which can
        // contain characters a query encoder would leave alone but a form
        // decoder would read differently.
        var allowed = CharacterSet.alphanumerics
        allowed.insert(charactersIn: "-._~")
        let body = fields
            .sorted { $0.key < $1.key }
            .map { key, value in
                let name = key.addingPercentEncoding(withAllowedCharacters: allowed) ?? key
                let encoded = value.addingPercentEncoding(withAllowedCharacters: allowed) ?? value
                return "\(name)=\(encoded)"
            }
            .joined(separator: "&")
        request.httpBody = Data(body.utf8)
        return request
    }
}

extension Data {
    /// base64url, per RFC 4648 §5 — the URL-safe alphabet, no padding.
    func base64URLEncoded() -> String {
        base64EncodedString()
            .replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")
    }
}
