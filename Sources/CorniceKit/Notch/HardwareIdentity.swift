import Foundation

/// Identifies the machine the app is running on.
///
/// Two tiers, because they have very different costs. The model identifier
/// comes from `sysctl`, which is a cheap in-process read and is available
/// immediately at launch. The marketing name and chip come from
/// `system_profiler`, which spawns a process and takes on the order of a second,
/// so it is fetched once, lazily, off the main actor, and cached for the
/// lifetime of the app.
public struct HardwareIdentity: Equatable, Sendable {
    /// e.g. `Mac15,12`. Always available.
    public let modelIdentifier: String
    /// e.g. `MacBook Air`. `nil` until the profiler call completes.
    public let marketingName: String?
    /// e.g. `Apple M3`. `nil` until the profiler call completes.
    public let chip: String?
    /// e.g. `MacBook Air 13″`, from the built-in catalog, when the model is known.
    public let catalogName: String?

    public init(modelIdentifier: String, marketingName: String?, chip: String?, catalogName: String?) {
        self.modelIdentifier = modelIdentifier
        self.marketingName = marketingName
        self.chip = chip
        self.catalogName = catalogName
    }

    /// Best available description, e.g. `MacBook Air 13″ · Apple M3`, degrading
    /// to the bare model identifier on an unrecognised machine.
    public var displayName: String {
        let base = catalogName ?? marketingName ?? modelIdentifier
        if let chip { return "\(base) · \(chip)" }
        return base
    }

    /// Whether this model is expected to have a notch, per the catalog.
    public var expectsNotch: Bool {
        MacModelCatalog.expectsNotch(modelIdentifier: modelIdentifier)
    }
}

/// Reads hardware identity from the system.
public actor HardwareIdentityProvider {
    private let runner: any ProcessRunning
    private var cached: HardwareIdentity?

    public init(runner: any ProcessRunning) {
        self.runner = runner
    }

    /// The model identifier from `sysctl hw.model`. Synchronous and cheap.
    ///
    /// Reads into a sized buffer rather than using a fixed-size array so an
    /// unexpectedly long identifier on some future machine truncates cleanly
    /// instead of overflowing.
    public nonisolated static func modelIdentifier() -> String {
        var size = 0
        guard sysctlbyname("hw.model", nil, &size, nil, 0) == 0, size > 0 else {
            return "unknown"
        }
        var buffer = [UInt8](repeating: 0, count: size)
        guard sysctlbyname("hw.model", &buffer, &size, nil, 0) == 0 else {
            return "unknown"
        }
        // sysctl returns a NUL-terminated string; drop the terminator and any
        // trailing slack before decoding.
        let bytes = buffer.prefix { $0 != 0 }
        return String(decoding: bytes, as: UTF8.self)
    }

    /// Full identity, including the marketing name. Cached after the first call.
    ///
    /// Never throws: an identity with only the model identifier is still useful,
    /// and the diagnostics panel is not worth failing over.
    public func identity() async -> HardwareIdentity {
        if let cached { return cached }

        let model = Self.modelIdentifier()
        var marketingName: String?
        var chip: String?

        do {
            let result = try await runner.run(
                Command(
                    executable: "/usr/sbin/system_profiler",
                    arguments: ["SPHardwareDataType", "-json"],
                    timeout: 8
                )
            )
            if result.isSuccess, let data = result.standardOutput.data(using: .utf8) {
                (marketingName, chip) = Self.parseHardwareProfile(data)
            }
        } catch {
            Log.app.notice("system_profiler unavailable; using sysctl identity only")
        }

        let identity = HardwareIdentity(
            modelIdentifier: model,
            marketingName: marketingName,
            chip: chip,
            catalogName: MacModelCatalog.displayName(forModelIdentifier: model)
        )
        cached = identity
        return identity
    }

    /// Extracts `machine_name` and `chip_type` from `system_profiler -json`.
    ///
    /// Intel Macs report `cpu_type` where Apple silicon reports `chip_type`, and
    /// the key names have changed across macOS releases, so several spellings
    /// are accepted and a miss simply yields `nil`.
    static func parseHardwareProfile(_ data: Data) -> (name: String?, chip: String?) {
        guard
            let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
            let items = root["SPHardwareDataType"] as? [[String: Any]],
            let entry = items.first
        else { return (nil, nil) }

        let name = (entry["machine_name"] as? String) ?? (entry["machine_model"] as? String)
        let chip = (entry["chip_type"] as? String) ?? (entry["cpu_type"] as? String)
        return (name, chip)
    }
}
