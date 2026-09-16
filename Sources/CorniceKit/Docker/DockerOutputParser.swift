import Foundation

/// Parses `docker ps --format '{{json .}}'` output.
public enum DockerOutputParser {

    /// Parses newline-delimited JSON objects into container summaries.
    ///
    /// Line-by-line rather than as one document, because that is the shape
    /// Docker emits. A single malformed line is skipped instead of failing the
    /// whole list: Docker occasionally interleaves warnings on stdout, and one
    /// bad line should not empty the panel.
    public static func parseContainers(_ output: String) -> [ContainerSummary] {
        output
            .split(separator: "\n", omittingEmptySubsequences: true)
            .compactMap { line -> ContainerSummary? in
                guard let data = line.data(using: .utf8),
                      let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
                else { return nil }
                return parseContainer(object)
            }
    }

    static func parseContainer(_ object: [String: Any]) -> ContainerSummary? {
        guard let id = object["ID"] as? String, !id.isEmpty else { return nil }
        // `docker ps` joins multiple names with commas; the first is canonical.
        let rawName = object["Names"] as? String ?? ""
        let name = rawName.split(separator: ",").first.map(String.init) ?? id
        return ContainerSummary(
            id: id,
            name: name,
            status: object["Status"] as? String ?? "unknown",
            image: object["Image"] as? String ?? "",
            publishedPorts: parsePorts(object["Ports"] as? String ?? "")
        )
    }

    /// Extracts host ports from Docker's port-mapping string.
    ///
    /// The format is a comma-separated list such as
    /// `0.0.0.0:8080->80/tcp, [::]:8080->80/tcp, 9229/tcp`. Only mappings with
    /// an arrow are reachable from the host — a bare `9229/tcp` is exposed
    /// inside the container network but not published — so opening a browser at
    /// one would fail. IPv4 and IPv6 mappings of the same port are deduplicated.
    static func parsePorts(_ raw: String) -> [Int] {
        var ports = Set<Int>()
        for mapping in raw.split(separator: ",") {
            let trimmed = mapping.trimmingCharacters(in: .whitespaces)
            guard let arrow = trimmed.range(of: "->") else { continue }
            let hostSide = trimmed[trimmed.startIndex..<arrow.lowerBound]
            guard let separator = hostSide.lastIndex(of: ":") else { continue }
            let portText = hostSide[hostSide.index(after: separator)...]
            if let port = Int(portText), (1...65_535).contains(port) {
                ports.insert(port)
            }
        }
        return ports.sorted()
    }

    /// Docker container IDs are lowercase hex, 12 or 64 characters.
    public static func isValidContainerID(_ id: String) -> Bool {
        guard (12...64).contains(id.count) else { return false }
        return id.allSatisfy { $0.isHexDigit && !$0.isUppercase }
    }
}
