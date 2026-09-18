import AppKit
import Foundation
import CorniceKit

/// A `ServiceContainer` backed entirely by doubles.
///
/// Used by `--capture-docs` to render documentation images, and useful for
/// driving states that are awkward to produce on demand. That this is short is
/// the payoff from putting every service behind a protocol: the whole app runs
/// on fake data with no change to any view.
enum PreviewServices {

    static func container() -> ServiceContainer {
        ServiceContainer(
            media: MediaCoordinator(controllers: [PreviewMediaController()]),
            telemetry: PreviewTelemetryProbe(),
            preferences: EphemeralPreferencesStore(previewPreferences()),
            hardware: HardwareIdentityProvider(runner: SubprocessRunner()),
            visualizer: AudioVisualizerEngine(bandCount: 8),
            outputDevices: OutputDeviceMonitor(),
            outputVolume: OutputVolumeReader(),
            reachability: NetworkReachability(),
            vpn: VPNMonitor(),
            downloads: DownloadsMonitor(),
            // No client ID, so it stays unconfigured and never reaches the network.
            spotify: SpotifyWebRemote(clientID: "", store: EphemeralTokenStore())
        )
    }

    static func previewPreferences() -> Preferences {
        var preferences = Preferences()
        preferences.enabledModules = Set(ModuleKind.allCases)
        // The documented resting state is the shipped one: a track title, not a
        // spectrum. Nothing animates while at rest.
        preferences.idleDisplay = .artworkAndTitle
        preferences.tintFromArtwork = true
        // Left off: the documentation build must not trigger a system audio
        // permission prompt on whatever machine renders it.
        preferences.audioVisualizerEnabled = false
        return preferences
    }
}

/// A player with a fixed track, whose playhead advances in real time.
private actor PreviewMediaController: MediaControlling {
    nonisolated let source: MediaSource = .spotify
    private let startedAt = Date()

    nonisolated func isRunning() async -> Bool { true }

    func snapshot() async throws -> MediaSnapshot? {
        let duration: TimeInterval = 272
        let elapsed = Date().timeIntervalSince(startedAt).truncatingRemainder(dividingBy: duration)
        return MediaSnapshot(
            source: .spotify,
            state: .playing,
            title: "Do I Wanna Know?",
            artist: "Arctic Monkeys",
            album: "AM",
            duration: duration,
            position: 74 + elapsed * 0,
            artworkURL: nil,
            artworkData: Self.cover,
            isShuffling: false,
            repeatMode: .off,
            volume: 0.68,
            capturedAt: .now
        )
    }

    func perform(_ command: MediaCommand) async throws {}

    /// A generated cover, so the documentation images exercise the artwork and
    /// tinting paths without shipping someone else's album art in the repo.
    private static let cover: Data = {
        let size = 300
        guard let representation = NSBitmapImageRep(
            bitmapDataPlanes: nil, pixelsWide: size, pixelsHigh: size,
            bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
            colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0
        ) else { return Data() }

        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: representation)

        // Several colours in distinct places, because a flat two-tone gradient
        // would not exercise the per-region palette at all, and the whole point
        // of the documentation images is that they show what the code does.
        NSGradient(colors: [
            NSColor(calibratedHue: 0.95, saturation: 0.72, brightness: 0.85, alpha: 1),
            NSColor(calibratedHue: 0.72, saturation: 0.68, brightness: 0.45, alpha: 1),
        ])?.draw(in: NSRect(x: 0, y: 0, width: size, height: size), angle: -60)

        let blobs: [(NSColor, NSRect)] = [
            (NSColor(calibratedHue: 0.13, saturation: 0.85, brightness: 0.95, alpha: 1),
             NSRect(x: 150, y: 170, width: 150, height: 130)),
            (NSColor(calibratedHue: 0.47, saturation: 0.75, brightness: 0.80, alpha: 1),
             NSRect(x: -20, y: -10, width: 170, height: 150)),
            (NSColor(calibratedHue: 0.58, saturation: 0.80, brightness: 0.75, alpha: 1),
             NSRect(x: 170, y: -30, width: 160, height: 140)),
        ]
        for (color, rect) in blobs {
            color.setFill()
            NSBezierPath(ovalIn: rect).fill()
        }
        NSGraphicsContext.restoreGraphicsState()

        return representation.representation(using: .png, properties: [:]) ?? Data()
    }()
}

/// Telemetry with plausible, slowly-varying values.
private struct PreviewTelemetryProbe: TelemetryProbing {
    func sample() async -> TelemetrySample {
        let phase = Date().timeIntervalSince1970
        return TelemetrySample(
            cpuUsage: 0.29 + 0.18 * sin(phase * 0.7),
            memoryUsage: 0.58 + 0.04 * sin(phase * 0.3),
            memoryUsedBytes: UInt64(18.6 * 1024 * 1024 * 1024),
            memoryTotalBytes: UInt64(32.0 * 1024 * 1024 * 1024),
            battery: BatteryState(level: 0.72, isCharging: false, isPluggedIn: false, minutesRemaining: 214),
            capturedAt: .now
        )
    }
}
