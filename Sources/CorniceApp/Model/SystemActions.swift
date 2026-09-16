import AppKit
import CorniceKit

/// Launching other applications on the user's behalf.
///
/// Everything here goes through `NSWorkspace` with a file URL or a bundle
/// identifier. Nothing shells out, so a repository living in a directory whose
/// name contains quotes, spaces, or semicolons is handled by the OS rather than
/// by string-escaping that eventually gets one case wrong.
enum SystemActions {

    static func revealInFinder(path: String) {
        NSWorkspace.shared.activateFileViewerSelecting([URL(fileURLWithPath: path)])
    }

    /// Opens the folder in the user's terminal.
    ///
    /// Resolved by asking Launch Services which application handles a directory
    /// among the known terminals, rather than hardcoding Terminal.app —
    /// a developer who uses iTerm or Ghostty should get theirs.
    static func openInTerminal(path: String) {
        let url = URL(fileURLWithPath: path)
        let candidates = [
            "com.googlecode.iterm2",
            "com.mitchellh.ghostty",
            "dev.warp.Warp-Stable",
            "net.kovidgoyal.kitty",
            "com.github.wez.wezterm",
            "com.apple.Terminal",
        ]
        for identifier in candidates {
            guard let application = NSWorkspace.shared
                .urlForApplication(withBundleIdentifier: identifier) else { continue }
            let configuration = NSWorkspace.OpenConfiguration()
            configuration.activates = true
            NSWorkspace.shared.open([url], withApplicationAt: application, configuration: configuration)
            return
        }
        // Every Mac has Terminal.app, so this is close to unreachable — but
        // failing silently would be worse than opening Finder.
        revealInFinder(path: path)
    }

    /// Opens a path in the configured editor.
    ///
    /// Launching by bundle identifier rather than by a command-line shim
    /// (`code`, `zed`, `subl`) because the shim is frequently not installed
    /// even when the editor is, and a missing shim produces a confusing
    /// "command not found" rather than a clear "that editor isn't installed".
    static func open(
        path: String,
        in editor: EditorTarget,
        onFailure: @escaping (String) -> Void
    ) {
        let url = URL(fileURLWithPath: path)

        guard let identifier = editor.bundleIdentifier else {
            NSWorkspace.shared.open(url)
            return
        }
        guard let application = NSWorkspace.shared
            .urlForApplication(withBundleIdentifier: identifier) else {
            onFailure("\(editor.title) does not appear to be installed. Choose a different editor in Settings.")
            return
        }

        let configuration = NSWorkspace.OpenConfiguration()
        configuration.activates = true
        NSWorkspace.shared.open([url], withApplicationAt: application, configuration: configuration) { _, error in
            guard let error else { return }
            Task { @MainActor in
                onFailure("\(editor.title) could not open the folder: \(error.localizedDescription)")
            }
        }
    }

    /// Which of the known editors are actually installed, for the settings picker.
    static func installedEditors() -> [EditorTarget] {
        EditorTarget.allCases.filter { editor in
            guard let identifier = editor.bundleIdentifier else { return true }
            return NSWorkspace.shared.urlForApplication(withBundleIdentifier: identifier) != nil
        }
    }
}
