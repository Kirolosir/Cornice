import CryptoKit
import Foundation
import Security

/// PKCE values for Spotify sign-in. Send the verifier's SHA-256 challenge to the browser,
/// then use the verifier to exchange the returned code. A desktop app can't safely store a
/// client secret.
public struct SpotifyPKCE: Sendable, Equatable {

    /// The random secret, held until the code is redeemed.
    public let verifier: String
    /// Its SHA-256 digest, base64url-encoded. This is the half that travels.
    public let challenge: String

    public init(verifier: String) {
        self.verifier = verifier
        self.challenge = Data(SHA256.hash(data: Data(verifier.utf8))).base64URLEncoded()
    }

    /// Generate 64 random bytes. Base64url encoding gives an 86-character verifier, within
    /// the allowed 43...128 range.
    public static func random() -> SpotifyPKCE {
        var bytes = [UInt8](repeating: 0, count: 64)
        let status = SecRandomCopyBytes(kSecRandomDefault, bytes.count, &bytes)
        precondition(status == errSecSuccess, "the system random source failed")
        return SpotifyPKCE(verifier: Data(bytes).base64URLEncoded())
    }
}

/// Request playback read and control scopes. Library, playlist and account-detail scopes
/// aren't needed.
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

    /// Refresh a little early so the token doesn't expire while a request is on its way.
    public func isFresh(at now: Date = .now) -> Bool {
        expiresAt > now.addingTimeInterval(30)
    }
}

/// Build sign-in requests and parse responses separately from networking, so tests don't
/// need a Spotify account.
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

    /// Only accept a redirect whose state matches the sign-in we started.
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

    /// Keep the previous refresh token if Spotify leaves it out of a refresh response.
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

        // Encode this as a form body. Query-string encoding doesn't handle every character
        // the same way.
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
    /// base64url, per RFC 4648 §5. The URL-safe alphabet, no padding.
    func base64URLEncoded() -> String {
        base64EncodedString()
            .replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")
    }
}
