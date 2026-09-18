import Foundation
import SystemConfiguration

/// Whether a VPN is carrying the Mac's default route.
///
/// The test is deliberately "is the primary interface a tunnel", not "does a
/// tunnel interface exist". Plenty of things create `utun` devices without being
/// a VPN (iCloud Private Relay, Handoff, AirDrop), so counting interfaces reports
/// a VPN connected on a machine that has none. What people mean by "the VPN is
/// on" is that their traffic is going through it, and that is exactly what the
/// primary interface says.
///
/// Event-driven through `SCDynamicStore` rather than polled: the networking
/// stack already publishes this and notifies on change.
public final class VPNMonitor: @unchecked Sendable {

    public struct Connection: Equatable, Sendable {
        /// The tunnel interface, e.g. `utun4`.
        public let interface: String
        /// When this monitor first saw it, which is as close to a session start
        /// as can be had without asking the VPN client itself.
        public let since: Date

        public init(interface: String, since: Date) {
            self.interface = interface
            self.since = since
        }
    }

    public typealias ChangeHandler = @Sendable (Connection?) -> Void

    private let lock = NSLock()
    private var handler: ChangeHandler?
    private var store: SCDynamicStore?
    private var current: Connection?
    private var hasSeededState = false

    private let queue = DispatchQueue(label: "dev.cornice.vpn", qos: .utility)
    /// A plain `String`, converted at each use: a `CFString` global is not
    /// `Sendable`, and this is read from two queues.
    private static let key = "State:/Network/Global/IPv4"

    /// Interface prefixes that mean "tunnel" on macOS.
    private static let tunnelPrefixes = ["utun", "ppp", "ipsec", "tap", "tun"]

    public init() {}

    public func start(onChange: @escaping ChangeHandler) {
        lock.lock()
        guard store == nil else { lock.unlock(); return }
        handler = onChange
        lock.unlock()

        var context = SCDynamicStoreContext(
            version: 0,
            info: Unmanaged.passUnretained(self).toOpaque(),
            retain: nil,
            release: nil,
            copyDescription: nil
        )

        let callback: SCDynamicStoreCallBack = { _, _, info in
            guard let info else { return }
            let monitor = Unmanaged<VPNMonitor>.fromOpaque(info).takeUnretainedValue()
            monitor.evaluate()
        }

        guard let store = SCDynamicStoreCreate(
            nil, "dev.cornice.vpn" as CFString, callback, &context
        ) else { return }

        SCDynamicStoreSetNotificationKeys(store, [Self.key as CFString] as CFArray, nil)
        SCDynamicStoreSetDispatchQueue(store, queue)

        lock.lock()
        self.store = store
        lock.unlock()

        queue.async { [weak self] in self?.evaluate() }
    }

    public func stop() {
        lock.lock()
        let store = self.store
        self.store = nil
        handler = nil
        lock.unlock()
        guard let store else { return }
        SCDynamicStoreSetDispatchQueue(store, nil)
    }

    /// The current connection, if any.
    public func connection() -> Connection? {
        lock.lock(); defer { lock.unlock() }
        return current
    }

    private func evaluate() {
        let interface = Self.primaryInterface()
        let isTunnel = interface.map { name in
            Self.tunnelPrefixes.contains { name.hasPrefix($0) }
        } ?? false

        lock.lock()
        let previous = current
        let seeded = hasSeededState
        hasSeededState = true

        let next: Connection?
        if isTunnel, let interface {
            // The session clock survives an unrelated network change: only a
            // genuinely different tunnel restarts it.
            next = previous?.interface == interface ? previous : Connection(interface: interface, since: .now)
        } else {
            next = nil
        }
        current = next
        let handler = self.handler
        lock.unlock()

        // The first evaluation is the current state, not a change. Announcing it
        // would pop a "VPN connected" HUD every launch for anyone who leaves one on.
        guard seeded, previous != next else { return }
        handler?(next)
    }

    private static func primaryInterface() -> String? {
        guard let store = SCDynamicStoreCreate(nil, "dev.cornice.vpn.read" as CFString, nil, nil),
              let value = SCDynamicStoreCopyValue(store, key as CFString) as? [String: Any],
              let interface = value["PrimaryInterface"] as? String
        else { return nil }
        return interface
    }
}
