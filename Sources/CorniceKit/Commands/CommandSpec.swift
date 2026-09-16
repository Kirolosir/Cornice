import Foundation

/// A command the user has configured and can run from the panel.
///
/// The security posture here is deliberate and narrow: **commands come only
/// from the user, typed into the settings window.** Nothing in the app
/// constructs, suggests, imports, or downloads one. There is no command
/// registry, no shared-config fetch, no "run this from a repository file"
/// feature — because each of those turns a convenience into a way for a
/// repository you cloned to execute code on your machine.
public struct CommandSpec: Codable, Equatable, Sendable, Identifiable {

    /// How the command is executed.
    public enum Mode: String, Codable, Sendable, CaseIterable {
        /// `execve` with an explicit argument array. No shell, so no word
        /// splitting, globbing, or metacharacter interpretation.
        case direct
        /// `/bin/sh -c "<script>"`. Necessary for pipelines and `&&`, and
        /// therefore the mode where a mistake actually costs something — so it
        /// is opt-in per command and the exact script is shown before it runs.
        case shell
    }

    public var id: UUID
    public var name: String
    public var mode: Mode
    /// For `.direct`: the executable name or absolute path. For `.shell`: unused.
    public var executable: String
    /// For `.direct`: arguments, already split. For `.shell`: unused.
    public var arguments: [String]
    /// For `.shell`: the script text, exactly as the user typed it.
    public var script: String
    /// Where to run. `nil` means the active repository, which is what makes a
    /// single "run tests" command useful across projects.
    public var workingDirectory: String?
    /// Ask before running. Defaults to true for shell commands.
    public var requiresConfirmation: Bool
    /// Wall-clock budget in seconds.
    public var timeout: Double

    public init(
        id: UUID = UUID(),
        name: String,
        mode: Mode = .direct,
        executable: String = "",
        arguments: [String] = [],
        script: String = "",
        workingDirectory: String? = nil,
        requiresConfirmation: Bool = true,
        timeout: Double = 300
    ) {
        self.id = id
        self.name = name
        self.mode = mode
        self.executable = executable
        self.arguments = arguments
        self.script = script
        self.workingDirectory = workingDirectory
        self.requiresConfirmation = requiresConfirmation
        self.timeout = timeout
    }

    /// Exactly what will run, for the confirmation sheet and the settings row.
    ///
    /// The user must be able to read this and recognise it. It is rendered
    /// verbatim in a monospaced font — never summarised, never truncated in the
    /// confirmation dialog — because "are you sure?" is worthless if it does
    /// not say what you are agreeing to.
    public var displayCommand: String {
        switch mode {
        case .direct:
            ([executable] + arguments).joined(separator: " ")
        case .shell:
            script
        }
    }

    /// Validates the spec, returning a reason it is unusable or `nil` if fine.
    ///
    /// Called on save *and* again immediately before execution. Validating
    /// twice is cheap and means a preferences file edited by hand between those
    /// two moments cannot slip something past the settings UI.
    public func validate() -> String? {
        let trimmedName = name.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmedName.isEmpty { return "Give the command a name." }
        if trimmedName.count > 60 { return "Name is too long." }

        // A NUL byte truncates a C string, so a value containing one would run
        // as something shorter than what the confirmation dialog displayed.
        // That breaks the guarantee that the user saw what they approved.
        let fields = [name, executable, script, workingDirectory ?? ""] + arguments
        if fields.contains(where: { $0.contains("\0") }) {
            return "Command contains a null byte."
        }

        switch mode {
        case .direct:
            let trimmedExecutable = executable.trimmingCharacters(in: .whitespacesAndNewlines)
            if trimmedExecutable.isEmpty { return "Choose a program to run." }
            // Reject a bare name with shell metacharacters: someone typing
            // `npm test && echo done` into the direct-mode field expects it to
            // work, and it silently would not. Better to say so than to pass
            // `&&` to execve as an argument.
            if trimmedExecutable.contains(where: { "|&;<>()$`\\\"'\n".contains($0) }) {
                return "Direct commands cannot contain shell syntax. Switch to shell mode."
            }
            if trimmedExecutable.hasPrefix("/"),
               !FileManager.default.isExecutableFile(atPath: trimmedExecutable) {
                return "No executable at that path."
            }
        case .shell:
            if script.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                return "Enter a script to run."
            }
            if script.count > 2000 { return "Script is too long." }
        }

        if let directory = workingDirectory, !directory.isEmpty {
            if !directory.hasPrefix("/") { return "Working directory must be an absolute path." }
            var isDirectory: ObjCBool = false
            let exists = FileManager.default.fileExists(atPath: directory, isDirectory: &isDirectory)
            if !exists || !isDirectory.boolValue { return "Working directory does not exist." }
        }

        if !(1...3600).contains(timeout) { return "Timeout must be between 1s and 1h." }
        return nil
    }

    public var isValid: Bool { validate() == nil }
}
