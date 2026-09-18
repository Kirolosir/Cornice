import Foundation
import AppKit

/// Executes AppleScript in-process.
///
/// `NSAppleScript` rather than spawning `osascript`: the player is polled about
/// once a second, and a process launch per poll would cost several milliseconds
/// of CPU and a fork for something that takes microseconds in-process. Scripts
/// are compiled once and reused, so the per-poll cost is just the Apple event
/// round-trip to the player.
///
/// Everything runs on one serial queue. `NSAppleScript` is not thread-safe and
/// is not `Sendable`; confining it to a single queue is what makes it safe to
/// call from an actor without the compiler having to take our word for it.
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

    /// What a script returned, reduced to `Sendable` values.
    ///
    /// The raw `NSAppleEventDescriptor` never leaves the execution queue: it
    /// is not `Sendable`, and it is a detail of how the answer was obtained
    /// rather than part of the answer. Both possible shapes (a delimited
    /// string, or raw artwork bytes) are extracted before returning.
    public struct ScriptResult: Sendable {
        public let string: String?
        public let data: Data?
    }

    /// Runs a script and returns its result.
    ///
    /// - Parameter target: the application being scripted, used only to record
    ///   an authorisation denial against it.
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

    /// Maps AppleScript's error dictionary onto a `ServiceError`.
    ///
    /// The codes that matter:
    /// `-1743` is "user has not allowed automation", which is a permission
    /// problem the user can fix; `-600` and `-609` mean the application is not
    /// running, which is normal rather than an error; `-1728` means the object
    /// does not exist, which happens when a player is open with nothing loaded.
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

    /// Whether an application is running, without launching it.
    ///
    /// Checked through `NSWorkspace` rather than by scripting: asking a stopped
    /// application anything through AppleScript *launches* it, which is a
    /// spectacularly bad thing for a background poller to do. This also needs no
    /// permission at all.
    public nonisolated static func isRunning(bundleIdentifier: String) -> Bool {
        !NSRunningApplication.runningApplications(withBundleIdentifier: bundleIdentifier).isEmpty
    }
}
