import Foundation
import CorniceKit

/// Every service the app needs, in one injectable bundle.
///
/// Dependency injection by construction rather than by framework: one
/// composition root, a handful of services, no runtime resolution. The payoff
/// is `PreviewServices`, where swapping this whole struct runs the entire app
/// against scripted data with no change to any view.
struct ServiceContainer: Sendable {
    let media: MediaCoordinator
    let telemetry: any TelemetryProbing
    let preferences: any PreferencesPersisting
    let hardware: HardwareIdentityProvider
    let visualizer: AudioVisualizerEngine
    let outputDevices: OutputDeviceMonitor
    let outputVolume: OutputVolumeReader
    let reachability: NetworkReachability
    let vpn: VPNMonitor
    let downloads: DownloadsMonitor
    /// Spotify's Web API, for the repeat state its scripting interface cannot
    /// express. Idle — and asking for nothing — until a client ID is entered.
    let spotify: SpotifyWebRemote

    static func live() -> ServiceContainer {
        let runner = SubprocessRunner()
        return ServiceContainer(
            media: MediaCoordinator.live(),
            telemetry: HostTelemetryProbe(),
            preferences: PreferencesStore(),
            hardware: HardwareIdentityProvider(runner: runner),
            visualizer: AudioVisualizerEngine(bandCount: 8),
            outputDevices: OutputDeviceMonitor(),
            outputVolume: OutputVolumeReader(),
            reachability: NetworkReachability(),
            vpn: VPNMonitor(),
            downloads: DownloadsMonitor(),
            spotify: SpotifyWebRemote(clientID: "")
        )
    }
}
