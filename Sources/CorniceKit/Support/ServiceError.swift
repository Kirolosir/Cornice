import Foundation

/// The single error type surfaced by every `CorniceKit` service.
///
/// Modules in the UI are rendered independently, and each one renders its own
/// error. Keeping one exhaustive enum means the presentation layer can map an
/// error to a headline, a detail line, and a recovery affordance without every
/// view knowing about every service's private failure modes.
public enum ServiceError: Error, Equatable, Sendable {
    /// A required command-line tool is not installed or not on the search path.
    case toolUnavailable(tool: String)
    /// The tool ran but exited non-zero. `stderr` is truncated and never contains secrets.
    case commandFailed(tool: String, exitCode: Int32, stderr: String)
    /// The tool exceeded its wall-clock budget and was terminated.
    case timedOut(tool: String, seconds: Double)
    /// A path we were told to use no longer exists, or is not what we expect.
    case invalidPath(path: String, reason: String)
    /// Output parsed into something we did not expect. Carries a short hint, not the payload.
    case unreadableOutput(tool: String, hint: String)
    /// The network is unreachable, or the request could not leave the machine.
    case offline
    /// Credentials are missing, expired, or rejected.
    case unauthorized(detail: String)
    /// The remote API refused the request because of rate limiting.
    case rateLimited(resetAt: Date?)
    /// A well-formed API error response.
    case api(status: Int, message: String)
    /// The operation was cancelled (usually by a newer request superseding it).
    case cancelled
    /// A user-supplied configuration value failed validation.
    case invalidConfiguration(reason: String)

    /// Short, human-readable headline for the UI.
    public var headline: String {
        switch self {
        case .toolUnavailable(let tool): "\(tool) not found"
        case .commandFailed(let tool, let code, _): "\(tool) exited \(code)"
        case .timedOut(let tool, _): "\(tool) timed out"
        case .invalidPath: "Path unavailable"
        case .unreadableOutput(let tool, _): "Unexpected \(tool) output"
        case .offline: "Offline"
        case .unauthorized: "Not authorized"
        case .rateLimited: "Rate limited"
        case .api(let status, _): "GitHub error \(status)"
        case .cancelled: "Cancelled"
        case .invalidConfiguration: "Invalid configuration"
        }
    }

    /// Longer explanation, safe to show in a tooltip or detail row.
    public var detail: String {
        switch self {
        case .toolUnavailable(let tool):
            "Install \(tool) or make sure it is on the PATH Cornice searches."
        case .commandFailed(_, _, let stderr):
            stderr.isEmpty ? "The command reported no diagnostics." : stderr
        case .timedOut(_, let seconds):
            "No response after \(Int(seconds))s. The command was terminated."
        case .invalidPath(let path, let reason):
            "\(Redaction.path(path)) — \(reason)"
        case .unreadableOutput(_, let hint):
            hint
        case .offline:
            "No network route. Cached values are shown where available."
        case .unauthorized(let detail):
            detail
        case .rateLimited(let resetAt):
            if let resetAt, resetAt > .now {
                "Quota exhausted. Resets in \(Format.duration(resetAt.timeIntervalSinceNow))."
            } else {
                "Quota exhausted."
            }
        case .api(_, let message):
            message
        case .cancelled:
            "Superseded by a newer request."
        case .invalidConfiguration(let reason):
            reason
        }
    }

    /// Whether retrying immediately could plausibly succeed. Drives whether the
    /// UI offers a "Retry" affordance.
    public var isRetryable: Bool {
        switch self {
        case .timedOut, .offline, .api, .commandFailed: true
        case .rateLimited(let resetAt): resetAt.map { $0 <= .now } ?? false
        case .toolUnavailable, .invalidPath, .unreadableOutput, .unauthorized,
             .cancelled, .invalidConfiguration: false
        }
    }
}
