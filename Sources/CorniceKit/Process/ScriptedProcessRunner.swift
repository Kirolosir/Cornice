import Foundation

/// A `ProcessRunning` whose responses are supplied by the test.
///
/// Ships in the library rather than the test target so SwiftUI previews and the
/// `--demo` launch mode can drive the whole app from canned output without any
/// of the real services running.
public actor ScriptedProcessRunner: ProcessRunning {

    /// How to answer one invocation.
    public enum Response: Sendable {
        case success(stdout: String, stderr: String = "")
        case failure(exitCode: Int32, stderr: String)
        case error(ServiceError)
        /// Waits before answering, for exercising timeout and cancellation paths.
        case delayed(Duration, then: CommandResult)
    }

    /// Matches an invocation. Matching on the argument list rather than on call
    /// order keeps tests readable when a service issues several git commands
    /// whose order is an implementation detail.
    public struct Rule: Sendable {
        let matches: @Sendable (Command) -> Bool
        let response: Response

        public init(response: Response, matches: @escaping @Sendable (Command) -> Bool) {
            self.matches = matches
            self.response = response
        }

        /// Matches when every fragment appears in the executable path or arguments.
        public static func containing(_ fragments: [String], _ response: Response) -> Rule {
            Rule(response: response) { command in
                let haystack = ([command.executable] + command.arguments).joined(separator: " ")
                return fragments.allSatisfy { haystack.contains($0) }
            }
        }
    }

    private var rules: [Rule]
    private var fallback: Response
    /// Every command received, in order, for assertions about what ran and,
    /// importantly, what did *not* run when a cache should have served the call.
    public private(set) var invocations: [Command] = []

    public init(rules: [Rule] = [], fallback: Response = .success(stdout: "")) {
        self.rules = rules
        self.fallback = fallback
    }

    public func setRules(_ rules: [Rule]) { self.rules = rules }
    public func setFallback(_ response: Response) { self.fallback = response }
    public func reset() { invocations.removeAll() }

    /// Number of invocations whose joined arguments contain `fragment`.
    public func invocationCount(containing fragment: String) -> Int {
        invocations.filter { ([$0.executable] + $0.arguments).joined(separator: " ").contains(fragment) }.count
    }

    public func run(_ command: Command) async throws -> CommandResult {
        invocations.append(command)
        let response = rules.first { $0.matches(command) }?.response ?? fallback
        switch response {
        case .success(let stdout, let stderr):
            return CommandResult(exitCode: 0, standardOutput: stdout, standardError: stderr, duration: 0.001)
        case .failure(let code, let stderr):
            return CommandResult(exitCode: code, standardOutput: "", standardError: stderr, duration: 0.001)
        case .error(let error):
            throw error
        case .delayed(let duration, let result):
            try await Task.sleep(for: duration)
            return result
        }
    }
}
