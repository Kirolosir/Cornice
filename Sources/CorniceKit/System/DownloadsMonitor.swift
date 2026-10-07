import Foundation

/// Watch browser download files such as .crdownload, .download and .part. Start only when
/// enabled because Downloads access can ask for permission. Only show a percentage if the
/// expected size is known.
public final class DownloadsMonitor: @unchecked Sendable {

    public struct Progress: Equatable, Sendable {
        /// The eventual filename, with the in-progress suffix removed.
        public let name: String
        public let bytesReceived: Int64
        /// 0...1 when the source publishes an expected size, `nil` otherwise.
        public let fraction: Double?
        public let bytesPerSecond: Double

        public init(name: String, bytesReceived: Int64, fraction: Double?, bytesPerSecond: Double) {
            self.name = name
            self.bytesReceived = bytesReceived
            self.fraction = fraction
            self.bytesPerSecond = bytesPerSecond
        }
    }

    /// `nil` means nothing is downloading any more.
    public typealias ChangeHandler = @Sendable (Progress?) -> Void

    private static let suffixes = ["crdownload", "download", "part", "partial", "opdownload"]

    private let directory: URL
    private let queue = DispatchQueue(label: "dev.cornice.downloads", qos: .utility)
    private let lock = NSLock()

    private var handler: ChangeHandler?
    private var poller: DispatchSourceTimer?
    private var lastSample: (name: String, bytes: Int64, at: Date)?
    private var lastPublished: Progress?

    public init(directory: URL? = nil) {
        self.directory = directory
            ?? FileManager.default.urls(for: .downloadsDirectory, in: .userDomainMask).first
            ?? URL(fileURLWithPath: NSHomeDirectory()).appendingPathComponent("Downloads")
    }

    public func start(onChange: @escaping ChangeHandler) {
        lock.lock()
        guard poller == nil else { lock.unlock(); return }
        handler = onChange
        lock.unlock()

        // Poll at a known interval to calculate speed from file growth. A file-change event
        // alone doesn't give a transfer rate.
        let timer = DispatchSource.makeTimerSource(queue: queue)
        timer.schedule(deadline: .now(), repeating: 1.0)
        timer.setEventHandler { [weak self] in self?.sample() }
        timer.resume()

        lock.lock()
        poller = timer
        lock.unlock()
    }

    public func stop() {
        lock.lock()
        poller?.cancel()
        poller = nil
        handler = nil
        lastSample = nil
        lastPublished = nil
        lock.unlock()
    }

    private func sample() {
        let now = Date()
        guard let candidate = largestInProgressFile() else {
            lock.lock()
            let hadOne = lastPublished != nil
            lastSample = nil
            lastPublished = nil
            let handler = self.handler
            lock.unlock()
            if hadOne { handler?(nil) }
            return
        }

        lock.lock()
        let previous = lastSample
        var rate: Double = 0
        if let previous, previous.name == candidate.name {
            let elapsed = now.timeIntervalSince(previous.at)
            if elapsed > 0 {
                rate = max(0, Double(candidate.bytes - previous.bytes) / elapsed)
            }
        }
        lastSample = (candidate.name, candidate.bytes, now)

        let progress = Progress(
            name: candidate.name,
            bytesReceived: candidate.bytes,
            fraction: candidate.expected.map { expected in
                expected > 0 ? min(1, Double(candidate.bytes) / Double(expected)) : 0
            },
            bytesPerSecond: rate
        )
        lastPublished = progress
        let handler = self.handler
        lock.unlock()

        handler?(progress)
    }

    /// The biggest in-progress download, which is the one worth showing.
    private func largestInProgressFile() -> (name: String, bytes: Int64, expected: Int64?)? {
        let manager = FileManager.default
        guard let entries = try? manager.contentsOfDirectory(
            at: directory,
            includingPropertiesForKeys: [.fileSizeKey, .totalFileAllocatedSizeKey, .isDirectoryKey],
            options: [.skipsHiddenFiles]
        ) else { return nil }

        var best: (name: String, bytes: Int64, expected: Int64?)?
        for url in entries {
            let suffix = url.pathExtension.lowercased()
            guard Self.suffixes.contains(suffix) else { continue }

            let bytes = Self.size(of: url)
            guard bytes > 0 else { continue }
            let name = url.deletingPathExtension().lastPathComponent
            let candidate = (name: name, bytes: bytes, expected: Self.expectedSize(of: url))
            if best == nil || bytes > best!.bytes { best = candidate }
        }
        return best
    }

    /// Bytes on disk, summing a package's contents when the temporary file is a
    /// directory, which is what Safari's `.download` is.
    private static func size(of url: URL) -> Int64 {
        let manager = FileManager.default
        var isDirectory: ObjCBool = false
        guard manager.fileExists(atPath: url.path, isDirectory: &isDirectory) else { return 0 }

        if !isDirectory.boolValue {
            let values = try? url.resourceValues(forKeys: [.fileSizeKey])
            return Int64(values?.fileSize ?? 0)
        }

        guard let enumerator = manager.enumerator(
            at: url, includingPropertiesForKeys: [.fileSizeKey], options: [.skipsHiddenFiles]
        ) else { return 0 }

        var total: Int64 = 0
        for case let child as URL in enumerator {
            let values = try? child.resourceValues(forKeys: [.fileSizeKey])
            total += Int64(values?.fileSize ?? 0)
        }
        return total
    }

    /// Read expected size from Safari's download package. For browsers that don't expose it
    /// here, show bytes received instead of guessing a percentage.
    private static func expectedSize(of url: URL) -> Int64? {
        guard url.pathExtension.lowercased() == "download" else { return nil }
        let plist = url.appendingPathComponent("Info.plist")
        guard let data = try? Data(contentsOf: plist),
              let root = try? PropertyListSerialization.propertyList(
                  from: data, options: [], format: nil
              ) as? [String: Any]
        else { return nil }

        for key in ["NSURLDownloadExpectedLength", "DownloadEntryProgressTotalToLoad"] {
            if let value = root[key] as? Int64, value > 0 { return value }
            if let value = root[key] as? Int, value > 0 { return Int64(value) }
        }
        return nil
    }
}
