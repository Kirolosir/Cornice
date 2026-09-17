import Foundation

/// Controls Apple Music or Spotify through their scripting interfaces.
///
/// One implementation for both, because the *shape* of the conversation is
/// identical — read a handful of properties, send a handful of commands — and
/// only the vocabulary differs. The differences are isolated in `Dialect`:
///
/// - Spotify reports track duration in **milliseconds**, Music in seconds.
/// - Spotify exposes `artwork url`; Music only hands over raw image data.
/// - Music spells repeat as `song repeat` with `off`/`one`/`all`; Spotify uses
///   a boolean `repeating`.
/// - Both report volume 0–100, not 0–1.
///
/// Getting any one of those wrong produces a plausible-looking but wrong UI —
/// a 272-second track showing as 272,394 seconds, for instance — which is why
/// each is parsed explicitly and covered by a test.
public actor ScriptedMediaController: MediaControlling {

    public nonisolated let source: MediaSource
    private let runner: AppleScriptRunner

    /// Field separator. A unit separator rather than anything printable,
    /// because track and album names contain every printable character there
    /// is — including the pipes and tabs people reach for first.
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

    /// Current state, or `nil` when nothing is loaded.
    ///
    /// Two tiers, because polling cost matters. Neither player supports reading
    /// a track's properties as one record — Spotify raises on
    /// `properties of current track` — so each property read is its own Apple
    /// event to another process. Reading all ten every second was measurably
    /// expensive.
    ///
    /// So the frequent read fetches only what actually changes between polls —
    /// playback state, playhead, volume, and the track title as a change
    /// signal — and the full metadata read runs only when the title or length
    /// says the track moved on. Steady-state cost drops by more than half.
    public func snapshot() async throws -> MediaSnapshot? {
        guard await isRunning() else { return nil }

        let light = try await runner.run(lightScript, target: source.scriptingName)
        guard let raw = light.string else { return nil }
        guard let state = Self.parseLight(raw, source: source) else { return nil }

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
            isShuffling: track.isShuffling,
            repeatMode: track.repeatMode,
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
    private var lightScript: String {
        let application = source.scriptingName
        let durationExpression = "trackDuration as text"
        return """
        tell application "\(application)"
            set s to (player state as text)
            if s is "stopped" then return "stopped\(Self.separator)\(Self.separator)0\(Self.separator)0\(Self.separator)0"
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
            return s & "\(Self.separator)" & trackName & "\(Self.separator)" & (\(durationExpression)) & "\(Self.separator)" & (pos as text) & "\(Self.separator)" & (vol as text)
        end tell
        """
    }

    /// Parsed result of `lightScript`.
    struct LightState {
        var state: PlaybackState
        var title: String
        var duration: TimeInterval
        var position: TimeInterval
        var volume: Double
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
        return LightState(
            state: state,
            title: fields[1],
            duration: source == .spotify ? rawDuration / 1000 : rawDuration,
            position: number(fields[3]),
            volume: (number(fields[4]) / 100).clamped(to: 0...1)
        )
    }

    /// The full read: everything, run only when the track changes.
    ///
    /// One round-trip rather than one per property: each is an IPC call to
    /// another process, and reading eight properties separately would be eight
    /// context switches per poll.
    ///
    /// Wrapped in `try` blocks because a player that is open with nothing
    /// loaded raises on `current track` rather than returning empty — so the
    /// script degrades to a "stopped" answer instead of throwing.
    private var readScript: String {
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

    /// Parses the delimited reply.
    ///
    /// Exposed for testing: this is where the millisecond/second mismatch and
    /// the locale-dependent number formatting actually bite, and both are far
    /// easier to cover with a fixture than with a running music player.
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

        // AppleScript renders reals using the *user's* locale, so a machine set
        // to a comma-decimal locale returns "182,813". Parsing with a fixed
        // POSIX locale and falling back to a comma swap keeps the playhead from
        // silently reading as zero for a large fraction of the world.
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

    /// Apple Music's artwork, as raw image data.
    ///
    /// Music has no artwork URL — the image lives in the library — so it comes
    /// back as an Apple event data descriptor rather than a string. Returns
    /// `nil` for tracks with no artwork, which is common for local files.
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

    private func commandScript(for command: MediaCommand) -> String? {
        let application = source.scriptingName

        switch command {
        case .playPause:
            return "tell application \"\(application)\" to playpause"
        case .next:
            return "tell application \"\(application)\" to next track"
        case .previous:
            // Both players restart the current track on a single "previous"
            // when the playhead has moved. Seeking to zero first makes the
            // button always mean "go back a track", which is what the icon says.
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
