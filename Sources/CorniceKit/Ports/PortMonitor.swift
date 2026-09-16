import Foundation

public protocol PortMonitoring: Sendable {
    func scan(ports: [MonitoredPort]) async throws -> [PortStatus]
    /// Sends SIGTERM to a listener. The caller must have confirmed with the user.
    func terminate(pid: Int32) async throws
}

/// A port the user asked us to watch.
public struct MonitoredPort: Equatable, Sendable, Codable, Identifiable {
    public var port: Int
    public var label: String?
    public var id: Int { port }

    public init(port: Int, label: String? = nil) {
        self.port = port
        self.label = label
    }

    /// Ports a developer machine typically serves from, used for first-run defaults.
    public static let defaults: [MonitoredPort] = [
        MonitoredPort(port: 3000, label: "Node / Next"),
        MonitoredPort(port: 5173, label: "Vite"),
        MonitoredPort(port: 8000, label: "Django / FastAPI"),
        MonitoredPort(port: 8080, label: "JVM / proxy"),
    ]
}

/// Detects which monitored ports have something listening on them.
///
/// The significant design decision is that this runs **one** `lsof` for every
/// port rather than one per port. `lsof` is not cheap — it walks every open file
/// descriptor on the system — so four ports polled separately every few seconds
/// is four process spawns and four full descriptor walks. One call filtered
/// in-process costs the same as checking a single port and scales to any number
/// of monitored ports for free.
public actor PortMonitor: PortMonitoring {
    private let runner: any ProcessRunning
    private let locator: ToolLocator

    /// Serialises overlapping scans. A refresh tick that arrives while the
    /// previous scan is still running joins that scan instead of starting a
    /// second one, which is what stops a slow `lsof` from queueing up behind
    /// itself and pinning a core.
    private var inFlight: Task<[Int: ListeningProcess], any Error>?

    public init(runner: any ProcessRunning, locator: ToolLocator) {
        self.runner = runner
        self.locator = locator
    }

    public func scan(ports: [MonitoredPort]) async throws -> [PortStatus] {
        guard !ports.isEmpty else { return [] }
        let listeners = try await listeners()
        let now = Date()

        let matched = ports.map { monitored in
            PortStatus(
                port: monitored.port,
                label: monitored.label,
                listener: listeners[monitored.port],
                checkedAt: now
            )
        }

        // Only the ports we are actually showing need an uptime, so the extra
        // `ps` call is skipped entirely when nothing is listening — the common
        // case when no dev server is running.
        let activePids = matched.compactMap(\.listener?.pid)
        guard !activePids.isEmpty else { return matched }

        let uptimes = await uptimes(for: activePids)
        return matched.map { status in
            guard var listener = status.listener, let uptime = uptimes[listener.pid] else { return status }
            listener.uptime = uptime
            return PortStatus(
                port: status.port,
                label: status.label,
                listener: listener,
                checkedAt: status.checkedAt
            )
        }
    }

    /// One `lsof` invocation covering every listening TCP socket.
    private func listeners() async throws -> [Int: ListeningProcess] {
        if let inFlight { return try await inFlight.value }

        let task = Task { [runner, locator] () throws -> [Int: ListeningProcess] in
            let lsof = try await locator.require("lsof")
            let result = try await runner.run(
                Command(
                    executable: lsof,
                    // -n and -P skip DNS and service-name lookups; without them
                    // lsof can block for seconds on a slow resolver.
                    arguments: ["-nP", "-iTCP", "-sTCP:LISTEN", "-FpcnL"],
                    timeout: 6
                )
            )
            // lsof exits 1 when it finds nothing at all, which is a normal
            // state rather than a failure, so the exit code is not checked.
            return LsofParser.parseListeners(result.standardOutput)
        }
        inFlight = task
        defer { inFlight = nil }
        return try await task.value
    }

    /// Best-effort uptimes. A failure here costs a label, not the whole scan,
    /// so it degrades to an empty map rather than throwing.
    private func uptimes(for pids: [Int32]) async -> [Int32: TimeInterval] {
        do {
            let ps = try await locator.require("ps")
            let result = try await runner.run(
                Command(
                    executable: ps,
                    arguments: ["-o", "pid=,etime=", "-p", pids.map(String.init).joined(separator: ",")],
                    timeout: 4
                )
            )
            return LsofParser.parseUptimes(result.standardOutput)
        } catch {
            Log.ports.debug("uptime lookup failed; continuing without it")
            return [:]
        }
    }

    /// Terminates a listener with SIGTERM.
    ///
    /// SIGTERM rather than SIGKILL so a dev server gets to run its shutdown
    /// handlers and release the port cleanly. There is deliberately no escalation
    /// to SIGKILL: silently force-killing a process the user asked to "stop" is
    /// a good way to lose unsaved state in a long-running job.
    public func terminate(pid: Int32) async throws {
        guard pid > 1 else {
            throw ServiceError.invalidConfiguration(reason: "refusing to signal pid \(pid)")
        }
        // Signal only processes owned by this user. `kill` would fail anyway,
        // but failing here keeps the error specific instead of "operation not permitted".
        guard Self.isOwnedByCurrentUser(pid: pid) else {
            throw ServiceError.invalidConfiguration(
                reason: "process \(pid) is not owned by the current user"
            )
        }
        Log.ports.notice("sending SIGTERM to pid \(pid)")
        guard kill(pid, SIGTERM) == 0 else {
            throw ServiceError.commandFailed(
                tool: "kill", exitCode: errno, stderr: String(cString: strerror(errno))
            )
        }
    }

    private static func isOwnedByCurrentUser(pid: Int32) -> Bool {
        var info = kinfo_proc()
        var size = MemoryLayout<kinfo_proc>.stride
        var mib: [Int32] = [CTL_KERN, KERN_PROC, KERN_PROC_PID, pid]
        guard sysctl(&mib, 4, &info, &size, nil, 0) == 0, size > 0 else { return false }
        return info.kp_eproc.e_ucred.cr_uid == getuid()
    }
}
