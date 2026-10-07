import Foundation

/// Sizes and behavior for each HUD, using the same panel shape. Widths grow from the
/// measured notch on each side; heights extend below the notch band.
public enum HUDKind: String, Equatable, Sendable, CaseIterable, Identifiable {
    case noInternet
    case filesReceived
    case timerRunning
    case charging
    case batteryLow
    case fullBattery
    case vpn
    case download
    case doNotDisturb
    case handoff

    public var id: String { rawValue }

    /// Growth past the notch on each side. 604 wide is a wing of 197.5.
    public var wing: CGFloat {
        switch self {
        case .noInternet, .filesReceived: 197.5   // 604
        case .vpn, .download: 175.5               // 560
        case .timerRunning: 135.5                 // 480
        case .charging, .doNotDisturb: 108        // 425
        case .batteryLow, .fullBattery: 71.5      // 352
        case .handoff: 45.5                       // 300
        }
    }

    /// Height below the notch band.
    public var drop: CGFloat {
        switch self {
        case .noInternet: 114        // 152
        case .filesReceived: 158     // 196
        case .timerRunning: 54       // 92
        case .charging: 6            // 44
        case .batteryLow: 88         // 126
        case .fullBattery: 66        // 104
        case .vpn: 54                // 92
        case .download: 66           // 104
        case .doNotDisturb: 4        // 42
        case .handoff: 2             // 40
        }
    }

    public var bottomRadius: CGFloat {
        switch self {
        case .noInternet, .filesReceived: 28
        case .timerRunning, .batteryLow, .fullBattery, .vpn, .download: 24
        case .charging, .doNotDisturb: 14
        case .handoff: 13
        }
    }

    public var flareRadius: CGFloat {
        switch self {
        case .noInternet, .filesReceived: 24
        case .timerRunning, .batteryLow, .fullBattery, .vpn, .download: 20
        case .charging, .doNotDisturb: 12
        case .handoff: 11
        }
    }

    /// Content inset for each HUD. Short notices use less padding than taller panels.
    public var contentPadding: CGFloat {
        switch self {
        case .charging: 18
        case .doNotDisturb, .handoff: 18
        case .batteryLow, .fullBattery: 20
        default: 22
        }
    }

    /// The first clear row below the band, for the HUDs tall enough to have one.
    public var contentTop: CGFloat {
        switch self {
        case .noInternet: 48
        case .filesReceived: 52
        case .batteryLow: 48
        case .fullBattery: 46
        case .download: 46
        case .timerRunning, .vpn: 44
        // The short pills have no clear row: everything lives in the two
        // margins beside the hole.
        case .charging, .doNotDisturb, .handoff: 0
        }
    }

    /// Whether the whole surface is shorter than the notch band, so content can
    /// only ever live in the margins either side of the hole.
    public var isShortPill: Bool { contentTop == 0 }

    /// Automatic dismissal delay. Nil means the notice waits for input, such as a ringing
    /// timer or an alert with buttons.
    public var dismissAfter: TimeInterval? {
        switch self {
        case .noInternet: nil
        case .filesReceived: nil
        case .timerRunning: nil
        case .charging: 2.6
        case .batteryLow: 5
        case .fullBattery: 3
        case .vpn: 3
        case .download: 3
        case .doNotDisturb: 2
        case .handoff: 1.5
        }
    }

    /// Whether an artwork tint may spill onto it. None of these are about music.
    public var takesTint: Bool { false }
}
