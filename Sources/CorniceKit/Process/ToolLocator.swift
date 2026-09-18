import Foundation

/// Finds command-line tools by absolute path.
///
/// A GUI app launched from Finder or as a login item inherits a bare
/// environment (typically `PATH=/usr/bin:/bin:/usr/sbin:/sbin`) not the PATH
/// from the user's shell profile. Tools installed by Homebrew therefore appear
/// to be missing even though they work perfectly in Terminal, which is a
/// classic and very confusing bug class for Mac developer tools. We search the
/// known install locations explicitly instead of trusting the inherited PATH.
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

    /// Absolute path for a tool name, or `nil` if it is not installed.
    ///
    /// Results are cached, including misses. A tool that was absent at launch
    /// is very unlikely to appear mid-session, and re-statting eight
    /// directories on every refresh tick is exactly the kind of idle cost this
    /// app is supposed to avoid. `forget(_:)` clears an entry when the user
    /// installs something and asks for a retry.
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
