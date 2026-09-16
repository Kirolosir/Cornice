import Foundation

/// The outcome of one run of a user command.
public struct CommandRun: Equatable, Sendable, Identifiable {
    public enum State: Equatable, Sendable {
        case running
        case succeeded
        case failed(exitCode: Int32)
        case errored(ServiceError)

        public var isTerminal: Bool {
            if case .running = self { return false }
            return true
        }

        public var isSuccess: Bool { self == .succeeded }
    }

    public let id: UUID
    public let specID: UUID
    public let name: String
    public let displayCommand: String
    public var state: State
    public var startedAt: Date
    public var finishedAt: Date?
    /// Tail of combined output. Capped, because this is a status strip, not a
    /// terminal emulator — the full output belongs in the user's own terminal.
    public var outputTail: String

    public init(
        id: UUID = UUID(),
        specID: UUID,
        name: String,
        displayCommand: String,
        state: State = .running,
        startedAt: Date = .now,
        finishedAt: Date? = nil,
        outputTail: String = ""
    ) {
        self.id = id
        self.specID = specID
        self.name = name
        self.displayCommand = displayCommand
        self.state = state
        self.startedAt = startedAt
        self.finishedAt = finishedAt
        self.outputTail = outputTail
    }

    public var duration: TimeInterval {
        (finishedAt ?? .now).timeIntervalSince(startedAt)
    }
}

/// Executes user-configured commands.
public protocol CommandExecuting: Sendable {
    func execute(_ spec: CommandSpec, defaultWorkingDirectory: String?) async -> CommandRun
}

/// Runs `CommandSpec`s, re-validating each one immediately before launch.
public actor CommandRunner: CommandExecuting {
    private let runner: any ProcessRunning
    private let locator: ToolLocator
    /// Lines of output retained per run.
    private static let outputTailLineLimit = 12

    public init(runner: any ProcessRunning, locator: ToolLocator) {
        self.runner = runner
        self.locator = locator
    }

    public func execute(_ spec: CommandSpec, defaultWorkingDirectory: String?) async -> CommandRun {
        var run = CommandRun(
            specID: spec.id,
            name: spec.name,
            displayCommand: spec.displayCommand
        )

        // Re-validate at the moment of execution. The spec may have come from a
        // preferences file that changed on disk since it was loaded.
        if let reason = spec.validate() {
            run.state = .errored(.invalidConfiguration(reason: reason))
            run.finishedAt = .now
            return run
        }

        do {
            let command = try await buildCommand(spec, defaultWorkingDirectory: defaultWorkingDirectory)
            Log.commands.notice(
                "running \(spec.name, privacy: .public) [\(spec.mode.rawValue, privacy: .public)]"
            )
            let result = try await runner.run(command)
            run.outputTail = Self.tail(of: result.standardOutput + result.standardError)
            run.state = result.isSuccess ? .succeeded : .failed(exitCode: result.exitCode)
        } catch let error as ServiceError {
            run.state = .errored(error)
        } catch {
            run.state = .errored(.commandFailed(tool: spec.name, exitCode: -1, stderr: "\(error)"))
        }

        run.finishedAt = .now
        return run
    }

    private func buildCommand(
        _ spec: CommandSpec,
        defaultWorkingDirectory: String?
    ) async throws -> Command {
        let directory = spec.workingDirectory ?? defaultWorkingDirectory

        switch spec.mode {
        case .direct:
            // Absolute paths are used as given; bare names go through the
            // locator so Homebrew installs resolve even though a GUI app does
            // not inherit the user's shell PATH.
            let executable = spec.executable.hasPrefix("/")
                ? spec.executable
                : try await locator.require(spec.executable)
            return Command(
                executable: executable,
                arguments: spec.arguments,
                workingDirectory: directory,
                timeout: spec.timeout
            )

        case .shell:
            // The script is passed as a single argv entry to `sh -c`. It is
            // never concatenated with any other value — no repository name, no
            // branch, no API response is interpolated into it — so the only
            // thing that can run is what the user typed and confirmed.
            return Command(
                executable: "/bin/sh",
                arguments: ["-c", spec.script],
                workingDirectory: directory,
                timeout: spec.timeout
            )
        }
    }

    /// Last few lines of output, for the status row.
    static func tail(of output: String) -> String {
        let lines = output
            .split(separator: "\n", omittingEmptySubsequences: false)
            .filter { !$0.trimmingCharacters(in: .whitespaces).isEmpty }
        return lines.suffix(outputTailLineLimit).joined(separator: "\n")
    }
}
