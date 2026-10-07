import Foundation

/// Store the notice's values with its state so a later reading doesn't change the message
/// while it's on screen.
public enum HUDContent: Equatable, Sendable {
    case noInternet
    case filesReceived(files: [String])
    case timerRunning(id: UUID, label: String, isRunning: Bool, isFinished: Bool)
    case charging(level: Double)
    case batteryLow(level: Double)
    case fullBattery
    case vpn(name: String, since: Date)
    /// `progress` is nil when the source does not publish an expected size,
    /// which is the normal case for a Chromium download. The bar is omitted
    /// rather than guessed at.
    case download(name: String, progress: Double?, bytesPerSecond: Double)
    case doNotDisturb
    case handoff

    public var kind: HUDKind {
        switch self {
        case .noInternet: .noInternet
        case .filesReceived: .filesReceived
        case .timerRunning: .timerRunning
        case .charging: .charging
        case .batteryLow: .batteryLow
        case .fullBattery: .fullBattery
        case .vpn: .vpn
        case .download: .download
        case .doNotDisturb: .doNotDisturb
        case .handoff: .handoff
        }
    }

    /// Keep unanswered alerts above ordinary notices. Battery warnings take priority over
    /// less urgent updates.
    public var priority: Int {
        switch self {
        case .noInternet, .timerRunning, .filesReceived: 2
        case .batteryLow: 1
        default: 0
        }
    }

    /// Whether this HUD is waiting on the user rather than counting down.
    public var isInteractive: Bool {
        switch self {
        case .noInternet, .filesReceived, .timerRunning: true
        default: false
        }
    }
}
