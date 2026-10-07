import Foundation

/// Prefer a player that's playing. If everything is paused, keep the last selected player
/// so the panel doesn't jump to an old track in another app.
public actor MediaCoordinator {

    private let controllers: [MediaSource: any MediaControlling]
    private var lastActiveSource: MediaSource?

    /// Artwork cache keyed by track identity, so the image is fetched once per
    /// song rather than once per poll.
    private var artworkCache: [String: Data] = [:]
    private var artworkOrder: [String] = []
    private let artworkCacheLimit = 12

    /// Sources whose automation the user refused, so we stop polling them.
    private var unavailableSources: Set<MediaSource> = []

    private let session: URLSession

    public init(controllers: [any MediaControlling], session: URLSession = .shared) {
        var map: [MediaSource: any MediaControlling] = [:]
        for controller in controllers { map[controller.source] = controller }
        self.controllers = map
        self.session = session
    }

    /// Convenience factory for the two supported players.
    public static func live(runner: AppleScriptRunner = AppleScriptRunner()) -> MediaCoordinator {
        MediaCoordinator(controllers: [
            ScriptedMediaController(source: .spotify, runner: runner),
            ScriptedMediaController(source: .appleMusic, runner: runner),
        ])
    }

    /// Which players are installed and currently open.
    public func runningSources() async -> [MediaSource] {
        var running: [MediaSource] = []
        for (source, controller) in controllers where !unavailableSources.contains(source) {
            if await controller.isRunning() { running.append(source) }
        }
        return running.sorted { $0.rawValue < $1.rawValue }
    }

    /// The current snapshot from whichever player should be shown.
    public func snapshot() async -> MediaSnapshot? {
        var candidates: [MediaSnapshot] = []

        for (source, controller) in controllers {
            guard !unavailableSources.contains(source) else { continue }
            guard await controller.isRunning() else { continue }
            do {
                if let snapshot = try await controller.snapshot(), snapshot.hasTrack {
                    candidates.append(snapshot)
                }
            } catch let error as ServiceError {
                if case .unauthorized = error {
                    // Do not keep re-asking. The user said no; respect it until
                    // they say otherwise.
                    unavailableSources.insert(source)
                    Log.media.notice("automation refused for \(source.displayName, privacy: .public)")
                }
                // A player that is open with nothing loaded raises rather than
                // returning empty; that is not worth surfacing.
            } catch {
                // Log unexpected script failures so an empty panel isn't the only clue.
                Log.media.error(
                    "\(source.displayName, privacy: .public) poll failed: \(String(describing: error), privacy: .public)"
                )
                continue
            }
        }

        guard !candidates.isEmpty else { return nil }

        if let playing = candidates.first(where: { $0.state.isPlaying }) {
            lastActiveSource = playing.source
            return playing
        }
        if let previous = lastActiveSource,
           let held = candidates.first(where: { $0.source == previous }) {
            return held
        }
        lastActiveSource = candidates[0].source
        return candidates[0]
    }

    public func perform(_ command: MediaCommand, on source: MediaSource) async throws {
        guard let controller = controllers[source] else {
            throw ServiceError.invalidConfiguration(reason: "no controller for \(source.displayName)")
        }
        try await controller.perform(command)
    }

    /// Whether every known player refused automation.
    public func allSourcesUnavailable() -> Bool {
        !unavailableSources.isEmpty && unavailableSources.count == controllers.count
    }

    /// Lets the user retry after granting permission in System Settings.
    public func resetAvailability() {
        unavailableSources.removeAll()
    }

    // MARK: - Artwork

    /// Cache artwork by track. Return nil if it can't be fetched; the rest of the player
    /// should still work.
    public func artwork(for snapshot: MediaSnapshot) async -> Data? {
        let key = snapshot.trackIdentity
        if let cached = artworkCache[key] { return cached }

        var data: Data?

        if let embedded = snapshot.artworkData, !embedded.isEmpty {
            data = embedded
        } else if let url = snapshot.artworkURL {
            data = try? await download(url)
        } else if snapshot.source == .appleMusic,
                  let controller = controllers[.appleMusic] as? ScriptedMediaController {
            data = try? await controller.artworkData()
        }

        guard let data, !data.isEmpty else { return nil }
        store(data, for: key)
        return data
    }

    private func download(_ url: URL) async throws -> Data {
        var request = URLRequest(url: url)
        request.timeoutInterval = 8
        let (data, response) = try await session.data(for: request)
        guard let http = response as? HTTPURLResponse, (200...299).contains(http.statusCode) else {
            throw ServiceError.api(status: 0, message: "artwork unavailable")
        }
        // Album art is small; anything huge is not what we asked for.
        guard data.count < 8 * 1024 * 1024 else {
            throw ServiceError.unreadableOutput(tool: "artwork", hint: "unexpectedly large image")
        }
        return data
    }

    private func store(_ data: Data, for key: String) {
        if artworkCache[key] == nil {
            artworkOrder.append(key)
            if artworkOrder.count > artworkCacheLimit {
                let evicted = artworkOrder.removeFirst()
                artworkCache.removeValue(forKey: evicted)
            }
        }
        artworkCache[key] = data
    }
}
