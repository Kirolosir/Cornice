import Foundation

/// Search known tool locations because apps launched from Finder don't inherit the
/// Terminal's PATH.
public actor ToolLocator {
    /// Searched in order. Homebrew on Apple silicon installs to `/opt/homebrew`,
    /// on Intel to `/usr/local`; MacPorts uses `/opt/local`.
    public static let searchPaths = [
        "/usr/bin",
        "/bin",
        "/usr/sbin",
        "/sbin",
        "/opt/homebrew/bin",
        "/usr/local/bin",
        "/opt/local/bin",
        "/Applications/Docker.app/Contents/Resources/bin",
    ]

    private var cache: [String: String?] = [:]
    private let fileManager: FileManager

    public init(fileManager: FileManager = .default) {
        self.fileManager = fileManager
    }

    /// Cache tool paths and misses. Call forget when a tool is installed and needs another
    /// lookup.
    public func locate(_ tool: String) -> String? {
        if let cached = cache[tool] { return cached }
        let found = Self.searchPaths
            .map { ($0 as NSString).appendingPathComponent(tool) }
            .first { fileManager.isExecutableFile(atPath: $0) }
        cache[tool] = found
        if found == nil {
            Log.process.notice("tool not found: \(tool, privacy: .public)")
        }
        return found
    }

    /// Absolute path, or a `toolUnavailable` error.
    public func require(_ tool: String) throws -> String {
        guard let path = locate(tool) else {
            throw ServiceError.toolUnavailable(tool: tool)
        }
        return path
    }

    /// Drops a cached lookup so the next call re-checks the filesystem.
    public func forget(_ tool: String) {
        cache.removeValue(forKey: tool)
    }
}
