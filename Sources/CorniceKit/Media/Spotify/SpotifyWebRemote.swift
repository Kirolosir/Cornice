import Foundation

/// The parts of an HTTP response this client needs. A plain value is easy to return from an
/// actor and replace in tests.
public struct HTTPReply: Sendable {
    public let status: Int
    public let body: Data
    public let headers: [String: String]

    public init(status: Int, body: Data, headers: [String: String] = [:]) {
        self.status = status
        self.body = body
        self.headers = headers
    }
}

public protocol HTTPTransport: Sendable {
    func send(_ request: URLRequest) async throws -> HTTPReply
}

public struct URLSessionTransport: HTTPTransport {
    private let session: URLSession

    public init(session: URLSession = .shared) { self.session = session }

    public func send(_ request: URLRequest) async throws -> HTTPReply {
        do {
            let (data, response) = try await session.data(for: request)
            guard let http = response as? HTTPURLResponse else {
                throw ServiceError.unreadableOutput(tool: "Spotify", hint: "not an HTTP response")
            }
            var headers: [String: String] = [:]
            for (key, value) in http.allHeaderFields {
                if let key = key as? String, let value = value as? String { headers[key] = value }
            }
            return HTTPReply(status: http.statusCode, body: data, headers: headers)
        } catch let error as URLError {
            switch error.code {
            case .notConnectedToInternet, .networkConnectionLost, .cannotFindHost, .timedOut:
                throw ServiceError.offline
            default:
                throw ServiceError.api(status: error.errorCode, message: error.localizedDescription)
            }
        }
    }
}

/// Web API repeat state and device information. Local scripting still supplies the regular
/// track readings.
public struct SpotifyPlaybackState: Sendable, Equatable {
    public let repeatMode: RepeatMode
    public let isShuffling: Bool
    public let isPlaying: Bool
    public let deviceName: String?

    public init(repeatMode: RepeatMode, isShuffling: Bool, isPlaying: Bool, deviceName: String?) {
        self.repeatMode = repeatMode
        self.isShuffling = isShuffling
        self.isPlaying = isPlaying
        self.deviceName = deviceName
    }
}

/// Use Spotify's Web API for repeat-one. Unlike its scripting interface, the API can set
/// track repeat directly.
public actor SpotifyWebRemote {

    /// Connection status tracks credentials. A failed playback command shouldn't disable
    /// the whole connection.
    public enum Status: Sendable, Equatable {
        /// No client ID entered, so sign-in cannot be offered yet.
        case unconfigured
        /// Configured, but nobody has signed in.
        case signedOut
        case signedIn
    }

    private static let base = URL(string: "https://api.spotify.com/v1")!

    private let store: SpotifyTokenStoring
    private let transport: HTTPTransport
    private var clientID: String
    private var tokens: SpotifyTokens?

    /// Set while a browser sign-in is in flight; the redirect is matched against it.
    private var pending: (pkce: SpotifyPKCE, state: String)?

    public init(
        clientID: String,
        store: SpotifyTokenStoring = KeychainTokenStore(),
        transport: HTTPTransport = URLSessionTransport()
    ) {
        self.clientID = clientID
        self.store = store
        self.transport = transport
    }

    public func configure(clientID: String) {
        guard clientID != self.clientID else { return }
        self.clientID = clientID
        tokens = nil
    }

    public func status() -> Status {
        guard !clientID.isEmpty else { return .unconfigured }
        return store.loadRefreshToken() == nil ? .signedOut : .signedIn
    }

    // MARK: - Sign in

    /// The URL to open in the browser. Holds the verifier until the redirect.
    public func beginSignIn() throws -> URL {
        guard !clientID.isEmpty else {
            throw ServiceError.invalidConfiguration(reason: "Enter a Spotify client ID first.")
        }
        let pkce = SpotifyPKCE.random()
        let state = SpotifyAuthorization.randomState()
        pending = (pkce, state)
        return SpotifyAuthorization.authorizeURL(clientID: clientID, pkce: pkce, state: state)
    }

    /// Redeems the code the browser handed back.
    public func completeSignIn(callback: URL) async throws {
        guard let pending else {
            // Ignore a repeated callback if sign-in already succeeded.
            if store.loadRefreshToken() != nil {
                Log.media.debug("spotify: ignoring a repeated sign-in reply")
                return
            }
            throw ServiceError.unauthorized(detail: "No sign-in was waiting for a reply.")
        }
        self.pending = nil

        let code = try SpotifyAuthorization.code(from: callback, expectedState: pending.state)
        let request = SpotifyAuthorization.exchangeRequest(
            code: code, clientID: clientID, pkce: pending.pkce
        )
        let reply = try await transport.send(request)
        let tokens = try SpotifyAuthorization.tokens(from: reply.body)
        self.tokens = tokens
        store.save(refreshToken: tokens.refreshToken)
        Log.media.notice("spotify: signed in")
    }

    public func signOut() {
        tokens = nil
        pending = nil
        store.clear()
        Log.media.notice("spotify: signed out")
    }

    // MARK: - Playback

    public func playbackState() async throws -> SpotifyPlaybackState? {
        let reply = try await authorized { token in
            var request = URLRequest(url: Self.base.appending(path: "me/player"))
            request.timeoutInterval = 10
            request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
            return request
        }

        // 204 is Spotify's way of saying nothing is active anywhere.
        guard reply.status != 204, !reply.body.isEmpty else { return nil }
        guard let object = try? JSONSerialization.jsonObject(with: reply.body) as? [String: Any] else {
            throw ServiceError.unreadableOutput(tool: "Spotify", hint: "player state was not JSON")
        }
        let device = object["device"] as? [String: Any]
        return SpotifyPlaybackState(
            repeatMode: Self.mode(from: object["repeat_state"] as? String),
            isShuffling: (object["shuffle_state"] as? Bool) ?? false,
            isPlaying: (object["is_playing"] as? Bool) ?? false,
            deviceName: device?["name"] as? String
        )
    }

    public func setRepeat(_ mode: RepeatMode) async throws {
        try await command(path: "me/player/repeat", value: Self.state(for: mode))
    }

    public func setShuffle(_ shuffling: Bool) async throws {
        try await command(path: "me/player/shuffle", value: shuffling ? "true" : "false")
    }

    private func command(path: String, value: String) async throws {
        _ = try await authorized { token in
            var components = URLComponents(
                url: Self.base.appending(path: path), resolvingAgainstBaseURL: false
            )!
            components.queryItems = [URLQueryItem(name: "state", value: value)]
            var request = URLRequest(url: components.url!)
            request.httpMethod = "PUT"
            request.timeoutInterval = 10
            request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
            // A PUT with no body still needs a declared length, or Spotify
            // answers 411 rather than acting.
            request.setValue("0", forHTTPHeaderField: "Content-Length")
            return request
        }
    }

    // MARK: - Tokens

    /// Refresh and retry once if the token expires. Don't keep sending a request Spotify
    /// has already refused twice.
    private func authorized(_ build: (String) -> URLRequest) async throws -> HTTPReply {
        let token = try await accessToken()
        let reply = try await transport.send(build(token))
        if reply.status == 401 {
            let refreshed = try await refreshAccessToken()
            let second = try await transport.send(build(refreshed))
            try Self.check(second)
            return second
        }
        try Self.check(reply)
        return reply
    }

    private func accessToken() async throws -> String {
        if let tokens, tokens.isFresh() { return tokens.accessToken }
        return try await refreshAccessToken()
    }

    private func refreshAccessToken() async throws -> String {
        guard !clientID.isEmpty else {
            throw ServiceError.invalidConfiguration(reason: "Enter a Spotify client ID first.")
        }
        guard let refreshToken = tokens?.refreshToken ?? store.loadRefreshToken() else {
            throw ServiceError.unauthorized(detail: "Connect Spotify in Settings.")
        }
        let request = SpotifyAuthorization.refreshRequest(
            refreshToken: refreshToken, clientID: clientID
        )
        let reply = try await transport.send(request)
        do {
            let fresh = try SpotifyAuthorization.tokens(
                from: reply.body, carryingOver: refreshToken
            )
            tokens = fresh
            store.save(refreshToken: fresh.refreshToken)
            return fresh.accessToken
        } catch {
            // Drop an invalid refresh token so the user can sign in again instead of
            // getting the same failure.
            if case ServiceError.unauthorized = error {
                tokens = nil
                store.clear()
            }
            throw error
        }
    }

    // MARK: - Translation

    static func mode(from state: String?) -> RepeatMode {
        switch state {
        case "track": .one
        case "context": .all
        default: .off
        }
    }

    static func state(for mode: RepeatMode) -> String {
        switch mode {
        case .one: "track"
        case .all: "context"
        case .off: "off"
        }
    }

    /// Turns Spotify's status codes into errors that say what to do about them.
    static func check(_ reply: HTTPReply) throws {
        switch reply.status {
        case 200...299:
            return
        case 401:
            throw ServiceError.unauthorized(detail: "Spotify rejected the sign-in. Connect again in Settings.")
        case 403:
            // The usual cause by a wide margin. The Web API's playback controls
            // are Premium-only, and it says so in the body rather than the code.
            throw ServiceError.unauthorized(detail: message(in: reply.body)
                ?? "Spotify refused the command. Playback control needs Premium.")
        case 404:
            throw ServiceError.api(status: 404, message: "No active Spotify device. Start playing something first.")
        case 429:
            let retryAfter = reply.headers["Retry-After"].flatMap(Double.init)
            throw ServiceError.rateLimited(resetAt: retryAfter.map { Date().addingTimeInterval($0) })
        default:
            throw ServiceError.api(
                status: reply.status,
                message: message(in: reply.body) ?? "Spotify returned \(reply.status)."
            )
        }
    }

    private static func message(in body: Data) -> String? {
        guard let object = try? JSONSerialization.jsonObject(with: body) as? [String: Any],
              let error = object["error"] as? [String: Any],
              let message = error["message"] as? String,
              !message.isEmpty
        else { return nil }
        return message
    }
}
