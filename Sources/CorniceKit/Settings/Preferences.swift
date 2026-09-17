import Foundation

/// The panels available in the expanded surface.
public enum ModuleKind: String, Codable, Sendable, CaseIterable, Identifiable {
    case media
    case timers
    case stats

    public var id: String { rawValue }

    public var title: String {
        switch self {
        case .media: "Now Playing"
        case .timers: "Timers"
        case .stats: "System"
        }
    }

    public var symbol: String {
        switch self {
        case .media: "music.note"
        case .timers: "timer"
        case .stats: "chart.bar.fill"
        }
    }
}

/// How the collapsed surface reacts to the pointer.
public enum ActivationStyle: String, Codable, Sendable, CaseIterable, Identifiable {
    /// Expand as soon as the pointer settles on the notch.
    case hover
    /// Expand only on click, so it never opens by accident.
    case click

    public var id: String { rawValue }

    public var title: String {
        switch self {
        case .hover: "Hover"
        case .click: "Click only"
        }
    }
}

/// What the collapsed surface shows while a track plays.
public enum IdleDisplay: String, Codable, Sendable, CaseIterable, Identifiable {
    /// Album art on one side, live spectrum on the other.
    case artworkAndSpectrum
    /// Album art and the scrolling track title.
    case artworkAndTitle
    /// Nothing at all — the notch stays exactly as the hardware made it.
    case nothing

    public var id: String { rawValue }

    public var title: String {
        switch self {
        case .artworkAndSpectrum: "Artwork and spectrum"
        case .artworkAndTitle: "Artwork and title"
        case .nothing: "Nothing"
        }
    }
}

/// Everything the user can configure.
public struct Preferences: Codable, Equatable, Sendable {
    public static let currentSchemaVersion = 2
    public var schemaVersion: Int

    // Presentation
    public var enabledModules: Set<ModuleKind>
    public var activationStyle: ActivationStyle
    /// Seconds the pointer must rest on the notch before it opens.
    public var hoverDwell: Double
    public var idleDisplay: IdleDisplay
    public var launchAtLogin: Bool

    // Media
    /// Poll interval for player state, in seconds.
    public var mediaRefreshInterval: Double
    /// Show the surface only while something is playing.
    public var hideWhenNothingPlaying: Bool

    // Visualiser
    /// Capture system audio for a spectrum that actually follows the music.
    /// Off until the user turns it on, because enabling it asks for a
    /// system-wide audio recording permission.
    public var audioVisualizerEnabled: Bool
    /// Tint the surface with the album artwork's dominant colour.
    public var tintFromArtwork: Bool
    /// How strongly, as a multiplier on the design's own tint alphas.
    ///
    /// The design specifies a deliberately restrained 22/8/0% wash, so that the
    /// surface reads as black picking up colour from the cover rather than as a
    /// coloured panel. This exists because "a little more noticeable" is a
    /// legitimate taste, and it is the one place the spec invites a dial.
    public var tintStrength: Double

    // System HUDs
    /// Watch the Downloads folder so a transfer in progress raises a HUD.
    ///
    /// Off by default, and deliberately so: reading that folder is
    /// TCC-protected, and starting the watch at launch would spring a
    /// permission dialog on somebody who never asked for a download HUD.
    public var downloadHUDEnabled: Bool

    // Timers
    public var timerPresetsMinutes: [Int]
    public var notifyOnTimerComplete: Bool

    // Stats
    public var telemetryRefreshInterval: Double

    public init(
        schemaVersion: Int = Preferences.currentSchemaVersion,
        enabledModules: Set<ModuleKind> = Set(ModuleKind.allCases),
        activationStyle: ActivationStyle = .hover,
        hoverDwell: Double = 0.05,
        idleDisplay: IdleDisplay = .artworkAndTitle,
        launchAtLogin: Bool = false,
        mediaRefreshInterval: Double = 1.0,
        hideWhenNothingPlaying: Bool = false,
        audioVisualizerEnabled: Bool = false,
        tintFromArtwork: Bool = true,
        tintStrength: Double = 1.0,
        downloadHUDEnabled: Bool = false,
        timerPresetsMinutes: [Int] = [5, 10, 15, 25],
        notifyOnTimerComplete: Bool = true,
        telemetryRefreshInterval: Double = 2
    ) {
        self.schemaVersion = schemaVersion
        self.enabledModules = enabledModules
        self.activationStyle = activationStyle
        self.hoverDwell = hoverDwell
        self.idleDisplay = idleDisplay
        self.launchAtLogin = launchAtLogin
        self.mediaRefreshInterval = mediaRefreshInterval
        self.hideWhenNothingPlaying = hideWhenNothingPlaying
        self.audioVisualizerEnabled = audioVisualizerEnabled
        self.tintFromArtwork = tintFromArtwork
        self.tintStrength = tintStrength
        self.downloadHUDEnabled = downloadHUDEnabled
        self.timerPresetsMinutes = timerPresetsMinutes
        self.notifyOnTimerComplete = notifyOnTimerComplete
        self.telemetryRefreshInterval = telemetryRefreshInterval
    }

    /// Decodes every field independently with a fallback to its default.
    ///
    /// The synthesised initialiser requires *every* key, so adding one setting
    /// would make every existing file fail to decode — and since a decode
    /// failure falls back to defaults, upgrading would silently reset everyone's
    /// configuration. Decoding key by key makes schema changes additive.
    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let defaults = Preferences()

        func value<T: Decodable>(_ key: CodingKeys, _ fallback: T) -> T {
            (try? container.decodeIfPresent(T.self, forKey: key)).flatMap { $0 } ?? fallback
        }

        schemaVersion = value(.schemaVersion, defaults.schemaVersion)
        enabledModules = value(.enabledModules, defaults.enabledModules)
        activationStyle = value(.activationStyle, defaults.activationStyle)
        hoverDwell = value(.hoverDwell, defaults.hoverDwell)
        idleDisplay = value(.idleDisplay, defaults.idleDisplay)
        launchAtLogin = value(.launchAtLogin, defaults.launchAtLogin)
        mediaRefreshInterval = value(.mediaRefreshInterval, defaults.mediaRefreshInterval)
        hideWhenNothingPlaying = value(.hideWhenNothingPlaying, defaults.hideWhenNothingPlaying)
        audioVisualizerEnabled = value(.audioVisualizerEnabled, defaults.audioVisualizerEnabled)
        tintFromArtwork = value(.tintFromArtwork, defaults.tintFromArtwork)
        tintStrength = value(.tintStrength, defaults.tintStrength)
        downloadHUDEnabled = value(.downloadHUDEnabled, defaults.downloadHUDEnabled)
        timerPresetsMinutes = value(.timerPresetsMinutes, defaults.timerPresetsMinutes)
        notifyOnTimerComplete = value(.notifyOnTimerComplete, defaults.notifyOnTimerComplete)
        telemetryRefreshInterval = value(.telemetryRefreshInterval, defaults.telemetryRefreshInterval)
    }

    /// Clamps every value into a range the app can actually run with, so a
    /// hand-edited or partially-corrupted file cannot put it into a state where
    /// it polls a music player a hundred times a second.
    public func sanitized() -> Preferences {
        var copy = self
        copy.hoverDwell = hoverDwell.clamped(to: 0...1.0)
        // A floor of 0.25s: each poll is an Apple event round-trip to another
        // process, and the playhead is extrapolated locally between polls
        // anyway, so faster buys nothing.
        copy.mediaRefreshInterval = mediaRefreshInterval.clamped(to: 0.25...10)
        copy.telemetryRefreshInterval = telemetryRefreshInterval.clamped(to: 1...60)
        // The upper bound is the point past which the accent stops being a tint
        // and starts competing with the album art it came from.
        copy.tintStrength = tintStrength.clamped(to: 0...1.4)
        copy.timerPresetsMinutes = timerPresetsMinutes
            .filter { (1...600).contains($0) }
            .reduplicated(by: \.self)
            .sorted()
        if copy.timerPresetsMinutes.isEmpty {
            copy.timerPresetsMinutes = Preferences().timerPresetsMinutes
        }
        // Media is the point of the app; it cannot be switched off.
        copy.enabledModules.insert(.media)
        return copy
    }
}
