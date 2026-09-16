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

    /// Refresh intervals are clamped so a hand-edited file cannot make the app
    /// poll `lsof` in a tight loop and pin a core.
    func testRefreshIntervalsAreClamped() {
        var preferences = Preferences()
        preferences.telemetryRefreshInterval = 0.001
        preferences.serverRefreshInterval = 0
        preferences.repositoryRefreshInterval = 99_999
        preferences.githubRefreshInterval = 1

        let sanitized = preferences.sanitized()

        XCTAssertEqual(sanitized.telemetryRefreshInterval, 1)
        XCTAssertEqual(sanitized.serverRefreshInterval, 3)
        XCTAssertEqual(sanitized.repositoryRefreshInterval, 600)
        XCTAssertEqual(sanitized.githubRefreshInterval, 60,
                       "a 60s floor keeps even a pathological config inside GitHub's quota")
    }

    func testInvalidPortsAreRemovedAndDeduplicated() {
        var preferences = Preferences()
        preferences.monitoredPorts = [
            .init(port: 3000), .init(port: 3000, label: "dup"),
            .init(port: 0), .init(port: 70_000), .init(port: 8080),
        ]

        let ports = preferences.sanitized().monitoredPorts.map(\.port)

        XCTAssertEqual(ports, [3000, 8080], "order is preserved, first occurrence wins")
    }

    func testMalformedRepositorySlugsAreRemoved() {
        var preferences = Preferences()
        preferences.githubRepositories = ["good/repo", "../../etc/passwd", "nope", "good/repo"]

        XCTAssertEqual(preferences.sanitized().githubRepositories, ["good/repo"])
    }

    /// An active repository that is no longer in the bookmark list would leave
    /// the panel pointing at something the user cannot select or clear.
    func testDanglingActiveRepositoryIsRepaired() {
        var preferences = Preferences()
        preferences.repositoryPaths = ["/one", "/two"]
        preferences.activeRepositoryPath = "/deleted"

        XCTAssertEqual(preferences.sanitized().activeRepositoryPath, "/one")
    }

    func testInvalidCommandsAreDropped() {
        var preferences = Preferences()
        preferences.commands = [
            CommandSpec(name: "Good", mode: .shell, script: "npm test"),
            CommandSpec(name: "", executable: ""),
        ]

        XCTAssertEqual(preferences.sanitized().commands.map(\.name), ["Good"])
    }

    // MARK: - Persistence

    func testRoundTripsThroughDisk() async throws {
        let store = PreferencesStore(fileURL: fileURL)
        var original = Preferences()
        original.githubLogin = "octocat"
        original.monitoredPorts = [.init(port: 4321, label: "api")]
        original.focusDurationMinutes = 45
        original.enabledModules = [.repository, .containers]
        original.editor = .zed

        try await store.save(original)
        let loaded = await PreferencesStore(fileURL: fileURL).load()

        XCTAssertEqual(loaded.githubLogin, "octocat")
        XCTAssertEqual(loaded.monitoredPorts.first?.label, "api")
        XCTAssertEqual(loaded.focusDurationMinutes, 45)
        XCTAssertEqual(loaded.enabledModules, [.repository, .containers])
        XCTAssertEqual(loaded.editor, .zed)
    }

    /// The settings file may hold a GitHub login and local repository paths.
    func testFileIsOwnerReadableOnly() async throws {
        try await PreferencesStore(fileURL: fileURL).save(Preferences())

        let attributes = try FileManager.default.attributesOfItem(atPath: fileURL.path)

        XCTAssertEqual((attributes[.posixPermissions] as? NSNumber)?.intValue, 0o600)
    }

    /// The token belongs in the Keychain and must never be serialised here.
    func testSerialisedFileContainsNoCredential() async throws {
        var preferences = Preferences()
        preferences.githubLogin = "octocat"
        try await PreferencesStore(fileURL: fileURL).save(preferences)

        let contents = try String(contentsOf: fileURL, encoding: .utf8).lowercased()

        XCTAssertFalse(contents.contains("token"))
        XCTAssertFalse(contents.contains("ghp_"))
    }

    /// A truncated file after a bad shutdown must not stop the app launching.
    func testCorruptFileFallsBackToDefaultsAndIsQuarantined() async throws {
        try Data("{ this is not json".utf8).write(to: fileURL)

        let loaded = await PreferencesStore(fileURL: fileURL).load()

        XCTAssertEqual(loaded.focusDurationMinutes, 25, "defaults, not a crash")
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

    /// Additive fields are absorbed by Codable defaults, so an older file
    /// written before a setting existed still loads.
    func testFileMissingNewerKeysStillDecodes() async throws {
        let minimal = Data(#"{"schemaVersion":1,"repositoryPaths":[],"editor":"zed"}"#.utf8)
        try minimal.write(to: fileURL)

        let loaded = await PreferencesStore(fileURL: fileURL).load()

        XCTAssertEqual(loaded.editor, .zed)
        XCTAssertEqual(loaded.focusDurationMinutes, 25, "absent keys take their defaults")
    }
}
