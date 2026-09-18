import Foundation

/// What a system HUD is actually saying.
///
/// The payload is carried with the state rather than read back out of the model
/// when the view draws, because a HUD outlives the condition that raised it: a
/// charge notice should not blank out because the next telemetry sample landed.
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

    /// Whether a newly-raised HUD should replace this one.
    ///
    /// An unanswered alert outranks everything else, because it is waiting on an
    /// answer; a charge warning outranks the rest of the announcements.
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
