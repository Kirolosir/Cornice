import Foundation

/// A process found listening on a TCP port.
public struct ListeningProcess: Equatable, Sendable, Codable {
    public let pid: Int32
    /// Full executable name. `lsof` field output gives the untruncated name,
    /// unlike its column output which clips at nine characters.
    public let command: String
    public let user: String
    /// Which interface it bound to: `*` for all, or a specific address.
    public let boundAddress: String
    /// How long the process has been running, when `ps` could tell us.
    public var uptime: TimeInterval?

    public init(
        pid: Int32,
        command: String,
        user: String,
        boundAddress: String,
        uptime: TimeInterval? = nil
    ) {
        self.pid = pid
        self.command = command
        self.user = user
        self.boundAddress = boundAddress
        self.uptime = uptime
    }

    /// Whether the socket is reachable from other machines, which is worth
    /// flagging for a dev server that the user probably meant to keep local.
    public var isPubliclyBound: Bool {
        boundAddress == "*" || boundAddress == "0.0.0.0" || boundAddress == "::"
    }
}

/// The state of one monitored port.
public struct PortStatus: Equatable, Sendable, Identifiable, Codable {
    public let port: Int
    /// User-supplied name, e.g. "web" or "api".
    public let label: String?
    /// `nil` when nothing is listening.
    public let listener: ListeningProcess?
    public let checkedAt: Date

    public var id: Int { port }

    public init(port: Int, label: String?, listener: ListeningProcess?, checkedAt: Date) {
        self.port = port
        self.label = label
        self.listener = listener
        self.checkedAt = checkedAt
    }

    public var isActive: Bool { listener != nil }

    /// The URL to open in a browser. `localhost` rather than the bound address
    /// because a server bound to `*` is still reached at localhost, and because
    /// `http://*:3000` is not a URL.
    public var localURL: URL? {
        URL(string: "http://localhost:\(port)")
    }

    public var displayName: String { label ?? "Port \(port)" }
}
