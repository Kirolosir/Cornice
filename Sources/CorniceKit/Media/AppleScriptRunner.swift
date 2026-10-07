import Foundation
import AppKit

/// Compile and reuse NSAppleScript objects instead of launching osascript on every poll.
/// Run them on one serial queue because they aren't thread-safe.
public actor AppleScriptRunner {

    /// Holds compiled scripts. `@unchecked Sendable` because the instances are
    /// only ever touched on `queue`, never concurrently.
    private final class ScriptBox: @unchecked Sendable {
        var scripts: [String: NSAppleScript] = [:]
    }

    private let box = ScriptBox()
    private let queue = DispatchQueue(label: "dev.cornice.applescript", qos: .userInitiated)

    /// Set once a call fails with "not authorised", so we stop re-triggering a
    /// prompt the user has already answered.
    private var deniedTargets: Set<String> = []

    public init() {}

    /// Whether automation of this target was refused.
    public func isDenied(_ target: String) -> Bool { deniedTargets.contains(target) }

    /// Clears a denial so the next call re-asks. Used after the user says they
    /// have granted permission in System Settings.
    public func clearDenial(_ target: String) { deniedTargets.remove(target) }

    /// Return only Sendable values. Keep the Apple event descriptor on the execution queue
    /// and extract its text or image bytes there.
    public struct ScriptResult: Sendable {
        public let string: String?
        public let data: Data?
    }

    /// Run a script and return its result.
    ///
    /// - Parameter target: Player name used when reporting an automation denial.
    public func run(_ source: String, target: String) async throws -> ScriptResult {
        if deniedTargets.contains(target) {
            throw ServiceError.unauthorized(
                detail: "Cornice is not allowed to control \(target). Grant it in System Settings › Privacy & Security › Automation."
            )
        }

        do {
            return try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<ScriptResult, any Error>) in
                queue.async { [box] in
                    let script: NSAppleScript
                    if let cached = box.scripts[source] {
                        script = cached
                    } else {
                        guard let compiled = NSAppleScript(source: source) else {
                            continuation.resume(throwing: ServiceError.invalidConfiguration(
                                reason: "could not compile script"
                            ))
                            return
                        }
                        box.scripts[source] = compiled
                        script = compiled
                    }

                    var errorInfo: NSDictionary?
                    let descriptor = script.executeAndReturnError(&errorInfo)
                    if let errorInfo {
                        continuation.resume(throwing: Self.mapError(errorInfo, target: target))
                    } else {
                        let data = descriptor.descriptorType == typeNull ? nil : descriptor.data
                        continuation.resume(returning: ScriptResult(
                            string: descriptor.stringValue,
                            data: (data?.isEmpty ?? true) ? nil : data
                        ))
                    }
                }
            }
        } catch let error as ServiceError {
            if case .unauthorized = error { deniedTargets.insert(target) }
            throw error
        }
    }

    /// Translate AppleScript errors: -1743 means automation was denied, -600/-609 mean the
    /// player isn't running, and -1728 means the requested object is missing.
    private static func mapError(_ info: NSDictionary, target: String) -> ServiceError {
        let code = (info[NSAppleScript.errorNumber] as? Int) ?? 0
        let message = (info[NSAppleScript.errorMessage] as? String) ?? "AppleScript failed"

        switch code {
        case -1743, -10004:
            return .unauthorized(
                detail: "Cornice needs permission to control \(target). Open System Settings › Privacy & Security › Automation and enable it."
            )
        case -600, -609, -1728:
            return .invalidConfiguration(reason: "\(target) is not running or has nothing loaded")
        default:
            return .commandFailed(tool: target, exitCode: Int32(code), stderr: String(message.prefix(200)))
        }
    }

    /// Check NSWorkspace before scripting a player. Sending an Apple event to a stopped app
    /// can launch it.
    public nonisolated static func isRunning(bundleIdentifier: String) -> Bool {
        !NSRunningApplication.runningApplications(withBundleIdentifier: bundleIdentifier).isEmpty
    }
}
