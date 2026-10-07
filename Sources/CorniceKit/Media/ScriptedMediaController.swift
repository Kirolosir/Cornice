import Foundation

/// Read and control Music and Spotify with AppleScript. Normalize their differences here:
/// Spotify's duration is in milliseconds, Music's is in seconds; artwork and repeat are
/// exposed differently; both report volume from 0 to 100.
public actor ScriptedMediaController: MediaControlling {

    public nonisolated let source: MediaSource
    private let runner: AppleScriptRunner

    /// Use a unit separator so normal punctuation in song and album names does not split
    /// fields.
    private static let separator = "\u{1f}"

    /// The last full metadata read, reused while the track has not changed.
    private var cachedTrack: MediaSnapshot?

    public init(source: MediaSource, runner: AppleScriptRunner) {
        self.source = source
        self.runner = runner
    }

    public nonisolated func isRunning() async -> Bool {
        AppleScriptRunner.isRunning(bundleIdentifier: source.bundleIdentifier)
    }

    /// Read playback and position often, but fetch full metadata only when the track
    /// changes. Each player property costs an Apple event.
    public func snapshot() async throws -> MediaSnapshot? {
        guard await isRunning() else { return nil }

        let light = try await runner.run(lightScript, target: source.scriptingName)
        guard let raw = light.string else { return nil }
        guard let state = Self.parseLight(raw, source: source) else { return nil }
        // State only, never the track: enough to tell a working poll from a
        // failing one in a bug report, without writing what someone is listening
        // to into the system log.
        Log.media.info("\(self.source.rawValue, privacy: .public) poll: \(state.state.rawValue, privacy: .public)")

        guard state.state != .stopped else {
            cachedTrack = nil
            return MediaSnapshot(source: source, state: .stopped, title: "", artist: "",
                                 duration: 0, position: 0)
        }

        // Title plus length is enough to detect a track change without asking
        // for an identifier the two players spell differently.
        let unchanged = cachedTrack.map {
            $0.title == state.title && abs($0.duration - state.duration) < 0.5
        } ?? false

        if !unchanged {
            let full = try await runner.run(readScript, target: source.scriptingName)
            guard let rawFull = full.string, let parsed = parse(rawFull) else { return nil }
            cachedTrack = parsed
        }

        guard let track = cachedTrack else { return nil }

        // Overlay the live values onto the cached metadata.
        return MediaSnapshot(
            source: track.source,
            state: state.state,
            title: track.title,
            artist: track.artist,
            album: track.album,
            duration: track.duration,
            position: state.position,
            artworkURL: track.artworkURL,
            artworkData: track.artworkData,
            isShuffling: state.isShuffling,
            repeatMode: state.repeatMode,
            volume: state.volume,
            capturedAt: .now
        )
    }

    public func perform(_ command: MediaCommand) async throws {
        guard await isRunning() else {
            throw ServiceError.invalidConfiguration(reason: "\(source.displayName) is not running")
        }
        guard let script = commandScript(for: command) else { return }
        _ = try await runner.run(script, target: source.scriptingName)
    }

    // MARK: - Reading

    /// The cheap read: only what changes between polls.
    nonisolated var lightScript: String {
        let application = source.scriptingName
        let durationExpression = "trackDuration as text"
        return """
        tell application "\(application)"
            set s to (player state as text)
            if s is "stopped" then return "stopped\(Self.separator)\(Self.separator)0\(Self.separator)0\(Self.separator)0\(Self.separator)false\(Self.separator)off"
            set trackName to ""
            set trackDuration to 0
            try
                set trackName to name of current track
                set trackDuration to duration of current track
            end try
            set pos to 0
            try
                set pos to player position
            end try
            set vol to 0
            try
                set vol to sound volume
            end try
            set shuf to "false"
            try
                if \(dialect.shuffleProperty) then set shuf to "true"
            end try
            set rep to "off"
            try
                \(dialect.repeatStatement)
            end try
            return s & "\(Self.separator)" & trackName & "\(Self.separator)" & (\(durationExpression)) & "\(Self.separator)" & (pos as text) & "\(Self.separator)" & (vol as text) & "\(Self.separator)" & shuf & "\(Self.separator)" & rep
        end tell
        """
    }

    /// Use proper AppleScript statements for repeat. AppleScript has no inline if
    /// expression, and one syntax error breaks the whole script.
    nonisolated var dialect: (shuffleProperty: String, repeatStatement: String) {
        switch source {
        case .spotify: ("shuffling", "if repeating then set rep to \"all\"")
        case .appleMusic: ("shuffle enabled", "set rep to (song repeat as text)")
        }
    }

    /// Parsed result of `lightScript`.
    struct LightState {
        var state: PlaybackState
        var title: String
        var duration: TimeInterval
        var position: TimeInterval
        var volume: Double
        var isShuffling: Bool
        var repeatMode: RepeatMode
    }

    static func parseLight(_ raw: String, source: MediaSource) -> LightState? {
        let fields = raw.components(separatedBy: separator)
        guard fields.count >= 5 else { return nil }
        let state: PlaybackState = switch fields[0] {
        case "playing": .playing
        case "paused": .paused
        default: .stopped
        }
        let rawDuration = number(fields[2])
        // Tolerant of a short reply: an older player, or one that raised on a
        // property, still yields a usable playhead rather than nothing at all.
        let shuffle = fields.count > 5 ? fields[5] == "true" : false
        let repeatMode = fields.count > 6 ? RepeatMode(rawValue: fields[6]) ?? .off : .off
        return LightState(
            state: state,
            title: fields[1],
            duration: source == .spotify ? rawDuration / 1000 : rawDuration,
            position: number(fields[3]),
            volume: (number(fields[4]) / 100).clamped(to: 0...1),
            isShuffling: shuffle,
            repeatMode: repeatMode
        )
    }

    /// Read the full track metadata when the song changes. Catch missing-track errors so an
    /// empty player reports stopped instead of failing the poll.
    nonisolated var readScript: String {
        switch source {
        case .spotify:
            """
            tell application "Spotify"
                set s to (player state as text)
                if s is "stopped" then return "stopped\(Self.separator)\(Self.separator)\(Self.separator)\(Self.separator)0\(Self.separator)0\(Self.separator)\(Self.separator)false\(Self.separator)off\(Self.separator)0"
                set t to current track
                set trackName to ""
                set trackArtist to ""
                set trackAlbum to ""
                set trackDuration to 0
                set artURL to ""
                try
                    set trackName to name of t
                    set trackArtist to artist of t
                    set trackAlbum to album of t
                    set trackDuration to duration of t
                    set artURL to artwork url of t
                end try
                set pos to 0
                try
                    set pos to player position
                end try
                set vol to 0
                try
                    set vol to sound volume
                end try
                set shuf to "false"
                try
                    if shuffling then set shuf to "true"
                end try
                set rep to "off"
                try
                    if repeating then set rep to "all"
                end try
                return s & "\(Self.separator)" & trackName & "\(Self.separator)" & trackArtist & "\(Self.separator)" & trackAlbum & "\(Self.separator)" & (trackDuration as text) & "\(Self.separator)" & (pos as text) & "\(Self.separator)" & artURL & "\(Self.separator)" & shuf & "\(Self.separator)" & rep & "\(Self.separator)" & (vol as text)
            end tell
            """
        case .appleMusic:
            """
            tell application "Music"
                set s to (player state as text)
                if s is "stopped" then return "stopped\(Self.separator)\(Self.separator)\(Self.separator)\(Self.separator)0\(Self.separator)0\(Self.separator)\(Self.separator)false\(Self.separator)off\(Self.separator)0"
                set trackName to ""
                set trackArtist to ""
                set trackAlbum to ""
                set trackDuration to 0
                try
                    set t to current track
                    set trackName to name of t
                    set trackArtist to artist of t
                    set trackAlbum to album of t
                    set trackDuration to duration of t
                end try
                set pos to 0
                try
                    set pos to player position
                end try
                set vol to 0
                try
                    set vol to sound volume
                end try
                set shuf to "false"
                try
                    if shuffle enabled then set shuf to "true"
                end try
                set rep to "off"
                try
                    set rep to (song repeat as text)
                end try
                return s & "\(Self.separator)" & trackName & "\(Self.separator)" & trackArtist & "\(Self.separator)" & trackAlbum & "\(Self.separator)" & (trackDuration as text) & "\(Self.separator)" & (pos as text) & "\(Self.separator)" & "" & "\(Self.separator)" & shuf & "\(Self.separator)" & rep & "\(Self.separator)" & (vol as text)
            end tell
            """
        }
    }

    /// Parse the player's delimited reply. Tests cover duration units and numbers formatted
    /// with different locales.
    public func parse(_ raw: String) -> MediaSnapshot? {
        Self.parse(raw, source: source)
    }

    static func parse(_ raw: String, source: MediaSource) -> MediaSnapshot? {
        let fields = raw.components(separatedBy: separator)
        guard fields.count >= 10 else { return nil }

        let state: PlaybackState = switch fields[0] {
        case "playing": .playing
        case "paused": .paused
        default: .stopped
        }

        let title = fields[1]
        guard state != .stopped || !title.isEmpty else {
            return MediaSnapshot(
                source: source, state: .stopped, title: "", artist: "",
                duration: 0, position: 0
            )
        }

        // AppleScript can return a comma decimal separator. Accept that too so positions
        // don't parse as zero.
        let rawDuration = Self.number(fields[4])
        let position = Self.number(fields[5])

        // Spotify reports milliseconds; Music reports seconds.
        let duration = source == .spotify ? rawDuration / 1000 : rawDuration

        let repeatMode: RepeatMode = switch fields[8].lowercased() {
        case "all": .all
        case "one": .one
        default: .off
        }

        return MediaSnapshot(
            source: source,
            state: state,
            title: title,
            artist: fields[2],
            album: fields[3],
            duration: duration,
            position: position,
            artworkURL: fields[6].isEmpty ? nil : URL(string: fields[6]),
            artworkData: nil,
            isShuffling: fields[7] == "true",
            repeatMode: repeatMode,
            // Both players report 0–100.
            volume: (Self.number(fields[9]) / 100).clamped(to: 0...1),
            capturedAt: .now
        )
    }

    /// Locale-independent number parsing.
    static func number(_ text: String) -> Double {
        let trimmed = text.trimmingCharacters(in: .whitespaces)
        if let value = Double(trimmed) { return value }
        // Comma-decimal locales.
        if let value = Double(trimmed.replacingOccurrences(of: ",", with: ".")) { return value }
        return 0
    }

    // MARK: - Artwork

    /// Music returns artwork as image bytes, not a URL. Local tracks may have no cover, so
    /// nil is fine.
    public func artworkData() async throws -> Data? {
        guard source == .appleMusic, await isRunning() else { return nil }
        let script = """
        tell application "Music"
            try
                set t to current track
                if (count of artworks of t) is 0 then return missing value
                return data of artwork 1 of t
            on error
                return missing value
            end try
        end tell
        """
        return try await runner.run(script, target: source.scriptingName).data
    }

    // MARK: - Commands

    nonisolated func commandScript(for command: MediaCommand) -> String? {
        let application = source.scriptingName

        switch command {
        case .playPause:
            return "tell application \"\(application)\" to playpause"
        case .next:
            return "tell application \"\(application)\" to next track"
        case .previous:
            // Seek to zero before Previous so it goes back a track instead of restarting
            // the current one.
            return """
            tell application "\(application)"
                set player position to 0
                previous track
            end tell
            """
        case .seek(let seconds):
            // Formatted with a POSIX locale for the same reason parsing is:
            // a comma-decimal string is a syntax error in AppleScript.
            return "tell application \"\(application)\" to set player position to \(Self.format(seconds))"
        case .setVolume(let level):
            let scaled = Int((level.clamped(to: 0...1) * 100).rounded())
            return "tell application \"\(application)\" to set sound volume to \(scaled)"
        case .toggleShuffle:
            switch source {
            case .spotify:
                return "tell application \"Spotify\" to set shuffling to not shuffling"
            case .appleMusic:
                return "tell application \"Music\" to set shuffle enabled to not shuffle enabled"
            }
        case .setRepeat(let mode):
            switch source {
            case .spotify:
                // The only thing Spotify's dictionary offers. Repeat-one is
                // carried by the app looping the track, not by the player.
                return "tell application \"Spotify\" to set repeating to \(mode == .off ? "false" : "true")"
            case .appleMusic:
                return "tell application \"Music\" to set song repeat to \(mode.rawValue)"
            }
        case .cycleRepeat:
            switch source {
            case .spotify:
                return "tell application \"Spotify\" to set repeating to not repeating"
            case .appleMusic:
                return """
                tell application "Music"
                    if song repeat is off then
                        set song repeat to all
                    else if song repeat is all then
                        set song repeat to one
                    else
                        set song repeat to off
                    end if
                end tell
                """
            }
        }
    }

    static func format(_ value: Double) -> String {
        String(format: "%.3f", value)
    }
}
