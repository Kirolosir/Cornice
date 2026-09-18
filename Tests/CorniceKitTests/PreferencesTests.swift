import XCTest
@testable import CorniceKit

final class PreferencesTests: XCTestCase {

    private var directory: URL!

    override func setUpWithError() throws {
        directory = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("cornice-tests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: directory)
    }

    private var fileURL: URL { directory.appendingPathComponent("preferences.json") }

    // MARK: - Sanitising

    /// Intervals are clamped so a hand-edited file cannot make the app poll a
    /// music player a hundred times a second.
    func testIntervalsAreClamped() {
        var preferences = Preferences()
        preferences.mediaRefreshInterval = 0.001
        preferences.telemetryRefreshInterval = 0
        preferences.hoverDwell = -3

        let sanitized = preferences.sanitized()

        XCTAssertEqual(sanitized.mediaRefreshInterval, 0.25,
                       "each poll is an Apple event to another process")
        XCTAssertEqual(sanitized.telemetryRefreshInterval, 1)
        XCTAssertEqual(sanitized.hoverDwell, 0)
    }

    func testTimerPresetsAreCleanedUp() {
        var preferences = Preferences()
        preferences.timerPresetsMinutes = [25, 25, 0, 9999, 5]

        XCTAssertEqual(preferences.sanitized().timerPresetsMinutes, [5, 25])
    }

    func testEmptyPresetsFallBackToDefaults() {
        var preferences = Preferences()
        preferences.timerPresetsMinutes = []

        XCTAssertFalse(preferences.sanitized().timerPresetsMinutes.isEmpty)
    }

    /// Media is the point of the app; switching it off would leave an empty
    /// surface with no way back.
    func testMediaModuleCannotBeDisabled() {
        var preferences = Preferences()
        preferences.enabledModules = []

        XCTAssertTrue(preferences.sanitized().enabledModules.contains(.media))
    }

    // MARK: - Persistence

    func testRoundTripsThroughDisk() async throws {
        let store = PreferencesStore(fileURL: fileURL)
        var original = Preferences()
        original.idleDisplay = .artworkAndTitle
        original.audioVisualizerEnabled = true
        original.enabledModules = [.media, .stats]
        original.hoverDwell = 0.2

        try await store.save(original)
        let loaded = await PreferencesStore(fileURL: fileURL).load()

        XCTAssertEqual(loaded.idleDisplay, .artworkAndTitle)
        XCTAssertTrue(loaded.audioVisualizerEnabled)
        XCTAssertEqual(loaded.enabledModules, [.media, .stats])
        XCTAssertEqual(loaded.hoverDwell, 0.2, accuracy: 0.001)
    }

    /// The settings file may hold a GitHub login and local repository paths.
    func testFileIsOwnerReadableOnly() async throws {
        try await PreferencesStore(fileURL: fileURL).save(Preferences())

        let attributes = try FileManager.default.attributesOfItem(atPath: fileURL.path)

        XCTAssertEqual((attributes[.posixPermissions] as? NSNumber)?.intValue, 0o600)
    }

    /// A truncated file after a bad shutdown must not stop the app launching.
    func testCorruptFileFallsBackToDefaultsAndIsQuarantined() async throws {
        try Data("{ this is not json".utf8).write(to: fileURL)

        let loaded = await PreferencesStore(fileURL: fileURL).load()

        // Compared against the defaults themselves rather than against a
        // literal, so changing a default is not also a test failure.
        XCTAssertEqual(loaded.idleDisplay, Preferences().idleDisplay, "defaults, not a crash")
        let siblings = try FileManager.default.contentsOfDirectory(atPath: directory.path)
        XCTAssertTrue(
            siblings.contains { $0.hasPrefix("preferences-corrupt-") },
            "the bad file is preserved for diagnosis rather than silently overwritten"
        )
    }

    func testMissingFileIsNotAnError() async {
        let loaded = await PreferencesStore(fileURL: directory.appendingPathComponent("absent.json")).load()

        XCTAssertEqual(loaded, Preferences().sanitized())
    }

    /// Settings views emit a change per keystroke; without this, dragging a
    /// slider would rewrite the file on every frame.
    func testRedundantSavesAreSkipped() async throws {
        let store = PreferencesStore(fileURL: fileURL)
        let preferences = Preferences()

        try await store.save(preferences)
        let firstModified = try FileManager.default
            .attributesOfItem(atPath: fileURL.path)[.modificationDate] as? Date

        try await Task.sleep(for: .milliseconds(50))
        try await store.save(preferences)
        let secondModified = try FileManager.default
            .attributesOfItem(atPath: fileURL.path)[.modificationDate] as? Date

        XCTAssertEqual(firstModified, secondModified, "identical content must not rewrite the file")
    }

    func testMigrationStampsCurrentSchemaVersion() {
        var old = Preferences()
        old.schemaVersion = 0

        XCTAssertEqual(PreferencesStore.migrate(old).schemaVersion, Preferences.currentSchemaVersion)
    }

    /// Additive schema: a file written before a setting existed must still
    /// load, or upgrading would silently reset everyone's configuration.
    func testFileMissingNewerKeysStillDecodes() async throws {
        try Data(#"{"schemaVersion":2,"hoverDwell":0.3}"#.utf8).write(to: fileURL)

        let loaded = await PreferencesStore(fileURL: fileURL).load()

        XCTAssertEqual(loaded.hoverDwell, 0.3, accuracy: 0.001)
        XCTAssertEqual(loaded.mediaRefreshInterval, 1.0, "absent keys take their defaults")
    }

    /// One wrong-typed field must not lose every other setting.
    func testWrongTypedFieldDoesNotPoisonTheRest() async throws {
        try Data(#"{"hoverDwell":"nope","tintFromArtwork":false}"#.utf8).write(to: fileURL)

        let loaded = await PreferencesStore(fileURL: fileURL).load()

        XCTAssertEqual(loaded.hoverDwell, 0.05, "bad field falls back to its default")
        XCTAssertFalse(loaded.tintFromArtwork, "good fields survive")
    }
}

/// Schema migrations.
final class PreferencesMigrationTests: XCTestCase {

    /// Someone sitting on the old tint ceiling had asked for as much colour as
    /// the app would give and been refused, so raising the ceiling should carry
    /// them up with it.
    func testATintSettingOnTheOldCeilingRisesWithIt() {
        var stored = Preferences()
        stored.schemaVersion = 2
        stored.tintStrength = Preferences.previousMaximumTintStrength

        let migrated = PreferencesStore.migrate(stored)

        XCTAssertEqual(migrated.tintStrength, Preferences().tintStrength)
        XCTAssertEqual(migrated.schemaVersion, Preferences.currentSchemaVersion)
    }

    /// A value chosen below the ceiling was chosen deliberately.
    func testADeliberateTintSettingIsLeftAlone() {
        var stored = Preferences()
        stored.schemaVersion = 2
        stored.tintStrength = 0.5

        XCTAssertEqual(PreferencesStore.migrate(stored).tintStrength, 0.5)
    }

    func testMigrationIsIdempotent() {
        var stored = Preferences()
        stored.schemaVersion = 2
        stored.tintStrength = Preferences.previousMaximumTintStrength

        let once = PreferencesStore.migrate(stored)
        XCTAssertEqual(PreferencesStore.migrate(once), once)
    }

    func testTintIsClampedToTheCeiling() {
        var wild = Preferences()
        wild.tintStrength = 99
        XCTAssertEqual(wild.sanitized().tintStrength, Preferences.maximumTintStrength)
    }
}
