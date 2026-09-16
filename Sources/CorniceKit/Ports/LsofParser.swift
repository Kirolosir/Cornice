import Foundation

/// Parses `lsof` field-mode output.
///
/// Field mode (`-F`) is used rather than the default columns for two reasons:
/// the column output truncates process names to nine characters, so a Vite dev
/// server shows up as `node` but Control Center shows up as `ControlCe`; and
/// field output is a stable, documented format rather than whitespace-aligned
/// columns that break on any name containing a space.
///
/// The format is a stream of one-letter-tagged lines. A `p` line opens a
/// process record and `c`/`L` describe it; an `f` line opens a file record
/// within that process and `n` gives its address. Values therefore have to be
/// carried forward, which is the only subtle part of this parser.
public enum LsofParser {

    /// Extracts listeners keyed by port number.
    ///
    /// A port maps to a single process even though `lsof` usually reports it
    /// twice — once for the IPv4 socket and once for IPv6. The first record
    /// wins; they describe the same server.
    public static func parseListeners(_ output: String) -> [Int: ListeningProcess] {
        var listeners: [Int: ListeningProcess] = [:]
        var pid: Int32?
        var command = ""
        var user = ""

        for line in output.split(separator: "\n", omittingEmptySubsequences: true) {
            guard let tag = line.first else { continue }
            let value = line.dropFirst()

            switch tag {
            case "p":
                pid = Int32(value)
                // A new process record invalidates the previous one's fields.
                command = ""
                user = ""
            case "c":
                command = String(value)
            case "L":
                user = String(value)
            case "n":
                guard let pid, let (address, port) = splitAddress(String(value)) else { continue }
                guard listeners[port] == nil else { continue }
                listeners[port] = ListeningProcess(
                    pid: pid,
                    command: command,
                    user: user,
                    boundAddress: address
                )
            default:
                continue
            }
        }
        return listeners
    }

    /// Splits an `lsof` address into host and port.
    ///
    /// Handles `*:3000`, `127.0.0.1:8080`, `[::1]:5173`, and the bracketed IPv6
    /// form with a zone, `[fe80::1%en0]:8000`. Splitting on the *last* colon is
    /// what makes the IPv6 cases work, since those addresses are full of colons.
    static func splitAddress(_ raw: String) -> (address: String, port: Int)? {
        guard let separator = raw.lastIndex(of: ":") else { return nil }
        let host = String(raw[raw.startIndex..<separator])
        let portText = String(raw[raw.index(after: separator)...])
        guard let port = Int(portText), (1...65_535).contains(port) else { return nil }
        // Strip the brackets IPv6 literals are wrapped in.
        let address = host.hasPrefix("[") && host.hasSuffix("]")
            ? String(host.dropFirst().dropLast())
            : host
        return (address.isEmpty ? "*" : address, port)
    }

    /// Parses `ps -o pid=,etime=` output into per-pid uptimes.
    public static func parseUptimes(_ output: String) -> [Int32: TimeInterval] {
        var uptimes: [Int32: TimeInterval] = [:]
        for line in output.split(separator: "\n", omittingEmptySubsequences: true) {
            let fields = line.split(separator: " ", omittingEmptySubsequences: true)
            guard fields.count >= 2, let pid = Int32(fields[0]),
                  let seconds = parseElapsed(String(fields[1]))
            else { continue }
            uptimes[pid] = seconds
        }
        return uptimes
    }

    /// Converts `ps` elapsed-time notation to seconds.
    ///
    /// The format is `[[dd-]hh:]mm:ss`, so `05:12` is five minutes and
    /// `3-04:15:12` is three days. The day separator is a hyphen, not a colon,
    /// which is the part that catches naive splitting.
    static func parseElapsed(_ raw: String) -> TimeInterval? {
        var text = raw
        var days = 0
        if let hyphen = text.firstIndex(of: "-") {
            guard let parsed = Int(text[text.startIndex..<hyphen]) else { return nil }
            days = parsed
            text = String(text[text.index(after: hyphen)...])
        }
        let parts = text.split(separator: ":").map { Int($0) }
        guard !parts.contains(where: { $0 == nil }) else { return nil }
        let numbers = parts.compactMap { $0 }
        let seconds: Int
        switch numbers.count {
        case 2: seconds = numbers[0] * 60 + numbers[1]
        case 3: seconds = numbers[0] * 3600 + numbers[1] * 60 + numbers[2]
        default: return nil
        }
        return TimeInterval(days * 86_400 + seconds)
    }
}
