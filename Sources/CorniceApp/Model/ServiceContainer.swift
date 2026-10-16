import Foundation
import CorniceKit

/// Keep the services together so previews and checks can replace them without changing the
/// views.
struct ServiceContainer: Sendable {
    let notices: any NoticePresenting
    let media: MediaCoordinator
    let telemetry: any TelemetryProbing
    let sessions: any SessionPersisting
    let preferences: any PreferencesPersisting
    let hardware: HardwareIdentityProvider
    let visualizer: AudioVisualizerEngine
    let outputDevices: OutputDeviceMonitor
    let outputVolume: OutputVolumeReader
    let reachability: NetworkReachability
    let vpn: VPNMonitor
    let downloads: DownloadsMonitor
    /// Spotify's Web API, for the repeat state its scripting interface cannot
    /// express. Idle (and asking for nothing) until a client ID is entered.
    let spotify: SpotifyWebRemote

    @MainActor static func live() -> ServiceContainer {
        let runner = SubprocessRunner()
        return ServiceContainer(
            notices: NotificationPresenter.shared,
            media: MediaCoordinator.live(),
            telemetry: HostTelemetryProbe(),
            sessions: SessionStore(),
            preferences: PreferencesStore(),
            hardware: HardwareIdentityProvider(runner: runner),
            visualizer: AudioVisualizerEngine(bandCount: 6),
            outputDevices: OutputDeviceMonitor(),
            outputVolume: OutputVolumeReader(),
            reachability: NetworkReachability(),
            vpn: VPNMonitor(),
            downloads: DownloadsMonitor(),
            spotify: SpotifyWebRemote(clientID: "")
        )
    }
}
