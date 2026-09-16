import Foundation

/// Which panels are available. Users can switch modules off entirely, which
/// also stops their refresh loops — a disabled module costs nothing.
public enum ModuleKind: String, Codable, Sendable, CaseIterable, Identifiable {
    case repository
    case servers
    case github
    case telemetry
    case containers
    case commands
    case focus

    public var id: String { rawValue }

    public var title: String {
        switch self {
        case .repository: "Repository"
        case .servers: "Servers"
        case .github: "GitHub"
        case .telemetry: "System"
        case .containers: "Containers"
        case .commands: "Commands"
        case .focus: "Focus"
        }
    }

    /// SF Symbol for the tab strip.
    public var symbol: String {
        switch self {
        case .repository: "arrow.triangle.branch"
        case .servers: "server.rack"
        case .github: "checkmark.seal"
        case .telemetry: "waveform.path.ecg"
        case .containers: "shippingbox"
        case .commands: "terminal"
        case .focus: "timer"
        }
    }
}

/// Which app a repository opens in.
public enum EditorTarget: String, Codable, Sendable, CaseIterable, Identifiable {
    case vscode
    case cursor
    case xcode
    case zed
    case sublime
    case systemDefault

    public var id: String { rawValue }

    public var title: String {
        switch self {
        case .vscode: "Visual Studio Code"
        case .cursor: "Cursor"
        case .xcode: "Xcode"
        case .zed: "Zed"
        case .sublime: "Sublime Text"
        case .systemDefault: "System default"
        }
    }

    /// Bundle identifier used to launch it, or `nil` for "whatever Finder would do".
    ///
    /// Launching by bundle identifier rather than by a CLI shim (`code`, `zed`)
    /// means it works when the shim was never installed, which is the usual
    /// state on a fresh machine.
    public var bundleIdentifier: String? {
        switch self {
        case .vscode: "com.microsoft.VSCode"
        case .cursor: "com.todesktop.230313mzl4w4u92"
        case .xcode: "com.apple.dt.Xcode"
        case .zed: "dev.zed.Zed"
        case .sublime: "com.sublimetext.4"
        case .systemDefault: nil
        }
    }
}

/// How the collapsed surface reacts to the pointer.
public enum ActivationStyle: String, Codable, Sendable, CaseIterable, Identifiable {
    /// Expand on hover after a short dwell.
    case hover
    /// Expand only on click, so the surface never opens by accident.
    case click
    public var id: String { rawValue }

    public var title: String {
        switch self {
        case .hover: "Hover"
        case .click: "Click only"
        }
    }
}

/// Everything the user can configure, in one `Codable` value.
///
/// A single struct rather than scattered `UserDefaults` keys: it gives one
/// atomic write, one schema version to migrate, and — most usefully — makes the
/// whole settings surface trivially testable, because a test can construct a
/// `Preferences` directly instead of standing up a defaults suite.
public struct Preferences: Codable, Equatable, Sendable {
    /// Bumped when a change cannot be handled by `Codable`'s defaulting alone.
    public static let currentSchemaVersion = 1
    public var schemaVersion: Int

    // Repository
    /// Bookmarked repository paths, most recently used first.
    public var repositoryPaths: [String]
    public var activeRepositoryPath: String?
    public var editor: EditorTarget

    // Servers
    public var monitoredPorts: [MonitoredPort]

    // GitHub
    /// Watched `owner/repo` slugs. Empty means "just show my pull requests".
    public var githubRepositories: [String]
    /// GitHub login, cached so the UI can show who is connected without
    /// touching the Keychain on every launch. The token itself is never here.
    public var githubLogin: String?

    // Modules and presentation
    public var enabledModules: Set<ModuleKind>
    public var activationStyle: ActivationStyle
    /// Dwell before a hover expands, in seconds. Guards against the surface
    /// opening as the pointer crosses the menu bar on its way somewhere else.
    public var hoverDwell: Double
    /// Show the collapsed surface only when something needs attention.
    public var collapseWhenIdle: Bool
    public var launchAtLogin: Bool
    public var notifyOnFailedChecks: Bool
    public var notifyOnFocusComplete: Bool

    // Refresh cadence, in seconds.
    public var repositoryRefreshInterval: Double
    public var serverRefreshInterval: Double
    public var githubRefreshInterval: Double
    public var telemetryRefreshInterval: Double

    // Focus timer
    public var focusDurationMinutes: Int

    // Commands
    public var commands: [CommandSpec]

    public init(
        schemaVersion: Int = Preferences.currentSchemaVersion,
        repositoryPaths: [String] = [],
        activeRepositoryPath: String? = nil,
        editor: EditorTarget = .vscode,
        monitoredPorts: [MonitoredPort] = MonitoredPort.defaults,
        githubRepositories: [String] = [],
        githubLogin: String? = nil,
        enabledModules: Set<ModuleKind> = [.repository, .servers, .github, .telemetry, .focus],
        activationStyle: ActivationStyle = .hover,
        hoverDwell: Double = 0.18,
        collapseWhenIdle: Bool = false,
        launchAtLogin: Bool = false,
        notifyOnFailedChecks: Bool = true,
        notifyOnFocusComplete: Bool = true,
        repositoryRefreshInterval: Double = 15,
        serverRefreshInterval: Double = 8,
        githubRefreshInterval: Double = 180,
        telemetryRefreshInterval: Double = 2,
        focusDurationMinutes: Int = 25,
        commands: [CommandSpec] = []
    ) {
        self.schemaVersion = schemaVersion
        self.repositoryPaths = repositoryPaths
        self.activeRepositoryPath = activeRepositoryPath
        self.editor = editor
        self.monitoredPorts = monitoredPorts
        self.githubRepositories = githubRepositories
        self.githubLogin = githubLogin
        self.enabledModules = enabledModules
        self.activationStyle = activationStyle
        self.hoverDwell = hoverDwell
        self.collapseWhenIdle = collapseWhenIdle
        self.launchAtLogin = launchAtLogin
        self.notifyOnFailedChecks = notifyOnFailedChecks
        self.notifyOnFocusComplete = notifyOnFocusComplete
        self.repositoryRefreshInterval = repositoryRefreshInterval
        self.serverRefreshInterval = serverRefreshInterval
        self.githubRefreshInterval = githubRefreshInterval
        self.telemetryRefreshInterval = telemetryRefreshInterval
        self.focusDurationMinutes = focusDurationMinutes
        self.commands = commands
    }

    // MARK: - Tolerant decoding

    /// Decodes every field with a fallback to its default.
    ///
    /// The synthesised `init(from:)` requires *every* key to be present, which
    /// means adding one setting in a new release makes every existing user's
    /// file fail to decode — and since a decode failure falls back to defaults,
    /// upgrading would silently reset everyone's configuration. Decoding each
    /// key independently makes schema changes additive: an old file loads, the
    /// new setting takes its default, and nothing else is lost.
    ///
    /// It also means a partially-corrupted file degrades one field at a time
    /// rather than all at once.
    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let defaults = Preferences()

        func value<T: Decodable>(_ key: CodingKeys, _ fallback: T) -> T {
            (try? container.decodeIfPresent(T.self, forKey: key)) .flatMap { $0 } ?? fallback
        }

        schemaVersion = value(.schemaVersion, defaults.schemaVersion)
        repositoryPaths = value(.repositoryPaths, defaults.repositoryPaths)
        activeRepositoryPath = value(.activeRepositoryPath, defaults.activeRepositoryPath)
        editor = value(.editor, defaults.editor)
        monitoredPorts = value(.monitoredPorts, defaults.monitoredPorts)
        githubRepositories = value(.githubRepositories, defaults.githubRepositories)
        githubLogin = value(.githubLogin, defaults.githubLogin)
        enabledModules = value(.enabledModules, defaults.enabledModules)
        activationStyle = value(.activationStyle, defaults.activationStyle)
        hoverDwell = value(.hoverDwell, defaults.hoverDwell)
        collapseWhenIdle = value(.collapseWhenIdle, defaults.collapseWhenIdle)
        launchAtLogin = value(.launchAtLogin, defaults.launchAtLogin)
        notifyOnFailedChecks = value(.notifyOnFailedChecks, defaults.notifyOnFailedChecks)
        notifyOnFocusComplete = value(.notifyOnFocusComplete, defaults.notifyOnFocusComplete)
        repositoryRefreshInterval = value(.repositoryRefreshInterval, defaults.repositoryRefreshInterval)
        serverRefreshInterval = value(.serverRefreshInterval, defaults.serverRefreshInterval)
        githubRefreshInterval = value(.githubRefreshInterval, defaults.githubRefreshInterval)
        telemetryRefreshInterval = value(.telemetryRefreshInterval, defaults.telemetryRefreshInterval)
        focusDurationMinutes = value(.focusDurationMinutes, defaults.focusDurationMinutes)
        commands = value(.commands, defaults.commands)
    }

    /// Clamps every value into a range the app can actually run with.
    ///
    /// Applied after decoding, so a hand-edited or partially-corrupted file
    /// cannot put the app into a state where it, say, polls `lsof` every 10ms
    /// and burns a core. Out-of-range values are corrected rather than
    /// rejected — losing the user's other settings over one bad number would be
    /// a worse outcome.
    public func sanitized() -> Preferences {
        var copy = self
        copy.hoverDwell = hoverDwell.clamped(to: 0...1.5)
        copy.repositoryRefreshInterval = repositoryRefreshInterval.clamped(to: 5...600)
        copy.serverRefreshInterval = serverRefreshInterval.clamped(to: 3...300)
        // GitHub's authenticated quota is 5,000 requests/hour. A 60-second
        // floor keeps a pathological config well inside it even with several
        // watched repositories.
        copy.githubRefreshInterval = githubRefreshInterval.clamped(to: 60...3600)
        copy.telemetryRefreshInterval = telemetryRefreshInterval.clamped(to: 1...60)
        copy.focusDurationMinutes = focusDurationMinutes.clamped(to: 1...240)
        copy.monitoredPorts = monitoredPorts
            .filter { (1...65_535).contains($0.port) }
            .reduplicated(by: \.port)
        copy.repositoryPaths = repositoryPaths.reduplicated(by: \.self)
        copy.githubRepositories = githubRepositories
            .filter(GitHubSlug.isValid)
            .reduplicated(by: \.self)
        copy.commands = commands.filter { $0.validate() == nil }
        // An active repository that is no longer bookmarked would leave the
        // panel pointing at nothing selectable.
        if let active = activeRepositoryPath, !copy.repositoryPaths.contains(active) {
            copy.activeRepositoryPath = copy.repositoryPaths.first
        }
        return copy
    }
}

extension Comparable {
    func clamped(to range: ClosedRange<Self>) -> Self {
        min(max(self, range.lowerBound), range.upperBound)
    }
}

extension Array {
    /// Removes duplicates by a key, keeping first occurrence and order.
    func reduplicated<Key: Hashable>(by key: (Element) -> Key) -> [Element] {
        var seen = Set<Key>()
        return filter { seen.insert(key($0)).inserted }
    }
}
