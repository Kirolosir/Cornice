import XCTest
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
        compilerError("tell application \"\(source.scriptingName)\" to return 1") == nil
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
}
