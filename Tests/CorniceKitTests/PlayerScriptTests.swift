import XCTest
@testable import CorniceKit

/// Compiles every script the app sends to a player.
///
/// Reply parsing is tested elsewhere, but a parser can only be reached by a
/// script that compiled. AppleScript is compiled as a whole, so one bad line
/// fails the entire script, and a surrounding `try` does not contain a compile
/// error, it only catches runtime ones. A single malformed expression therefore
/// takes out the whole poll and the app shows nothing at all, which is exactly
/// what `set rep to (if repeating then "all" else "off")` did.
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

    /// Whether this machine can resolve the player's scripting terminology.
    ///
    /// Compiling `tell application "Spotify"` needs Spotify's dictionary, so on
    /// a machine without it these tests would fail for a reason that has nothing
    /// to do with the scripts. The probe separates "not installed" from "wrong".
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

    /// AppleScript has no conditional *expression*. Asserted directly as well as
    /// through the compiler, because the compiler check is skipped on a machine
    /// without the player installed, including CI.
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
