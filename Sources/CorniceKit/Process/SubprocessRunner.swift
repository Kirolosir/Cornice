import Foundation

/// Runs real subprocesses with a timeout, a cancellation path, and a cap on
/// captured output.
///
/// The awkward part of running a process from Swift concurrency is that three
/// things finish independently (stdout reaching EOF, stderr reaching EOF, and
/// the process exiting), and the continuation must be resumed exactly once
/// after all three, or after a timeout or cancellation pre-empts them. All of
/// that bookkeeping lives in `RunState`, which is the only place a lock is
/// taken.
///
/// Reads happen on a dedicated dispatch queue rather than in detached tasks.
/// `readDataToEndOfFile` blocks, and blocking a thread from Swift's cooperative
/// pool is precisely the thing that deadlocks a concurrency-heavy app: the pool
/// is sized to the core count, and this app can have a git refresh, a port
/// scan, and a docker query in flight at once.
public struct SubprocessRunner: ProcessRunning {

    /// Grace period between SIGTERM and SIGKILL when a command overruns.
    private static let killGrace: TimeInterval = 1.5

    /// Dedicated queue for blocking pipe reads and process waits.
    private static let ioQueue = DispatchQueue(
        label: "dev.cornice.subprocess.io",
        qos: .utility,
        attributes: .concurrent
    )

    /// Base environment handed to every child.
    ///
    /// Built from scratch rather than inherited so behaviour does not change
    /// depending on how the app was launched. `HOME` is needed for git to find
    /// the user's global config; `LC_ALL=C` keeps git's output in the stable
    /// machine-readable spelling that the parsers expect regardless of the
    /// user's locale.
    private static var baseEnvironment: [String: String] {
        [
            "PATH": ToolLocator.searchPaths.joined(separator: ":"),
            "HOME": NSHomeDirectory(),
            "LC_ALL": "C",
            "LANG": "C",
            // Stops git from ever trying to open an interactive credential or
            // editor prompt, which would hang until the timeout fired.
            "GIT_TERMINAL_PROMPT": "0",
            "GIT_OPTIONAL_LOCKS": "0",
        ]
    }

    public init() {}

    public func run(_ command: Command) async throws -> CommandResult {
        try Task.checkCancellation()

        guard FileManager.default.isExecutableFile(atPath: command.executable) else {
            throw ServiceError.toolUnavailable(tool: command.toolName)
        }
        if let directory = command.workingDirectory {
            var isDirectory: ObjCBool = false
            guard FileManager.default.fileExists(atPath: directory, isDirectory: &isDirectory),
                  isDirectory.boolValue
            else {
                throw ServiceError.invalidPath(path: directory, reason: "not a directory")
            }
        }

        let state = RunState(command: command)
        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                state.start(continuation: continuation, killGrace: Self.killGrace, queue: Self.ioQueue)
            }
        } onCancel: {
            state.cancel()
        }
    }

    /// Owns one running process and the three-way completion handshake.
    ///
    /// `@unchecked Sendable` because correctness here rests on the lock rather
    /// than on the compiler: every mutable field is touched only inside
    /// `lock`, and the continuation is resumed outside it so a resumed task
    /// can never re-enter and deadlock.
    private final class RunState: @unchecked Sendable {
        private let command: Command
        private let lock = NSLock()
        private let process = Process()

        private var continuation: CheckedContinuation<CommandResult, any Error>?
        private var standardOutput = Data()
        private var standardError = Data()
        private var truncated = false
        private var outputClosed = false
        private var errorClosed = false
        private var exited = false
        private var outcome: Outcome = .pending
        private var startedAt = Date()

        private enum Outcome {
            case pending
            case timedOut
            case cancelled
            case launchFailed(any Error)
        }

        init(command: Command) {
            self.command = command
        }

        func start(
            continuation: CheckedContinuation<CommandResult, any Error>,
            killGrace: TimeInterval,
            queue: DispatchQueue
        ) {
            let outputPipe = Pipe()
            let errorPipe = Pipe()

            lock.lock()
            self.continuation = continuation
            startedAt = Date()
            lock.unlock()

            process.executableURL = URL(fileURLWithPath: command.executable)
            process.arguments = command.arguments
            process.standardOutput = outputPipe
            process.standardError = errorPipe
            // No stdin: a child that reads from the terminal gets EOF
            // immediately rather than blocking until the timeout.
            process.standardInput = FileHandle.nullDevice
            process.environment = SubprocessRunner.baseEnvironment.merging(
                command.environment, uniquingKeysWith: { _, override in override }
            )
            if let directory = command.workingDirectory {
                process.currentDirectoryURL = URL(fileURLWithPath: directory)
            }
            process.terminationHandler = { [weak self] _ in
                self?.markExited()
            }

            do {
                try process.run()
            } catch {
                lock.lock()
                outcome = .launchFailed(error)
                outputClosed = true
                errorClosed = true
                exited = true
                lock.unlock()
                finishIfReady()
                return
            }

            queue.async { [weak self] in
                let data = outputPipe.fileHandleForReading.readDataToEndOfFile()
                self?.appendOutput(data)
            }
            queue.async { [weak self] in
                let data = errorPipe.fileHandleForReading.readDataToEndOfFile()
                self?.appendError(data)
            }
            queue.asyncAfter(deadline: .now() + command.timeout) { [weak self] in
                self?.expire(killGrace: killGrace, queue: queue)
            }
        }

        private func appendOutput(_ data: Data) {
            lock.lock()
            let room = command.maxOutputBytes - standardOutput.count
            if data.count > room {
                standardOutput.append(data.prefix(max(0, room)))
                truncated = true
            } else {
                standardOutput.append(data)
            }
            outputClosed = true
            lock.unlock()
            finishIfReady()
        }

        private func appendError(_ data: Data) {
            lock.lock()
            let room = command.maxOutputBytes - standardError.count
            if data.count > room {
                standardError.append(data.prefix(max(0, room)))
                truncated = true
            } else {
                standardError.append(data)
            }
            errorClosed = true
            lock.unlock()
            finishIfReady()
        }

        private func markExited() {
            lock.lock()
            exited = true
            lock.unlock()
            finishIfReady()
        }

        /// Timeout fired. SIGTERM first so the child can clean up, SIGKILL after
        /// a grace period if it ignores that. The continuation is not resumed
        /// here. It resumes through the normal path once the pipes close, which
        /// guarantees we never resume while a read is still running.
        private func expire(killGrace: TimeInterval, queue: DispatchQueue) {
            lock.lock()
            let alreadyDone = continuation == nil || exited
            if case .pending = outcome, !alreadyDone {
                outcome = .timedOut
            }
            lock.unlock()
            guard !alreadyDone, process.isRunning else { return }

            Log.process.notice(
                "timeout after \(self.command.timeout, format: .fixed(precision: 1))s: \(self.command.toolName, privacy: .public)"
            )
            process.terminate()
            queue.asyncAfter(deadline: .now() + killGrace) { [weak self] in
                guard let self, self.process.isRunning else { return }
                kill(self.process.processIdentifier, SIGKILL)
            }
        }

        /// The enclosing `Task` was cancelled. Same escalation as a timeout.
        func cancel() {
            lock.lock()
            if case .pending = outcome { outcome = .cancelled }
            let running = continuation != nil
            lock.unlock()
            guard running, process.isRunning else { return }
            process.terminate()
        }

        /// Resumes the continuation once stdout, stderr, and the process itself
        /// have all finished, and exactly once, because taking the continuation
        /// out of the field under the lock is what makes the second caller a
        /// no-op.
        private func finishIfReady() {
            lock.lock()
            guard outputClosed, errorClosed, exited, let continuation else {
                lock.unlock()
                return
            }
            self.continuation = nil
            let result = CommandResult(
                exitCode: process.terminationStatus,
                standardOutput: String(decoding: standardOutput, as: UTF8.self),
                standardError: String(decoding: standardError, as: UTF8.self),
                duration: Date().timeIntervalSince(startedAt),
                wasTruncated: truncated
            )
            let outcome = self.outcome
            lock.unlock()

            switch outcome {
            case .pending:
                continuation.resume(returning: result)
            case .timedOut:
                continuation.resume(
                    throwing: ServiceError.timedOut(tool: command.toolName, seconds: command.timeout)
                )
            case .cancelled:
                continuation.resume(throwing: ServiceError.cancelled)
            case .launchFailed(let error):
                Log.process.error(
                    "launch failed for \(self.command.toolName, privacy: .public): \(error.localizedDescription, privacy: .public)"
                )
                continuation.resume(
                    throwing: ServiceError.toolUnavailable(tool: command.toolName)
                )
            }
        }
    }
}
