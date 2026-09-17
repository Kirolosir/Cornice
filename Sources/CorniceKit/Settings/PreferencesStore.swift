import Foundation

/// Loads and saves `Preferences`. Injected so tests can run against a temp
/// directory (or memory) instead of the real Application Support folder.
public protocol PreferencesPersisting: Sendable {
    func load() async -> Preferences
    func save(_ preferences: Preferences) async throws
}

/// JSON-file-backed preferences with atomic writes and corruption recovery.
///
/// A file rather than `UserDefaults` because the settings form one coherent
/// document that should be written all-or-nothing: a crash midway through
/// saving must not leave the app with new ports and an old repository list.
/// It is also inspectable and diffable, which matters when someone reports a
/// bug that depends on their configuration.
public actor PreferencesStore: PreferencesPersisting {

    private let fileURL: URL
    private let fileManager: FileManager
    /// The last value written, so a redundant save can be skipped. Settings
    /// views emit a change per keystroke; without this, dragging a slider would
    /// write the file a hundred times.
    private var lastWritten: Preferences?

    /// Standard location: `~/Library/Application Support/Cornice/preferences.json`.
    public static func defaultURL(fileManager: FileManager = .default) -> URL {
        let base = fileManager.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? fileManager.homeDirectoryForCurrentUser.appendingPathComponent("Library/Application Support")
        return base
            .appendingPathComponent("Cornice", isDirectory: true)
            .appendingPathComponent("preferences.json")
    }

    public init(fileURL: URL? = nil, fileManager: FileManager = .default) {
        self.fileURL = fileURL ?? Self.defaultURL(fileManager: fileManager)
        self.fileManager = fileManager
    }

    /// Reads preferences, falling back to defaults on any failure.
    ///
    /// Never throws. A user whose settings file was truncated by a bad shutdown
    /// should get a working app with default settings, not a launch failure —
    /// so a corrupt file is moved aside (preserved for debugging, and so the
    /// next save does not immediately overwrite the evidence) and defaults are
    /// returned.
    public func load() async -> Preferences {
        guard fileManager.fileExists(atPath: fileURL.path) else {
            Log.settings.info("no preferences file; starting from defaults")
            return Preferences()
        }
        do {
            let data = try Data(contentsOf: fileURL)
            let decoded = try JSONDecoder().decode(Preferences.self, from: data)
            let migrated = Self.migrate(decoded)
            lastWritten = migrated
            return migrated.sanitized()
        } catch {
            Log.settings.error(
                "preferences unreadable (\(error.localizedDescription, privacy: .public)); quarantining and using defaults"
            )
            quarantineCorruptFile()
            return Preferences()
        }
    }

    /// Writes preferences atomically.
    ///
    /// `.atomic` writes to a temporary file and renames it into place, so a
    /// reader either sees the whole old file or the whole new one. Combined
    /// with the `lastWritten` check this makes saving cheap enough to call on
    /// every change without debouncing at the call site.
    public func save(_ preferences: Preferences) async throws {
        let sanitized = preferences.sanitized()
        guard sanitized != lastWritten else { return }

        try fileManager.createDirectory(
            at: fileURL.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        let data = try encoder.encode(sanitized)
        try data.write(to: fileURL, options: [.atomic])

        // Settings can include a GitHub login and repository paths, so the file
        // is owner-only. The token is in the Keychain, never here, but the rest
        // is still nobody else's business.
        try? fileManager.setAttributes([.posixPermissions: 0o600], ofItemAtPath: fileURL.path)

        lastWritten = sanitized
        Log.settings.debug("preferences saved (\(data.count) bytes)")
    }

    /// Applies any schema migrations needed to bring an older file up to date.
    ///
    /// Additive changes are handled by giving every `Preferences` property a
    /// default in its initialiser, so most releases need nothing here. This
    /// exists for the changes `Codable` cannot absorb — a renamed key, or a
    /// value whose meaning changed.
    static func migrate(_ preferences: Preferences) -> Preferences {
        var result = preferences
        guard result.schemaVersion < Preferences.currentSchemaVersion else { return result }
        // Version 2 dropped the repository, servers, GitHub, container and
        // command modules when the app became media-first. Their keys simply
        // stop being decoded, and `enabledModules` values that no longer exist
        // are discarded by the tolerant decoder — so nothing needs doing here
        // beyond stamping the version. Future steps go here as
        // `if result.schemaVersion < N { ... }` in ascending order.
        result.schemaVersion = Preferences.currentSchemaVersion
        return result
    }

    private func quarantineCorruptFile() {
        let stamp = ISO8601DateFormatter.cornice.string(from: .now)
            .replacingOccurrences(of: ":", with: "-")
        let target = fileURL.deletingLastPathComponent()
            .appendingPathComponent("preferences-corrupt-\(stamp).json")
        try? fileManager.moveItem(at: fileURL, to: target)
    }
}

/// In-memory preferences for tests and previews.
public actor EphemeralPreferencesStore: PreferencesPersisting {
    private var stored: Preferences
    public private(set) var saveCount = 0

    public init(_ initial: Preferences = Preferences()) {
        stored = initial
    }

    public func load() async -> Preferences { stored.sanitized() }

    public func save(_ preferences: Preferences) async throws {
        stored = preferences.sanitized()
        saveCount += 1
    }
}


extension ISO8601DateFormatter {
    /// Shared formatter for timestamping quarantined files.
    ///
    /// `nonisolated(unsafe)` rather than a new instance per call:
    /// `ISO8601DateFormatter` is expensive to construct, and this one is
    /// configured once and only ever read afterwards.
    nonisolated(unsafe) static let cornice: ISO8601DateFormatter = {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime]
        return formatter
    }()
}
