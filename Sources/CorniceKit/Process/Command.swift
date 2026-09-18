import Foundation

/// A fully-specified subprocess invocation.
///
/// There is no shell anywhere in this type. `executable` is an absolute path and
/// `arguments` is an array that is passed to `execve` verbatim, so a branch
/// named `; rm -rf ~` is just an unusual branch name rather than a command. The
/// only place a shell is ever involved is `CommandSpec`, where the user has
/// explicitly configured one, and that path validates its input separately.
public struct Command: Sendable, Equatable {
    /// Absolute path to the binary. Resolved by `ToolLocator`, never by `$PATH`.
    public var executable: String
    public var arguments: [String]
    /// Directory to run in. Validated by the caller before it gets here.
    public var workingDirectory: String?
    /// Environment overlay. Merged onto a minimal base environment rather than
    /// inheriting the app's, so subprocess behaviour does not drift with
    /// whatever the launching context happened to export.
    public var environment: [String: String]
    /// Wall-clock budget. The process is terminated, then killed, on expiry.
    public var timeout: TimeInterval
    /// Cap on captured output. Prevents a runaway command from growing the
    /// app's memory without bound; anything past this is discarded and the
    /// result is flagged as truncated.
    public var maxOutputBytes: Int

    public init(
        executable: String,
        arguments: [String] = [],
        workingDirectory: String? = nil,
        environment: [String: String] = [:],
        timeout: TimeInterval = 10,
        maxOutputBytes: Int = 1 << 20
    ) {
        self.executable = executable
        self.arguments = arguments
        self.workingDirectory = workingDirectory
        self.environment = environment
        self.timeout = timeout
        self.maxOutputBytes = maxOutputBytes
    }

    /// Name used in errors and logs. The binary's basename, not the full path.
    public var toolName: String {
        (executable as NSString).lastPathComponent
    }
}

/// What a finished subprocess produced.
public struct CommandResult: Sendable, Equatable {
    public var exitCode: Int32
    public var standardOutput: String
    public var standardError: String
    /// Wall-clock time from spawn to exit, used for the latency measurements
    /// quoted in the README.
    public var duration: TimeInterval
    /// Whether output hit `maxOutputBytes` and was cut short.
    public var wasTruncated: Bool

    public init(
        exitCode: Int32,
        standardOutput: String,
        standardError: String,
        duration: TimeInterval,
        wasTruncated: Bool = false
    ) {
        self.exitCode = exitCode
        self.standardOutput = standardOutput
        self.standardError = standardError
        self.duration = duration
        self.wasTruncated = wasTruncated
    }

    public var isSuccess: Bool { exitCode == 0 }

    /// Trimmed stdout, which is what almost every caller actually wants.
    public var trimmedOutput: String {
        standardOutput.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// Converts a non-zero exit into a `ServiceError`, truncating stderr so a
    /// verbose failure cannot flood a tooltip or a log line.
    public func requireSuccess(tool: String) throws -> CommandResult {
        guard isSuccess else {
            let diagnostics = standardError.trimmingCharacters(in: .whitespacesAndNewlines)
            throw ServiceError.commandFailed(
                tool: tool,
                exitCode: exitCode,
                stderr: String(diagnostics.prefix(400))
            )
        }
        return self
    }
}

/// Runs subprocesses. Injected everywhere so services can be tested against a
/// scripted runner instead of the real filesystem.
public protocol ProcessRunning: Sendable {
    func run(_ command: Command) async throws -> CommandResult
}
