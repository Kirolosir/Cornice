import Foundation

/// One HTTP answer, reduced to the three things this client reads.
///
/// The transport hands back a value type rather than `URLResponse` so that the
/// whole client can be exercised against a stub, and so nothing has to reason
/// about the sendability of a Foundation class across an actor hop.
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

/// What the Web API says is playing.
///
/// Narrower than `MediaSnapshot` on purpose: the scripting interface is faster
/// and cheaper for everything the panel draws every frame, so this carries only
/// what scripting cannot answer. The true three-state repeat, and which device
/// the commands will land on.
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

/// Spotify's Web API, for the things AppleScript cannot say.
///
/// The scripting dictionary has one boolean where repeat needs three states, so
/// `repeat one` on Spotify was previously the app faking it. Watching for the
/// end of a track and seeking back to zero. That works, but it is Cornice's
/// state and not Spotify's: the player's own button never shows the `1`, and
/// anything that happens outside Cornice's poll gets it wrong.
///
/// This asks Spotify directly. `repeat_state` comes back as `off`, `context` or
/// `track`, and setting `track` is real repeat-one. The badge appears in the
/// Spotify window, it survives skips, and it needs no timers at all.
public actor SpotifyWebRemote {

    /// Whether the API can be called at all.
    ///
    /// Deliberately only about credentials. A failed *command* (no active
    /// device, a rate limit) is reported separately, because folding it in
    /// here meant one transient refusal disabled the Web API path for the rest
    /// of the session and quietly reverted to imitating repeat-one.
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
            // A redirect can arrive more than once: the browser re-sends it on a
            // reload, and macOS delivers it again if it had to launch the app to
            // do so. The first copy consumes the verifier, so the rest find
            // nothing waiting, which is a replay of work already done, not a
            // failure, and treating it as one used to tear down the sign-in that
            // had just succeeded.
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

    /// Runs a request with a live access token, refreshing once if it is stale.
    ///
    /// The retry is deliberately single: a token refused twice is a token that
    /// will not work, and looping on it would turn one bad credential into a
    /// stream of requests at Spotify.
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
            // A refresh token Spotify no longer honours is worse than none: it
            // makes every later call fail the same way. Drop it so the UI can
            // offer a fresh sign-in instead of retrying a dead credential.
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
