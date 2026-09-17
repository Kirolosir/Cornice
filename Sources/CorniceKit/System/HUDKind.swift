import Foundation

/// Every system notification the surface can show, and the size it takes.
///
/// All eleven use the one construction — square top corners, convex bottom,
/// concave cove — at whatever size the notification needs. Nothing here is a
/// separate window or a separate shape; a HUD is the same object as the player,
/// stopped at a different size.
///
/// Widths are expressed as a *wing* — how far the surface grows past the notch
/// on each side — rather than as an absolute, so a display whose notch measures
/// something other than the 209 pt the design was drawn against still gets a
/// surface centred on its own cut-out. Heights are a drop below the 38 pt band
/// for the same reason.
public enum HUDKind: String, Equatable, Sendable, CaseIterable, Identifiable {
    case noInternet
    case filesReceived
    case timerRunning
    case charging
    case batteryLow
    case fullBattery
    case vpn
    case volume
    case download
    case doNotDisturb
    case handoff

    public var id: String { rawValue }

    /// Growth past the notch on each side. 604 wide is a wing of 197.5.
    public var wing: CGFloat {
        switch self {
        case .noInternet, .filesReceived: 197.5   // 604
        case .vpn, .download: 175.5               // 560
        case .timerRunning, .volume: 135.5        // 480
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
        case .volume: 66             // 104
        case .download: 66           // 104
        case .doNotDisturb: 4        // 42
        case .handoff: 2             // 40
        }
    }

    public var bottomRadius: CGFloat {
        switch self {
        case .noInternet, .filesReceived: 28
        case .timerRunning, .batteryLow, .fullBattery, .vpn, .volume, .download: 24
        case .charging, .doNotDisturb: 14
        case .handoff: 13
        }
    }

    public var flareRadius: CGFloat {
        switch self {
        case .noInternet, .filesReceived: 24
        case .timerRunning, .batteryLow, .fullBattery, .vpn, .volume, .download: 20
        case .charging, .doNotDisturb: 12
        case .handoff: 11
        }
    }

    /// Horizontal inset for this HUD's content, measured from the body's edge.
    ///
    /// Short pills sit tighter to their edges than tall panels do, which is what
    /// keeps a 42 pt strip from looking padded out and a 196 pt panel from
    /// looking cramped.
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
        case .timerRunning, .vpn, .volume: 44
        // The short pills have no clear row: everything lives in the two
        // margins beside the hole.
        case .charging, .doNotDisturb, .handoff: 0
        }
    }

    /// Whether the whole surface is shorter than the notch band, so content can
    /// only ever live in the margins either side of the hole.
    public var isShortPill: Bool { contentTop == 0 }

    /// How long it stays up before retracting on its own.
    ///
    /// `nil` means it waits to be dealt with: an alert with buttons, or a timer
    /// that is currently making a noise. Everything else is an announcement, and
    /// an announcement that needs dismissing is a dialog wearing a disguise.
    public var dismissAfter: TimeInterval? {
        switch self {
        case .noInternet: nil
        case .filesReceived: nil
        case .timerRunning: nil
        case .charging: 2.6
        case .batteryLow: 5
        case .fullBattery: 3
        case .vpn: 3
        case .volume: 1.6
        case .download: 3
        case .doNotDisturb: 2
        case .handoff: 1.5
        }
    }

    /// Whether an artwork tint may spill onto it. None of these are about music.
    public var takesTint: Bool { false }
}
