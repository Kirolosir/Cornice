import Foundation

/// Which application is playing.
public enum MediaSource: String, Sendable, Codable, CaseIterable, Identifiable {
    case appleMusic
    case spotify

    public var id: String { rawValue }

    public var displayName: String {
        switch self {
        case .appleMusic: "Music"
        case .spotify: "Spotify"
        }
    }

    /// The scripting target's application name, as AppleScript expects it.
    public var scriptingName: String {
        switch self {
        case .appleMusic: "Music"
        case .spotify: "Spotify"
        }
    }

    public var bundleIdentifier: String {
        switch self {
        case .appleMusic: "com.apple.Music"
        case .spotify: "com.spotify.client"
        }
    }
}

/// Playback state, normalised across sources.
public enum PlaybackState: String, Sendable, Equatable {
    case playing
    case paused
    case stopped

    public var isPlaying: Bool { self == .playing }
}

public enum RepeatMode: String, Sendable, Equatable, CaseIterable {
    case off
    case all
    case one

    /// The order the button cycles through, matching both players' own.
    public var next: RepeatMode {
        switch self {
        case .off: .all
        case .all: .one
        case .one: .off
        }
    }
}

/// One instant of what is playing.
///
/// Deliberately a value type with no reference to the source application, so the
/// UI never has to branch on which player produced it. Everything that differs
/// between Music and Spotify — units, key names, how shuffle is spelled — is
/// normalised in the provider.
public struct MediaSnapshot: Sendable, Equatable {
    public let source: MediaSource
    public let state: PlaybackState
    public let title: String
    public let artist: String
    public let album: String
    /// Track length in seconds.
    public let duration: TimeInterval
    /// Playhead position in seconds, at `capturedAt`.
    public let position: TimeInterval
    /// Remote artwork URL, when the source exposes one.
    public let artworkURL: URL?
    /// Raw artwork bytes, when the source can only hand them over directly.
    public let artworkData: Data?
    public let isShuffling: Bool
    public let repeatMode: RepeatMode
    /// Player volume, 0...1, when the source exposes it.
    public let volume: Double?
    public let capturedAt: Date

    public init(
        source: MediaSource,
        state: PlaybackState,
        title: String,
        artist: String,
        album: String = "",
        duration: TimeInterval,
        position: TimeInterval,
        artworkURL: URL? = nil,
        artworkData: Data? = nil,
        isShuffling: Bool = false,
        repeatMode: RepeatMode = .off,
        volume: Double? = nil,
        capturedAt: Date = .now
    ) {
        self.source = source
        self.state = state
        self.title = title
        self.artist = artist
        self.album = album
        self.duration = duration
        self.position = position
        self.artworkURL = artworkURL
        self.artworkData = artworkData
        self.isShuffling = isShuffling
        self.repeatMode = repeatMode
        self.volume = volume
        self.capturedAt = capturedAt
    }

    /// A copy with one field replaced.
    ///
    /// Used to reflect a command locally before the player has been re-read, so
    /// a toggle responds on the frame it was pressed rather than on the next
    /// poll. The next real snapshot overwrites it either way, so an optimistic
    /// value that turns out to be wrong corrects itself within a second.
    public func with(
        state: PlaybackState? = nil,
        position: TimeInterval? = nil,
        isShuffling: Bool? = nil,
        repeatMode: RepeatMode? = nil
    ) -> MediaSnapshot {
        MediaSnapshot(
            source: source,
            state: state ?? self.state,
            title: title,
            artist: artist,
            album: album,
            duration: duration,
            position: position ?? self.position,
            artworkURL: artworkURL,
            artworkData: artworkData,
            isShuffling: isShuffling ?? self.isShuffling,
            repeatMode: repeatMode ?? self.repeatMode,
            volume: volume,
            capturedAt: .now
        )
    }

    /// Identity of the *track*, ignoring playhead movement.
    ///
    /// Used to decide when artwork must be refetched and when the UI should
    /// treat this as a new song rather than a progress update — without it,
    /// every one-second poll would look like a track change and the artwork
    /// would reload constantly.
    public var trackIdentity: String {
        "\(source.rawValue)|\(title)|\(artist)|\(album)|\(Int(duration))"
    }

    /// Position extrapolated to `now`.
    ///
    /// The provider is polled on the order of once a second, but the scrubber
    /// updates every frame. Rather than poll faster — which means spawning an
    /// AppleScript call per frame — the playhead is advanced locally from the
    /// last known position and corrected whenever a real sample arrives. This
    /// is the difference between a scrubber that glides and one that ticks.
    public func extrapolatedPosition(at now: Date = .now) -> TimeInterval {
        guard state.isPlaying else { return position }
        let elapsed = now.timeIntervalSince(capturedAt)
        guard elapsed > 0 else { return position }
        return min(duration, position + elapsed)
    }

    public func progress(at now: Date = .now) -> Double {
        guard duration > 0 else { return 0 }
        return (extrapolatedPosition(at: now) / duration).clamped(to: 0...1)
    }

    /// Time left, for the trailing `-m:ss` label.
    public func remaining(at now: Date = .now) -> TimeInterval {
        max(0, duration - extrapolatedPosition(at: now))
    }

    public var hasTrack: Bool { !title.isEmpty && state != .stopped }
}

/// Commands a player can be asked to perform.
public enum MediaCommand: Sendable, Equatable {
    case playPause
    case next
    case previous
    /// Seek to an absolute position in seconds.
    case seek(TimeInterval)
    case setVolume(Double)
    case toggleShuffle
    case cycleRepeat
}

/// Reads and controls a media application.
public protocol MediaControlling: Sendable {
    /// Which source this controls.
    var source: MediaSource { get }
    /// Whether the application is currently running. Checked before scripting
    /// it, because scripting a stopped app would launch it.
    func isRunning() async -> Bool
    /// Current state, or `nil` when nothing is loaded.
    func snapshot() async throws -> MediaSnapshot?
    func perform(_ command: MediaCommand) async throws
}
