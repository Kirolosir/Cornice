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
            reachability: NetworkReachability(),
            vpn: VPNMonitor(),
            downloads: DownloadsMonitor()
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
        let gradient = NSGradient(
            colors: [
                NSColor(calibratedRed: 0.86, green: 0.24, blue: 0.20, alpha: 1),
                NSColor(calibratedRed: 0.36, green: 0.10, blue: 0.22, alpha: 1),
                NSColor(calibratedRed: 0.09, green: 0.06, blue: 0.14, alpha: 1),
            ]
        )
        gradient?.draw(in: NSRect(x: 0, y: 0, width: size, height: size), angle: -60)
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
            networkInBytesPerSecond: max(0, 820_000 + 640_000 * sin(phase * 1.3)),
            networkOutBytesPerSecond: max(0, 150_000 + 120_000 * sin(phase * 0.9)),
            battery: BatteryState(level: 0.72, isCharging: false, isPluggedIn: false, minutesRemaining: 214),
            capturedAt: .now
        )
    }
}
