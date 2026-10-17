import XCTest
import AppKit
@testable import CorniceKit

/// Compile every player script. AppleScript try blocks catch runtime errors, not a syntax
/// error that prevents the whole script from compiling.
final class PlayerScriptTests: XCTestCase {

    /// `nil` when the source compiles, otherwise the compiler's complaint.
    @MainActor
    private func compilerError(_ source: String) -> String? {
        guard let script = NSAppleScript(source: source) else {
            return "NSAppleScript could not be constructed"
        }
        var error: NSDictionary?
        if script.compileAndReturnError(&error) { return nil }
        return (error?[NSAppleScript.errorMessage] as? String) ?? "unknown error"
    }

    /// Script compilation needs the player's scripting dictionary. Skip this check when the
    /// player isn't installed.
    @MainActor
    private func terminologyAvailable(for source: MediaSource) -> Bool {
        // AppleScript can compile a generic tell block even when the app is missing.
        guard let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: source.bundleIdentifier),
              FileManager.default.fileExists(atPath: url.path) else { return false }
        return compilerError("tell application \"\(source.scriptingName)\" to return 1") == nil
    }

    @MainActor
    private func assertCompiles(_ script: String, _ label: String, _ source: MediaSource) {
        if let error = compilerError(script) {
            XCTFail("\(source.scriptingName) \(label) does not compile: \(error)")
        }
    }

    @MainActor
    func testPollingScriptsCompile() {
        for source in MediaSource.allCases {
            guard terminologyAvailable(for: source) else { continue }
            let controller = ScriptedMediaController(source: source, runner: AppleScriptRunner())
            assertCompiles(controller.lightScript, "light script", source)
            assertCompiles(controller.readScript, "full read script", source)
        }
    }

    @MainActor
    func testEveryCommandScriptCompiles() {
        let commands: [MediaCommand] = [
            .playPause, .next, .previous, .seek(91.5), .setVolume(0.4),
            .toggleShuffle, .cycleRepeat,
        ]
        for source in MediaSource.allCases {
            guard terminologyAvailable(for: source) else { continue }
            let controller = ScriptedMediaController(source: source, runner: AppleScriptRunner())
            for command in commands {
                guard let script = controller.commandScript(for: command) else { continue }
                assertCompiles(script, "\(command)", source)
            }
        }
    }

    /// Check the script form even when the player is missing and compilation has to be
    /// skipped.
    func testRepeatIsWrittenAsAStatement() {
        for source in MediaSource.allCases {
            let controller = ScriptedMediaController(source: source, runner: AppleScriptRunner())
            XCTAssertFalse(
                controller.lightScript.contains("set rep to (if"),
                "\(source.scriptingName) uses a conditional expression, which will not compile"
            )
        }
    }

    func testReconnectDiscardsAnOldFullMetadataReply() async throws {
        let runner = HeldMetadataRunner()
        let controller = ScriptedMediaController(source: .spotify, runner: runner)
        let oldRead = Task { try await controller.snapshot() }
        await runner.waitForFullRead()
        await controller.resetAuthorization()
        await runner.finishFullRead()

        do {
            _ = try await oldRead.value
            XCTFail("metadata requested before reconnect should be discarded")
        } catch is CancellationError {} catch { XCTFail("unexpected error: \(error)") }
        let current = try await controller.snapshot()
        let fullReads = await runner.fullReads
        XCTAssertEqual(fullReads, 2, "reconnect must fetch metadata again even for the same title and duration")
        XCTAssertEqual(current?.artist, "Current artist")
    }

    func testCancelledMetadataCannotFillTheTrackCache() async throws {
        let runner = HeldMetadataRunner()
        let controller = ScriptedMediaController(source: .spotify, runner: runner)
        let oldRead = Task { try await controller.snapshot() }
        await runner.waitForFullRead()
        oldRead.cancel()
        await runner.finishFullRead()

        do {
            _ = try await oldRead.value
            XCTFail("a cancelled metadata reply should be discarded")
        } catch is CancellationError {} catch { XCTFail("unexpected error: \(error)") }
        let current = try await controller.snapshot()
        let fullReads = await runner.fullReads
        XCTAssertEqual(fullReads, 2)
        XCTAssertEqual(current?.artist, "Current artist")
    }
}

private actor HeldMetadataRunner: PlayerScriptRunning {
    private(set) var fullReads = 0
    private var pendingFullRead: CheckedContinuation<Void, Never>?
    private var fullReadStarted: CheckedContinuation<Void, Never>?

    func applicationIsRunning(bundleIdentifier: String) async -> Bool { true }
    func clearDenial(_ target: String) async {}
    func run(_ source: String, target: String) async throws -> AppleScriptRunner.ScriptResult {
        let fields: [String]
        if source.contains("set trackArtist") {
            fullReads += 1
            let read = fullReads
            if read == 1 {
                await withCheckedContinuation { continuation in
                    pendingFullRead = continuation
                    fullReadStarted?.resume()
                    fullReadStarted = nil
                }
            }
            fields = ["playing", "Same title", read == 1 ? "Old artist" : "Current artist", "Album",
                      "180000", "20", "", "false", "off", "50"]
        } else {
            fields = ["playing", "Same title", "180000", "20", "50", "false", "off"]
        }
        return AppleScriptRunner.ScriptResult(string: fields.joined(separator: "\u{1f}"), data: nil)
    }
    func waitForFullRead() async {
        if pendingFullRead != nil { return }
        await withCheckedContinuation { fullReadStarted = $0 }
    }
    func finishFullRead() { pendingFullRead?.resume(); pendingFullRead = nil }
}
