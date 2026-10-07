import Foundation

/// Loads and saves `Preferences`. Injected so tests can run against a temp
/// directory (or memory) instead of the real Application Support folder.
public protocol PreferencesPersisting: Sendable {
    func load() async -> Preferences
    func save(_ preferences: Preferences) async throws
}

/// Save settings as JSON with atomic writes. The file is easy to inspect when debugging a
/// settings problem.
public actor PreferencesStore: PreferencesPersisting {

    private let fileURL: URL
    private let fileManager: FileManager
    /// Skip repeated saves with the same settings. Sliders and text fields can call this
    /// often.
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

    /// Use defaults if loading fails. Move a corrupt file aside so it can be inspected
    /// instead of overwritten.
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

    /// Write a temporary file and replace the old one atomically. Skip the write if nothing
    /// changed.
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

        // Keep the settings file owner-only. Tokens are stored separately in the Keychain.
        try? fileManager.setAttributes([.posixPermissions: 0o600], ofItemAtPath: fileURL.path)

        lastWritten = sanitized
        Log.settings.debug("preferences saved (\(data.count) bytes)")
    }

    /// Migrate settings whose meaning changed. New fields with defaults don't need a
    /// special migration.
    static func migrate(_ preferences: Preferences) -> Preferences {
        var result = preferences
        guard result.schemaVersion < Preferences.currentSchemaVersion else { return result }
        // Version 2 removed the old developer modules. Unknown keys and module names are
        // ignored by the decoder.

        // Version 3 increased the tint limit. Move settings at the old maximum to the new
        // default; keep values the user set below it.
        if result.schemaVersion < 3,
           result.tintStrength >= Preferences.previousMaximumTintStrength {
            result.tintStrength = Preferences().tintStrength
        }

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
    /// Reuse a formatter for corrupt-file timestamps. Configure it once and don't change it
    /// afterwards.
    nonisolated(unsafe) static let cornice: ISO8601DateFormatter = {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime]
        return formatter
    }()
}
